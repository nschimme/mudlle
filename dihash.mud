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

library dihash
requires misc, sequences
defines dihash?, dihash_copy, dihash_empty!, dihash_entries, dihash_exists?,
  dihash_filter!, dihash_foreach, dihash_get, dihash_keys, dihash_list,
  dihash_map, dihash_map!, dihash_protect, dihash_reduce, dihash_ref,
  dihash_remove!, dihash_resize, dihash_resize!, dihash_set!, dihash_size,
  dihash_sorted_vector, dihash_vector, ihash_to_dihash, make_dihash
[
  | div_used, div_data, vslot_next, vslot_key, vslot_data, vslot_entries,
    next_size, good_size, get_entry |

  div_used = 0;
  div_data = 1;

  vslot_next = 0;               // null for last, false for deleted
  vslot_key  = 1;
  vslot_data = 2;
  vslot_entries = 3;

  assert(MAX_VECTOR_SIZE == 2097150); // change next_size() if this changes

  next_size = fn (int size)
    [
      | sizes, i |

      // random primes near 2^n * 3
      sizes = '[ 3 5 11 19 41 79 163 317 641 1279 2557 5119 10243 20479 40961
		 81919 163841 327673 655357 1310719 ,MAX_VECTOR_SIZE ,MAXINT ];
      i = 0;
      while (size >= sizes[i])
	++i;
      sizes[i]
    ];

  // should return a "nice" hash vector size to use given that we have
  // used number of entries
  good_size = fn (int used)
    used * 3 / 2;

  make_dihash = fn """[`n] -> `d. Creates an empty dynamic-sized integer\
 indexed hash table, optionally initialized to size `n""" ({int} size = null)
    vector(0, if (integer?(size)) make_vector(size) else '[]);

  dihash? = fn "`x -> `b. Returns true if `x could be a dihash" (x)
    (vector?(x) && vlength(x) == 2
     && integer?(x[div_used]) && x[div_used] >= 0
     && vector?(x[div_data]));

  dihash_resize = fn """`d0 `n -> `d1. Return a copy of dihash `d0 with `n\
 slots, or a reasonable amount of slots if `n < 0""" (vector hash, int size)
    [
      | new |
      if (size < 0)
	size = good_size(hash[div_used]);

      if (size == 0 && hash[div_used] > 0)
        error(error_bad_value);

      new = make_vector(size);

      dihash_foreach(fn (key, value) [
	| slot, v |
	slot = abs(key) % size;
	v = vector(new[slot], key, value);
	new[slot] = v
      ], hash);

      vector(hash[div_used], new)
    ];

  dihash_resize! = fn """`d `n -> `d. Resize dihash `d to have `n slots, or a\
 reasonable amount of slots if `n < 0""" (vector hash, int size)
    [
      | new |
      if (size < 0)
	size = good_size(hash[div_used]);

      if (size == 0 && hash[div_used] > 0)
        error(error_bad_value);

      if (size == vlength(hash[div_data]))
        exit<function> hash;

      new = make_vector(size);
      vforeach(fn (v) [
	while (v != null)
	  [
            assert(vlength(v) == vslot_entries); // optimization
	    | this, slot |
	    this = v;
	    v = v[vslot_next];
	    slot = abs(this[vslot_key]) % size;
	    this[vslot_next] = new[slot];
	    new[slot] = this;
	  ];
      ], hash[div_data]);
      hash[div_data] = new;
      hash
    ];

  get_entry = fn (vector hash, int key, make?)
    [
      | size, idx |
      size = vlength(hash[div_data]);
      if (size > 0)
	[
	  | v |
          idx = abs(key) % size;
	  v = hash[div_data][idx];
	  loop
	    [
	      if (v == null)
		exit null;
              assert(vlength(v) == vslot_entries); // optimization
	      if (v[vslot_key] == key)
		exit<function> v;
	      v = v[vslot_next];
	    ];
	];

      if (!make?)
        exit<function> false;

      if (hash[div_used] * 3 >= size * 2)
	[
	  size = next_size(size);
	  dihash_resize!(hash, size);
	  idx = abs(key) % size;
	];

      | slot |
      slot = vector(hash[div_data][idx], key, null);
      hash[div_data][idx] = slot;
      ++hash[div_used];
      slot
    ];

  dihash_set! = fn "`d `n `x -> `x. Set entry `n to `x in dihash `d"
    (vector hash, int key, value)
    get_entry(hash, key, true)[vslot_data] = value;

  | internal_dihash_get |
  internal_dihash_get = fn (hash, key, x)
    [
      | e |
      e = get_entry(hash, key, false);
      if (e)
        e[vslot_data]
      else
        x
    ];

  dihash_get = fn """`d `n `x0 -> `x1. Returns dihash data for index `n or `x0\
 if unset. Cf. `dihash_ref().""" (vector hash, int key, x)
    internal_dihash_get(hash, key, x);

  dihash_ref = fn """`d `n -> `x. Returns dihash data for index `n or null.\
 Cf. `dihash_get().""" (vector hash, int key)
    internal_dihash_get(hash, key, null);

  dihash_reduce = fn """`c `x0 `d -> `x1. Returns the reduction `c(`k, `e, `x)\
 -> `x for each element `e with key `k in dihash `d"""
    (function func, x, vector hash)
    [
      | i, data, len |
      i = 0;
      data = hash[div_data];
      len = vlength(data);
      loop
	[
	  | v |
	  if (i == len)
	    exit x;
	  v = data[i++];
	  while (v != null)
	    [
              assert(vlength(v) == vslot_entries); // optimization
              | n |
              n = v[vslot_next]; // preserve in case func() deletes this entry
	      x = func(v[vslot_key], v[vslot_data], x);
	      v = n
	    ]
	]
    ];

  dihash_protect = fn """`d -> `d. Make dihash `d protected (read-only). Does\
 not recurse into contained data.""" (vector hash)
    [
      vforeach(fn (v) [
        while (v != null)
          [
            protect(v);
            v = v[vslot_next];
          ];
      ], hash[div_data]);
      protect(hash)
    ];

  dihash_foreach = fn """`c `d -> . Runs `c(`n, `x) for each entry in dihash\
 `d, with key `n and value `x.""" (function func, vector hash)
    [
      dihash_reduce(fn (key, value, f) [
        f(key, value);
        f
      ], func, hash);
      null
    ];

  dihash_filter! = fn """`c `d -> `d. Filters data in dihash `d with function\
 `c(`n, `x)""" (function func, vector hash)
    [
      | used, hdata |
      used = 0;
      hdata = hash[div_data];
      for (|vi| vi = vlength(hdata); --vi >= 0; )
        <nbucket> [
          | v |
          v = hdata[vi];
          if (v == null)
            exit<nbucket> null; // empty bucket (somewhat common case)

          // find the first element to include
          loop
            [
              assert(vlength(v) == vslot_entries); // optimization
              if (func(v[vslot_key], v[vslot_data]))
                exit null;
              v = v[vslot_next];
              if (v == null)
                exit null;
            ];

          hdata[vi] = v;
          if (v == null)
            exit<nbucket> null; // no items

          ++used;
          | last |
          last = v;
          for (|n| ; (n = v[vslot_next]) != null; v = n)
            [
              assert(vlength(n) == vslot_entries); // optimization
              if (func(n[vslot_key], n[vslot_data]))
                [
                  ++used;
                  last[vslot_next] = n;
                  last = n;
                ]
              else
                v[vslot_next] = null; // help GC
            ];
          last[vslot_next] = null;
        ];
      hash[div_used] = used;
      hash
    ];

  dihash_remove! = fn """`d `n -> `b. Removes entry `n from dihash `d. Returns\
 true if the entry was found""" (vector hash, int key)
    [
      | slot, v, size, hdata |
      hdata = hash[div_data];
      size = vlength(hdata);
      if (size == 0)
        exit<function> false;

      slot = abs(key) % size;
      v = hdata[slot];
      if (v == null)
        exit<function> false;

      // check if the first entry is a match
      assert(vlength(v) == vslot_entries); // optimization
      if (v[vslot_key] == key)
        [
          hdata[slot] = v[vslot_next];
          v[vslot_next] = false; // help GC
          --hash[div_used];
          exit<function> true;
        ];

      for (|n| ; (n = v[vslot_next]) != null; v = n)
        [
          assert(vlength(n) == vslot_entries); // optimization
          if (n[vslot_key] == key)
            [
              v[vslot_next] = n[vslot_next];
              n[vslot_next] = false; // help GC
              --hash[div_used];
              exit<function> true;
            ];
        ];
      false
    ];

  dihash_empty! = fn "`d -> `d. Remove all entries from dihash `d"
    (vector hash)
    [
      if (hash[div_used])
        [
          hash[div_used] = 0;
          vmap!(fn (v) [
            // unlink lists to help GC
            while (v != null)
              [
                | next |
                next = v[vslot_next];
                v[vslot_next] = false;
                v = next
              ];
            null
          ], hash[div_data]);
        ];
      hash
    ];

  dihash_map! = fn """`c `d -> `d. Maps all entries `x0 with key `i to `c(`i,\
 `x0) -> `x1 in the dihash `d""" (function func, vector hash)
    [
      vforeach(fn (v) [
        loop
          [
            if (v == null)
              exit null;
            assert(vlength(v) == vslot_entries); // optimization
            v[vslot_data] = func(v[vslot_key], v[vslot_data]);
            v = v[vslot_next]
          ];
      ], hash[div_data]);
      hash
    ];

  dihash_map = fn """`c `d0 -> `d1. Return a new dihash as mapped by `c(`i,\
 `x0) -> `x1 for each entry in the dihash""" (function func, vector hash)
    [
      | new |
      new = make_dihash(good_size(hash[div_used]));
      dihash_foreach(fn (key, value) dihash_set!(new, key, func(key, value)),
                     hash);
      new
    ];

  dihash_copy = fn """`d0 -> `d1. Returns a copy of dihash `d0."""
    (vector hash)
    dihash_map(fn (key, value) value, hash);

  dihash_entries = int fn """`d -> `n. Returns the number of entries in the\
 dihash `d""" (vector hash)
    hash[div_used];

  dihash_size = fn "`d -> `n. Returns the current size of the dihash `d"
    (vector hash)
    vlength(hash[div_data]);

  dihash_keys = fn """`d -> `l. Returns a unsorted copy of all the keys of `d\
 as a list""" (vector hash)
    dihash_reduce(fn (k, e, keys) k . keys, null, hash);

  dihash_list = list fn """`d -> `l. Returns a list of (`key . `value) of the\
 entries in dihash `d""" (vector hash)
    dihash_reduce(fn (k, e, x) (k . e) . x, null, hash);

  | internal_dihash_vector |
  internal_dihash_vector = fn (hash)
    [
      | i |
      i = 0;
      dihash_reduce(fn (n, x, res) [
	res[i++] = n . x;
        res
      ], make_vector(hash[div_used]), hash);
    ];

  dihash_vector = fn """`d -> `v. Returns a vector of (`key . `value) of the\
 entries in dihash `d""" (vector hash)
    internal_dihash_vector(hash);

  dihash_sorted_vector = fn """`d -> `v. Returns a vector of (`key . `value)\
 of the entries in dihash `d, ordered by lowest keys first.""" (vector hash)
    vqsort!(fn (a, b) car(a) < car(b), internal_dihash_vector(hash));

  dihash_exists? = fn """`c `d -> `x. Returns (`key . `value) for the first\
 entry in dihash `d, for which `c(`key, `value) is true; false if none\
 found.""" (function func, vector hash)
    [
      | result |
      result = false;
      vexists?(fn (v) [
        while (v != null)
          [
            assert(vlength(v) == vslot_entries); // optimization
            if (func(v[vslot_key], v[vslot_data]))
              [
                result = v[vslot_key] . v[vslot_data];
                exit<function> true;
              ];
            v = v[vslot_next];
          ];
        false
      ], hash[div_data]);
      result
    ];

  ihash_to_dihash = vector fn """`i -> `d. Returns a dihash of the data stored\
 in the legacy ihash `i, a vector of lists of cons(`key, `value)."""
    (vector ihash)
    vreduce(fn (l, dh) lreduce(fn (@(key . value), dh) [
      dihash_set!(dh, key, value);
      dh
    ], dh, l), make_dihash(), ihash);

]
