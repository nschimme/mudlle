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

#ifndef MUDLLE_CONFIG_H
#define MUDLLE_CONFIG_H


#if defined _SYS_TYPES_H || defined _SYS_TYPES_H_
#  error "Include mudlle-config.h before sys/types.h"
#endif

#ifndef __GNUC__
#  define __attribute__(x)
#endif

#define ALWAYS_INLINE __attribute__((always_inline)) inline

#undef GCDBEUG

#if defined __x86_64__ || defined __aarch64__
#  define GCQDEBUG
#  define GCDEBUG_CHECK
#  undef WORDS_BIGENDIAN
#  define HAVE___UINT128_T 1
#else
#  error "Unsupported architecture"
#endif

#ifdef __MACH__
#  define HAVE_CRYPT 1
#endif

/* GC configuration, basic parameters */
/* More parameters are found in alloc.h (and some logic in alloc.c). */
#define INITIAL_BLOCKSIZE (128 * 1024)
#define DEF_SAVE_SIZE     (64 * 1024)

#define GLOBAL_SIZE 512

#define DEFAULT_SECLEVEL 0   /* Seclevel when not calling type_secure/.. fns */
#define MIN_SECLEVEL     0   /* Minimum valid seclevel */
#define SECLEVEL_GLOBALS 1   /* Maxseclevel required to mess with globals */
#define LEGACY_SECLEVEL  1   /* Maxseclevel is used if seclevel < LEGACY */
#define MAX_SECLEVEL     1   /* Maximum valid seclevel */

#define MUDLLE_INTERRUPT 1
#define PRINT_CODE       1

#ifndef __has_extension
#  define __has_extension(x) 0
#endif

#ifdef __aarch64__
#  undef NOCOMPILER
#  define NOCOMPILER
#endif


#if defined __linux__ || defined __MACH__
#  ifdef __x86_64__
#    define USE_CCONTEXT
#  endif
#else
#  error Unsupported platform
#endif /* __linux__ || __MACH__ */

/* Execution limits */

/* max mudlle stack usage in bytes */
#define MAX_STACK_DEPTH (180 * 1024)

/* relative cost of an interpreted loop */
#ifdef NOCOMPILER
#  define INTERPRETED_LOOP_COST 1
#else
#  define INTERPRETED_LOOP_COST 10
#endif

#  define MAX_LOOP_COUNT MAX_TAGGED_INT

/* set to generate call count profiling information */
#undef PROFILE_CALL_COUNT

#endif  /* MUDLLE_CONFIG_H */
