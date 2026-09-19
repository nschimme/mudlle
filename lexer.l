/*                                                                    -*- c -*-
 * Copyright (c) 1993-2012 David Gay and Gustav Hållberg
 * All rights reserved.
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose, without fee, and without written agreement is hereby granted,
 * provided that the above copyright notice and the following two paragraphs
 * appear in all copies of this software.
 *
 * IN NO EVENT SHALL DAVID GAY OR GUSTAV HALLBERG BE LIABLE TO ANY PARTY FOR
 * DIRECT, INDIRECT, SPECIAL, INCIDENTAL, OR CONSEQUENTIAL DAMAGES ARISING OUT
 * OF THE USE OF THIS SOFTWARE AND ITS DOCUMENTATION, EVEN IF DAVID GAY OR
 * GUSTAV HALLBERG HAVE BEEN ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 *
 * DAVID GAY AND GUSTAV HALLBERG SPECIFICALLY DISCLAIM ANY WARRANTIES,
 * INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND
 * FITNESS FOR A PARTICULAR PURPOSE.  THE SOFTWARE PROVIDED HEREUNDER IS ON AN
 * "AS IS" BASIS, AND DAVID GAY AND GUSTAV HALLBERG HAVE NO OBLIGATION TO
 * PROVIDE MAINTENANCE, SUPPORT, UPDATES, ENHANCEMENTS, OR MODIFICATIONS.
 */

%top{
#include "mudlle-config.h"
}

%{
#include <ctype.h>
#include <string.h>
#include <unistd.h>

#include "calloc.h"
#include "charset.h"
#include "global.h"
#include "lexer.h"
#include "mparser.h"
#include "mvalues.h"
#include "strbuf.h"
#include "tree.h"
#include "utils.h"

#  include "parser.tab.h"

#define YY_USER_ACTION advance_location(yylloc);

#define LOCATION_STEP() do {                    \
  yylloc->first.col = yylloc->last_column;      \
  yylloc->first.pos = yylloc->last_pos;         \
  yylloc->first.line = yylloc->last_line;       \
} while (0)

#define LOCATION_NEWLINE() do {                 \
  yylloc->last_column = 1;                      \
  yylloc->last_line += 1;                       \
} while (0)
typedef size_t (*reader_fn)(void *ptr, size_t size, size_t nmemb,
                            FILE *stream);
static size_t string_read(void *ptr, size_t size, size_t nmemb, FILE *stream);

#undef YY_INPUT
#define YY_INPUT(buf, result, max_size) do {            \
  (result) = lstate.reader((buf), 1, (max_size), yyin); \
} while (0)

static void loc_add(struct loc *loc, int delta)
{
  loc->col += delta;
  loc->pos += delta;
}

static const char *base_name(int base);

static YY_BUFFER_STATE mbuf;

struct lexer_state {
  reader_fn reader;
  bool allow_comma_expr, track_comments;
  int start_token;
  struct lexer_str_state {
    size_t cstr;                /* current index into pconfig->strs[] */
    const char *cur;            /* current string */
    size_t len;                 /* chars remaining in 'cur' */
  } s;
  struct comment_list *comments;
  const struct parser_config *pconfig;
};

static struct lexer_state lstate;

struct lkeyword {
  const char *name;
  int value;
};

static const struct lkeyword keywords[] = {
  { "else",     ELSE },
  { "exit",     LOOP_EXIT },
  { "fn",       FUNCTION },
  { "for",      FOR },
  { "if",       IF_KEYWORD },
  { "loop",     LOOP },
  { "match!",   MATCH_FORCE },
  { "match",    MATCH },
  { "while",    WHILE },

  { "defines",  DEFINES },
  { "library",  LIBRARY },
  { "module",   MODULE },
  { "reads",    READS },
  { "requires", REQUIRES },
  { "static",   STATIC },
  { "writes",   WRITES },
};
#define NKEYWORDS VLENGTH(keywords)

#define STRING_START(is_char, is_triple) do {   \
  assert(cstring.loc.fname == NULL);            \
  cstring.loc = *LLOC_LOC(*yylloc);             \
  cstring.is_char_const = (is_char);            \
  cstring.is_triple_quote = (is_triple);        \
  sb_empty(&cstring.sb);                        \
} while (0)

#define END_STRING() do {                       \
  assert(cstring.loc.fname != NULL);            \
  cstring.loc.fname = NULL;                     \
} while (0)

