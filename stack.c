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

#include "alloc.h"
#include "error.h"
#include "stack.h"


#define STACK_SIZE 256
#define LARGE_STACK 1024

struct env *stack;

/* Note: This stack never shrinks except when cleared.
   This shouldn't be changed */

void stack_init(void)
{
  stack_clear();
  staticpro(&stack);
}

void stack_clear(void)
{
  assert(stack == NULL || intval(stack->used) == 0);
  if (stack == NULL || vector_len(stack->values) > LARGE_STACK)
    stack = alloc_env(STACK_SIZE);
}

value stack_pop(void)
{
  ulong used = intval(stack->used);
  if (used == 0)
    runtime_error(error_stack_underflow);
  stack->used = mudlle_iadd(stack->used, -1);
  return stack->values->data[used - 1];
}

void stack_push(value v)
{
  GCCHECK(v);
  env_add_entry(stack, v);
}

value stack_get(ulong idx)
{
  ulong used = intval(stack->used);
  if (used <= idx)
    runtime_error(error_stack_underflow);
  return stack->values->data[used - idx - 1];
}

void stack_set(ulong idx, value v)
{
  GCCHECK(v);
  ulong used = intval(stack->used);
  if (used <= idx)
    runtime_error(error_stack_underflow);
  stack->values->data[used - idx - 1] = v;
}

ulong stack_depth(void)
{
  return uintval(stack->used);
}
