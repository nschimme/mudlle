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

library dlist // Doubly-linked, circular list
defines dcons!, dremove!, dmerge!, dnext, dsnext, dprev, dsprev, dget, dset!,
  dlength, dlist_to_list
[
  // representation uses a triple cell: [ contents next prev ]
  // an empty list is represented by null

  dcons! = fn """`x `d1 -> `d2. Inserts a new dlist node with value `x in\
 front of node `d1 and returns the new node `d2.""" (x, {vector,null} d)
    if (d == null)
      [
        | new |
        new = vector(x, null, null);
        new[1] = new[2] = new
      ]
    else
      [
        | new |
        new = vector(x, d, d[2]);
        d[2][1] = new;
        d[2] = new
      ];

  dremove! = {vector,null} fn "`d1 `d2 -> `d3. Removes `d1 from the dlist with\
 head `d2. Returns the new head `d3." (vector del, vector head)
    if (del != head)
      [
        del[1][2] = del[2];
        del[2][1] = del[1];
        head
      ]
    else if (del[1] == head) // last element!
      null
    else
      [
        del[1][2] = del[2];
        del[2][1] = del[1];
        del[1]
      ];

  dmerge! = fn """`d1 `d2 -> `d3. The dlist `d1 is inserted in front of dlist\
 `d2. Returns the dlist starting at `d1."""
    ({vector,null} d1, {vector,null} d2)
    if (d1 == null)
      d2
    else if (d2 == null)
      d1
    else
      [
        | lastd1, lastd2 |
        lastd1 = d1[2];
        lastd2 = d2[2];

        lastd1[1] = d2;
        d2[2] = lastd1;

        lastd2[1] = d1;
        d1[2] = lastd2;

        d1
      ];

  dnext = vector fn "`d1 -> `d2. Returns the node after the dlist node `d1."
    (vector d)
    d[1];
  dsnext = {null,vector} fn """`d1 `d2 -> `d3. Returns the dlist node after\
 `d1 or null if at the end of the dlist. `d2 is the dlist head."""
    (vector d1, vector d2)
    if (d1[1] == d2) null else d1[1];
  dprev = vector fn "`d1 -> `d2. Returns the node before the dlist node `d1."
    (vector d)
    d[2];
  dsprev = {null,vector} fn "`d1 `d2 -> `d3. Returns the dlist node before\
 `d1, or null if at beginning of the dlist. `d2 is the dlist head."
    (vector d1, vector d2)
    if (d1[2] == d2) null else d1[2];
  dget = fn "`d -> `x. Returns the contents of dlist node `d." (vector d) d[0];
  dset! = fn "`d `x -> `x. Sets the contents of dlist node `d to `x."
    (vector d, x)
    d[0] = x;

  dlength = fn "`d -> `n. Returns the number of elements in dlist `d."
    ({vector,null} d)
    [
      if (d == null) exit<function> 0;
      | l, scan |
      l = 1;
      scan = d[1];
      while (scan != d)
        [
          scan = scan[1];
          l = l + 1;
        ];
      l
    ];

  dlist_to_list = fn "`d -> `l. Returns a conventional list from a\
 doubly-linked list." ({vector,null} d)
    [
      if (d == null) exit<function> null;

      | l, scan |
      // scan backwards
      scan = d[2];
      while (scan != d)
        [
          l = scan[0] . l;
          scan = scan[2];
        ];
      d[0] . l
    ];
]
