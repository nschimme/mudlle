/*
 * Copyright (c) 1993-2006 David Gay and Gustav H�llberg
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

struct local_value *addtail(block_t heap, valuelist *list, value lvalue)
{
  struct local_value *newp = allocate(heap, sizeof *newp);

  GCCHECK(lvalue);
  newp->lvalue = lvalue;
  newp->prev = list->last;
  newp->next = NULL;
  if (!list->first) list->first = list->last = newp;
  else
    {
      list->last->next = newp;
      list->last = newp;
    }

  return newp;
}
