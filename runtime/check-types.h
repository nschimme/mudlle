#ifndef RUNTIME_CHECK_TYPES_H
#define RUNTIME_CHECK_TYPES_H

#include "../call.h"

/*
  CHECK_TYPES(var0, type0, var1, type1, ...)

  Validates each var<N> against its type<N>. A type is one of:
    <type name>          Check that var is of that type.
                         See "add new <type name> ..." below if your type
                         doesn't work.
    any                  No checks performed.
    CT_ARGV(min, max)    Tail arguments for vararg primitive. Checks that there
                         are [min..max] tail arguments, or [min..] if max < 0.
    CT_FUNCTION          Check that is_function(var) is true.
    CT_CALLABLE(n)       Check that is_function(var) is true; check that it
                         can be called with 'n' arguments.
    CT_TYPES(<type name>...)
                         Check that var is one of the listed types.
    CT_TYPESET(typeset)  Check that var is in 'typeset' (a typeset_t)
    CT_INT(dst)          Check that var is an integer; store the result
                         in 'dst' (a long).
    CT_INT_P(arg, pred)  Check that var is an integer; check that
                         pred(intval(var), errmsg, arg) returns error_none.
    CT_AUTO_RANGE(dst)   Check that var is an integer; check that intval(var)
                         fits in 'dst'; store the result in 'dst'.
                         Warning: don't use on 'dst' enums.
    CT_RANGE(dst, min, max)
                         Check that var is an integer; check that
                         min <= intval(var) <= max; store the result in
                         'dst' (no type check).
    CT_TYPED_RANGE(type, dst, min, max)
                         Check that var is an integer; check that
                         min <= intval(var) <= max; store the result in 'dst';
                         assert that 'dst' is compatible with 'type'.
    OR(type0, type1)     Checks that var is of either type0 or type1.
    F(typeset, pred, arg)
                         Checks that 'var' is a type in 'typeset'; checks that
                         pred(edst, var, msg, arg) does not set 'edst';
                         optionally set *msg to an error message (can be NULL).
    F2(typeset, pred, arg)
                         As F() but pred(var, msg, arg) returns error_xxx.

  The initial type(set) check is performed first for all vars. After they all
  pass, any additional tests are performed (similar to pred() for F).

  In vararg functions, you need to manually test the number of arguments first.

  RUNTIME_ERROR(error, msg) triggers 'error' with message 'msg' (can be NULL).
  All vars must still be valid.

  RUNTIME_ERROR_ARG(argn, error, msg) is the same but pertains to (zero-based)
  argument 'argn'.
 */

#define __NOTHING(...)

#define __JOIN_ARGS(...) ( __VA_ARGS__, __INCLUDE_PAREN
#define __INCLUDE_PAREN(...) __VA_ARGS__ )

/* add new <type name> in the following lists */
#define _IS_MTYPE_character  MARK
#define _IS_MTYPE_closure    MARK
#define _IS_MTYPE_connection MARK
#define _IS_MTYPE_cookie     MARK
#define _IS_MTYPE_integer    MARK
#define _IS_MTYPE_mcode      MARK
#define _IS_MTYPE_null       MARK
#define _IS_MTYPE_object     MARK
#define _IS_MTYPE_oport      MARK
#define _IS_MTYPE_pair       MARK
#define _IS_MTYPE_regexp     MARK
#define _IS_MTYPE_string     MARK
#define _IS_MTYPE_symbol     MARK
#define _IS_MTYPE_table      MARK
#define _IS_MTYPE_variable   MARK
#define _IS_MTYPE_vector     MARK
#define _IS_MTYPE_weak_ref   MARK

#define _IS_MTYPE(t) IS_MARK(_IS_MTYPE_ ## t)
#define IS_MTYPE(t) _IS_MTYPE(t)
#define IF_MTYPE(t) IF(IS_MTYPE(t))

/* 'false' is defined to 0 before C23 */
#define __CT_E_0(v)
#define __CT_S_0 TYPESET_FALSE
#define __CT_VALID_0 MARK
#define __CT_E_false(v)
#define __CT_S_false TYPESET_FALSE
#define __CT_VALID_false MARK

#define __CT_E_any(v)
#define __CT_S_any TYPESET_ANY
#define __CT_VALID_any MARK

#define ___CT_E_CT_ARGV(v)
#define __CT_E_CT_ARGV(min, max) ___CT_E_CT_ARGV
#define __CT_S_CT_ARGV TYPESET_ANY
#define __CT_VALID_CT_ARGV MARK

#define ___CT_E_F(tsig, pred, cbdata, arg)      \
  pred(__ct_error, arg, &__ct_errmsg, cbdata);  \
  if (__ct_error != error_none)                 \
    goto __ct_error_label;
#define __CT_E_F ___CT_E_F __JOIN_ARGS
#define __CT_S_F(tsig, pred, cbdata) (tsig)
#define __CT_VALID_F MARK

