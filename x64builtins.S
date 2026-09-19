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

/* WARNING: catchsegv() in runtime.c depends on the order of the operators! */

#include "mudlle-config.h"
#include "x64.h"

#  include "x64consts.h"

#define SEP_SEMI() ;

#ifdef __MACH__
.text
#else
.section        .text
#endif

#ifndef NOCOMPILER

#define CHECK_STACK_ALIGNMENT 1

#ifdef __MACH__
 #define N(x) _ ## x
 #define SO_N(x) _ ## x
 #define SETSIZE(x)
 #define FALIGN 4               /* in powers of two */
 #define LLAB(n) L ## n
#else
 #define N(x) x
 #define SO_N(x) x@PLT
 #define SETSIZE(x) .size x, . - x
 #define FALIGN 16              /* in bytes */
 #define LLAB(n) .L ## n
#endif

/* warning: may change flags for 'n' == 0 */
#define MOVIMM(n, reg)             \
  .if n == 0 ;                     \
    xor reg ## d, reg ## d ;       \
  .elseif n > 0 && n < (1 << 32) ; \
    mov $n, reg ## d ;             \
  .else ;                          \
    mov $n, reg ;                  \
  .endif

#define GA(x) N(x)@GOTPCREL(%rip) /* address to global */

#define GLABEL(n) .globl N(n) ; N(n)

#define GFUNC(n) .align FALIGN ; GLABEL(n): ; .cfi_startproc
#define GEND(n) .cfi_endproc ; SETSIZE(N(n))
#define LFUNC(n) .align FALIGN ; n: ; .cfi_startproc
#define LEND(n) .cfi_endproc ; SETSIZE(n)

#define ALIGN(n, align) ((n + align - 1) & ~(align - 1))

GLABEL(builtin_start):

#define ICST(n) (2 * (n) | 1)

/* Register usage for mudlle
 *   rax: scratch, argument count, function result
 *   rbx: callee-saved, (opt.) globals
 *   rdi,rsi: args 0-1, scratch
 *   rdx,rcx,r8,r9: caller-saved, native args 2-5
 *   r10: caller-saved, closure-in
 *   r11: scratch
 *   r12-r14: callee-saved
 *   r15: callee-saved, (opt.) closure
 *   rbp: frame pointer
 *   rsp: stack pointer
 *
 * Arguments to mudlle functions are on the stack (for debuggability).
 *
 * The non-scratch registers must hold valid mudlle values when a GC
 * might happen. SAVE_CALLE{R,E} store them where the garbage collector
 * can update them as necessary.
 *
 * The stack preceding the current (END_PREVIOUS_FRAME) or previous
 * (END_PARENT_FRAME) stack frame (as pointed to by %rbp) will be
 * updated by the garbage collector as well. */

/* Register assignments */
#define arg0        %rdi
#define arg0d       %edi
#define arg0w       %di
#define arg0b       %dil
#define arg1        %rsi
#define arg1d       %esi
#define arg1w       %si
#define arg1b       %sil
#define arg2        %rdx
#define arg2d       %edx
#define arg2w       %dx
#define arg2b       %dl
#define arg3        %rcx
#define arg3d       %ecx
#define arg3b       %cl
#define arg4        %r8
#define arg4d       %r8d
#define arg4b       %r8b
#define arg5        %r9
#define arg5d       %r9d
#define arg5w       %r9w
#define globals     %rbx
#define argcount    %rax
#define argcountd   %eax
#define argcountw   %ax
#define argcountb   %al
#define closure     %r15
#define closure_in  %r10
#define closure_inb %r10b
#define result      %rax
#define resultd     %eax
#define resultb     %al

#define raxd eax
#define rbxd ebx
#define rcxd ecx
#define rdxd edx

#define WORD_BITS 3             /* bits per word size */
#define WORD_SIZE 8

#define argstart (2 * WORD_SIZE)

/* The stack is kept aligned at mudlle function entry, but may be
   misaligned when builtins are called. */
#define STACK_ALIGN 16

#ifdef CHECK_STACK_ALIGNMENT
#define ASSERT_STACK_ALIGNED                    \
        test    $(STACK_ALIGN - 1),%spl;        \
        jnz     bad_stack_align

#define ASSERT_STACK_UNALIGNED                  \
        test    $(STACK_ALIGN - 1),%spl;        \
        jz      bad_stack_align
#else
#define ASSERT_STACK_ALIGNED
#define ASSERT_STACK_UNALIGNED
#endif

#define ALIGN_STACK and $-STACK_ALIGN,%rsp

#define CCALL_LEAF(fn)          \
        ASSERT_STACK_ALIGNED;   \
        call    fn

#ifdef GCSTATS
#define GCSTAT_ADD(type, size)                                  \
        mov     GA(gcstats),%r11;                               \
        addq    $1,(gcstats_alloc + gcstats_alloc_size * type   \
                    + gcstats_alloc_nb)(%r11);                  \
        addq    size,(gcstats_alloc + gcstats_alloc_size * type \
                      + gcstats_alloc_sz)(%r11)
#else  /* !GCSTATS */
#define GCSTAT_ADD(type, size)
#endif /* !GCSTATS */

/* some very incomplete CFI information included */
#define FUNC_ENTER                              \
        push %rbp;                              \
        .cfi_def_cfa_offset (2 * WORD_SIZE);    \
        .cfi_offset %rbp, -(2 * WORD_SIZE);     \
        mov %rsp,%rbp;                          \
        .cfi_def_cfa_register %rbp

#define FUNC_LEAVE                              \
        leave;                                  \
        .cfi_def_cfa %rsp, WORD_SIZE

#define FUNC_RETURN                             \
        FUNC_LEAVE;                             \
        ret

#define FUNC_NORETURN /* nothing to see here */


/* end mudlle frame ending at last frame (at push %rbp);
   cf. ccontext_frame() in context.h */
#define END_NTH_FRAME(n)                        \
        mov     GA(ccontext),%r11;              \
        movq    n,cc_frame_end_bp(%r11);        \
        mov     %rbp,cc_frame_end_sp(%r11)

#define END_PREVIOUS_FRAME END_NTH_FRAME($0)
#define END_PARENT_FRAME   END_NTH_FRAME($1)

