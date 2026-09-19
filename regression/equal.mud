// Test some aspects of equal?().

t = fn (a, b) equal?(a, b) && equal?(b, a) || (1 / 0);
f = fn (a, b) !equal?(a, b) && !equal?(b, a) || (1 / 0);

a = vector(0, 1);
t(a, a);
b = vector(0, 1);
t(a, b);

f(a, '[ 1 0 ]);
f(a, '[0]);
f(a, '[]);
f(a, null);
f(a, 0);

a[0] = a;
f(a, b);
b[0] = b;
t(a, b);

b[0] = a;
f(a, b);
a[0] = b;
t(a, b);

t('{"a" = "x"}, '{"A" = "x"});
f('{"a" = "x"}, '{"A" = "X"});
a = make_table();
b = make_table();
t(a, b);
f(a, '{"a" = 0});
t(a, '{"a" = ()});
a["a"] = 1;
f(a, b);
b["a"] = 1;
t(a, b);
a["a"] = a;
b["a"] = a;
f(a, b);
b["a"] = b;
t(a, b);

t("ab", "ab");
f("ab", "Ab");
f("a", "a\0b");
t("a\0b", "a\0b");

t(1.0, 1.0);
f(1.0, 1);
f(a = fsqrt(-1), fsqrt(-1));
t(a, a);