#define __CT_E_ORT(t, v) __CT_E_ ## t(v)
#define ___CT_E_OR(t0, t1, v)                                   \
  static_assert((__CT_S_ORT(t0) & __CT_S_ORT(t1)) == 0,         \
                "OR(): overlapping typesets unsupported");      \
  IF_MTYPE(t0)(                                                 \
    , if (is_typeset(v, __CT_S_ORT(t0))) { __CT_E_ORT(t0, v) }) \
  IF_MTYPE(t1)(                                                 \
    , if (is_typeset(v, __CT_S_ORT(t1))) { __CT_E_ORT(t1, v) })
#define __CT_E_OR ___CT_E_OR __JOIN_ARGS
#define __CT_S_ORT(t) IF_MTYPE(t)(                              \
    TSET(t),                                                    \
    __CT_S_ ## t)
#define __CT_S_OR(t0, t1) (__CT_S_ORT(t0) | __CT_S_ORT(t1))
#define __CT_VALID_OR MARK

#define __IS_ANY_any MARK
#define __IS_ANY_CT_ARGV MARK
#define __CT(v, t, arg) do {                                    \
    ++__ct_argnum;                                              \
    IF(IS_MARK(__IS_ANY_ ## t))(                                \
      ,                                                         \
      __check = v;                                              \
      IF_MTYPE(t)(                                              \
        /* regular type */                                      \
        if (!TYPE(__check, t))                                  \
          {                                                     \
            __typeset = TSET(t);                                \
            goto __ct_typeset_label;                            \
          },                                                    \
        /* special function */                                  \
        __typeset  = __CT_S_ ## t;                              \
        if (!is_typeset(__check, __typeset))                    \
          goto __ct_typeset_label;))                            \
      } while (0)

