#!/usr/bin/perl
# Copyright (c) 2026 Nils Schimmelmann
# All rights reserved.
#
# Permission to use, copy, modify, and distribute this software for any
# purpose, without fee, and without written agreement is hereby granted,
# provided that the above copyright notice and the following two paragraphs
# appear in all copies of this software.
#
# IN NO EVENT SHALL NILS SCHIMMELMANN BE LIABLE TO ANY PARTY FOR DIRECT, INDIRECT,
# SPECIAL, INCIDENTAL, OR CONSEQUENTIAL DAMAGES ARISING OUT OF THE USE OF
# THIS SOFTWARE AND ITS DOCUMENTATION, EVEN IF NILS SCHIMMELMANN HAS BEEN ADVISED OF
# THE POSSIBILITY OF SUCH DAMAGE.
#
# NILS SCHIMMELMANN SPECIFICALLY DISCLAIMS ANY WARRANTIES, INCLUDING, BUT NOT LIMITED
# TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
# PURPOSE.  THE SOFTWARE PROVIDED HEREUNDER IS ON AN "AS IS" BASIS, AND NILS
# SCHIMMELMANN HAS NO OBLIGATION TO PROVIDE MAINTENANCE, SUPPORT, UPDATES,
# ENHANCEMENTS, OR MODIFICATIONS.

# Generate a stable ABI fingerprint for the native LLVM object cache.

use strict;
use warnings;
use Digest::SHA;
use File::Basename qw(dirname);
use File::Path qw(make_path);
use Getopt::Long;

sub slurp {
    my ($path) = @_;
    open(my $fh, '<:raw', $path) or die "$path: $!\n";
    local $/;
    my $content = <$fh>;
    close($fh);
    return $content;
}

sub add {
    my ($hasher, $name, $content) = @_;
    $hasher->add(pack('Q>', length $name), $name,
                 pack('Q>', length $content), $content);
}

sub sources_in {
    my ($dir, $prefix) = @_;
    my @files;
    for my $pattern ('*.c', '*.h') {
        push @files, sort glob("$dir/$pattern");
    }
    return map { [ $_, $prefix . substr($_, length($dir) + 1) ] } @files;
}

my ($source_dir, $makefile, $cflags, $cppflags, $output);
GetOptions('source-dir=s' => \$source_dir, 'makefile=s' => \$makefile,
           'cflags=s' => \$cflags, 'cppflags=s' => \$cppflags,
           'output=s' => \$output)
    or die "usage: $0 --source-dir D --makefile F --cflags S --cppflags S "
         . "--output F\n";
defined $_ or die "missing required option\n"
    for $source_dir, $makefile, $cflags, $cppflags, $output;

my $hasher = Digest::SHA->new(256);
for my $source (sources_in($source_dir, ''),
                sources_in("$source_dir/runtime", 'runtime/')) {
    next if $source->[1] eq 'runtime/llvm-cache-abi.h';
    add($hasher, $source->[1], slurp($source->[0]));
}
add($hasher, 'Makefile', slurp($makefile));
add($hasher, 'CFLAGS', $cflags);
add($hasher, 'CPPFLAGS', $cppflags);

my $content = '#define MUDLLE_LLVM_CACHE_ABI "' . $hasher->hexdigest . "\"\n";
exit 0 if -e $output && slurp($output) eq $content;

make_path(dirname($output));
my $temporary = "$output.$$";
open(my $fh, '>', $temporary) or die "$temporary: $!\n";
print $fh $content;
close($fh) or die "$temporary: $!\n";
rename($temporary, $output) or die "rename $temporary: $!\n";
