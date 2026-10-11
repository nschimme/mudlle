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
# INDIRECT, INCIDENTAL, OR CONSEQUENTIAL DAMAGES ARISING OUT OF THE USE OF
# THIS SOFTWARE AND ITS DOCUMENTATION, EVEN IF NILS SCHIMMELMANN HAS BEEN
# ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
#
# NILS SCHIMMELMANN SPECIFICALLY DISCLAIMS ANY WARRANTIES, INCLUDING, BUT NOT
# LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A
# PARTICULAR PURPOSE. THE SOFTWARE PROVIDED HEREUNDER IS ON AN "AS IS" BASIS,
# AND NILS SCHIMMELMANN HAS NO OBLIGATION TO PROVIDE MAINTENANCE, SUPPORT,
# UPDATES, ENHANCEMENTS, OR MODIFICATIONS.

use strict;
use warnings;
use Cwd qw(abs_path);
use FindBin;
use Getopt::Long;
use File::Basename qw(dirname);
use File::Path qw(make_path);
use Time::HiRes qw(time);
use lib $FindBin::Bin;
use BenchLib qw(slurp spew sha256_file median round6 host_info to_json run_command);

my ($llvm, $x64, $output);
my $runs = 5;
my $suite = 'all';
GetOptions('llvm=s' => \$llvm, 'x64=s' => \$x64, 'output=s' => \$output,
           'runs=i' => \$runs, 'suite=s' => \$suite)
    or die "invalid options\n";
defined $llvm && defined $x64 && defined $output && $runs > 0
    or die "usage: $0 --llvm DIR --x64 DIR --output FILE [--runs 5] [--suite all|numeric|sequences|tables]\n";
$suite =~ /\A(?:all|numeric|sequences|tables)\z/ or die "unknown suite $suite\n";
my @suites = $suite eq 'all' ? qw(numeric sequences tables) : ($suite);
my @files = map { "regression/benchmark-$_.mud" } @suites;
my @workloads;
push @workloads, qw(float-primitives bigint-primitives mixed)
    if grep { $_ eq 'numeric' } @suites;
push @workloads, qw(list-vector-library-32 list-vector-native-32 list-vector-native-257)
    if grep { $_ eq 'sequences' } @suites;
push @workloads, qw(table-mixed-32 table-mixed-257)
    if grep { $_ eq 'tables' } @suites;