#define STRING_ERROR(...) do {                  \
  struct loc loc = cstring.loc;                 \
  END_STRING();                                 \
  compile_error(&loc, __VA_ARGS__);             \
  yyterminate();                                \
} while (0)

#define UNTERMINATED_STRING()                                   \
  STRING_ERROR("unterminated %s constant",                      \
                cstring.is_char_const ? "character" : "string")

#define INVALID_FLOAT(msg) do {                 \
  cstring.loc.col += sb_len(&cstring.sb);       \
  STRING_ERROR(msg);                            \
} while (0)

static struct {
  struct strbuf sb;
  struct loc loc;
  bool is_char_const, is_triple_quote;
  unsigned raw_delim_len;       /* length of ###" prefix */
} cstring = { .sb = SBNULL };

static struct {
  YYLTYPE start;
  int level;
} ccomment;

#define lexer_error(...) do {                           \
  compile_error(LLOC_LOC(*yylloc), __VA_ARGS__);        \
  yyterminate();                                        \
} while (0)

#define END_FLOAT() do {                                                \
  if (!mudlle_strtofloat(sb_str(&cstring.sb),                           \
                         sb_len(&cstring.sb),                           \
                         &yylval->mudlle_float.d))                      \
    STRING_ERROR("illegal floating-point number");                      \
  END_STRING();                                                         \
  BEGIN(INITIAL);                                                       \
  return FLOAT;                                                         \
} while (0)

#define END_COMMENT() do {                                              \
  if (lstate.track_comments)                                            \
    {                                                                   \
      struct comment_list *c = allocate(parser_heap(), sizeof *c);      \
      *c = (struct comment_list){                                       \
        .next  = lstate.comments,                                       \
        .start = *LLOC_LOC(ccomment.start),                             \
        .end   = *LLOC_LAST_LOC(*yylloc)                                \
      };                                                                \
      lstate.comments = c;                                              \
    }                                                                   \
  LOCATION_STEP();                                                      \
  BEGIN(INITIAL);                                                       \
} while (0)

static bool check_int(const char **str, size_t len, int *base,
                      const char *type, bool *is_float,
                      const struct loc *sloc);

static void advance_location(YYLTYPE *loc)
{
  loc->last_pos += yyleng;
  loc->last_column += yyleng;
}

%}

%option bison-locations
%option noinput
%option nounput
%option noyymore
%option noyywrap
%option warn

DIGIT           [0-9]
OCTDIGIT        [0-7]
EXP             [eE][+-]?{DIGIT}+
HEXDIGIT        [0-9a-fA-F]
GLOBAL_PREFIX   :
OPT_SYMBOL_TAIL [a-zA-Z0-9_:?!]?
SYMBOL_NAME     [a-zA-Z][a-zA-Z0-9_:?!]{0,1024}
USER_VAR_NAME   ([a-zA-Z0-9$][a-zA-Z0-9$_:?!]{0,1024})?
I_BIN_TAIL      [bB][01]{0,1024}
I_HEX_TAIL      [xX]{HEXDIGIT}{0,1024}
I_DEC           {DIGIT}{1,1024}
INT             ({I_DEC}|0({I_HEX_TAIL}|{I_BIN_TAIL}))

%x HASH

%x STRING_CONST
%x STRING_CONST_RAW
%x STRING_CONST_TRIPLE
%x SC_ESC
%x SC_NAME
%x DEC_PERIOD
%x HEX_PERIOD
%x FLOAT_EXP

%x LINE_COMMENT
%x COMMENT

%%

%{
  LOCATION_STEP();
  if (lstate.start_token != YY_NULL)
    {
      int t = lstate.start_token;
      lstate.start_token = YY_NULL;
      return t;
    }
%}

\n {
  LOCATION_NEWLINE();
  LOCATION_STEP();
}
[ \t\r]+  { LOCATION_STEP(); }
"/"[/\*]? {
  if (yyleng == 1) return '/';
  ccomment.start = *yylloc;
  ccomment.level = 1;
  if (yytext[1] == '*')
    BEGIN(COMMENT);
  else
    BEGIN(LINE_COMMENT);
}

<LINE_COMMENT>.* { }
<LINE_COMMENT><<eof>> { END_COMMENT(); }
<LINE_COMMENT>\n {
  LOCATION_NEWLINE();
  END_COMMENT();
}