/* Various ways of preserving the registers:
   SAVE_CALLEE/RESTORE_CALLEE: preserve value of callee saved registers
     only (caller saved are cleared in RESTORE)
   SAVE_CALLER/RESTORE_CALLER: preserve value of callee and caller registers
   CLEAR_CALLER: preserve no registers, just clear caller saved on return
     (assumes that called fn is NOALLOC)
*/
#define __SAVE_CALLEE(n, reg) mov %reg,cc_callee_ ## reg(%r11)
#define __RESTORE_CALLEE(n, reg) mov cc_callee_ ## reg(%r11),%reg
#define SAVE_CALLEE                                     \
        mov     GA(ccontext),%r11;                      \
        FOR_CALLEE_SAVE(__SAVE_CALLEE, SEP_SEMI)
#define RESTORE_CALLEE                                  \
        mov     GA(ccontext),%r11;                      \
        FOR_CALLEE_SAVE(__RESTORE_CALLEE, SEP_SEMI);    \
        CLEAR_CALLER

#define __SAVE_CALLER(n, reg) mov %reg,cc_caller_ ## reg(%r11)
#define __RESTORE_CALLER(n, reg) mov cc_caller_ ## reg(%r11),%reg
#define SAVE_CALLER                                     \
        SAVE_CALLEE;                                    \
        FOR_CALLER_SAVE(__SAVE_CALLER, SEP_SEMI)
#define RESTORE_CALLER                                  \
        mov     GA(ccontext),%r11;                      \
        FOR_CALLEE_SAVE(__RESTORE_CALLEE, SEP_SEMI);    \
        FOR_CALLER_SAVE(__RESTORE_CALLER, SEP_SEMI)

#define __CLEAR_REG(n, reg) MOVIMM(0,%reg)
#define CLEAR_CALLER                            \
        FOR_CALLER_SAVE(__CLEAR_REG, SEP_SEMI)

#define ARGS_FROM_STACK                                 \
        mov     (argstart + 0 * WORD_SIZE)(%rbp),arg0;  \
        mov     (argstart + 1 * WORD_SIZE)(%rbp),arg1;  \
        mov     (argstart + 2 * WORD_SIZE)(%rbp),arg2;  \
        mov     (argstart + 3 * WORD_SIZE)(%rbp),arg3;  \
        mov     (argstart + 4 * WORD_SIZE)(%rbp),arg4

#define SAVE_TO_STACK(n, reg)      mov %reg,-((n) * WORD_SIZE)(%rbp)
#define RESTORE_FROM_STACK(n, reg) mov -((n) * WORD_SIZE)(%rbp),%reg

/* Simple integer manipulation macros */
#define SETINT(x) \
        or      $1,x            /* set integer type bit */

#define INTVAL(x) \
        sar     $1,x            /* Make into normal integer */

#define MAKEINTTO(x,y) \
        lea     1(x,x),y        /* Make into mudlle integer */
#define MAKEINT(x) MAKEINTTO(x, x)
#define MAKEINTD(x) MAKEINTTO(x, x ## d)

#define ISINT(x) \
        testb   $1,x            /* Not-equal if x is an integer */

#define ISNULL(x) \
        test    x,x             /* Equal if x is NULL */

#define IS_READ_WRITE(x) \
        /* Equal if x is read/write */ \
        testb   $OBJ_READONLY,object_flags(x)

/* only clobbers %r11 */
#define CHECK_LOOP()                                    \
        mov     GA(internal_xcount),%r11;               \
        subq    $1,(%r11);                              \
        /* forward jump predicts not taken */           \
        jle     14f;                                    \
15:     mov     GA(mudlle_stack_limit),%r11;            \
        cmp     (%r11),%rsp;                            \
        jb      E(early_error_recurse);                 \
        mov     GA(minlevel),%r11;                      \
        cmpb    (%r11),arg1b;                           \
        jb      E(early_error_security_violation)

#define CHECK_LOOP_TAIL()                               \
14:     call    N(bcheck_xcount);                       \
        jmp     15b

#define E(n) N(b ## n)

/* Builtins that must preserve all non-scratch registers follow here: */

/* result = arg0 * arg1 */
GFUNC(bmultiply)
        btr     $0,arg0
        jnc     1f
        sar     $1,arg1
        jnc     0f

        imul    arg1,arg0
        lea     1(arg0), result
        ret

0:      /* restore argument values */
        SETINT(arg0b)
        add     arg1,arg1
1:      mov     GA(code_multiply),closure
        jmp     call_binary_primitive
GEND(bmultiply)

/* result = arg0 / arg1 */
GFUNC(bdivide)
        mov     arg0,result
        sar     $1,result
        jnc     2f
        sar     $1,arg1
        jnc     0f
        jz      1f
        mov     arg2,arg0       /* preserve arg2 (%rdx) */
        cqo                     /* sign extend %rax to %rdx:%rax */
        idiv    arg1            /* %rax = quotient, %rdx = remainder */
        mov     arg0,arg2       /* restore arg2 */
        MAKEINT(result)
        ret

        /* restore arguments */
0:      add     arg1,arg1
        jmp     2f
1:      MAKEINT(arg1)
2:      mov     GA(code_divide),closure
        jmp     call_binary_primitive
GEND(bdivide)

/* result = arg0 % arg1 */
GFUNC(bremainder)
        mov     arg0,result
        sar     $1,result
        jnc     2f
        sar     $1,arg1
        jnc     0f
        jz      1f
        mov     arg2,arg0       /* preserve arg2 (%rdx) */
        cqo                     /* sign extend %rax to %rdx:%rax */
        idiv    arg1            /* %rax = quotient, %rdx = remainder */
        MAKEINTTO(%rdx, result)
        mov     arg0,arg2       /* restore arg2 */
        ret

        /* restore arguments */
0:      add     arg1,arg1
        jmp     2f
1:      MAKEINT(arg1)
2:      mov     GA(code_remainder),closure
        jmp     call_binary_primitive
GEND(bremainder)

/* result = arg0 << arg1 */
GFUNC(bshift_left)
        sar     $1,arg1
        jnc     0f
        btr     $0,arg0
        jnc     1f
        xchg    %rcx,arg1
        shl     %cl,arg0
        SETINT(arg0b)
        mov     arg1,%rcx       /* restore old %rcx */
        mov     arg0,result
        ret

0:      add     arg1,arg1
        jmp     2f
1:      MAKEINT(arg1)
2:      mov     GA(code_shift_left),closure
        jmp     call_binary_primitive
GEND(bshift_left)

/* result = arg0 >> arg1 */
GFUNC(bshift_right)
        sar     $1,arg1
        jnc     0f
        test    $1,arg0b
        je      1f
        xchg    %rcx,arg1
        sar     %cl,arg0
        SETINT(arg0b)
        mov     arg1,%rcx       /* restore old %rcx */
        mov     arg0,result
        ret

0:      add     arg1,arg1
        jmp     2f
