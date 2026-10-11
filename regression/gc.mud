reval("gcfn = fn (f, n) [ while (n = n - 1) f() ]");

reval("vfn = fn (v...) v");
reval("gcfn((fn () vfn(10, 22)), 100000)");

reval("cfn = fn (x) fn () x");
reval("gcfn((fn () cfn(\"mad\")), 100000)");

reval("cvfn = fn (x) (fn (y) x = y)");
reval("gcfn((fn () cvfn('(1 2 3))), 100000)");

reval("consfn = fn (x) x . 1");
reval("gcfn((fn () consfn('(1 2 3))), 100000)");

reval("gcfn((fn () vector(7, 99, 544, 23, \"fun\", '(1 2 3))), 100000)");
cprim4 = vector;
reval("gcfn((fn () cprim4(7, 99, 544, 23, \"fun\", '(1 2 3))), 100000)");

/* Keep distinct movable values alive through vector allocation exhaustion,
 * explicit minor/major collections, and a subsequent exceptional unwind.
 * Identity checks catch stale copies as well as damaged contents. */
reval("""[
  | child, other, latest, i |
  child = vector(17);
  other = vector(child);
  i = 0;
  while (i < 100000) [
    latest = vector(child, other, child, i);
    assert(latest[0] == child && latest[1] == other);
    assert(latest[2] == child && latest[3] == i);
    assert(latest[1][0] == child && latest[0][0] == 17);
    if (i % 1000 == 0) [
      garbage_collect(0);
      garbage_collect(0);
      assert(latest[0] == child && latest[1][0] == child);
    ];
    i = i + 1;
  ];
  trap_error(fn () [ garbage_collect(0); 1 / 0 ], null, call_trace_on, null);
  garbage_collect(0);
  assert(latest[0] == child && latest[1] == other && other[0] == child);
]""");

reval("gcfn(fn () lappend('(1 2), '(3 4)), 100000)");

reval("gcfn(fn () make_string(10), 1000000)");
reval("gcfn(fn () ggg = make_string(10), 100000)");

gi = 999;
reval("""[
  trap_error(fn () [
    garbage_collect(0);
    1 / 0
  ], null, call_trace_on, null);
  gi
]""");