<COMMENT>[^/\*\n] { }
<COMMENT>\n { LOCATION_NEWLINE(); }
<COMMENT><<eof>> {
  compile_error(LLOC_LOC(ccomment.start), "unterminated comment");
  yyterminate();
}

<COMMENT>\*\/? {
  if (yyleng == 2 && --ccomment.level == 0)
    END_COMMENT();
}
<COMMENT>\/\*? {
  if (yyleng == 2)
    ++ccomment.level;
}

[][!%&\'()*+;<=>@^_{|}~-] { return yytext[0]; }

"&&"    { return LOGICAL_AND; }
"||"    { return LOGICAL_OR; }
"^^"    { return LOGICAL_XOR; }
"+="    { yylval->bop = b_add;         return ASSIGN_OP; }
"&="    { yylval->bop = b_bitand;      return ASSIGN_OP; }
"|="    { yylval->bop = b_bitor;       return ASSIGN_OP; }
"^="    { yylval->bop = b_bitxor;      return ASSIGN_OP; }
"/="    { yylval->bop = b_divide;      return ASSIGN_OP; }
"*="    { yylval->bop = b_multiply;    return ASSIGN_OP; }
"%="    { yylval->bop = b_remainder;   return ASSIGN_OP; }
"&&="   { yylval->bop = b_logical_and; return ASSIGN_OP; }
"||="   { yylval->bop = b_logical_or;  return ASSIGN_OP; }
"<<="   { yylval->bop = b_shift_left;  return ASSIGN_OP; }
">>="   { yylval->bop = b_shift_right; return ASSIGN_OP; }
"-="    { yylval->bop = b_subtract;    return ASSIGN_OP; }
"^^="   { yylval->bop = b_logical_xor; return ASSIGN_OP; }
"=="    { return EQ; }
">="    { return GE; }
"<="    { return LE; }
"!="    { return NE; }
"<<"    { return SHIFT_LEFT; }
">>"    { return SHIFT_RIGHT; }
"--"    { return DECREMENT; }
"++"    { return INCREMENT; }

"=>"    { return PATTERN_MATCH; }
"."{1,4}[0-9]? {
  int last = yytext[yyleng - 1];
  int nperiod = yyleng;
  if (last == '.')
    {
      if (nperiod == 1) return '.';
      if (nperiod == 3) return ELLIPSIS;
    }
  else
    --nperiod;
  switch (nperiod)
    {
    case 1:
      lexer_error("floating-point numbers must start with a digit");
    case 2: lexer_error("invalid '..' operator");
    case 4: lexer_error("invalid '....' operator");
    default:
      loc_add(&yylloc->first, nperiod);
      lexer_error("'...' must be followed by whitespace before"
                  " a digit");
    }
}

","[ \n\t\r]? {
  yylval->tcomma.space_suffix = (yytext[1] != 0);
  if (yytext[1] == '\n')
    LOCATION_NEWLINE();
  return COMMA;
}

"?"([0-9A-Za-z_][a-zA-Z0-9$_:?!]?|.)? {
  if (yyleng == 1)
    {
      STRING_START(true, false);
      UNTERMINATED_STRING();
    }

  if (yyleng == 3)
    lexer_error("invalid character constant");

  yylval->integer.base = cstbase_char;

  unsigned char c = yytext[1];
  if (c == '\\')
    {
      STRING_START(true, false);
      BEGIN(SC_ESC);
    }
  else if (!IS_8PRINT(c))
    {
      int esc = 0;
      switch (c)
        {
#define _E(escchr, chr) case escchr: esc = chr; break
          FOR_CHAR_ESCAPES(_E, SEP_SEMI);
#undef _E
        }
      if (esc)
        lexer_error("invalid character constant: use '%s?\\%c%s'",
                    CMARKUP(string, esc));
      else
        lexer_error("invalid character constant: use '?%s\\%03o%s'",
                    CMARKUP(string, c));
    }
  else if (IS_8SPACE(c) || strchr("(){}[]\"", c) != NULL)
    lexer_error("'%s?%c%s' must be written '%s?\\%c%s'",
                CMARKUP(string, c), CMARKUP(string, c));
  else
    {
      yylval->integer = (struct int_and_base){
        .i    = c,
        .base = cstbase_char
      };
      return INTEGER;
    }
}

{INT}[0-9A-Za-z_.]? {
  const char *s = yytext;
  int base;
  bool is_float;
  if (!check_int(&s, yyleng, &base, "integer", &is_float,
                 LLOC_LOC(*yylloc)))
    yyterminate();

  if (!is_float)
    {
      if (!mudlle_strtolong(s, yytext + yyleng - s, &yylval->integer.i,
                            base, true))
        lexer_error("%sinteger constant out of range",
                    base_name(base));
      yylval->integer.base = base;
      return INTEGER;
    }

  STRING_START(false, false);
  sb_addmem(&cstring.sb, yytext, yyleng);
  int last = yytext[yyleng - 1];
  yylval->mudlle_float.base = base;
  if (last == 'p' || last == 'P')
    {
      assert(base == 16);
      BEGIN(FLOAT_EXP);
    }
  else if (last == 'e' || last == 'E')
    {
      assert(base == 10);
      BEGIN(FLOAT_EXP);
    }
  else
    {
      assert(last == '.');
      if (base == 10)
        BEGIN(DEC_PERIOD);
      else if (base == 16)
        BEGIN(HEX_PERIOD);
      else
        abort();
    }
}

<DEC_PERIOD>{DIGIT}+[a-zA-Z$_:?!.]? {
  sb_addmem(&cstring.sb, yytext, yyleng);
  int last = yytext[yyleng - 1];
  if (last == 'e' || last == 'E')
    {
      BEGIN(FLOAT_EXP);
    }
  else if (!isdigit((unsigned char)last))
    {
      cstring.loc.col += sb_len(&cstring.sb) - 1;
      STRING_ERROR(
        "invalid suffix in floating-point constant: %c",
        last);
    }
  else
    END_FLOAT();
}

<DEC_PERIOD>[^0] { INVALID_FLOAT("expected digit after decimal period"); }
<DEC_PERIOD><<eof>> { INVALID_FLOAT("expected digit after decimal period"); }

<HEX_PERIOD>{HEXDIGIT}+[A-Za-z_]? {
  sb_addmem(&cstring.sb, yytext, yyleng);
  int last = yytext[yyleng - 1];
  if (last == 'p' || last == 'P')
    {
      BEGIN(FLOAT_EXP);
    }
  else
    {
      cstring.loc.col += sb_len(&cstring.sb) - 1;
      STRING_ERROR(
        "expected exponent in hexadecimal floating-point constant");
    }
}

<HEX_PERIOD>[^0] {
  INVALID_FLOAT("expected hexadecimal digit after period");
}
<HEX_PERIOD><<eof>> {
  INVALID_FLOAT("expected hexadecimal digit after period");
}

<FLOAT_EXP>[+-]?{DIGIT}{0,1024}[A-Za-z_]? {
  sb_addmem(&cstring.sb, yytext, yyleng);
  if (sb_len(&cstring.sb) > 1024)
    {
      cstring.loc.col += 1024;
      STRING_ERROR("too many characters in floating-point constant");
    }
  int last = yytext[yyleng - 1];
  if (last == '+' || last == '-')
    {
      cstring.loc.col += sb_len(&cstring.sb);
      STRING_ERROR("expected exponent in floating-point constant");
    }
  if (!isdigit((unsigned char)last))
    {
      cstring.loc.col += sb_len(&cstring.sb);
      STRING_ERROR(
        "invalid suffix in floating-point constant: %c", last);
    }
  END_FLOAT();
}

<FLOAT_EXP>[^0] {
  INVALID_FLOAT("expected exponent in floating-point constant");
}
<FLOAT_EXP><<eof>> {
  INVALID_FLOAT("expected exponent in floating-point constant");
}

"#" { BEGIN(HASH); }

<HASH>"arith"{OPT_SYMBOL_TAIL} {
  BEGIN(INITIAL);
  if (yyleng != 5) goto bad_hash;
  return ARITH;
}

<HASH>[bB](\[|-?{INT}?[0-9A-Za-z_]?) {
  BEGIN(INITIAL);

  if (!yytext[1])
    {
      loc_add(&yylloc->first, yyleng);
      lexer_error("#%c must be followed by a bigint constant",
                  yytext[0]);
    }

#ifdef USE_GMP
  const char *s = yytext + 1;
  bool neg = *s == '-';
  if (neg) ++s;
  int base;
  struct loc loc = *LLOC_LOC(*yylloc);
  loc.col += s - yytext;
  if (!check_int(&s, yytext + yyleng - s, &base, "bigint", NULL, &loc))
    yyterminate();
  size_t sz = yytext + yyleng - s + 1;
  yylval->bigint = allocate(parser_heap(), sizeof *yylval->bigint + sz);
  yylval->bigint->base = base;
  yylval->bigint->neg  = neg;
  memcpy(yylval->bigint->str, s, sz);
  return BIGINT;
#else   /* ! USE_GMP */
  lexer_error("bigints are not supported");
#endif  /* ! USE_GMP */
}

<HASH>"gone"{OPT_SYMBOL_TAIL} {
  BEGIN(INITIAL);
  if (yyleng != 4) goto bad_hash;
  return HASH_GONE;
}
<HASH>r[ow]{OPT_SYMBOL_TAIL} {
  BEGIN(INITIAL);
  if (yyleng != 2) goto bad_hash;
  yylval->rwmode = yytext[1] == 'o' ? rwmode_ro : rwmode_rw;
  return yytext[1] == 'o' ? HASH_RO : HASH_RW;
}
<HASH>"im"{OPT_SYMBOL_TAIL} {
  BEGIN(INITIAL);
  if (yyleng != 2) goto bad_hash;
  yylval->rwmode = rwmode_im;
  return HASH_IM;
}
<HASH><<eof>> { goto bad_hash; }
<HASH>. {
 bad_hash:
  lexer_error("# must be followed by \"arith\", \"b\" (bigint),"
              " \"gone\", \"im\", \"ro\", or \"rw\"");
}

r#{0,256}[#\"] {
  CASSERT(MAX_RAW_STRING_HASHES == 256);
  if (yytext[yyleng - 1] != '"')
    {
      loc_add(&yylloc->first, yyleng);
      if (yyleng == 1 + MAX_RAW_STRING_HASHES + 1)
        lexer_error("raw string delimeters can have at most %d '#'"
                    " characters", MAX_RAW_STRING_HASHES);
      lexer_error("missing '\"' in raw string delimeter");
    }
  STRING_START(false, false);
  cstring.raw_delim_len = yyleng - 1;
  BEGIN(STRING_CONST_RAW);
}

\"{1,7} {
  if (yyleng > 6)
    {
      loc_add(&yylloc->first, 6);
      lexer_error("closing triple-quote must not be followed by"
                  " another double quote");
    }
  if (yyleng == 2 || yyleng == 6)
    {
      yylval->string = CSTRLEN("");
      return STRING;
    }
  if (yyleng > 3)
    {
      loc_add(&yylloc->first, 3);
      lexer_error("leading double quote inside triple-quoted string"
                  " must be escaped");
    }
  assert(yyleng == 1 || yyleng == 3);
  STRING_START(false, yyleng > 1);
  if (cstring.is_triple_quote)
    BEGIN(STRING_CONST_TRIPLE);
  else
    BEGIN(STRING_CONST);
}