1:      MAKEINT(arg1)
2:      mov     GA(code_shift_right),closure
        jmp     call_binary_primitive
GEND(bshift_right)

LFUNC(call_binary_primitive)
        /* used to call primitive (in 'closure') to trigger errors
           with call trace */
        FUNC_ENTER
        ALIGN_STACK
        END_PREVIOUS_FRAME
        CCALL_LEAF(*closure)
        /* should never get here */
        CCALL_LEAF(SO_N(abort))
        FUNC_NORETURN
LEND(call_binary_primitive)

/* Call C code: ref, + */

GFUNC(badd)
        ISINT(arg0b)
        je      cadd
        ISINT(arg1b)
        je      cadd

        /* Integer addition */
        lea     -1(arg0,arg1),result
        ret
GEND(badd)

LFUNC(cadd)     /* Call plus primitive for string append */
        FUNC_ENTER
        ALIGN_STACK
        SAVE_CALLER
        END_PREVIOUS_FRAME
        CCALL_LEAF(N(code_plus))
        RESTORE_CALLER
        FUNC_RETURN
LEND(cadd)

GFUNC(bconcat) /* concatenate arg0 strings on stack */
        FUNC_ENTER
        ALIGN_STACK
        SAVE_CALLER
        lea     argstart(%rbp),arg1
        END_PREVIOUS_FRAME
        CCALL_LEAF(N(concat_strings))
        RESTORE_CALLER
        FUNC_RETURN
GEND(bconcat)

/* carry flag = arg0[arg1 >> 3] & (arg1 & 7) */
GFUNC(bbitref)
        mov     arg1,result
        sar     $4,result               /* result = byte offset */
        js      .Lbbitref_error

        add     $object_offset+1,result
        cmp     object_size(arg0),result
        jae     .Lbbitref_error

        sar     $1,arg1
        bt      arg1,object_offset(arg0)
        ret

.Lbbitref_error:
        mov     GA(code_bit_setp),closure
        jmp     call_binary_primitive
GEND(bbitref)

/* result = arg0[arg1] for vector arg0 */
GFUNC(bvref)
        ISINT(arg1b)
        je      cref
        mov     arg1,result

        add     result,result
        jo      cref
        add     result,result   /* result = native offset + 4 */
        jo      cref
        js      .Lvecsign       /* forward jump predicts not taken */

.Lvecnosign:
        add     $object_offset-4,result
        cmp     object_size(arg0),result
        jae     cref
        mov     (arg0,result),result
        ret

.Lvecsign:
        /* index is signed */
        add     object_size(arg0),result
        sub     $object_offset,result
        jns     .Lvecnosign
        jmp     cref
GEND(bvref)

/* result = arg0[arg1] for string arg0 */
GFUNC(bsref)
        ISINT(arg1b)
        je      cref
        mov     arg1,result
        INTVAL(result)
        js      .Lstrsign       /* forward jump predicts not taken */

.Lstrnosign:
        add     $object_offset+1,result
        cmp     object_size(arg0),result
        jae     cref
        movzb   -1(arg0,result),resultd
        MAKEINTD(result)
        ret

.Lstrsign:
        /* index is signed */
        add     object_size(arg0),result
        sub     $object_offset+1,result
        jns     .Lstrnosign
        jmp     cref
GEND(bsref)

/* result = arg0[arg1] */
GFUNC(bref)
        ISINT(arg0b)
        jne     cref

        /* causes SIGSEGV on arg0 == NULL */
        cmpb    $type_string,object_type(arg0)
        je      N(bsref)
        cmpb    $type_vector,object_type(arg0)
        je      N(bvref)
        jmp     cref
GEND(bref)
GLABEL(bref_end):

LFUNC(cref)
        FUNC_ENTER
        /* only need to save caller-saves; ref doesn't allocate */
        sub     $WORD_SIZE * NCALLER_SAVE,%rsp
        FOR_CALLER_SAVE(SAVE_TO_STACK, SEP_SEMI)
        ALIGN_STACK
        END_PREVIOUS_FRAME
        CCALL_LEAF(N(code_ref))
        FOR_CALLER_SAVE(RESTORE_FROM_STACK, SEP_SEMI)
        FUNC_RETURN
LEND(cref)

/* result = arg0[arg1] = arg2 */
GFUNC(bset)
        ISINT(arg0b)
        jne     cset

        /* causes SIGSEGV on arg0 == NULL */
        cmpb    $type_string,object_type(arg0)
        je      .Lstringset
        cmpb    $type_vector,object_type(arg0)
        jne     cset

        /* vector set */
        ISINT(arg1b)
        je      cset
        IS_READ_WRITE(arg0)
        jne     cset

        mov     arg1,arg3
        add     arg3,arg3
        jo      cset
        add     arg3,arg3       /* arg3 = native offset + 4 */
        jo      cset
        js      .Lvecsetsign    /* forward jump predicts not taken */

.Lvecsetnosign:
        add     $object_offset-4,arg3
        cmp     object_size(arg0),arg3
        jae     cset
        mov     arg2,(arg0,arg3)
        mov     arg2,result
        MOVIMM  (0,arg3)        /* give proper mudlle value */
        ret

.Lvecsetsign:
        /* index is signed */
        add     object_size(arg0),arg3
        sub     $object_offset,arg3
        jns     .Lvecsetnosign
        jmp     cset

.Lstringset:
        mov     arg2,arg4
        INTVAL(arg4)
        jnc     cset
        IS_READ_WRITE(arg0)
        jne     cset
        mov     arg1,arg3
        INTVAL(arg3)
        jnc     cset
        js      .Lstrsetsign    /* forward jump predicts not taken */

.Lstrsetnosign:
        add     $object_offset+1,arg3
        cmp     object_size(arg0),arg3
        jae     cset
        mov     arg4b,-1(arg0,arg3)
        movzbl  arg4b,resultd
        MAKEINTD(result)
        MOVIMM  (0,arg3)        /* give proper mudlle value */
        MOVIMM  (0,arg4)        /* give proper mudlle value */
        ret

.Lstrsetsign:
        add     object_size(arg0),arg3
        sub     $object_offset+1,arg3
        jns     .Lstrsetnosign
        jmp     cref
GEND(bset)
GLABEL(bset_end):

LFUNC(cset)                    /* Call set! */
        FUNC_ENTER
        ALIGN_STACK
        SAVE_CALLEE
        END_PREVIOUS_FRAME
        CCALL_LEAF(N(code_setb))
        RESTORE_CALLEE
        FUNC_RETURN
LEND(cset)

/* Special ops: bcleargc */

