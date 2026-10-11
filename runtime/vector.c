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

#include "check-types.h"
#include "prims.h"
#include "vector.h"

struct vector *empty_vector;

static enum runtime_error ct_vector_index(long idx, const char **errmsg,
                                          struct vector *vec, bool beyond,
                                          long *dst)
{
  if (idx < 0)
    idx += vector_len(vec);
  if (idx < 0 || (ulong)idx >= vector_len(vec) + beyond)
    {
      *errmsg = "vector index out of range";
      return error_bad_index;
    }
  *dst = idx;
  return error_none;
}

#define __CT_VEC_IDX_E(v, msg, dst_vec_beyond)                          \
  ct_vector_index(v, msg, ARGN2 dst_vec_beyond,                         \
                  ARGN3 dst_vec_beyond, &(ARGN1 dst_vec_beyond))
#define CT_VEC_IDX(dst, vec, beyond) \
  CT_INT_P((dst, vec, beyond), __CT_VEC_IDX_E)

TYPEDOP(vectorp, "vector?", "`x -> `b. True if `x is a vector", (value v),
        OP_LEAF | OP_NOALLOC | OP_NOESCAPE | OP_TRIVIAL, "x.n")
{
  return makebool(TYPE(v, vector));
}

TYPEDOP(make_vector, , "`n -> `v. Create an all-null vector of length `n,"
        " where 0 <= `n <= `MAX_VECTOR_SIZE.", (value msize),
        OP_LEAF | OP_NOESCAPE | OP_TRIVIAL, "n.v")
{
  long size;
  CHECK_TYPES(msize, CT_RANGE(size, 0, MAX_VECTOR_SIZE));
  return alloc_vector(size);
}

TYPEDOP(vlength, , "`v -> `n. Returns the length of vector `v.",
        (struct vector *vec),
        OP_LEAF | OP_NOALLOC | OP_NOESCAPE | OP_TRIVIAL, "v.n")
{
  CHECK_TYPES(vec, vector);
  return makeint(vector_len(vec));
}

TYPEDOP(vfillb, "vfill!",
        "`v `x -> `v. Set all elements of `v to `x",
        (struct vector *vec, value x),
        OP_LEAF | OP_NOALLOC | OP_NOESCAPE | OP_TRIVIAL, "vx.1")
{
  CHECK_TYPES(vec, vector,
              x,   any);
  size_t len = vector_len(vec);
  /* allow readonly for empty vector */
  if (len == 0)
    return vec;

  if (obj_readonlyp(&vec->o))
    RUNTIME_ERROR(error_value_read_only, NULL);

  while (len-- > 0)
    vec->data[len] = x;

  return vec;
}

value vector_ref(struct vector *vec, value midx, const struct prim_op *op)
{
  long idx;
  CHECK_TYPES_OP(op,
                 vec,  vector,
                 midx, CT_VEC_IDX(idx, vec, false));
  return vec->data[idx];
}

TYPEDOP(vector_ref, , "`v `n -> `x. Return the `n'th element of `v.\n"
        "Negative `n are counted from the end of `v.",
        (struct vector *vec, value midx),
        OP_LEAF | OP_NOALLOC | OP_NOESCAPE | OP_TRIVIAL, "vn.x")
{
  return vector_ref(vec, midx, THIS_OP);
}

value vector_set(struct vector *vec, value midx, value x,
                 const struct prim_op *op)
{
  long idx;
  CHECK_TYPES_OP(op,
                 vec,  vector,
                 midx, CT_VEC_IDX(idx, vec, false),
                 x,    any);
  if (obj_readonlyp(&vec->o))
    RUNTIME_ERROR(error_value_read_only, NULL);
  vec->data[idx] = x;
  return x;
}

TYPEDOP(vector_set, "vector_set!",
        "`v `n `x -> `x. Set the `n'th element of `v to `x.\n"
        "Negative `n are counted from the end of `v.",
        (struct vector *vec, value midx, value x),
        OP_LEAF | OP_NOALLOC | OP_NOESCAPE | OP_TRIVIAL, "vnx.3")
{
  return vector_set(vec, midx, x, THIS_OP);
}

TYPEDOP(vswap, "vswap!",
        "`v `n0 `n1 -> `v. Swaps elements `n0 and `n1 in the vector `v.",
        (struct vector *v, value idx0, value idx1),
        OP_LEAF | OP_NOALLOC | OP_NOESCAPE | OP_TRIVIAL, "vnn.v")
{
  long a, b;
  CHECK_TYPES(v,    vector,
              idx0, CT_VEC_IDX(a, v, false),
              idx1, CT_VEC_IDX(b, v, false));
  if (obj_readonlyp(&v->o))
    RUNTIME_ERROR(error_value_read_only, NULL);
  value e = v->data[a];
  v->data[a] = v->data[b];
  v->data[b] = e;
  return v;
}

