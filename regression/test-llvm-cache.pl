#!/usr/bin/perl
# Copyright (c) 2026 Nils Schimmelmann
# All rights reserved.
#
# Permission to use, copy, modify, and distribute this software for any
# purpose, without fee, and without written agreement is hereby granted,
# provided that the above copyright notice and the following two paragraphs
# appear in all copies of this software.
#
# IN NO EVENT SHALL NILS SCHIMMELMANN BE LIABLE TO ANY PARTY FOR DIRECT,
# INDIRECT, SPECIAL, INCIDENTAL, OR CONSEQUENTIAL DAMAGES ARISING OUT OF THE
# USE OF THIS SOFTWARE AND ITS DOCUMENTATION, EVEN IF NILS SCHIMMELMANN HAS
# BEEN ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
#
# NILS SCHIMMELMANN SPECIFICALLY DISCLAIMS ANY WARRANTIES, INCLUDING, BUT NOT
# LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A
# PARTICULAR PURPOSE.  THE SOFTWARE PROVIDED HEREUNDER IS ON AN "AS IS"
# BASIS, AND NILS SCHIMMELMANN HAS NO OBLIGATION TO PROVIDE MAINTENANCE,
# SUPPORT, UPDATES, ENHANCEMENTS, OR MODIFICATIONS.

# Exercise the LLVM native-object cache through fresh Mudlle processes.

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use Getopt::Long;
use lib dirname(abs_path(__FILE__));
use BenchLib qw(slurp spew run_command);

my $ROOT = abs_path(dirname(abs_path(__FILE__)) . '/..');
my $SUCCESS = 'LLVM_CACHE_TEST_OK';

sub fail { die join('', @_) . "\n" }

sub run {
    my ($binary, $script, $cache, $optimization, %opt) = @_;
    my $trace = $opt{trace} // 1;
    my %env = %ENV;
    $env{MUDLLE_LLVM_CACHE} = defined $cache ? $cache : '';
    delete $env{MUDLLE_LLVM_OPT};
    $env{MUDLLE_LLVM_OPT} = $optimization if defined $optimization;
    delete $env{MUDLLE_LLVM_VERIFY_EACH};
    $env{MUDLLE_LLVM_VERIFY_EACH} = $opt{verify_each} if defined $opt{verify_each};
    if ($trace) {
        $env{MUDLLE_LLVM_CACHE_TRACE} = '1';
    } else {
        delete $env{MUDLLE_LLVM_CACHE_TRACE};
    }

    my $dir = tempdir('mudlle-llvm-script-XXXXXX', TMPDIR => 1, CLEANUP => 1);
    my $source = "$dir/script.mud";
    spew($source, qq(load("xc.mud");\n) . $script);
    my ($code, $stdout, $stderr) =
        run_command([$binary, '-e', $source], cwd => $ROOT, env => \%env);
    if ($code != 0 || index($stdout, $SUCCESS) < 0) {
        fail "Mudlle did not reach its success sentinel (exit $code)\n",
             "stdout:\n$stdout\nstderr:\n$stderr";
    }
    my @traces = $stderr =~ /^LLVM object cache (hit|miss)$/mg;
    return [\@traces, $stdout, $stderr];
}

sub expect_trace {
    my ($label, $result, @expected) = @_;
    my ($traces, $stdout, $stderr) = @$result;
    return if "@$traces" eq "@expected";
    fail "$label: expected cache trace [@expected], got [@$traces]\n",
         "stdout:\n$stdout\nstderr:\n$stderr";
}

sub simple_script {
    return <<"EOS";
[
  | source, tree, prelinked, linked, function |
  source = "fn (x) x + 40";
  tree = mudlle_parse(source, "cache-test.mud", false);
  prelinked = mc:compile(tree, false, 1, mc:source_code(source));
  if (!vector?(prelinked)) error(error_bad_value);
  linked = mc:linkrun(prelinked, 1, true);
  if (!pair?(linked)) error(error_bad_value);
  function = car(linked);
  if (function(2) != 42) error(error_bad_value);
  display("$SUCCESS");
];
EOS
}

sub invalid_ir_script {
    return <<"EOS";
[
  | ir, error |
  ir = "define i64 \@verify_bad(i64 %env, ptr %args, i64 %nargs) {\\n"
       + "entry: br i1 true, label %left, label %right\\n"
       + "left: %v = add i64 1, 2\\n"
       + "br label %right\\n"
       + "right: ret i64 %v\\n}\\n";
  error = trap_error(
    fn () llvm_load_ir_closure(ir, "verify_bad", 0, 1, vector(vector(), vector())),
    fn (n) n, call_trace_off, null);
  assert(error == error_bad_value);
  display("$SUCCESS");
];
EOS
}