/* Preambles:
   bcleargc: clear stack between sp and bp, trap if not ZF (bad arguments),
             check seclevel and loop count
   bvarargs: clear stack between sp and bp, check seclevel and loop count,
             return vector of arguments
   Register usage:
     in: ZF, closure_in, seclevel in arg1
     out: closure_in unchanged
          arg vector in result for bvarargs
*/

/* Clear the allocated stack frame (between caller's %rsp and %rbp) */

/* clobbers scratch, rdi and rcx */
GFUNC(bcleargc)
        jne     E(early_error_wrong_parameters)
        CHECK_LOOP()

        /* Clear stack frame */
        MOVIMM  (0,%rax)
        lea     WORD_SIZE(%rsp),%rdi
        mov     %rbp,%rcx
        sub     %rdi,%rcx
        sar     $WORD_BITS,%rcx
        rep stosq

        ret

        CHECK_LOOP_TAIL()
GEND(bcleargc)

GFUNC(bcleargc4)
        movq    $0,(4 * WORD_SIZE)(%rsp)
GEND(bcleargc4)
GFUNC(bcleargc3)
        movq    $0,(3 * WORD_SIZE)(%rsp)
GEND(bcleargc3)
GFUNC(bcleargc2)
        movq    $0,(2 * WORD_SIZE)(%rsp)
GEND(bcleargc2)
GFUNC(bcleargc1)
        movq    $0,(1 * WORD_SIZE)(%rsp)
GEND(bcleargc1)
GFUNC(bcleargc0)
        jne     E(early_error_wrong_parameters)
        CHECK_LOOP()
        ret
        CHECK_LOOP_TAIL()
GEND(bcleargc0)

/* Input: intval(bp[-1]) arguments on stack
          intval(arg0) number of non-vararg formal arguments
   Output: vector in result
   Preserves callee-saves. */
GFUNC(bvarargs)
        mov     -WORD_SIZE(%rbp),%rax /* get argcount */
        sub     arg0,%rax       /* 2 * number of vararg arguments */
        jg      0f

        /* no varargs on stack, use the empty vector */
        mov     GA(empty_vector),%r11
        mov     (%r11),result
        jmp     1f

0:      /* have varargs on stack, allocate and copy */
        FUNC_ENTER
        push    arg0            /* preserve non-vararg arguments */
        /* allocate argument vector */
        lea     object_offset(,%rax,WORD_SIZE / 2),arg0 /* object size */
        call    N(balloc_vector)
        mov     (%rsp),arg0     /* restore arg0 */
        FUNC_LEAVE

        mov     %rcx,-WORD_SIZE(%rsp) /* preserve used register */

        mov     -WORD_SIZE(%rbp),%rcx
        INTVAL(%rcx)            /* argcount */
        INTVAL(arg0)            /* non-vararg arguments */
        sub     arg0,%rcx       /* number of vararg arguments */
        lea     argstart(%rbp,arg0,WORD_SIZE),%rsi /* start of varargs */
        lea     object_offset(result),%rdi
        rep movsq

        mov     -WORD_SIZE(%rsp),%rcx /* restore used register */

1:      ret

GEND(bvarargs)

/* Storage allocation operations */

/* Allocate arg0 bytes and return in result. The caller's stack frame
   will be GC-protected. Preserves mudlle values in all the non-scratch
   registers. Does not require stack to be aligned.*/
LFUNC(alloc_bytes)
        cmp     $MAX_MUDLLE_OBJECT_SIZE,arg0
        ja      LLAB(alloc_bytes_fail)

        mov     GA(posgen0),%r11
        mov     (%r11),result
        sub     arg0,result
        mov     GA(startgen0),%r11
        cmp     (%r11),result
        jb      LLAB(alloc_bytes_gc)

        mov     GA(posgen0),%r11
        mov     result,(%r11)
        mov     arg0,object_size(result)
#ifdef GCDEBUG
        mov     GA(minorgen),%r11
        mov     (%r11),%r11
        mov     %r11,object_gen(result)
#endif
        ret

LLAB(alloc_bytes_gc):
        FUNC_ENTER
        ALIGN_STACK
        SAVE_CALLER
        mov     arg0,%rbx       /* store arg0 in callee-saved */
        END_PARENT_FRAME
        CCALL_LEAF(N(garbage_collect))
        mov     %rbx,arg0
        RESTORE_CALLER
        FUNC_LEAVE
        jmp     alloc_bytes
        FUNC_NORETURN

LLAB(alloc_bytes_fail):
        FUNC_ENTER
        END_PARENT_FRAME
        CCALL_LEAF(SO_N(abort))
        FUNC_NORETURN

LEND(alloc_bytes)

/* Alloc variable cell, return in result */
GFUNC(balloc_variable)
        GCSTAT_ADD(type_variable, $variable_size)
        MOVIMM  (variable_size,arg0)
        call    alloc_bytes
        movq    $garbage_record | type_variable << 8,object_info(result)
        ret
GEND(balloc_variable)

/* Size of closure is in arg0, return in result */
GFUNC(balloc_closure)
        GCSTAT_ADD(type_closure, arg0)
        call    alloc_bytes
        movq    $garbage_mtemp | type_closure << 8 | OBJ_READONLY << 16, \
                object_info(result)
        ret
GEND(balloc_closure)

/* Allocate cons cell, return in arg1 */
LFUNC(alloc_cons)
        GCSTAT_ADD(type_pair, $pair_size)
        MOVIMM  (pair_size,arg0)
        call    alloc_bytes
        movq    $garbage_record | type_pair << 8,object_info(result)
        ret
LEND(alloc_cons)

/* result = cons(arg1, arg0) */
GFUNC(bcons)
        FUNC_ENTER
        push    arg1
        push    arg0
        call    alloc_cons      /* cons cell in result */
        mov     (%rsp),arg0
        mov     arg0,pair_cdr_offset(result)
        mov     WORD_SIZE(%rsp),arg0
        mov     arg0,pair_car_offset(result)
        FUNC_RETURN
GEND(bcons)

/* result = pcons(arg1, arg0) */
GFUNC(bpcons)
        FUNC_ENTER

        push    %rbx            /* save value */

        push    arg1
        push    arg0
        call    alloc_cons      /* cons cell in result */

        MOVIMM  (OBJ_IMMUTABLE,%rbx)

        mov     (%rsp),arg0     /* load arg0: the cdr */
        mov     arg0,pair_cdr_offset(result)
        ISNULL(arg0)
        je      0f
        ISINT(arg0b)
        jne     0f
        andb    object_flags(arg0),%bl

