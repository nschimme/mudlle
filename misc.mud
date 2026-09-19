/*
 * Copyright (c) 1993-2012 David Gay
 * All rights reserved.
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose, without fee, and without written agreement is hereby granted,
 * provided that the above copyright notice and the following two paragraphs
 * appear in all copies of this software.
 *
 * IN NO EVENT SHALL DAVID GAY BE LIABLE TO ANY PARTY FOR DIRECT, INDIRECT,
 * SPECIAL, INCIDENTAL, OR CONSEQUENTIAL DAMAGES ARISING OUT OF THE USE OF
 * THIS SOFTWARE AND ITS DOCUMENTATION, EVEN IF DAVID GAY HAVE BEEN ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 *
 * DAVID GAY SPECIFICALLY DISCLAIM ANY WARRANTIES, INCLUDING, BUT NOT LIMITED
 * TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE.  THE SOFTWARE PROVIDED HEREUNDER IS ON AN "AS IS" BASIS, AND DAVID
 * GAY HAVE NO OBLIGATION TO PROVIDE MAINTENANCE, SUPPORT, UPDATES,
 * ENHANCEMENTS, OR MODIFICATIONS.
 */

library misc // Miscellaneous useful functions
requires sequences
defines abbrev?, assert, assert_message, assoc, assq, bcomplement,
  bcomplement!,  bcopy, bforeach, bsearch, bitset_map_list,
  bitset_list, bitset_ffs, breduce,
  bits_foreach, bits_filter, bits_reduce, bits_exists,
  caaar, caadr, caar, cadar, caddr, cadr, cdaar, cdadr, cdar, cddar,
  cdddr, cddr,
  less_than, greater_than,
  concat_words, difference, fail, fail_message, find_word?,
  intersection, last_element, last_pair, list_first_n!, list_index,
  list_to_vector, lprotect, lqsort, mappend, member, memq, nth,
  nth_element, nth_pair, random_element,
  proper_list?, repeat,
  set_eq?, set_in?, skip_white, sorted_table_list,
  string_head?, string_ljustify, string_ljustify_cut,
  string_rindex, string_rjustify, string_rjustify_cut, string_tail,
  union, unquote, vector_exists_index, vector_index, vector_rindex,
  vector_to_list, vequal?, vector_bitor!, vqsort!, vqsort_slice!,
  call_cc,
  types_from_typeset
