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

# Tests for the LLVM native object cache ABI fingerprint generator.

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use Test::More;
use lib dirname(abs_path(__FILE__));
use BenchLib qw(slurp spew);

my $root = abs_path(dirname(abs_path(__FILE__)) . '/..');
my $generator = "$root/runtime/llvm-cache-abi.pl";

my $source_dir = tempdir('mudlle-cache-abi-test-XXXXXX', TMPDIR => 1, CLEANUP => 1);
my $runtime_dir = "$source_dir/runtime";
make_path($runtime_dir);
my $makefile = "$source_dir/Makefile";
spew($makefile, "all: app\n");
spew("$source_dir/$_->[0]", $_->[1]) for
    ['module.c', "int root_source;\n"],
    ['module.h', "#define ROOT_HEADER 1\n"],
    ['runtime/llvm.c', "int llvm_source;\n"],
    ['runtime/llvm.h', "#define LLVM_HEADER 1\n"];

sub generate {
    my ($output, $cflags, $cppflags) = @_;
    system('perl', $generator, '--source-dir', $source_dir,
           '--makefile', $makefile, "--cflags=$cflags",
           "--cppflags=$cppflags", '--output', $output) == 0
        or die "generator failed\n";
}

sub fingerprint {
    my ($cflags, $cppflags) = @_;
    my $output = "$runtime_dir/fingerprint.h";
    generate($output, $cflags // '-O2', $cppflags // '-I.');
    my $value = slurp($output);
    unlink $output;
    return $value;
}

my $baseline = fingerprint();
for my $input (
    ["$source_dir/module.c", "int root_source_changed;\n"],
    ["$source_dir/module.h", "#define ROOT_HEADER 2\n"],
    ["$runtime_dir/llvm.c", "int llvm_source_changed;\n"],
    ["$runtime_dir/llvm.h", "#define LLVM_HEADER 2\n"],
    [$makefile, "all: different-target\n"],
) {
    my ($path, $changed) = @$input;
    my $original = slurp($path);
    spew($path, $changed);
    isnt(fingerprint(), $baseline, "change to $path alters fingerprint");
    spew($path, $original);
}
isnt(fingerprint('-O3'), $baseline, 'CFLAGS alter fingerprint');
isnt(fingerprint('-O2', '-Iinclude'), $baseline, 'CPPFLAGS alter fingerprint');

spew("$runtime_dir/llvm-cache-abi.h",
     qq(#define MUDLLE_LLVM_CACHE_ABI "old-value"\n));
is(fingerprint(), $baseline, 'generated header is excluded from fingerprint');
unlink "$runtime_dir/llvm-cache-abi.h";

my $output = "$runtime_dir/llvm-cache-abi.h";
generate($output, '-O2', '-I.');
like(slurp($output), qr/\A#define MUDLLE_LLVM_CACHE_ABI "[0-9a-f]{64}"\n\z/,
     'header has the expected form');
my $original_mtime = 1_600_000_000;
utime($original_mtime, $original_mtime, $output) or die "utime: $!\n";
generate($output, '-O2', '-I.');
is((stat $output)[9], $original_mtime,
   'regeneration preserves mtime when content is unchanged');

done_testing;