0:      mov     WORD_SIZE(%rsp),arg0    /* load arg1: the car */
        mov     arg0,pair_car_offset(result)
        ISNULL(arg0)
        je      1f
        ISINT(arg0b)
        jne     1f
        andb    object_flags(arg0),%bl

1:      orb     $OBJ_READONLY,%bl
        mov     %bl,object_flags(result)

        mov     -WORD_SIZE(%rbp),%rbx /* restore value */

        FUNC_RETURN
GEND(bpcons)

/* Allocate vector of arg0 bytes, return in result */
GFUNC(balloc_vector)
        GCSTAT_ADD(type_vector, arg0)
        call    alloc_bytes
        movq    $garbage_record | type_vector << 8,object_info(result)
        ret
GEND(balloc_vector)

/* Copy vector in arg0, return in result */
GFUNC(bvcopy)
        ISINT(arg0b)
        jne     0f
        ISNULL(arg0)
        je      0f
        cmpb    $type_vector,object_type(arg0)
        jne     0f

        mov     arg0,%rdx
        mov     object_size(arg0),arg0

        GCSTAT_ADD(type_vector, arg0)
        call    alloc_bytes
        movq    $garbage_record | type_vector << 8,object_info(result)

        mov     object_size(result),%rcx
        sub     $object_offset,%rcx
        sar     $WORD_BITS,%rcx
        lea     object_offset(%rdx),%rsi
        lea     object_offset(result),%rdi
        rep movsq
        ret

0:      MOVIMM  (1 << type_vector,arg1)
        MOVIMM  (0,arg2)
        jmp     N(btype_error)
GEND(bvcopy)

/* Compare vectors in arg0 and arg1; return boolean in result */
GFUNC(bvequalp)
        ISINT(arg0b)
        jne     0f
        ISNULL(arg0)
        je      0f
        cmpb    $type_vector,object_type(arg0)
        jne     0f

        ISINT(arg1b)
        jne     1f
        cmpb    $type_vector,object_type(arg1)
        jne     1f

        mov     object_size(arg0),%rcx
        cmp     object_size(arg1),%rcx
        jne     4f

        MOVIMM  (object_offset,%rax) /* offset into vector */
5:      cmp     %rax,%rcx
        je      3f

        mov     (arg0,%rax),%r11
        cmp     %r11,(arg1,%rax)
        jne     4f

        add     $WORD_SIZE,%rax
        jmp     5b

4:      MOVIMM  (ICST(0),result) /* return false */
        jmp     2f

3:      MOVIMM  (ICST(1),result) /* return true */
2:      MOVIMM  (0,%rcx)       /* give proper mudlle value */
        ret

1:      mov     arg1,arg0
0:      MOVIMM  (1 << type_vector,arg1)
        MOVIMM  (0,arg2)
        jmp     N(btype_error)
GEND(bvequalp)

/* sets ZF if vfind?(arg0, arg1); traps unless arg1 is a vector */
GFUNC(bvfindp)
        ISINT(arg1b)
        jne     3f
        ISNULL(arg1)
        je      3f
        cmpb    $type_vector,object_type(arg1)
        jne     3f

        mov     $object_offset,%r11d
0:      cmp     %r11,object_size(arg1)
        je      1f

        cmp     arg0,(arg1,%r11)
        je      2f

        add     $WORD_SIZE,%r11
        jmp     0b

1:      test    arg1,arg1       /* clears ZF */
2:      ret

3:      mov     arg1,arg0
        MOVIMM  (1 << type_vector,arg1)
        MOVIMM  (0,arg2)
        jmp     N(btype_error)
GEND(bvfindp)

/* arg0[i] |= arg1[i] for vectors arg0 and arg1; returns arg0 */
GFUNC(bvector_bitor)
        ISINT(arg0b)
        jne     0f
        ISNULL(arg0)
        je      0f
        cmpb    $type_vector,object_type(arg0)
        jne     0f

        ISINT(arg1b)
        jne     1f
        ISNULL(arg1)
        je      1f
        cmpb    $type_vector,object_type(arg1)
        jne     1f

        mov     object_size(arg0),%rcx
        cmp     object_size(arg1),%rcx
        jne     N(berror_bad_value)

        IS_READ_WRITE(arg0)
        jne     N(berror_variable_read_only)

        MOVIMM  (object_offset,%rax) /* offset into vector */
5:      cmp     %rax,%rcx
        je      3f

        mov     (arg1,%rax),%r11
        ISINT(%r11b)
        je      1f

        ISINT((arg0,%rax))
        je      1f

        or      %r11,(arg0,%rax)

        add     $WORD_SIZE,%rax
        jmp     5b

3:      MOVIMM  (0,%rcx)       /* give proper mudlle value */
        mov     arg0,result
        ret

1:      mov     arg1,arg0
0:      MOVIMM  (1 << type_vector, arg1)
        MOVIMM  (0,arg2)
        jmp     N(btype_error)
GEND(bvector_bitor)

GFUNC(bcall_prim)
        FUNC_ENTER
        ALIGN_STACK

        SAVE_CALLEE
        END_PREVIOUS_FRAME
        call    *closure_in
        RESTORE_CALLEE

        FUNC_RETURN
GEND(bcall_prim)

GFUNC(bcall_prim_noalloc)
        FUNC_ENTER
        ALIGN_STACK

        END_PREVIOUS_FRAME
        call    *closure_in
        CLEAR_CALLER

        FUNC_RETURN
GEND(bcall_prim_noalloc)

GFUNC(brestore_caller)
        ASSERT_STACK_UNALIGNED
        RESTORE_CALLEE
        ret
GEND(brestore_caller)

/* Interface operations:
    bcall: any call from machine language
    interpreter_invoke: machine language -> interpreter
    mc_invoke: C code -> machine language
*/

/* Call function closure_in with argcount arguments on stack */
GFUNC(bcall)
        ASSERT_STACK_UNALIGNED

        ISNULL(closure_in)
        je      bcall_error_bad_function

        ISINT(closure_inb)
        jne     bcall_error_bad_function

        mov     GA(internal_seclevel),%r11
        movb    $DEFAULT_SECLEVEL,(%r11)

        movzb   object_type(closure_in),arg2d
        cmp     $type_closure,arg2b
        je      LLAB(call_closure)

        cmp     $type_primitive,arg2b
        je      LLAB(call_primitive)

        cmp     $type_secure,arg2b
        je      LLAB(call_secure)

        cmp     $type_varargs,arg2b
        jne     bcall_error_bad_function
        /* fallthrough */

