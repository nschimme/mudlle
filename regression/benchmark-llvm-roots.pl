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
use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use Getopt::Long;
use Time::HiRes qw(time);
use JSON::PP ();
use lib dirname(abs_path(__FILE__));
use BenchLib qw(slurp spew sha256_file sha256_hex median round6 host_info to_json run_command);
use RootsBench qw(identity_probe_source);

my @WORKLOADS = qw(scalar-noalloc scalar-live-roots-0 vector-alloc-live-roots-0 scalar-live-roots-1 vector-alloc-live-roots-1
                   scalar-live-roots-4 vector-alloc-live-roots-4
                   scalar-live-roots-16 vector-alloc-live-roots-16);

sub provenance {
    my ($directory) = @_;
    my %hashes;
    for my $file ("$directory/mudlle", "$directory/genllvm.mud",
                  "$directory/regression/benchmark-llvm-roots.mud",
                  "$directory/alloc.c", "$directory/alloc.h",
                  "$directory/runtime/llvm.c", "$directory/runtime/llvm.h") {
        -f $file or die "required provenance file missing: $file\n";
        $hashes{$file} = sha256_file($file);
    }
    my $arch_path = "$directory/.mudlle-arch";
    -f $arch_path or die "missing $arch_path\n";
    open(my $fh, '<', $arch_path) or die "$arch_path: $!\n";
    my $arch = do { local $/; <$fh> };
    close($fh);
    $arch =~ s/^\s+|\s+$//g;
    return { path => $directory, mudlle_arch => $arch, sha256 => \%hashes };
}

sub parse_output {
    my ($stdout, $directory, $expected_backend) = @_;
    my %cpu;
    my %backend;
    my $success = 0;
    for my $line (split /\n/, $stdout) {
        if ($line eq 'benchmark-llvm-roots-success') { $success++; next; }
        next unless $line =~ /^backend=/;
        $line =~ /^backend=(\w+) workload=(scalar-noalloc|scalar-live-roots|vector-alloc-live-roots)(?: roots=(0|1|4|16))? work=(\d+) runs=(\d+) cpu_ms=(\d+) checksum=(-?\d+)$/
            or die "unexpected benchmark output from $directory: $line\n";
        my ($b, $name, $roots, $work, $runs, $ms, $checksum) = ($1, $2, $3, $4, $5, $6, $7);
        $backend{$b} = 1;
        $name .= "-$roots" if defined $roots;
        exists $cpu{$name} and die "duplicate workload $name from $directory\n";
        $cpu{$name} = { cpu_ms => 0 + $ms, work => 0 + $work,
                        loops => 0 + $runs, checksum => 0 + $checksum };
    }
    keys(%backend) == 1 && exists $backend{$expected_backend}
        or die "$directory reported an unexpected or inconsistent backend\n";
    $success == 1 or die "$directory did not print its success marker:\n$stdout\n";
    for my $name (@WORKLOADS) {
        exists $cpu{$name} or die "missing $name output from $directory\n";
    }
    keys(%cpu) == @WORKLOADS or die "unexpected workload count from $directory\n";
    return \%cpu;
}

sub measure {
    my ($label, $directory, $workload_path) = @_;
    my %env = %ENV;
    $env{MUDLLE_LLVM_OPT} = 'O2';
    $env{MUDLLE_LLVM_CACHE} = '';
    delete $env{MUDLLE_LLVM_CACHE_TRACE};
    delete $env{MUDLLE_LLVM_VERIFY_EACH};
    delete $env{MUDLLE_LLVM_TIMING};
    my $started = time();
    my ($code, $stdout, $stderr) = run_command(
        ['./mudlle', '-c', 'silent=true', '-e', 'xc.mud', '-e',
         $workload_path], cwd => $directory, env => \%env);
    my $wall = round6(time() - $started);
    die "$label failed in $directory (exit $code):\n$stdout$stderr"
        if $code != 0 || $stderr =~ /\b(?:error|fatal)\b/i;
    my $backend = $label eq 'llvm' ? 'llvm' : 'x64';
    my $records = parse_output($stdout, $directory, $backend);
    return { wall_s => $wall, workloads => $records };
}

sub main {
    my ($llvm, $x64, $output, $identity_only);
    my $runs = 3;
    GetOptions('llvm=s' => \$llvm, 'x64=s' => \$x64,
               'runs=i' => \$runs, 'output=s' => \$output,
               'identity-only' => \$identity_only)
        or die "usage: $0 --llvm D --x64 D [--runs N] [--identity-only] --output F\n";
    defined $llvm && defined $x64 && defined $output
        or die "--llvm, --x64, and --output are required\n";
    $runs >= 1 or die "--runs must be positive\n";
    my %report = (
        mode => $identity_only ? 'identity-only' : 'default',
        runs => 0 + $runs,
        workloads => \@WORKLOADS,
        workload_parameters => { iterations_per_kernel => 1_000_000,
                                 timed_calls => 10,
                                 allocation_count_per_allocating_workload => 10_000_000 },
        interpretation => $identity_only
          ? 'Identity comparisons replace reference element reads and return their ordinals. Differences include allocator, collection, scratch indexing, root loads and generated-code effects; this is not a GC correctness test.'
          : 'Controls match reference reads and accumulation. Allocation cases additionally construct a four-integer vector each loop. Differences include allocator, collection, and generated-code effects; they do not isolate a single GC-root cost.',
        cache_state => 'fresh serial processes; LLVM object cache disabled; OS filesystem cache not flushed',
        host => host_info(), builds => {}, results => {},
    );
    my $identity_dir = $identity_only
        ? tempdir('mudlle-roots-identity-XXXXXX', TMPDIR => 1, CLEANUP => 1)
        : undef;
    $report{workload_source_sha256} = {};
    for my $entry (['llvm', abs_path($llvm)], ['x64', abs_path($x64)]) {
        my ($label, $directory) = @$entry;
        defined $directory && -d $directory or die "invalid $label directory\n";
        -f "$directory/mudlle" or die "Mudlle executable not found in $directory\n";
        $report{builds}{$label} = provenance($directory);
        my $workload_path = 'regression/benchmark-llvm-roots.mud';
        my $source = slurp("$directory/$workload_path");
        if ($identity_only) {
            $source = identity_probe_source($source);
            $workload_path = "$identity_dir/$label-identity-only.mud";
            spew($workload_path, $source);
        }
        $report{workload_source_sha256}{$label} = sha256_hex($source);
        my @samples;
        for my $run (1 .. $runs) {
            my $sample = measure($label, $directory, $workload_path);
            push @samples, $sample;
            print STDERR "$label $run/$runs: ", JSON::PP->new->canonical->encode($sample), "\n";
        }
        my %medians;
        for my $workload (@WORKLOADS) {
            $medians{$workload . '_cpu_ms'} = median(
                map { $_->{workloads}{$workload}{cpu_ms} } @samples);
        }
        $medians{wall_s} = median(map { $_->{wall_s} } @samples);
        $report{results}{$label} = { samples => \@samples, medians => \%medians };
    }
    my $path = File::Spec->rel2abs($output);
    make_path(dirname($path));
    spew($path, to_json(\%report));
    print STDERR "wrote $path\n";
}

main();
