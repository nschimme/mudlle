This document describes how to write correct code considering mudlle's
garbage collection.

# Garbage collector overview

Mudlle's garbage collector (GC) is a copying two-generational garbage
collector. All newly allocated objects go in generation 0. Immutable
objects are migrated to generation 1 by GC sweeps.

An immutable object must only reference immutable values. Generation 1 is not
scanned during minor collections, so an immutable vector containing a mutable
generation 0 object would retain a stale pointer when that child moves. Readonly
does not imply immutable, and being a compiler constant does not establish
immutability. Check the actual elements before setting `OBJ_IMMUTABLE` on a
constructed vector.

All mudlle values except `null`, integers, and static strings are
stored in GC memory. Mudlle `null` is represented by C `NULL`, mudlle
integers are ``intptr_t``/``long`` C integers with the lowest bit
set to 1. All other mudlle objects are C pointers to `struct obj`.
Specific types like `struct string` all have a `struct obj` as their
first field.

Any mudlle allocation may trigger a GC, unless
`alloc_available(bytes)` returns true. A GC may invalidate all
pointers to GC objects as it may move GC objects to a new memory
location. You need to explicitly _protect_ all variables that may
point to GC objects if you need to access them after any operation
that may cause a mudlle allocation. All protected variables will be
repointed to the new object location if it moves.

These variables are automatically protected:

* statically protected using `staticpro()`
* dynamically protected using `dynpro()`/`undynpro()` or `protect()`/`unprotect()`
* locally protected using `GCPRO()`/`UNGCPRO()` or `GCPROV()`/`UNGCPROV()`
* a number of compiler-, interpreter-, and session-specific variables

See `forward_roots()` in `alloc.c` for details.

# Local variables

Whenever you have C function arguments and other local variables that
may point to GC memory, you have to protect them across any function
call that may cause memory allocations.

The simplest mechanism is using `GCPRO()`/`UNGCPRO()`:

```C
void f(value v)
{
  GCPRO(v);
  struct string *s = alloc_string("test");
  UNGCPRO();
    :
  /* safe to use 'v' and 's' */
}
```

This is only needed if you are going to _read_ those variables after
the call.

```C
struct list *make_list_of(value v)
{
  struct list *l = alloc_list(v, NULL);
  /* we are not using 'v' beyond this point; no protected needed */
  return l;
}
```

If you cannot prove that a function call doesn't cause mudlle memory
allocations, it is best practice to protect all your mudlle variables
(that will be read at a later point) using `GCPRO()`.

All variables must have valid mudlle values while protected. The
easiest is to initialize them all to `NULL` before calling `GCPRO()`
or similar:

```C
void f(void)
{
  value a = NULL, b = NULL, c = NULL;
  GCPRO(a, b, c);
  a = alloc_string("x");
  b = alloc_list(NULL, NULL);
  c = alloc_vector(3);
    :
  UNGCPRO();
}
```

## Advanced usage

The `GCPRO()`-protected variables are stored in a stack and any
`GCPRO()` must be matched with a corresponding `UNGCPRO()` in
first-in, last-out order. If a mudlle exception occurs, the stack is
automatically popped to the correct location.

You cannot have multiple `GCPRO()`/`UNGPRO()` calls in the same code
block. Use `GCPROV()`/`UNGCPROV()` to name a `struct gcpro` variable
where to store this stack entry if you need to work around that.

It is actually safe to call `UNGCPRO()` corresponding to a deeper
(earlier) `GCPRO()` call. That will pop the stack to that location:

```C
void f(value a)
{
  GCPRO(a);
  /* safely use 'a' */
    :
  struct string *s = alloc_string("string");
  struct gcpro inner_gcpro;
  GCPROV(inner_gcpro,  s);
  /* safe to use 'a' and 's' */
    :
  /* UNGCPROV(inner_gcpro) is not needed here */
  UNGCPRO();
}
```

# Long-lived variables

For variables that must live outside the function where they are
allocated, the easiest is to use `dynpro()`/`undynpro()`:

```C
struct data {
  union dynpro_string name;
};

struct data *alloc_data(const char *name)
{
  struct data *data = malloc(sizeof *data);
  /* the dynpro object must be zero-initialized */
  data->name = (union dynpro_string){ 0 };
  dynpro(&data->name, alloc_string(name));
  return data;
}

struct string *get_name(struct data *data)
{
  return data->name.str;
}

void free_data(struct data *data)
{
  undynpro(&data->name);
  free(data);
}
```

The different `union dynpro_<type>` types contain a field that exposes
the value it holds as the correct pointer: `str` for strings, `v` for
vectors, and `l` for lists (pairs). See the `FOR_DYNPROS()` macro in
`alloc.h`.

`maybe_dynpro()` and `maybe_undynpro()` are slightly optimized
variants that only add the variables to the list of protected
variables if they point to GC memory.

`protect()` and `unprotect()` wrap `malloc()`/`dynpro()` and
`undynpro()`/`free()` in a user-friendly way.

# Static variables

For static variables that will point to GC memory until the program
shuts down, use `staticpro(&var)`.

# Sequence points

Special care needs to be taken to avoid accessing mudlle variables and
allocating GC memory in the same C statement (between sequence
points).

For example if `v` is a mudlle value, `f(v, alloc_string(...))` has
undefined behavior. If `v` is evaluated before `alloc_string()` is
called, it can be invalidated by a GC triggered by the allocation.

## Vectors

There is a helper macro `SET_VECTOR(vec, idx, val)` which does
`vec->data[idx] = val`, except that it guarantees to evaluate `val`
before `vec`. It is equivalent to:

```C
  value __v = (val);
  (vec)->data[idx] = __v;
```

Note that `vec` must be GC-protected. Example use:

```C
struct vector *three_strings(const char *a, const char *b, const char *c)
{
  struct vector *v = alloc_vector(3);
  GCPRO(v);
  SET_VECTOR(v, 0, alloc_string(a));
  SET_VECTOR(v, 1, alloc_string(b));
  SET_VECTOR(v, 2, alloc_string(c));
  UNGCPRO();
  return v;
}
```

You don't have to use `SET_VECTOR()` unless the `val` expression does
any GC-allocation. There's no harm in doing it though.

## Tables

There is no special magic for tables, so you must manually make sure
to first compute any value before calling `table_set()` or similar to
store it into a table:

```C
void table_set_float(struct table *t, const char *field, double d)
{
  GCPRO(t);
  struct mudlle_float *f = alloc_float(d);
  UNGCPO();
  table_set(t, field, f);
}
```

# Integer tricks

You can embed C bitfields in a mudlle integer using the
`MUDLLE_VALUE_UNION()` macro. This is useful to prevent the GC from
rewriting them, and you're using a mudlle object (like a vector) to
store them.

```C
MUDLLE_VALUE_UNION(
  my_foo,
  int foo     : 4,
  long unused : TAGGED_INT_BITS - 4);

/* the 'unused' field is there to ensure that '(union my_foo){ .i = ...}' zeroes
   those bits */

value foo_as_value(int foo)
{
  /* you _must_ set the 'isint' field to true */
  union my_ints u = { .i = { .isint = true, .foo = foo } };
  return u.v;
}

int foo_from_value(value v)
{
  union my_ints u = { .v = v };
  return u.i.foo;
}
```

In a similar vein, to save a C pointer as a mudlle integer, use
`set_tagged_ptr()` and `get_tagged_ptr()`.

# Bigints

The pointers inside mudlle's `struct bigint` may be corrupted by the
GC. Before using them you must call `check_bigint()` on such a
variable if a GC could have run before the last call to
`check_bigint()`.