LLAB(call_varargs):
        FUNC_ENTER

        /* set up arguments */
        mov     primitive_op(closure_in),arg0
        mov     argcount,arg1
        lea     argstart(%rbp),arg2

        SAVE_CALLEE
        END_PREVIOUS_FRAME

        /* For call traces; read from handle_primitive_frame() in error.c */
        push    $0
        pushq   GA(bcall_primitive_tail)
        push    arg0
        push    arg1

        CCALL_LEAF(N(builtin_call_vararg))
        /* add  $4 * WORD_SIZE,%rsp */
        RESTORE_CALLEE

        FUNC_RETURN

LLAB(call_closure):
        mov     closure_code_offset(closure_in),%r11
        add     $mcode_code_offset,%r11
        jmp     *%r11

LLAB(call_secure):
        /* Check arg count first to give the right error message */
        mov     primitive_op(closure_in),arg5
        cmpw    primop_nargs(arg5),argcountw
        jne     bcall_error_wrong_parameters

        movzb   primop_seclevel(arg5),arg0d
        mov     GA(internal_seclevel),%r11
        cmp     arg0b,(%r11)
        jb      bcall_error_security_violation
        mov     GA(internal_maxseclevel),%r11
        mov     (%r11),arg5
        INTVAL(arg5)
        cmp     arg0,arg5
        jb      bcall_error_security_violation

        mov     primitive_op(closure_in),arg5
        jmp     N(bcall_primitive_tail)

LLAB(call_primitive):
        /* Check arg count */
        mov     primitive_op(closure_in),arg5
        cmpw    primop_nargs(arg5),argcountw
        jne     bcall_error_wrong_parameters
        /* fallthrough */

GEND(bcall)

GFUNC(bcall_primitive_tail)
        FUNC_ENTER

        /* Fetch actual C function */
        mov     primop_op(arg5),closure_in
        MOVIMM  (0,arg5)        /* give a proper mudlle value */

        /* For call traces; read from handle_primitive_frame() in error.c */
        push    GA(bcall_primitive_tail)
        push    closure_in
        push    argcount
        push    $0              /* align stack */

        SAVE_CALLEE
        END_PREVIOUS_FRAME
        ARGS_FROM_STACK
        CCALL_LEAF(*closure_in)
        RESTORE_CALLEE

        FUNC_RETURN
GEND(bcall_primitive_tail)

/* input: argcount, arguments in arg0-arg4, secure in
          closure_in, seclevel in arg5 */
GFUNC(bcall_secure)
        mov     argcount,-2*WORD_SIZE(%rsp)   /* save argcount */
        mov     closure_in,-3*WORD_SIZE(%rsp) /* save in case of error */
        mov     arg5,argcount   /* argcount now holds seclevel */

        mov     primitive_op(closure_in),closure_in
        /* Check the immediate caller's security level */
        cmpb    primop_seclevel(closure_in),argcountb
        jb      0f
        mov     GA(internal_seclevel),%r11
        mov     argcountb,(%r11)
        /* Check the session's security level */
        mov     GA(internal_maxseclevel),%r11
        mov     (%r11),argcount
        INTVAL(argcount)
        cmpb    primop_seclevel(closure_in),argcountb
        jb      0f
        /* Check arg count */
        mov     -2*WORD_SIZE(%rsp),argcount
        cmpw    argcountw,primop_nargs(closure_in)
        jne     1f

        FUNC_ENTER
        ALIGN_STACK
        mov     primop_op(closure_in),closure_in
        SAVE_CALLEE
        END_PREVIOUS_FRAME
        CCALL_LEAF(*closure_in)
        RESTORE_CALLEE
        FUNC_RETURN

0:      movq    $error_security_violation,-4*WORD_SIZE(%rsp)
        jmp     2f
1:      movq    $error_wrong_parameters,-4*WORD_SIZE(%rsp)
2:      FUNC_ENTER

        /* argcount is now at bp[-1]; callee at bp[-2]; errno at bp[-3] */
        sub     $3*WORD_SIZE,%rsp
        push    arg4
        push    arg3
        push    arg2
        push    arg1
        push    arg0
        mov     -3*WORD_SIZE(%rbp),arg0 /* errno */
        mov     -2*WORD_SIZE(%rbp),arg1 /* called function */
        mov     -WORD_SIZE(%rbp),arg2   /* argcount */
        mov     %rsp,arg3               /* argstart */

        ALIGN_STACK
        END_PREVIOUS_FRAME
        CCALL_LEAF(N(bad_call_error))
        FUNC_NORETURN
GEND(bcall_secure)

/* Call varargs prim_op in arg0 with arg1 arguments from the stack,
   at seclevel in arg2 */
GFUNC(bcall_varargs)
        FUNC_ENTER
        ASSERT_STACK_ALIGNED
        mov     GA(internal_seclevel),%r11
        movb    arg2b,(%r11)
        SAVE_CALLEE
        END_PREVIOUS_FRAME
        lea     argstart(%rbp),arg2
        CCALL_LEAF(N(builtin_call_vararg))
        RESTORE_CALLEE
        FUNC_RETURN
GEND(bcall_varargs)

/* call varargs primitive arg0 with arguments on stack (the last
   argument is a vector), at seclevel arg2 */
GFUNC(bapply_varargs)
        FUNC_ENTER
        ASSERT_STACK_ALIGNED
        mov     GA(internal_seclevel),%r11
        movb    arg2b,(%r11)
        lea     argstart(%rbp),arg1
        SAVE_CALLEE
        END_PREVIOUS_FRAME
        CCALL_LEAF(N(builtin_apply_vararg))
        RESTORE_CALLEE
        FUNC_RETURN
GEND(bapply_varargs)

/* Only clobbers %r11; if %r11 is zero, called from CHECK_LOOP();
   flags are from test of xcount */
GFUNC(bcheck_xcount)
        jne     0f

        test    %r11,%r11
        je      E(early_error_loop)
        jmp     E(error_loop)

0:      FUNC_ENTER
        sub     $WORD_SIZE * (NCALLER_SAVE + 3),%rsp
        mov     %r11,-WORD_SIZE(%rsp) /* preserve register */

        FOR_CALLER_SAVE(SAVE_TO_STACK, SEP_SEMI)
        SAVE_TO_STACK(NCALLER_SAVE + 1, rax)
        SAVE_TO_STACK(NCALLER_SAVE + 2, rsi)
        SAVE_TO_STACK(NCALLER_SAVE + 3, rdi)

        MOVIMM  (0,%rax)
        cmpq    $0,-WORD_SIZE(%rsp)
        sete    %al    /* now %rax is 1 for CHECK_LOOP; 0 otherwise */
        END_NTH_FRAME(%rax)

        ALIGN_STACK
        CCALL_LEAF(N(profile_tick))
        RESTORE_FROM_STACK(NCALLER_SAVE + 1, rax)
        RESTORE_FROM_STACK(NCALLER_SAVE + 2, rsi)
        RESTORE_FROM_STACK(NCALLER_SAVE + 3, rdi)
        FOR_CALLER_SAVE(RESTORE_FROM_STACK, SEP_SEMI)
        FUNC_RETURN