VAROP(vector, , "`x0 `x1 ... -> `v. Returns a vector of the arguments",
      (struct vector *args),
      OP_LEAF | OP_NOESCAPE | OP_TRIVIAL | OP_VARARG_COPY, "x*.v")
{
  return args;
}

VAROP(sequence, ,
      "`x0 `x1 ... -> `v. Returns a read-only vector of the arguments",
      (struct vector *args),
      OP_LEAF | OP_NOESCAPE | OP_CONST | OP_TRIVIAL | OP_VARARG_COPY, "x*.v")
{
  /* we could create immutable vectors here by scanning all args... */
  return make_readonly(args);
}

static struct vector *indexed_vector(struct vector *args,
                                     bool readonly, const struct prim_op *op)
{
  const size_t nargs = vector_len(args);
  enum runtime_error error;
  long size = 0;
  long idx = -1;
  for (size_t i = 0; i < nargs; ++i)
    {
      struct list *p = args->data[i];
      if (!TYPE(p, pair) || !(p->car == NULL || integerp(p->car)))
        {
          error = error_bad_type;
          goto got_error;
        }
      if (p->car == NULL)
        ++idx;
      else
        idx = intval(p->car);
      if (idx < 0 || idx >= MAX_VECTOR_SIZE)
        {
          error = error_bad_index;
          goto got_error;
        }
      if (size <= idx)
        size = idx + 1;
    }

  GCPRO(args);
  struct vector *result = alloc_vector(size);
  UNGCPRO();

  bool immutable = readonly;
  idx = -1;
  for (size_t i = 0; i < nargs; ++i)
    {
      struct list *p = args->data[i];
      if (p->car == NULL)
        ++idx;
      else
        idx = intval(p->car);
      value val = p->cdr;
      result->data[idx] = val;
      immutable = immutable && immutablep(val);
    }
  if (readonly)
    result->o.flags |= OBJ_READONLY | (immutable ? OBJ_IMMUTABLE : 0);
  return result;

 got_error:
  primitive_runtime_error(error, op, NARGSPLUS(0), args);
}

VAROP(indexed_sequence, ,
      "`p0 `p1 ... -> `v. Returns a read-only, possibly immutable, vector"
      " built from the arguments, each a cons(`n<`i>|null, `x<`i>) where"
      " `x<`i> is the data at index `n<`i>.\n"
      "If an index `n<`i> is null, this item will be placed at the index"
      " following the previous item.\n"
      "Later entries overwrite earlier if the same index is used several"
      " times.\n"
      "Unused indices are left as null.",
      (struct vector *args),
      OP_LEAF | OP_NOESCAPE | OP_CONST, "k*.v")
{
  return indexed_vector(args, true, THIS_OP);
}

VAROP(indexed_vector, ,
      "`p0 `p1 ... -> `v. Returns a vector built from the arguments,"
      " each a cons(`n<`i>|null, `x<`i>) where `x<`i> is the data at"
      " index `n<`i>.\n"
      "If an index `n<`i> is null, this item will be placed at the index"
      " following the previous item.\n"
      "Later entries overwrite earlier if the same index is used several"
      " times.\n"
      "Unused indices are left as null.",
      (struct vector *args),
      OP_LEAF | OP_NOESCAPE, "k*.v")
{
  return indexed_vector(args, false, THIS_OP);
}

const struct prim_op *const indexed_sequence_ext = &op_indexed_sequence;

TYPEDOP(vindexed_sequence, ,
        "`v0 -> `v1. Returns a read-only, possibly immutable, vector built"
        " from the items in `v0, each a cons(`n<`i>|null, `x<`i>) where"
        " `x<`i> is the data at index `n<`i>.\n"
        "If an index `n<`i> is null, this item will be placed at the index"
        " following the previous item.\n"
        "Later entries overwrite earlier if the same index is used several"
        " times.\n"
        "Unused indices are left as null.",
        (struct vector *args), OP_LEAF | OP_NOESCAPE | OP_CONST, "v.v")
{
  CHECK_TYPES(args, vector);
  return indexed_vector(args, true, THIS_OP);
}

void vector_init(void)
{
  empty_vector = alloc_vector(0);
  staticpro(&empty_vector);

  DEFINE(vectorp);
  DEFINE(make_vector);
  DEFINE(vlength);
  DEFINE(vfillb);
  DEFINE(vector_ref);
  DEFINE(vector_set);
  DEFINE(vector);
  DEFINE(sequence);
  DEFINE(vswap);

  DEFINE(indexed_sequence);
  DEFINE(vindexed_sequence);
  DEFINE(indexed_vector);

  DEFINE_INT(MAX_VECTOR_SIZE);
}