my %directories = (llvm => abs_path($llvm), x64 => abs_path($x64));
my %report = (
    runs => $runs, suite => $suite, workloads => \@workloads, host => host_info(),
    cache_state => 'fresh serial processes; native object cache disabled; filesystem cache not flushed',
    sampling_order => 'alternate backend order in successive rounds; no concurrent validation',
    interpretation => 'Kernel compilation, warmup, interpreter numeric references, explicit collection stress, and post-call oracle/aggregate checks are outside kernel CPU timers. Sequence and table kernels keep identity/content guards inside timed loops. Library conversions call loaded misc/sequences closures; native conversions compile the same loops locally. Floating-point comparisons use 1e-10 * (1 + abs(reference)); bigint, sequence, and table checksums are exact. Timed kernels retain ordinary loop accounting.',
    workload_parameters => {
        numeric_iterations => { float => 100_000, bigint => 20_000, mixed => 20_000 },
        sequence_iterations_per_kernel => { width_32 => 10_000, width_257 => 2_000 },
        table_iterations_per_kernel => { keys_32 => 32 * 256, keys_257 => 257 * 32,
                                         rounds_per_call => { keys_32 => 256, keys_257 => 32 },
                                         timed_calls_per_sample => 5 },
        table_operations => [qw(insert lookup replace_twice delete_every_third reinsert iterate)],
        table_key_mix => 'even indexes inserted as string keys; odd indexes inserted as symbols; case-sensitive table',
        table_payload => '[integer, shared-child-vector]',
        sequence_collection_stress => 'checked outside CPU timers; identity/content guards remain inside timed loop',
        table_collection_stress => 'checked outside CPU timers; identity/content guards remain inside timed loop',
    },
    builds => {}, results => {},
);
for my $backend (qw(llvm x64)) {
    my $dir = $directories{$backend};
    defined $dir && -f "$dir/mudlle" or die "invalid $backend build\n";
    my $arch = slurp("$dir/.mudlle-arch"); $arch =~ s/\s+\z//;
    $arch =~ /\Q$backend\E\z/ or ($backend eq 'x64' && $arch eq 'amd64')
        or die "$dir architecture $arch does not match $backend\n";
    my %hashes;
    for my $file ('mudlle', 'genllvm.mud', 'alloc.c', 'alloc.h', 'runtime/llvm.c',
                  'misc.mud', 'sequences.mud', 'regression/benchmark-rich.mud', @files) {
        $hashes{$file} = sha256_file("$dir/$file");
    }
    $report{builds}{$backend} = { path => $dir, mudlle_arch => $arch, sha256 => \%hashes };
    $report{results}{$backend} = { samples => [] };
}
for my $file ('regression/benchmark-rich.mud', @files) {
    $report{builds}{llvm}{sha256}{$file} eq $report{builds}{x64}{sha256}{$file}
        or die "workload differs between builds: $file\n";
}
for my $round (1 .. $runs) {
    for my $backend ($round % 2 ? qw(llvm x64) : qw(x64 llvm)) {
        my %env = %ENV;
        $env{MUDLLE_LLVM_OPT} = 'O2'; $env{MUDLLE_LLVM_CACHE} = '';
        delete @env{qw(MUDLLE_LLVM_CACHE_TRACE MUDLLE_LLVM_VERIFY_EACH MUDLLE_LLVM_TIMING)};
        my @args = ('./mudlle', '-c', 'silent=true', '-e', 'xc.mud');
        push @args, ('-e', $suite eq 'all' ? 'regression/benchmark-rich.mud' : $files[0]);
        my $start = time();
        my ($exit, $stdout, $stderr) = run_command(\@args, cwd => $directories{$backend}, env => \%env);
        my $wall = round6(time() - $start);
        $exit == 0 or die "$backend failed ($exit):\n$stdout$stderr\n";
        my %records;
        for my $line (split /\n/, $stdout) {
            next unless $line =~ /^backend=/;
            $line =~ /^backend=(\w+) workload=([\w-]+) work=(\d+)(?: width=(\d+))? runs=(\d+) cpu_ms=(\d+) checksum=(.+)$/
                or die "invalid result: $line\n";
            my ($b, $name, $work, $width, $calls, $cpu, $checksum) = ($1,$2,$3,$4,$5,$6,$7);
            $b eq $backend && !exists $records{$name} or die "invalid backend/duplicate result (expected $backend, got $b, name $name): $line\n$stdout$stderr\n";
            $records{$name} = { work => 0+$work, timed_calls => 0+$calls, cpu_ms => 0+$cpu,
                               checksum => $checksum };
            $records{$name}{width} = 0+$width if defined $width;
        }
        for my $name (@workloads) { exists $records{$name} or die "missing $name:\n$stdout$stderr\n"; }
        keys(%records) == @workloads or die "unexpected workload count\n";
        for my $s (@suites) { $stdout =~ /^benchmark-\Q$s\E-success$/m or die "missing $s success marker\n$stdout$stderr\n"; }
        my $sample = { round => $round, wall_s => $wall, workloads => \%records };
        push @{$report{results}{$backend}{samples}}, $sample;
        print STDERR "$backend round $round/$runs: ", to_json($sample);
    }
}
for my $name (@workloads) {
    my $reference = $report{results}{llvm}{samples}[0]{workloads}{$name};
    for my $backend (qw(llvm x64)) {
        for my $sample (@{$report{results}{$backend}{samples}}) {
            my $actual = $sample->{workloads}{$name};
            for my $key (qw(work timed_calls checksum width)) {
                ($actual->{$key} // '') eq ($reference->{$key} // '')
                    or die "inconsistent $name $key between samples/backends\n";
            }
        }
        $report{results}{$backend}{medians}{$name . '_cpu_ms'} = median(
            map { $_->{workloads}{$name}{cpu_ms} } @{$report{results}{$backend}{samples}});
    }
}
make_path(dirname($output));
spew($output, to_json(\%report));
print STDERR "wrote $output\n";
