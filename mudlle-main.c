/*
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

#include "mudlle-config.h"

#include <stdio.h>
#include <unistd.h>

#ifdef USE_READLINE
#  include <readline/history.h>
#  include <readline/readline.h>

#  define HISTORY_FILE ".mudlle-history"
#endif

#include "compile.h"
#include "context.h"
#include "lexer.h"
#include "print.h"
#include "tree.h"

#include "runtime/runtime.h"

static void execute(const char *line, bool verbose, bool show_result)
{
  if (verbose)
    fprintf(stderr, "Evaluating %s\n", line);

  const struct cstrlen lines[] = { cstrlen_from_str(line) };

  value result;
  const struct parser_config pconfig = {
    .filename = {
      .filename = "<string>",
      .nicename = "<string>"
    },
    .pmode = parser_mode_file,
    .nstrs = VLENGTH(lines),
    .strs = lines
  };
  if (interpret(&result, 1, true, &pconfig) && show_result)
    {
      printf("Result: ");
      output_value(mudout(), fmt_write, result, true);
      printf("\n");
    }
}

#ifdef USE_READLINE
static void history_exit(void)
{
  write_history(HISTORY_FILE);
}
#endif  /* USE_READLINE */

static void show_help(const char *progname, FILE *file)
{
  fprintf(file,
          "Usage:\n"
          "  %s [OPTION...] [FILE...]\n"
          "Options:\n"
          "  -h       show this help\n"
          "  -c EXPR  run mudlle expression EXPR\n"
          "  -e FILE  load mudlle file FILE\n"
          "  -v       enable verbose mode\n",
          progname);
}

static void interactive_loop(bool is_tty)
{
  for (;;)
    {
#ifdef USE_READLINE
      char *alloc = NULL;
      const char *line;
      if (is_tty)
	line = alloc = readline("mudlle> ");
      else
	{
	  static char buf[1024];
	  line = fgets(buf, sizeof buf, stdin);
          if (line == NULL)
            break;
          size_t len = strlen(line);
          if (len == sizeof buf - 1 && line[len - 1] != '\n')
            {
              fputs("Input line too long.\n", stderr);
              exit(EXIT_FAILURE);
            }
	}

      if (line == NULL)
	break;
      if (*line)
        {
	  if (is_tty)
	    add_history(line);
	  execute(line, false, is_tty);
        }
      free(alloc);
#else
      char line[512];

      if (is_tty)
        {
          fputs("mudlle> ", stdout);
          fflush(stdout);
        }
      if (!fgets(line, sizeof line, stdin))
	break;
      if (*line)
        execute(line, false, is_tty);
#endif
    }
}

static void load_one_file(const char *filename, bool verbose)
{
  if (verbose)
    fprintf(stderr, "Loading %s\n", filename);
  load_file(filename, MAX_SECLEVEL, false, true);
}

int main(int argc, char **argv)
{
  const char *progname = argc > 0 ? argv[0] : "mudlle";

  init_pagesize();
  mudlle_init();

  define_string_vector("argv", (const char *const *)argv, argc);

  bool is_tty = isatty(STDIN_FILENO);

#ifdef USE_READLINE
  if (is_tty)
    {
      using_history();
      read_history(HISTORY_FILE);
      rl_bind_key('\t', rl_insert);

      if (atexit(history_exit))
        perror("atexit(history_exit)");
    }
#endif

  struct oport *out = make_file_oport(stdout, true);
  struct session_context context;
  session_start(&context,
                &(const struct session_info){
                  .mout        = out,
                  .merr        = out,
                  .maxseclevel = MAX_SECLEVEL });

  bool do_interact = true;
  bool verbose = false;
  for (;;)
    {
      int opt = getopt(argc, argv, "vhc:e:");
      if (opt < 0)
          break;
      switch (opt)
        {
        case 'h':
          show_help(progname, stdout);
          exit(EXIT_SUCCESS);
        case '?':
          show_help(progname, stderr);
          exit(EXIT_FAILURE);
        case 'c':
          do_interact = false;
          execute(optarg, verbose, false);
          break;
        case 'e':
          do_interact = false;
          load_one_file(optarg, verbose);
          break;
        case 'v':
          verbose = true;
          break;
        default:
          abort();
        }
    }

  for (; optind < argc; ++optind)
    {
      do_interact = false;
      load_one_file(argv[optind], verbose);
    }

  if (do_interact)
    interactive_loop(is_tty);

  session_end();

  return 0;
}