sub cache_files {
    my ($directory) = @_;
    return -d $directory ? sort glob("$directory/*.cache") : ();
}

# 64-bit FNV-1a, wrapping modulo 2**64 via signed integer arithmetic.
my $FNV_OFFSET = do { no warnings; unpack("q<", pack("Q<", 0xcbf29ce484222325)) };

sub fnv1a {
    use integer;
    my ($bytes) = @_;
    my $hash = $FNV_OFFSET;
    $hash = ($hash ^ $_) * 1099511628211 for unpack('C*', $bytes);
    return $hash;
}

sub validate_cache_file {
    my ($path) = @_;
    my $data = slurp($path);
    fail "cache file is shorter than its header: $path" if length $data < 24;
    my ($key_size, $object_size, $checksum) = unpack('Q<Q<q<', $data);
    fail "cache file has an empty key or object: $path"
        if $key_size == 0 || $object_size == 0;
    fail "cache file lengths do not match its header: $path"
        if length $data != 24 + $key_size + $object_size;
    fail "cache object checksum does not match: $path"
        if fnv1a(substr($data, 24 + $key_size)) != $checksum;
    return substr($data, 24, $key_size);
}

sub main {
    my $mudlle = "$ROOT/mudlle";
    GetOptions('mudlle=s' => \$mudlle)
        or die "usage: $0 [--mudlle PATH]\n";
    my $binary = abs_path($mudlle) // '';
    -f $binary or die "Mudlle executable not found: $mudlle\n";

    my $base = tempdir('mudlle-llvm-cache-test-XXXXXX', TMPDIR => 1, CLEANUP => 1);

    # A fresh process populates the cache; another process reuses it.
    my $cache = "$base/cold-warm";
    expect_trace('cold process', run($binary, simple_script(), $cache), 'miss');
    expect_trace('warm process', run($binary, simple_script(), $cache), 'hit');
    my @files = cache_files($cache);
    fail 'expected one cache entry, found ' . @files if @files != 1;
    validate_cache_file($files[0]);

    # Reusing one object twice must not collide in ORC's module namespace.
    my $duplicate_script = <<"EOS";
[
  | source, tree, prelinked, first, second, f1, f2 |
  source = "fn (x) x + 40";
  tree = mudlle_parse(source, "cache-duplicate.mud", false);
  prelinked = mc:compile(tree, false, 1, mc:source_code(source));
  if (!vector?(prelinked)) error(error_bad_value);
  first = mc:linkrun(prelinked, 1, true);
  if (!pair?(first)) error(error_bad_value);
  f1 = car(first);
  second = mc:linkrun(prelinked, 1, true);
  if (!pair?(second)) error(error_bad_value);
  f2 = car(second);
  if (f1(2) != 42 || f2(2) != 42 || f1(3) != 43) error(error_bad_value);
  display("LLVM_CACHE_TEST_OK");
];
EOS
    $cache = "$base/duplicate";
    my $cold_duplicate = run($binary, $duplicate_script, $cache);
    my @keys = map { validate_cache_file($_) } cache_files($cache);
    fail 'duplicate loads did not populate the cache' unless @keys;
    my $legacy_sequence_key = grep {
        index($_, 'LLVM14-module-sequence=') >= 0
            || index($_, 'legacy-module-sequence=') >= 0 } @keys;
    expect_trace('duplicate links cold', $cold_duplicate,
                 $legacy_sequence_key ? ('miss', 'miss') : ('miss', 'hit'));
    expect_trace('duplicate links warm', run($binary, $duplicate_script, $cache),
                 'hit', 'hit');

    # The exact same source refers to globals at different offsets when
    # their registration order changes. Each ordering must miss once and
    # then hit its own correctly relocated object.
    my $source = 'fn () cache_global_a * 100 + cache_global_b';
    my $descriptor_path = "$base/global-relocation.obj";
    my $producer = <<"EOS";
[
  | source, tree, prelinked |
  cache_global_a = 11;
  cache_global_b = 22;
  source = "$source";
  tree = mudlle_parse(source, "cache-global-order.mud", false);
  prelinked = mc:compile(tree, false, 1, mc:source_code(source));
  if (!vector?(prelinked)) error(error_bad_value);
  save_data("$descriptor_path", prelinked);
  display("LLVM_CACHE_TEST_OK");
];
EOS
    expect_trace('serialize global relocation descriptor',
                 run($binary, $producer, undef, undef, trace => 0));
    -f $descriptor_path or fail 'Mudlle did not serialize the LLVM descriptor';

    my $ordered_globals = sub {
        my ($first, $expected) = @_;
        my $assignments = $first eq 'a'
            ? 'cache_global_a = 11; cache_global_b = 22;'
            : 'cache_global_b = 22; cache_global_a = 11;';
        return <<"EOS";
$assignments
[
  | prelinked, linked, function |
  prelinked = load_data("$descriptor_path");
  linked = mc:linkrun(prelinked, 1, true);
  if (!pair?(linked)) error(error_bad_value);
  function = car(linked);
  if (function() != $expected) error(error_bad_value);
  display("LLVM_CACHE_TEST_OK");
];
EOS
    };

    $cache = "$base/global-order";
    expect_trace('globals A/B cold', run($binary, $ordered_globals->('a', 1122), $cache), 'miss');
    expect_trace('globals A/B warm', run($binary, $ordered_globals->('a', 1122), $cache), 'hit');
    expect_trace('globals B/A cold', run($binary, $ordered_globals->('b', 1122), $cache), 'miss');
    expect_trace('globals B/A warm', run($binary, $ordered_globals->('b', 1122), $cache), 'hit');

    # Optimization settings are part of the cache key.
    $cache = "$base/optimization";
    for my $step (['O2 cold', 'O2', 'miss'], ['none cold', 'none', 'miss'],
                  ['none warm', 'none', 'hit'], ['fast cold', 'fast', 'miss'],
                  ['fast warm', 'fast', 'hit'], ['O2 warm', 'O2', 'hit']) {
        expect_trace($step->[0], run($binary, simple_script(), $cache, $step->[1]),
                     $step->[2]);
    }

    # Invalid but parseable IR is rejected by the unconditional verifier
    # before optimization, and the runtime error remains catchable.
    for my $optimization ('none', 'O2') {
        my $invalid_ir = run($binary, invalid_ir_script(), undef,
                             $optimization, verify_each => '0');
        index($invalid_ir->[2], 'LLVM IR verification error:') >= 0
            or fail "$optimization did not report LLVM IR verification failure\n",
                    "stdout:\n$invalid_ir->[1]\nstderr:\n$invalid_ir->[2]";
    }

    # A truncated object and a checksum-corrupted object are both ignored
    # and regenerated while execution still reaches its sentinel.
    for my $mode ('truncated', 'corrupted') {
        $cache = "$base/$mode";
        expect_trace("$mode populate", run($binary, simple_script(), $cache), 'miss');
        my ($entry) = cache_files($cache);
        my $data = slurp($entry);
        if ($mode eq 'truncated') {
            spew($entry, substr($data, 0, 24));
        } else {
            substr($data, -1, 1) = chr(ord(substr($data, -1, 1)) ^ 0x01);
            spew($entry, $data);
        }
        expect_trace("$mode fallback", run($binary, simple_script(), $cache), 'miss');
        validate_cache_file($entry);
        expect_trace("$mode repaired hit", run($binary, simple_script(), $cache), 'hit');
    }

    # Keep the cached object and checksum intact, but alter the stored key
    # while leaving the filename at the hash of the original key. The
    # complete-key comparison must reject this entry.
    $cache = "$base/mismatched-key";
    expect_trace('mismatched key populate', run($binary, simple_script(), $cache), 'miss');
    my ($entry) = cache_files($cache);
    my $data = slurp($entry);
    my ($key_size) = unpack('Q<', $data);
    fail 'cache file has an empty key' if $key_size == 0;
    substr($data, 24, 1) = chr(ord(substr($data, 24, 1)) ^ 0x01);
    spew($entry, $data);
    expect_trace('mismatched key fallback', run($binary, simple_script(), $cache), 'miss');
    validate_cache_file($entry);
    expect_trace('mismatched key repaired hit', run($binary, simple_script(), $cache), 'hit');

    # A path occupied by a regular file cannot be used as a cache dir.
    my $unavailable = "$base/not-a-directory";
    spew($unavailable, 'occupied');
    expect_trace('unavailable cache directory',
                 run($binary, simple_script(), $unavailable), 'miss');
    slurp($unavailable) eq 'occupied' or fail 'unavailable cache path was modified';

    # Empty MUDLLE_LLVM_CACHE disables persistence and tracing.
    expect_trace('disabled cache', run($binary, simple_script(), undef, undef, trace => 0));

    print "LLVM native object cache integration tests passed\n";
}

main();