GEND(bcheck_xcount)

/* Interpret the closure in closure_in with argcount arguments on the stack */
GFUNC(interpreter_invoke)
        FUNC_ENTER

        mov     closure_in,arg0
        mov     argcount,arg1
        lea     argstart(%rbp),arg2

        SAVE_CALLEE
        END_PREVIOUS_FRAME
        CCALL_LEAF(N(builtin_call_interpreter))
        RESTORE_CALLEE
        FUNC_RETURN
GEND(interpreter_invoke)

#define INVOKE_STACK_SIZE \
        ALIGN(cc_size + cs_size + NCALLEE_SAVE * WORD_SIZE, STACK_ALIGN)

#define START_INVOKE                                    \
        FUNC_ENTER;                                     \
        sub     $INVOKE_STACK_SIZE,%rsp;                \
        /* preserve native callee-save */               \
        FOR_CALLEE_SAVE(SAVE_TO_STACK, SEP_SEMI);       \
        /* preserve clobbered registers */              \
        mov     %rdi,%r12;                              \
        mov     %rsi,%r13;                              \
        mov     %rcx,%r14;                              \
        SAVE_CCONTEXT;                                  \
        PUSH_CALL_STACK;                                \
        /* restored clobbered registers */              \
        mov     %r14,%rcx;                              \
        mov     %r13,%rsi;                              \
        mov     %r12,%rdi

#define END_INVOKE                                      \
        RESTORE_CCONTEXT;                               \
        POP_CALL_STACK;                                 \
        /* restore native callee-save */                \
        FOR_CALLEE_SAVE(RESTORE_FROM_STACK, SEP_SEMI);  \
        FUNC_RETURN

#define SAVE_CCONTEXT                           \
        mov     GA(ccontext),%r11;              \
        mov     %r11,%rsi;                      \
        mov     %rsp,%rdi;                      \
        MOVIMM  (cc_size >> WORD_BITS,%rcx);    \
        rep movsq;                              \
        mov     %rbp,cc_frame_start(%r11)

#define RESTORE_CCONTEXT                        \
        lea     -INVOKE_STACK_SIZE(%rbp),%rsi;  \
        mov     GA(ccontext),%rdi;              \
        MOVIMM  (cc_size >> WORD_BITS,%rcx);    \
        rep movsq

/* Assumes call_stack entry address in rdi */
#define PUSH_CALL_STACK                         \
        mov     GA(call_stack),%r11;            \
        mov     (%r11),%rbx;                    \
        mov     %rbx,cs_next(%rdi);             \
        movl    $call_compiled,cs_type(%rdi);   \
        mov     %rdi,(%r11)

/* Assumes call_stack entry address in %rsi */
#define POP_CALL_STACK                          \
        mov     cs_next(%rsi),%rcx;             \
        mov     GA(call_stack),%r11;            \
        mov     %rcx,(%r11)

/* Pushes contents of vector in %rsi to stack. Leave room for arg2
   extra bytes of arguments. Returns vlength(%rsi) in argcount. */
#define PUSH_VECTORARGS                         \
        /* clear possible pad area */           \
        movq    $0,-WORD_SIZE(%rsp);            \
        mov     object_size(%rsi),argcount;     \
        sub     $object_offset,argcount;        \
        sub     argcount,%rsp;                  \
        sub     arg2,%rsp;                      \
        ALIGN_STACK;                            \
        sar     $WORD_BITS,argcount;            \
        mov     argcount,%rcx;                  \
        add     $object_offset,%rsi;            \
        lea     (%rsp,arg2),%rdi;               \
        rep movsq

GFUNC(invoke1plus)
        START_INVOKE
        mov     arg0,closure
        mov     arg1,arg4
        mov     arg2,%rsi
        MOVIMM  (WORD_SIZE,arg2)
        PUSH_VECTORARGS
        add     $1,argcount
        mov     arg4,(%rsp)
        jmp     LLAB(invoke_tail)
        FUNC_NORETURN
GEND(invoke1plus)

GFUNC(invokev)
        START_INVOKE
        mov     arg0,closure
        /* arg1 (%rsi) already holds the argument vector */
        MOVIMM  (0,arg2)
        PUSH_VECTORARGS
        jmp     LLAB(invoke_tail)
        FUNC_NORETURN
GEND(invokev)

GFUNC(invoke0)
        START_INVOKE
        MOVIMM  (0,argcount)
        mov     arg0,closure
        jmp     LLAB(invoke_tail)
        FUNC_NORETURN
GEND(invoke0)

GFUNC(x64_invoke1)
        START_INVOKE
        MOVIMM  (1,argcount)
        mov     arg1,closure
        push    $0              /* align stack */
        jmp     LLAB(invoke1_tail)
        FUNC_NORETURN
GEND(x64_invoke1)

GFUNC(x64_invoke2)
        START_INVOKE
        MOVIMM  (2,argcount)
        mov     arg2,closure
        jmp     LLAB(invoke2_tail)
        FUNC_NORETURN
GEND(x64_invoke2)

GFUNC(x64_invoke3)
        START_INVOKE
        MOVIMM  (3,argcount)
        mov     arg3,closure
        push    $0              /* align stack */
        jmp     LLAB(invoke3_tail)
        FUNC_NORETURN
GEND(x64_invoke3)

GFUNC(x64_invoke4)
        START_INVOKE
        MOVIMM  (4,argcount)
        mov     arg4,closure
        jmp     LLAB(invoke4_tail)
        FUNC_NORETURN
GEND(x64_invoke4)

GFUNC(x64_invoke5)
        START_INVOKE
        MOVIMM  (5,argcount)
        mov     arg5,closure
        push    $0              /* align stack */

        push    arg4
LLAB(invoke4_tail):
        push    arg3
LLAB(invoke3_tail):
        push    arg2
LLAB(invoke2_tail):
        push    arg1
LLAB(invoke1_tail):
        push    arg0

LLAB(invoke_tail):
        CLEAR_CALLER
        mov     closure,closure_in
        mov     closure_code_offset(closure_in),%r11
        add     $mcode_code_offset,%r11
        /* make sure all non-scratch registers have valid mudlle values */
        FOR_CALLEE_SAVE(__CLEAR_REG, SEP_SEMI)

        ASSERT_STACK_ALIGNED
        call    *%r11
        END_INVOKE