#define ___CE(...) __VA_ARGS__  /* force evaluate macros */
#define __CE(v, t, arg)                         \
  ++__ct_argnum;                                \
  IF_MTYPE(t)(, ___CE(__CT_E_ ## t(v)))
#define __CARGS(...) FOR_PAIRS(ARGN1, , SEP_COMMA, __VA_ARGS__)

#if __clang_major__ >= 8 && ! defined __OPTIMIZE__
/* clang 8 doesn't optimize this away */
static inline noreturn void check_types_wrong_nargs(void) { abort(); }
#else
void check_types_wrong_nargs(void); /* used to signal an error below */
#endif

#define _CT_FAIL(s) static_assert(0, s)

#define _IS_ARGV_CT_ARGV MARK

#define __CHECK_NARGV(min, max, v, count) do {                  \
    ulong nargv = vector_len(v);                                \
    if (CMP(nargv, (min)) < 0 || ((max) >= 0 && nargv > (max))) \
      RUNTIME_ERROR(                                            \
        error_wrong_parameters,                                 \
        bad_nargs_message(                                      \
          count - 1 + nargv,                                    \
          count - 1 + (min),                                    \
          (max) < 0 ? UINT_MAX : count - 1 + (max)));           \
    is_argv = true;                                             \
  } while (0)
#define _CHECK_NARGV_CT_ARGV __CHECK_NARGV __JOIN_ARGS

/* verify that CHECK_TYPE(v, t) is supported */
#define __CT_VALID(v, t, count)                                 \
  IF(IS_MARK(_IS_ARGV_ ## t))(_CHECK_NARGV_ ## t(v, count);, )  \
  IF_MTYPE(t)(                                                  \
    , IF(IS_MARK(__CT_VALID_ ## t))(                            \
      , _CT_FAIL("Unsupported CHECK_TYPES() type " #t);))

#define __IS_X_X MARK
#define __IS_X(count) __IS_X_ ## count

#define __CHECK_NARGS(op, count, is_argv) do {  \
  if ((op)->nargs >= 0 || (is_argv))            \
    {                                           \
      const int expect = ((op)->nargs < 0       \
                          ? -(op)->nargs        \
                          : (op)->nargs);       \
      if (!__builtin_constant_p(expect))        \
        assert((count) == expect);              \
      else if ((count) != expect)               \
        check_types_wrong_nargs();              \
    }                                           \
  } while (0)

#define __SEP_OR() ||
#define __CHECK_TYPES(check_nargs, op, count, ...) IF(  \
  IS_MARK(__IS_X(count)))(                              \
    _CT_FAIL("invalid number of arguments"),            \
    enum runtime_error __ct_error = error_none;         \
    const char *__ct_errmsg = NULL;                     \
    int __ct_argnum = -1;                               \
                                                        \
    do                                                  \
      {                                                 \
        bool is_argv = false;                           \
        FOR_PAIRS(__CT_VALID, (count), __NOTHING,       \
                  __VA_ARGS__)                          \
        if (!(check_nargs)) break;                      \
        __CHECK_NARGS(op, count, is_argv);              \
      }                                                 \
    while (0);                                          \
                                                        \
    do                                                  \
      {                                                 \
        value __check;                                  \
        typeset_t __typeset;                            \
        FOR_PAIRS(__CT, , SEP_SEMI, __VA_ARGS__);       \
        __ct_argnum = -1;                               \
        FOR_PAIRS(__CE, , __NOTHING, __VA_ARGS__)       \
        __ct_argnum = -1;                               \
        break;                                          \
      __ct_typeset_label:                               \
        primitive_bad_typeset_error(                    \
          __check, __typeset, op, __ct_argnum, count,   \
          __CARGS(__VA_ARGS__));                        \
      __ct_error_label: UNUSED;                         \
        primitive_runtime_error_msg(                    \
          __ct_error, __ct_errmsg, op, __ct_argnum,     \
          count, __CARGS(__VA_ARGS__));                 \
      }                                                 \
    while (0))

#define __CHECK_TYPES0(op)                              \
  enum runtime_error __ct_error = error_none;           \
  const char *__ct_errmsg = NULL;                       \
  int __ct_argnum = -1;                                 \
  __CHECK_NARGS(op, 0, false);                          \
  if (false)                                            \
    {                                                   \
    __ct_error_label: UNUSED;                           \
      primitive_runtime_error_msg(                      \
        __ct_error, __ct_errmsg, op, __ct_argnum, 0);   \
    }                                                   \
  ((void)0)

/* 'argn' is zero-based */
#define RUNTIME_ERROR_ARG(argn, errno, msg) do {        \
    __ct_error = (errno);                               \
    __ct_errmsg = (msg);                                \
    __ct_argnum = (argn);                               \
    goto __ct_error_label;                              \
  } while (0)

#define RUNTIME_ERROR(errno, msg) RUNTIME_ERROR_ARG(-1, (errno), (msg))

#define CHECK_TYPES(...)                                                \
  IF_NO_ARGS(__VA_ARGS__)(                                              \
    __CHECK_TYPES0(THIS_OP),                                            \
    __CHECK_TYPES(true, THIS_OP, VA_NPAIRS(__VA_ARGS__), __VA_ARGS__))
#define CHECK_TYPES_OP(op, ...)                                         \
  __CHECK_TYPES(false, op, VA_NPAIRS(__VA_ARGS__), __VA_ARGS__)

#define _F2_E(edst, v, msg, pred_arg)                           \
  edst = ARGN1 pred_arg (v, msg, ARGN2 pred_arg)
#define F2(typeset, pred, arg) F(typeset, _F2_E, (pred, arg))

#define __CT_INT_P_E(var, msg, arg_pred)                \
  ARGN2 arg_pred(intval(var), msg, ARGN1 arg_pred)
#define CT_INT_P(arg, pred)                             \
  F2(TSET(integer), __CT_INT_P_E, (arg, pred))

#define __CT_INT_E(edst, v, msg, dst)           \
  do {                                          \
    CASSERT_TYPE(dst, long);                    \
    dst = intval(v);                            \
  } while (0)
#define CT_INT(dst) F(TSET(integer), __CT_INT_E, dst)

#define __CT_TYPESET_E(edst, v, msg, arg)
#define CT_TYPESET(typeset) F((typeset), __CT_TYPESET_E, )

#define CT_CALLABLE(nargs) F2(TYPESET_FUNCTION, function_callable, nargs)

#define CT_FUNCTION CT_TYPESET(TYPESET_FUNCTION)

#define ___CT_RANGE_E(edst, v, msg, dst, min, max)              \
  do {                                                          \
    long __l = intval(v);                                       \
    long __rmin = MAX((min), LONG_MIN);                         \
    long __rmax = MIN((max), LONG_MAX);                         \
    if (__rmin <= __l && __l <= __rmax)                         \
      dst = __l;                                                \
    else                                                        \
      {                                                         \
        *msg = out_of_range_message(__l, __rmin, __rmax);       \
        edst = error_bad_value;                                 \
      }                                                         \
  } while (0)
#define __CT_RANGE_E(edst, v, msg, dst_min_max)                         \
  ___CT_RANGE_E(edst, v, msg, ARGN1 dst_min_max, ARGN2 dst_min_max,     \
                ARGN3 dst_min_max)
#define CT_RANGE(dst, min, max) F(TSET(integer), __CT_RANGE_E, (dst, min, max))

#define ___CT_TYPED_RANGE_E(edst, v, msg, dst, type, min, max)          \
  CASSERT_TYPE(dst, type);                                              \
  ___CT_RANGE_E(edst, v, msg, dst, min, max)
#define __CT_TYPED_RANGE_E(edst, v, msg, dst_type_min_max)              \
  ___CT_TYPED_RANGE_E(edst, v, msg, ARGN1 dst_type_min_max,             \
                      ARGN2 dst_type_min_max, ARGN3 dst_type_min_max,   \
                      ARGN4 dst_type_min_max)
#define CT_TYPED_RANGE(type, dst, min, max)                             \
  F(TSET(integer), __CT_TYPED_RANGE_E, (dst, type, min, max))

/* &dst catches if dst is a bitfield */
#define CT_AUTO_RANGE(dst) \
  CT_RANGE(dst, ((void)&dst, MIN_VALUE(dst)), MAX_VALUE(dst))

#define CT_TYPES(...) CT_TYPESET(FOR_ARGS(TSET, SEP_BITOR, __VA_ARGS__))

#endif  /* RUNTIME_CHECK_TYPES_H */