<STRING_CONST>\" {
 finish_string: ;
  size_t len = sb_len(&cstring.sb);
  yylval->string.len = len;
  char *sbuf = allocate(parser_heap(), len);
  memcpy(sbuf, sb_str(&cstring.sb), len);
  yylval->string.str = sbuf;
  if (len > 512)
    sb_free(&cstring.sb);
  yylloc->first = cstring.loc;
  END_STRING();
  BEGIN(INITIAL);
  return STRING;
}

<STRING_CONST,STRING_CONST_TRIPLE>[^\n\\\"]+ {
  sb_addmem(&cstring.sb, yytext, yyleng);
  if (sb_len(&cstring.sb) > MAX_STRING_SIZE)
    lexer_error("string length exceeds %s%ld%s characters",
                CMARKUP(number, (long)MAX_STRING_SIZE));
}

<STRING_CONST>\n { UNTERMINATED_STRING(); }

<STRING_CONST,STRING_CONST_RAW,STRING_CONST_TRIPLE,SC_NAME,SC_ESC><<eof>> {
  UNTERMINATED_STRING();
}

<STRING_CONST_TRIPLE,STRING_CONST_RAW>\n {
  sb_addc(&cstring.sb, '\n');
  LOCATION_NEWLINE();
}

<STRING_CONST_TRIPLE>\"{1,4} {
  if (yyleng > 3)
    {
      LOCATION_STEP();
      lexer_error("closing triple-quote must not be followed by"
                  " another double quote");
    }
  if (yyleng == 3)
    goto finish_string;
  sb_addmem(&cstring.sb, yytext, yyleng);
}