[

less_than = fn "`n0 `n1 -> `b. Returns true if `n0 is less than `n1."
  (int a, int b) a < b;

greater_than = fn "`n0 `n1 -> `b. Returns true if `n0 is greater than `n1."
  (int a, int b) a > b;

repeat = fn "`n `f -> . Execute `f() `n times" (int n, function f)
  while (n-- > 0) f();

lprotect = fn "`l -> `l. Protects list `l" (list l)
  [
    for (|t| t = l; t != null && !immutable?(t); t = cdr(protect(t)) )
      null;
    l
  ];

caar = fn "`x0 -> `x1. Returns car(car(`x0))" (pair x) car(car(x));
cadr = fn "`x0 -> `x1. Returns car(cdr(`x0))" (pair x) car(cdr(x));
cddr = fn "`x0 -> `x1. Returns cdr(cdr(`x0))" (pair x) cdr(cdr(x));
cdar = fn "`x0 -> `x1. Returns cdr(car(`x0))" (pair x) cdr(car(x));
caaar = fn "`x0 -> `x1. Returns car(car(car(`x0)))" (pair x) car(car(car(x)));
caadr = fn "`x0 -> `x1. Returns car(car(cdr(`x0)))" (pair x) car(car(cdr(x)));
cadar = fn "`x0 -> `x1. Returns car(cdr(car(`x0)))" (pair x) car(cdr(car(x)));
caddr = fn "`x0 -> `x1. Returns car(cdr(cdr(`x0)))" (pair x) car(cdr(cdr(x)));
cdaar = fn "`x0 -> `x1. Returns cdr(car(car(`x0)))" (pair x) cdr(car(car(x)));
cdadr = fn "`x0 -> `x1. Returns cdr(car(cdr(`x0)))" (pair x) cdr(car(cdr(x)));
cddar = fn "`x0 -> `x1. Returns cdr(cdr(car(`x0)))" (pair x) cdr(cdr(car(x)));
cdddr = fn "`x0 -> `x1. Returns cdr(cdr(cdr(`x0)))" (pair x) cdr(cdr(cdr(x)));

assert = fn "`b -> . Cause `error_abort if `b is false" (b) if (!b) fail();
assert_message = fn """`b `s -> . Cause `error_abort and display message `s if\
 `b is false""" (b, string s)
  if (!b) error_message(error_abort, s);
fail = none fn "-> . Cause `error_abort." () error(error_abort);
fail_message = fn "`s -> . Cause `error_abort and display message `s."
  (string s)
  error_message(error_abort, s);

union = fn "`l1 `l2 -> `l3. Set union of `l1 and `l2" (list l1, list l2)
  // Types: l1, l2: set
  // Returns: The set union (comparison with ==) of l1 and l2.
  [
    | result |

    result = l1;
    while (l2 != null)
      [
	| f2 |

	if (!memq(f2 = car(l2), l1)) result = f2 . result;
	l2 = cdr(l2)
      ];
    result
  ];

intersection = fn "`l1 `l2 -> `l3. Set intersection of `l1 and `l2"
  (list l1, list l2)
  // Types: l1, l2: set
  // Returns: The set intersection (comparison with ==) of l1 and l2.
  [
    | result |

    while (l1 != null)
      [
	| f |
	if (memq(f = car(l1), l2)) result = f . result;
	l1 = cdr(l1)
      ];
    result
  ];

difference = fn "`l1 `l2 -> `l3. Set difference of `l1 and `l2"
  (list l1, list l2)
  // Types: l1, l2: set
  // Returns: The set difference (comparison with ==) of l1 and l2.
  [
    | result |

    while (l1 != null)
      [
	| f |
	if (!memq(f = car(l1), l2)) result = f . result;
	l1 = cdr(l1)
      ];
    result
  ];

set_in? = fn "`l1 `l2 -> `b. True if `l1 is a subset of `l2" (list s1, list s2)
  // Types: s1, s2: set
  // Returns: TRUE if s1 is a subset of s2
  loop
    if (s1 == null) exit true
    else if (!memq(car(s1), s2)) exit false
    else s1 = cdr(s1);

set_eq? = fn "`l1 `l2 -> `b. True if set `l1 == set `l2" (list s1, list s2)
  // Types: s1, s2: set
  // Returns: TRUE if s1 == s2
  set_in?(s1, s2) && set_in?(s2, s1);

vector_index = fn "`x `v -> `n. Finds index of `x in `v, or -1 if none"
  (x, vector v)
  [
    | check, max |
    check = 0;
    max = vlength(v);
    loop
      if (check == max) exit -1
      else if (v[check] == x) exit check
      else ++check
  ];

vector_rindex = fn """`x `v -> `n. Finds index of last `x in `v, or -1 if\
 none""" (x, vector v)
  [
    | check |
    check = vlength(v);
    loop
      if (check == 0) exit -1
      else if (v[--check] == x) exit check
  ];

vector_exists_index = fn """`f `v -> `n. Returns the index of first element `x\
 of `v for which `f(`x) is true, or -1 if none""" (function f, vector v)
  [
    | l, i |

    l = vlength(v);
    i = 0;
    loop
      if (i == l) exit -1
      else if (f(v[i])) exit i
      else ++i
  ];

string_rindex = fn """`s `n1 -> `n2. Finds last index of char `n1 in `s, or -1\
 if none""" (string str, int n)
  [
    n &= 255;
    for (|i| i = slength(str); i > 0; )
      if (str[--i] == n) exit<function> i;
    -1
  ];

vequal? = fn """`v1 `v2 -> `b. True if the elements of `v1 are == to\
 those of `v2""" (vector v1, vector v2)
  [
    | l |
    l = vlength(v1);
    if (l != vlength(v2)) false
    else
      [
	while (--l >= 0)
	  if (v1[l] != v2[l]) exit<function> false;
	true
      ]
  ];

vector_bitor! = fn """`v1 `v2 -> `v1. Set each element in `v1 to the\
 bitwise OR of the corresponding element in `v2.""" (vector v1, vector v2)
  [
    | l |
    l = vlength(v1);
    if (vlength(v2) != l)
      error(error_bad_value);
    while (--l >= 0)
      v1[l] |= v2[l];
    v1
  ];

lqsort = fn """`f `l0 -> `l1. Sort `l0 according to `f(`x0, `x1) -> `b, which\
 should return true if `x0 goes before `x1.""" (function f, list l)
  vector_to_list(vqsort!(f, list_to_vector(l)));

[
  | insertion_sort! |
  insertion_sort! = fn (function f, vector v, int start, int end)
    [
      for (|i| i = start + 1; i < end; ++i)
        [
          | j, e, ej |
          e = v[i];
          j = i;
          while (j > start && !f(ej = v[j - 1], e))
            v[j--] = ej;
          v[j] = e
        ];
      v
    ];

  | subsort, insertion_sort_cutoff |

  insertion_sort_cutoff = 10; // from a few manual tests

  subsort = fn (function f, vector v, int low, int high)
    for (|work| ; ;)
      [
        if (low + insertion_sort_cutoff >= high)
          [
            // insertion sort the rest
            if (work == null)
              exit null;
            @[work low high] = work;
          ];

        | pivpos, pivot, free, pos_low, pos_high, x |
        pivpos = random(low, high);
        pivot = v[pivpos];
        v[pivpos] = v[high];
        free = high;
        pos_low = low;
        pos_high = high - 1;
        <separate> loop // scan up from low
          [
            x = v[pos_low];
            ++pos_low;
            if (!f(x, pivot)) // x must move above pivot
              [
                v[free] = x;
                // where x was is now free
                free = pos_low - 1;

                // scan down from high
                loop
                  [
                    if (pos_low > pos_high) exit<separate> 0;
                    x = v[pos_high];
                    --pos_high;
                    if (f(x, pivot)) // x must move below pivot
                      [
                        v[free] = x;
                        // where x was is now free
                        free = pos_high + 1;
                        exit 0
                      ]
                  ]
              ];
            if (pos_low > pos_high) exit<separate> 0;
          ];
        v[free] = pivot;

        // put the shorter half on the work stack; iterate with the longer
        | wlow, whigh |
        if (high - free >= free - low)
          [
            wlow = low;
            whigh = free - 1;
            low = free + 1
          ]
        else
          [
            wlow = free + 1;
            whigh = high;
            high = free - 1
          ];

        if (wlow + insertion_sort_cutoff < whigh)
          work = vector(work, wlow, whigh);
      ];

  vqsort_slice! = fn """`f `n0 `n1 `v -> `v. Sort the `n1 items in `v starting\
 with index `n0 according to `f(`x0, `x1) -> `b which should return true if\
 `x0 sorts before `x1.
Cf. `vqsort!().""" (function f, int start, int length, vector v)
    [
      if (start < 0)
        start += vlength(v);
      | end |
      end = start + length;
      if (!(start >= 0 && start <= end && end <= vlength(v)))
        error(error_bad_value);
      subsort(f, v, start, end - 1);
      insertion_sort!(f, v, start, end)
    ];

  vqsort! = fn """`f `v -> `v. Sort `v according to `f(`x0, `x1) -> `b which\
 should return true if `x0 sorts before `x1.
Cf. `vqsort_slice!().""" (function f, vector v)
    [
      | len |
      len = vlength(v);
      subsort(f, v, 0, len - 1);
      insertion_sort!(f, v, 0, len)
    ];
];

mappend = fn """`f `l1 -> `l2. Like `lmap, but (destructively) appends the\
 results of `f(`x) for each element `x in `l1 together""" (function f, list l)
  [
    | result, tail |
    while (l != null)
      <next> [
        | e, il |
        @(e . l) = l;
        il = f(e);
        if (il == null) exit<next> null;

        if (tail == null)
          tail = result = il
        else
          [
            tail = last_pair(tail);
            set_cdr!(tail, il);
          ];
      ];
    result
  ];

memq = fn """`x `l -> `p. Returns the first pair `p of list `l whose\
 `car is == `x, or `false if none""" (x, list l)
  loop
    if (l == null) exit false
    else if (x == car(l)) exit l
    else l = cdr(l);

member = fn """`x `l -> `p. Returns the first pair `p of list `l whose `car is\
 `equal? to `x, or `false if none""" (x, list l)
  loop
    if (l == null) exit false
    else if (equal?(x, car(l))) exit l
    else l = cdr(l);

assq = fn """`x `l -> `p. Looks for a pair in `l whose `car is == to `x.\
 Returns that pair, false if not found""" (x, list l)
  loop
    [
      if (l == null) exit false;
      | item |
      item = car(l);
      if (car(item) == x) exit item;
      l = cdr(l)
    ];

assoc = fn """`x `l -> `p. Looks for a pair in `l whose `car is `equal? to `x.\
 Returns that pair, false if not found""" (x, list l)
  loop
    [
      if (l == null) exit false;
      | item |
      item = car(l);
      if (equal?(car(item), x)) exit item;
      l = cdr(l)
    ];

nth = fn "`n `l -> `x. Returns `n'th (one-based) element of list `l"
  (int n, list l)
  [
    while (--n > 0)
      l = cdr(l);
    car(l)
  ];

proper_list? = fn """`x -> `b. True if `x is a null-terminated list. Handles\
 loops.""" (l)
  [
    | slowl, n |
    slowl = l;                  // detects loops; Floyd's algorithm
    n = 0;
    loop
      [
        if (l == null) exit true;
        if (!pair?(l)) exit false;
        l = cdr(l);
        if (n)
          [
            slowl = cdr(slowl);
            if (l == slowl) exit false;
          ];
        n ^= 1;
      ]
  ];

| my:llen |
my:llen = llength;

list_to_vector = fn "`l -> `v. Makes a vector out of a list" (list lst)
  [
    | vec, i |
    vec = make_vector(my:llen(lst));
    i = 0;
    while (pair?(lst))
      [
        vec[i] = car(lst);
        ++i;
        lst = cdr(lst);
      ];
    vec
  ];

vector_to_list = fn "`v -> `l. Makes a vector into a list" (vector v)
  [
    | len, l |
    len = vlength(v);
    while (--len >= 0)
      l = v[len] . l;
    l
  ];

sorted_table_list = fn """`table -> `l. Returns a list of the symbols in\
 `table, sorted by name (case-sensitive for ctables).""" (table table)
  vector_to_list(sorted_table_vector(table));

/// Ancalagon's stuff

/// LIST FUNCTIONS

nth_pair = fn """`n `l -> `x. Return pair number `n in `l (1-based), or the\
 last `cdr if there are not enough elements.""" (int n, list lst)
  [
    while (pair?(lst) && n > 1)
      [
        lst = cdr(lst);
        --n;
      ];
    if (n == 1) lst else null;
  ];

nth_element = fn "`n `l -> `x. Returns element `n (1-based) of a list or null"
  (int n, list lst)
  [
    | nth |
    nth = nth_pair(n, lst);
    if (pair?(nth)) car(nth) else null;
  ];

random_element = fn "`l -> `x. Returns a random element in list `l or null"
  (list lst)
  if (lst == null)
    null
  else
    nth_element(random(1, llength(lst)), lst);

last_pair = fn "`l0 -> `l1. Returns the last pair of list `l0, or null."
  (list lst)
  [
    | tail |
    while (pair?(lst))
      [
        tail = lst;
        lst = cdr(lst);
      ];
    tail;
  ];

last_element = fn "`l -> `x. Returns the last element of list `l or null"
  (list lst)
  [
    | res |
    res = last_pair(lst);
    if (pair?(res)) car(res) else null;
  ];

list_first_n! = fn """`n `l -> `l. Returns first `n elements of `l, or the\
 whole list of `n is larger than the number of elements.""" (int n, list lst)
  [
    if (n == 0) exit<function> null;
    | nth |
    nth = nth_pair(n, lst);
    if (pair?(nth))
      set_cdr!(nth, null);
    lst
  ];

list_index = fn """`x `l -> `n. Returns the index of `x in `l (1-based), or\
 false""" (x, list lst)
  [
    |count|
    count = 1;
    while (pair?(lst))
      [
        if (car(lst) == x) exit<function> count;
        ++count;
        lst = cdr(lst);
      ];
    false
  ];

/// STRING FUNCTIONS

string_tail = fn """`s `n -> `s. Returns the tail of `s starting from\
 position `n""" (string str, int from)
  substring(str, from, if (from < 0) -from else slength(str) - from);

string_head? = fn """`s1 `s2 `n -> `b. True if `s1 = first of `s2, min `n\
 characters (case and accentuation insensitive)"""
  (string head, string whole, int n)
  [
    | hlen |

    hlen = slength(head);

    if (hlen < n || hlen > slength(whole))
      exit<function> false;

    for (|i|i = 0; i < hlen; ++i)
      if (cicmp(head[i], whole[i]) != 0)
        exit<function> false;
    true;
];

abbrev? = fn """`s1 `s2 -> `b. Returns true if `s1 is an abbreviation of `s2\
 (case and accentuation insensitive)""" (string a, string b)
  [
    | la |
    la = slength(a);
    la && la <= slength(b) && string_nicmp(a, b, la) == 0
  ];

find_word? = fn """`s1 `s2 -> `b. True if `s1 is a word in the `s2 sentence,\
 as seen by `split_words().""" (string word, string sent)
  lexists?(fn (x) !string_icmp(word, x), split_words(sent)) != false;

unquote = fn """`s1 -> `s2. Returns `s1 without any surrounding single or\
 double quotes""" (string s)
  [
    | c, l |
    l = slength(s);
    if (l <= 1)
      exit<function> s;
    c = s[0];
    if ((c == ?\' || c == ?\") && s[l - 1] == c)
      substring(s, 1, l - 2)
    else
      s
  ];

skip_white = fn """`s1 -> `s2. Returns `s1 without any leading white space.\
 May return `s1 unmodified.""" (string s)
  [
    | n, l |
    n = 0;
    l = slength(s);
    while (n < l && cspace?(s[n]))
      ++n;
    if (n == 0)
      s
    else
      substring(s, n, l - n)
  ];

| string_lpad |
string_lpad = fn (string s, int n)
  [
    | r, l |
    r = make_string(n);
    l = slength(s);
    for (|i| i = 0; i < n; ++i)
      r[i] = if (i < l) s[i] else ?\ ;
    r
  ];

string_ljustify = fn """`s1 `n -> `s2. Left justifies `s1 in a field `n\
 characters wide""" (string s, int n)
  if (slength(s) >= n)
    s
  else
    string_lpad(s, n);

string_ljustify_cut = fn """`s1 `n -> `s2. Left justifies `s1 in a field `n\
 characters wide. Truncates `s1 if necessary. May return `s1 unmodified."""
  (string s, int n)
  [
    | l |
    l = slength(s);
    if (l == n)
      s
    else if (l > n)
      substring(s, 0, n)
    else
      string_lpad(s, n);
  ];

| string_rpad |
string_rpad = fn (string s, int n)
  [
    | r, b |
    r = make_string(n);
    b = n - slength(s);
    for (|i| i = 0; i < n; ++i)
      r[i] = if (i < b) ?\  else s[i - b];
    r
  ];

string_rjustify = fn """`s1 `n -> `s2. Right justifies `s1 in a field `n\
 characters wide""" (string s, int n)
  if (slength(s) >= n)
    s
  else
    string_rpad(s, n);

string_rjustify_cut = fn """`s1 `n -> `s2. Right justifies `s1 in a field `n\
 characters wide. Truncates `s1 if necessary. May return `s1 unmodified."""
  (string s, int n)
  [
    | l |
    l = slength(s);
    if (l == n)
      s
    else if (l > n)
      substring(s, 0, n)
    else
      string_rpad(s, n)
  ];

[
  | op |
  op = make_string_port();

  concat_words = fn """`l `s1 -> `s2. Assembles a list of a string into a\
 single string with `s1 as separator""" (list l, string sep)
    if (l == null)
      ""
    else if (cdr(l) == null)
      [
        | s |
        s = car(l);
        if (!string?(s))
          error(error_bad_type);
        s
      ]
    else
      [
        port_empty!(op);
        loop
          [
            pprint(op, car(l));
            l = cdr(l);
            if (l == null)
              exit port_string(op);
            pprint(op, sep)
          ]
      ];
];

// Bitsets (basic operations are in C)

bcopy = fn "`b0 -> `b1. Returns a copy of `b0." (string s) s + "";

bitset_map_list = list fn """`bitset `map -> `l. Returns a list of `map[`i]\
 for all bits `i in `bitset, highest bit first.
`map must be a vector or a string.""" (string set, {vector,string} map)
  breduce(fn (i, l) map[i] . l, null, set);

bitset_list = list fn """`bitset -> `l. Returns a list of all set bits in\
 `bitset, highest bit first.""" (string set)
  breduce(fn (i, l) i . l, null, set);

breduce = fn """`f `x0 `bitset -> `x. Reduces `bitset by `x = `f(`i, `x) for\
 each bit `i (lowest bit first), and initial value `x0."""
  (function f, x, string b)
  [
    for (| l, i, n | [ i = n = 0; l = slength(b) ]; i < l; [ ++i; n += 8 ])
      for (| bi | bi = b[i]; bi; )
        [
          | bit |
          bit = ffs(bi) - 1;
          x = f(n + bit, x);
          bi &= ~(1 << bit)
        ];
    x
  ];

bitset_ffs = fn """`bitset -> `n. Returns the position of the first bit set in\
 `bitset.
The least significant bit is position 1.
If `bitset has no set bits, 0 is returned."""
  (string b)
  [
    for (| l, i | [ i = 0; l = slength(b) ]; i < l; ++i)
      [
        | n |
        n = ffs(b[i]);
        if (n > 0)
          exit<function> (i << 3) + n;
      ];
    0
  ];

bcomplement! = fn """`bitset1 -> `bitset1. `bitset1 = ~`bitset1 (beware extra\
 bits)""" (string b1)
  [
    | l |

    l = slength(b1);
    while (--l >= 0) b1[l] = ~b1[l];
    b1
  ];

bcomplement = fn """`bitset1 -> `bitset2. `bitset2 = ~`bitset1 (beware extra\
 bits)""" (string b1)
  [
    | b2 |

    sfill!(b2 = bcopy(b1), 255);
    bdifference!(b2, b1)
  ];

bforeach = fn """`f `bitset -> . Calls `f(`i) for each bit `i set in `bitset,\
 lowest bit first.""" (function f, string b)
  [
    for (| l, i, n | [ i = n = 0; l = slength(b) ]; i < l; [ ++i; n += 8 ])
      for (| bi | bi = b[i]; bi; )
        [
          | bit |
          bit = ffs(bi) - 1;
          f(n + bit);
          bi &= ~(1 << bit)
        ];
    null
  ];

bsearch = fn """`f `bitset -> `n. Returns the number `n of the lowest bit set\
 in `bitset for which `f(`n) returns true, or -1 if none."""
  (function f, string b)
  [
    for (| l, i, n | [ i = n = 0; l = slength(b) ]; i < l; [ ++i; n += 8 ])
      for (| bi | bi = b[i]; bi; )
        [
          | bit, bpos |
          bit = ffs(bi) - 1;
          bpos = n + bit;
          if (f(bpos))
            exit<function> bpos;
          bi &= ~(1 << bit)
        ];
    -1
  ];

bits_foreach = fn """`c `n -> . Calls `c(`i) for each bit `i set in `n, lowest\
 bit first.""" (function f, int n)
  loop
    [
      if (n == 0) exit null;
      | bit |
      bit = ffs(n) - 1;
      f(bit);
      n &= ~(1 << bit);
    ];

bits_filter = fn "`c `n0 -> `n1. Filters the bits `i in `n0 by `c(`i)"
  (function f, int n)
  [
    | r |
    r = 0;
    loop
      [
        if (n == 0) exit r;
        | bit, mask |
        bit = ffs(n) - 1;
        mask = 1 << bit;
        if (f(bit))
          r |= mask;
        n &= ~mask;
      ];
  ];

bits_reduce = fn """`c `x0 `n -> . Reduce `n by `x = `c(`i, `x) for each bit\
 `i set in `n (lowest bit first), and initial value `x0."""
  (function f, x, int n)
  loop
    [
      if (n == 0) exit x;
      | bit |
      bit = ffs(n) - 1;
      x = f(bit, x);
      n &= ~(1 << bit);
    ];

bits_exists = fn """`c `n0 -> `n1. Returns the lowest set bit `i in `n0 for\
 which `c(`i), or -1 if none""" (function f, int n)
  loop
    [
      if (n == 0) exit -1;
      | bit |
      bit = ffs(n) - 1;
      if (f(bit)) exit bit;
      n &= ~(1 << bit);
    ];

call_cc = fn """`f0 -> `x0. Call `f0(`f1), where `f1(`x1) can be used to\
 return `x1 from the call to `call_cc.""" (function f)
[
  | call_cc2 |

  call_cc2 = fn (buf)
    f([
        | continuation |
        // "useless" variable to name the function
        continuation = fn "`x -> . Continuation function from `call_cc()" (x)
          longjmp(buf, x);
        continuation
    ]);

  setjmp(call_cc2)
];

// save on frequent allocations
| static_type_pairs |
static_type_pairs = make_vector(mudlle_synthetic_types);
for (|t| t = 0; t < mudlle_synthetic_types; ++t)
  static_type_pairs[t] = '(,t);
protect(static_type_pairs);

types_from_typeset = fn """`n -> `l. Returns a (possibly immutable) list of\
 types (`type_xxx or `stype_xxx constants) included in the typesets `n\
 (bitwise OR of 1 << `type_xxx).""" (int typeset)
  [
    if ((typeset & ~(typeset_any | typeset_false)) != 0)
      error(error_bad_value);

    // optimize common cases
    if (typeset == typeset_any)
      exit<function> static_type_pairs[stype_any];

    if (typeset == 0)
      exit<function> static_type_pairs[stype_none];

    for (|r, t| t = stype_none + 1; ; ++t)
      [
        if (t == mudlle_synthetic_types)
          t = 0
        else if (t == stype_bigint_like
                 && (typeset & typeset_float_like) == typeset_float_like)
          exit<continue> null;

        | ts |
        ts = type_typesets[t];
        if ((typeset & ts) == ts)
          [
            typeset &= ~ts;
            if (r == null)
              r = static_type_pairs[t]
            else
              r = t . r;
            if (typeset == 0)
              exit r;
          ]
      ]
  ];

];