GEND(x64_invoke5)

/* Put errorstubs last for branches to predict non-taken */

#define BCALLERRORSTUB(n)                       \
LFUNC(bcall_ ## n);                             \
        MOVIMM  (n,arg0);                       \
        jmp     bcall_error;                    \
LEND(bcall_ ## n)

BCALLERRORSTUB(error_bad_function)
BCALLERRORSTUB(error_security_violation)
BCALLERRORSTUB(error_wrong_parameters)

LFUNC(bcall_error)
        FUNC_ENTER
        ASSERT_STACK_ALIGNED

        mov     closure_in,arg1
        mov     argcount,arg2
        lea     argstart(%rbp),arg3

        END_PREVIOUS_FRAME
        CCALL_LEAF(N(bad_call_error))
        FUNC_NORETURN
LEND(bcall_error)

/* arg0 is the mudlle value (of bad type); arg1 is the expected typeset;
   arg2 is the (one-based) function argument number (or 0 for none) */
GFUNC(btype_error)
        FUNC_ENTER
        ALIGN_STACK
        END_PREVIOUS_FRAME
        sub $1,arg2
        CCALL_LEAF(N(bad_typeset_error))
        FUNC_NORETURN
GEND(btype_error)

/* arg0 is the mudlle value failing the pattern match */
GFUNC(bno_match_error)
        FUNC_ENTER
        ALIGN_STACK
        END_PREVIOUS_FRAME
        CCALL_LEAF(N(no_match_error))
        FUNC_NORETURN
GEND(btype_error)

LFUNC(berror)
        FUNC_ENTER
        ALIGN_STACK
        END_PREVIOUS_FRAME
        CCALL_LEAF(N(runtime_error))
        FUNC_NORETURN
LEND(berror)

#define ERRORSTUB(n)                            \
GFUNC(b ## n);                                  \
        MOVIMM  (n,arg0);                       \
        jmp     berror;                         \
GEND(b ## n)

ERRORSTUB(error_bad_function)
ERRORSTUB(error_stack_underflow)
ERRORSTUB(error_bad_type)
ERRORSTUB(error_divide_by_zero)
ERRORSTUB(error_bad_index)
ERRORSTUB(error_bad_value)
ERRORSTUB(error_variable_read_only)
ERRORSTUB(error_loop)
ERRORSTUB(error_recurse)
ERRORSTUB(error_wrong_parameters)
ERRORSTUB(error_security_violation)
ERRORSTUB(error_value_read_only)
ERRORSTUB(error_user_interrupt)
ERRORSTUB(error_no_match)
ERRORSTUB(error_compile)
ERRORSTUB(error_abort)

LFUNC(bearly_error)
        FUNC_ENTER
        ALIGN_STACK
        mov     argcount,arg1
        END_PREVIOUS_FRAME
        CCALL_LEAF(N(compiled_early_runtime_error))
        FUNC_NORETURN
LEND(bearly_error)

/* argcount must be set correctly here */
#define EARLYERRORSTUB(n)                       \
GFUNC(bearly_ ## n);                            \
        MOVIMM  (n,arg0);                       \
        jmp     bearly_error;                   \
GEND(bearly_ ## n)

EARLYERRORSTUB(error_loop)
EARLYERRORSTUB(error_recurse)
EARLYERRORSTUB(error_security_violation)
EARLYERRORSTUB(error_wrong_parameters)

LFUNC(bad_stack_align)
        FUNC_ENTER
        ALIGN_STACK
        call SO_N(abort)
        FUNC_NORETURN
LEND(bad_stack_align)

GLABEL(builtin_end):

#ifdef __MACH__
.const
#else
.section .rodata
#endif

/* These are all instruction bit patterns that are allowed to generate SIGSEGV
 * if the memory base register is the NULL pointer.
 *
 * A pattern is represented by one 'size' byte followed by two instructions,
 * each consisting of 'size' bytes.
 *
 * An allowed instruction must match the bits that are identical between the
 * two instructions.
 *
 *   %rax=0, %rdi=7
 *   %r8=8 through %r15=15 require a REX prefix
 *   %rsp=4 and %r12=12 are special and require SIB byte to encode
 */
GLABEL(valid_segvs):
.byte (0f - . - 1) / 2
        cmpb $0x55,object_type(%rax)       /* without REX prefix */
        cmpb $0xaa,object_type(%rdi)
0: .byte (0f - . - 1) / 2
        cmpb $0x55,object_type(%r8)        /* with REX prefix */
        cmpb $0xaa,object_type(%r15)
0: .byte (0f - . - 1) / 2
        cmpb $0x55,object_type(%r12)       /* with REX prefix and SIB */
        cmpb $0xaa,object_type(%r12)

0: .byte (0f - . - 1) / 2
        movzbl object_type(%rax),%eax
        movzbl object_type(%rdi),%edi
0: .byte (0f - . - 1) / 2
        movzbl object_type(%rax),%r15d
        movzbl object_type(%r15),%eax
0: .byte (0f - . - 1) / 2
        movzbl object_type(%r12),%eax
        movzbl object_type(%r12),%r15d

        /* cmpq $imm8,... */
0: .byte (0f - . - 1) / 2
        cmpq $0x55,object_size(%rax)
        cmpq $~0x55,object_size(%r15)
0: .byte (0f - . - 1) / 2
        cmpq $0x55,object_size(%r12)
        cmpq $~0x55,object_size(%r12)

        /* cmpq $imm32,... */
0: .byte (0f - . - 1) / 2
        cmpq $0x55555555,object_size(%rax)
        cmpq $~0x55555555,object_size(%r15)
0: .byte (0f - . - 1) / 2
        cmpq $0x55555555,object_size(%r12)
        cmpq $~0x55555555,object_size(%r12)

0: .byte (0f - . - 1) / 2
        mov object_size(%rax),%rax
        mov object_size(%r15),%r15
0: .byte (0f - . - 1) / 2
        mov object_size(%r12),%rax
        mov object_size(%r12),%r15

0: .byte (0f - . - 1) / 2
        mov pair_car_offset(%rax),%rax
        mov pair_cdr_offset(%r15),%r15
0: .byte (0f - . - 1) / 2
        mov pair_car_offset(%r12),%rax
        mov pair_cdr_offset(%r12),%r15

0: .byte 0
SETSIZE(N(valid_segvs))

#ifdef __linux__
.section .note.GNU-stack,"",@progbits
#endif

#endif