<STRING_CONST_RAW>\"#{0,257} {
  CASSERT(MAX_RAW_STRING_HASHES == 256);
  if (yyleng < (int)cstring.raw_delim_len)
    sb_addmem(&cstring.sb, yytext, yyleng);
  else if (yyleng > (int)cstring.raw_delim_len)
    {
      LOCATION_STEP();
      loc_add(&yylloc->first, cstring.raw_delim_len - yyleng);
      lexer_error("extra '#' in raw string terminator");
    }
  else
    goto finish_string;
}

<STRING_CONST_RAW>[^\n\"]{1,1024} {
  sb_addmem(&cstring.sb, yytext, yyleng);
  if (sb_len(&cstring.sb) > MAX_STRING_SIZE)
    lexer_error("string length exceeds %s%ld%s characters",
                CMARKUP(number, (long)MAX_STRING_SIZE));
}

<STRING_CONST,STRING_CONST_TRIPLE>\\ { BEGIN(SC_ESC); }

<SC_ESC>\n {
  if (cstring.is_char_const)
    UNTERMINATED_STRING();
  LOCATION_NEWLINE();

 end_esc_char:
  if (cstring.is_char_const)
    {
      END_STRING();
      BEGIN(INITIAL);
      assert(sb_len(&cstring.sb) == 1);
      yylval->integer.i = (unsigned char)sb_str(&cstring.sb)[0];
      return INTEGER;
    }
  if (cstring.is_triple_quote)
    BEGIN(STRING_CONST_TRIPLE);
  else
    BEGIN(STRING_CONST);
}

<SC_ESC>N\{? {
  if (yytext[1] != '{')
    {
      LOCATION_STEP();
      lexer_error("\\N must be followed by left curly bracket ({)");
    }
  BEGIN(SC_NAME);
}

<SC_NAME>[- A-Z]{0,1024}[^A]? {
  unsigned char last = yytext[yyleng - 1];
  if (last != '}')
    {
      LOCATION_STEP();
      loc_add(&yylloc->first, -1);
      if (yyleng > 1024)
        lexer_error("too long character name");
      else if (isupper(last) || last == '-' || last == ' '
               || last == '\n')
        {
          loc_add(&yylloc->first, 1);
          lexer_error("unterminated character name");
        }
      else if (isprint(last) && !isspace(last))
        lexer_error("invalid character in character name: %c", last);
      else
        lexer_error("invalid%s character in character name: \\x%02x",
                    isspace(last) ? " space" : "", last);
    }
  int c = lookup_named_character(yytext, yyleng - 1);
  if (c < 0)
    {
      LOCATION_STEP();
      loc_add(&yylloc->first, -yyleng);
      lexer_error("unknown named character");
    }
  yylval->integer.base = cstbase_named_char;
  sb_addc(&cstring.sb, c);
  goto end_esc_char;
}

<SC_ESC>{OCTDIGIT}{1,3}[a-zA-Z0-9$_:?!]? {
  int last = yytext[yyleng - 1];
  /* check for invalid next character for octal constants */
  if ((last < '0' || last > '7') || yyleng > 3)
    {
      if (cstring.is_char_const)
        {
          LOCATION_STEP();
          lexer_error("invalid character constant");
        }
      --yyleng;
    }
  else
    last = 0;
  int val = 0;
  for (int i = 0; i < yyleng; ++i)
    val = val * 8 + yytext[i] - '0';
  if (val > 255)
    {
      LOCATION_STEP();
      loc_add(&yylloc->first, -yyleng - 1);
      lexer_error("invalid octal character: \\%03o", val);
    }
  sb_addc(&cstring.sb, val);
  if (last)
    sb_addc(&cstring.sb, last);
  goto end_esc_char;
}

<SC_ESC>x{HEXDIGIT}{0,2}[a-zA-Z0-9$_:?!] {
  int d2 = -1;
  if (yyleng >= 3)
    d2 = xdigit_val(yytext[2]);
  if (d2 < 0 || d2 > 15 || (yyleng == 4 && cstring.is_char_const))
    {
      LOCATION_STEP();
      loc_add(&yylloc->first, -yyleng - 1);
      lexer_error("invalid hexadecimal character constant");
    }
  int d1 = xdigit_val(yytext[1]);
  assert(d1 >= 0);
  sb_addc(&cstring.sb, (d1 << 4) + d2);
  if (yyleng == 4)
    sb_addc(&cstring.sb, yytext[3]);
  goto end_esc_char;
}

<SC_ESC>([A-Za-z_][a-zA-Z0-9$_:?!]?|.) {
  if (yyleng == 2 && cstring.is_char_const)
    {
      LOCATION_STEP();
      lexer_error("invalid character constant");
    }
  int c = yytext[0];
  switch (c)
    {
    case 'x':
      LOCATION_STEP();
      lexer_error("invalid hexadecimal character constant");
#define _E(escchr, chr) case chr: c = escchr; break
      FOR_CHAR_ESCAPES(_E, SEP_SEMI);
#undef _E
    }
  sb_addc(&cstring.sb, c);
  if (yyleng == 2)
    sb_addc(&cstring.sb, yytext[1]);
  goto end_esc_char;
}

"$"{USER_VAR_NAME} {
  if (!lstate.pconfig->user_syms)
    goto bad_char;

  if (yyleng > MAX_VARIABLE_LENGTH)
    lexer_error("symbol name exceeds %s%d%s characters",
                CMARKUP(number, MAX_VARIABLE_LENGTH));

  size_t size = yyleng + 1;
  char *sym = allocate(parser_heap(), size);
  memcpy(sym, yytext, size);
  yylval->symbol = sym;
  return SYMBOL;
}

{GLOBAL_PREFIX}?{SYMBOL_NAME} {
  for (size_t i = 0; i < NKEYWORDS; i++)
    if (strcasecmp(yytext, keywords[i].name) == 0)
      return keywords[i].value;

  size_t len = yyleng;
  if (is_global_var_name(yytext))
    len -= strlen(GLOBAL_ENV_PREFIX);

  if (len > MAX_VARIABLE_LENGTH)
    lexer_error("symbol name exceeds %s%d%s characters",
                CMARKUP(number, MAX_VARIABLE_LENGTH));

  size_t size = yyleng + 1;
  char *sym = allocate(parser_heap(), size);
  memcpy(sym, yytext, size);
  yylval->symbol = sym;
  return SYMBOL;
}

. {
 bad_char: ;
  unsigned char c = yytext[0];
  if (isprint(c))
    lexer_error("bad character %c (0x%02x)", c, c);
  else
    lexer_error("bad character 0x%02x", c);
}

%%

static const char *base_name(int base)
{
  switch (base)
    {
    case 2: return "binary ";
    case 8: return "octal ";
    case 10: return "decimal ";
    case 16: return "hexadecimal ";
    }
  return "";
}

/* set *base to detected base; set *str to start of digit sequence;
   return true if valid */
static bool check_int(const char **str, size_t len, int *base,
                      const char *type, bool *is_float,
                      const struct loc *sloc)
{
  if (is_float)
    *is_float = false;

  if (len > 1024)
    {
      struct loc loc = *sloc;
      loc.col += 1024;
      compile_error(&loc, "too many characters in numeric constant");
      return false;
    }

  const char *s = *str, *end = s + len;

  int b = 0;
  const char *lastp;
  if (s < end && *s == '0')
    {
      ++s;
      if (s == end)
        {
          *base = 8;
          return true;
        }
      switch (*s)
        {
        case 'b': case 'B':
          *str = ++s;
          b = 2;
          break;
        case 'x': case 'X':
          *str = ++s;
          b = 16;
          if (end > s)
            {
              lastp = end - 1;
              int last = *lastp;
              if (last == '.' || last == 'p' || last == 'P')
                {
                  if (is_float == NULL)
                    goto invalid_last;
                  *base = 16;
                  *is_float = true;
                  return true;
                }
            }
          break;
        default:
          b = 8;
          const char *non_octal = NULL;
          do
            {
              lastp = s++;
              int last = *lastp;
              if (last == '8' || last == '9')
                {
                  /* handle decimal floating-point constants with leading
                     zero */
                  if (is_float == NULL)
                    goto invalid_last;
                  non_octal = lastp;
                  /* only decimal digits can occur before the last character,
                     so we skip to it right away */
                  s = end;
                  lastp = s - 1;
                }
            }
          while (s < end);
          int last = *lastp;
          if (last == '.' || last == 'e' || last == 'E')
            {
              if (is_float == NULL)
                goto invalid_last;
              assert(s == end);
              *base = 10;
              *is_float = true;
              return true;
            }
          if (non_octal)
            {
              lastp = non_octal;
              goto invalid_last;
            }
          if (last < '0' || last > '7')
            goto invalid_last;
          *base = 8;
          return true;
        }
    }

  if (s == end)
    goto incomplete;

  if (b == 0)
    {
      lastp = s;
      if (!isdigit((unsigned char)*lastp))
        goto invalid_last;
      b = 10;
    }

  *base = b;

  lastp = end - 1;
  if (b == 10 && (*lastp == '.' || *lastp == 'e' || *lastp == 'E'))
    {
      if (is_float == NULL)
        goto invalid_last;
      *is_float = true;
      return true;
    }

  if (b == 16
      ? !isxdigit((unsigned char)*lastp)
      : *lastp < '0' || *lastp >= '0' + b)
    goto invalid_last;

  return true;

  struct loc loc;

 invalid_last:
  loc = *sloc;
  loc.col += lastp + len - end;
  compile_error(&loc, "invalid %s in %s%s constant: %s%c%s",
                (isdigit((unsigned char)*lastp)
                 ? "digit"
                 : b == 0 ? "leading character" : "character"),
                base_name(b), type, CMARKUP(string, *lastp));
  return false;

 incomplete:
  loc = *sloc;
  loc.col += len;
  compile_error(&loc, "incomplete %s%s constant", base_name(b), type);
  return false;
}

static size_t string_read(void *ptr, size_t size, size_t nmemb, FILE *stream)
{
  char *dst = ptr;
  size_t max_size = size * nmemb;
  size_t total = 0;
  for (;;)
    {
      if (lstate.s.cstr == lstate.pconfig->nstrs)
        return total;

      size_t cnt = MIN(lstate.s.len, max_size);
      memcpy(dst, lstate.s.cur, cnt);
      max_size -= cnt;
      lstate.s.cur += cnt;
      lstate.s.len -= cnt;
      total += cnt;
      if (max_size == 0)
        return total;
      dst += cnt;

      if (++lstate.s.cstr == lstate.pconfig->nstrs)
        {
          lstate.s.cur = NULL;
          lstate.s.len = 0;
        }
      else
        {
          lstate.s.cur = lstate.pconfig->strs[lstate.s.cstr].str;
          lstate.s.len = lstate.pconfig->strs[lstate.s.cstr].len;
        }
    }
}

bool allow_comma_expression(void)
{
  return lstate.allow_comma_expr;
}

void set_lex_config(const struct parser_config *pconfig)
{
  if (pconfig == NULL)
    {
      lstate.pconfig = NULL;
      return;
    }

  assert(lstate.pconfig == NULL);

  if (mbuf == NULL)
    {
      mbuf = yy_create_buffer(pconfig->f, YY_BUF_SIZE);
      yy_switch_to_buffer(mbuf);
    }
  else
    yyrestart(pconfig->f);

  static const int start_tokens[] = {
    [parser_mode_file]         = YY_NULL,
    [parser_mode_constant]     = START_CONSTANT,
    [parser_mode_storable]     = START_STORABLE,
    [parser_mode_any_expr]     = START_ANY_EXPR,
    [parser_mode_primary_expr] = START_PRIMARY_EXPR,
    [parser_mode_paren_expr]   = START_PAREN_EXPR,
  };
  assert(pconfig->pmode >= 0 && pconfig->pmode < VLENGTH(start_tokens));

  lstate = (struct lexer_state){
    .reader           = pconfig->f == NULL ? string_read : fread,
    .start_token      = start_tokens[pconfig->pmode],
    .allow_comma_expr = (pconfig->pmode != parser_mode_constant
                         && pconfig->pmode != parser_mode_storable),
    .track_comments   = pconfig->comments,
    .pconfig          = pconfig,
    .s = {
      .cur   = pconfig->nstrs == 0 ? NULL : pconfig->strs[0].str,
      .len   = pconfig->nstrs == 0 ? 0 : pconfig->strs[0].len
    }
  };

  cstring.loc = (struct loc)INIT_LOC;
  BEGIN(INITIAL);
}

struct comment_list *lexer_comments(void)
{
  return lstate.comments;
}
