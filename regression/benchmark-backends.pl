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

# Measure compiled kernel execution and fresh compiler loads sequentially.

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Basename qw(dirname);
use File::Spec;
use File::Temp qw(tempdir);
use Getopt::Long;
use lib dirname(abs_path(__FILE__));
use BenchLib qw(slurp sha256_file median round6 host_info to_json
                run_command child_cpu);

sub build_provenance {
    my ($directory) = @_;
    my $executable = "$directory/mudlle";
    my $arch_file = "$directory/.mudlle-arch";
    my $abi_header = "$directory/runtime/llvm-cache-abi.h";
    my $abi;
    if (-f $abi_header
        && slurp($abi_header) =~ /^#define MUDLLE_LLVM_CACHE_ABI "([0-9a-f]+)"$/m) {
        $abi = $1;
    }
    my $arch;
    if (-f $arch_file) {
        $arch = slurp($arch_file);
        $arch =~ s/^\s+|\s+$//g;
    }
    return {
        path => $directory,
        mudlle_arch => $arch,
        mudlle_sha256 => (-f $executable ? sha256_file($executable) : undef),
        llvm_cache_abi => $abi,
    };
}

sub count_lines {
    my ($text, $line) = @_;
    my $count = 0;
    $count++ while $text =~ /^\Q$line\E$/mg;
    return $count;
}

sub measure {
    my ($directory, $optimization, $workload, $cache_directory) = @_;
    my %env = %ENV;
    delete $env{MUDLLE_LLVM_OPT};
    $env{MUDLLE_LLVM_OPT} = $optimization if defined $optimization;
    if (!defined $cache_directory) {
        $env{MUDLLE_LLVM_CACHE} = '';
        delete $env{MUDLLE_LLVM_CACHE_TRACE};
    } else {
        $env{MUDLLE_LLVM_CACHE} = $cache_directory;
        $env{MUDLLE_LLVM_CACHE_TRACE} = '1';
    }
    my @command = ('./mudlle', '-c', 'silent=true');
    if ($workload eq 'kernel') {
        push @command, '-e', 'xc.mud', '-e', 'regression/benchmark.mud';
    } else {
        push @command, '-e', 'icxc.mud', '-c',
            'assert(car(eval("iadd(20,22)")) == 42); '
            . 'display("compiler-load-ok\n")';
    }
    my ($user0, $system0) = child_cpu();
    my $start = Time::HiRes::time();
    my ($code, $stdout, $stderr) =
        run_command(\@command, cwd => $directory, env => \%env);
    my $wall = Time::HiRes::time() - $start;
    my ($user1, $system1) = child_cpu();
    my %sample = (
        wall_s => round6($wall),
        user_s => round6($user1 - $user0),
        system_s => round6($system1 - $system0),
    );
    if (defined $cache_directory) {
        $sample{cache_hits} = count_lines($stderr, 'LLVM object cache hit');
        $sample{cache_misses} = count_lines($stderr, 'LLVM object cache miss');
    }
    # Mudlle can return zero after a load error; require workload completion.
    die $stdout . $stderr if $code != 0;
    if ($workload eq 'kernel') {
        $stdout =~ /backend=(\w+) workload=loop-sum work=50000 runs=2000 cpu_ms=(\d+)/
            or die $stdout . $stderr;
        $sample{backend} = $1;
        $sample{kernel_cpu_ms} = $2 + 0;
    } elsif (index($stdout, "compiler-load-ok\n") < 0) {
        die $stdout . $stderr;
    }
    return \%sample;
}

# Median of every numeric metric in the samples.
sub medians {
    my ($samples) = @_;
    my %medians;
    for my $key (grep { /_(?:s|ms|hits|misses)$/ } keys %{$samples->[0]}) {
        $medians{$key} = median(map { $_->{$key} } @$samples);
    }
    return \%medians;
}

sub run_benchmark {
    my ($x64, $llvm, $arm64, $kernel_only);
    my $runs = 3;
    GetOptions('x64=s' => \$x64, 'llvm=s' => \$llvm, 'arm64=s' => \$arm64,
               'runs=i' => \$runs, 'kernel-only' => \$kernel_only)
        or die "usage: $0 (--x64 D | --llvm D | --arm64 D) [--runs N] "
             . "[--kernel-only]\n";
    (defined $x64) + (defined $llvm) + (defined $arm64) == 1
        or die "exactly one of --x64, --llvm, --arm64 is required\n";
    $runs >= 1 or die "--runs must be positive\n";
    my $is_arm64 = defined $arm64;
    my $x64_directory = defined $x64 ? abs_path($x64) : undef;
    my $llvm_directory = abs_path($llvm // $arm64);
    my @workloads_to_run = $kernel_only ? ('kernel') : ('kernel', 'compiler_load');
    my %report = (
        runs => $runs + 0,
        kernel_iterations => 100_000_000,
        workloads => \@workloads_to_run,
        cache_state => 'fresh processes; OS filesystem cache not flushed',
        host => host_info(),
        builds => $is_arm64
            ? { arm64 => build_provenance($llvm_directory) }
            : { x64 => build_provenance($x64_directory),
                llvm => build_provenance($llvm_directory) },
        results => {},
    );
    my @configurations = $is_arm64
        ? (['llvm_O2', $llvm_directory, 'O2'],
           ['llvm_none', $llvm_directory, 'none'])
        : (['x64', $x64_directory, undef],
           ['llvm_O2', $llvm_directory, 'O2'],
           ['llvm_none', $llvm_directory, 'none']);
    for my $configuration (@configurations) {
        my ($label, $directory, $optimization) = @$configuration;
        my %workloads;
        for my $workload (@workloads_to_run) {
            my @samples;
            for my $run (1 .. $runs) {
                my $sample = measure($directory, $optimization, $workload);
                if ($workload eq 'kernel') {
                    my $expected = $label eq 'x64' ? 'x64' : 'llvm';
                    $sample->{backend} eq $expected
                        or die "$directory is not a $expected build\n";
                }
                push @samples, $sample;
                print STDERR "$label $workload $run/$runs: ",
                    JSON::PP->new->canonical->encode($sample), "\n";
            }
            $workloads{$workload} = { samples => \@samples,
                                      medians => medians(\@samples) };
        }
        $report{results}{$label} = \%workloads;
    }

    # Pair each cold-cache sample with a warm-cache measurement in its own
    # temporary cache, so runs cannot inherit entries from earlier samples.
    for my $workload (@workloads_to_run) {
        my (@miss_samples, @hit_samples);
        for my $run (1 .. $runs) {
            my $cache = tempdir('mudlle-llvm-cache-XXXXXX', TMPDIR => 1,
                                CLEANUP => 1);
            my $miss = measure($llvm_directory, 'O2', $workload, $cache);
            $miss->{cache_misses} >= 1
                or die "LLVM cache miss was not observed\n";
            # Explicitly prime immediately before timing the cache hit.
            measure($llvm_directory, 'O2', $workload, $cache);
            my $hit = measure($llvm_directory, 'O2', $workload, $cache);
            ($hit->{cache_hits} >= 1 && $hit->{cache_misses} == 0)
                or die "LLVM warm cache was not exclusively hit\n";
            if ($workload eq 'kernel') {
                ($miss->{backend} eq 'llvm' && $hit->{backend} eq 'llvm')
                    or die "$llvm_directory is not an llvm build\n";
            }
            push @miss_samples, $miss;
            push @hit_samples, $hit;
            for my $pair (['miss', $miss], ['hit', $hit]) {
                print STDERR "llvm_O2_cache_$pair->[0] $workload $run/$runs: ",
                    JSON::PP->new->canonical->encode($pair->[1]), "\n";
            }
        }
        for my $pair (['miss', \@miss_samples], ['hit', \@hit_samples]) {
            $report{results}{"llvm_O2_cache_$pair->[0]"}{$workload} = {
                samples => $pair->[1], medians => medians($pair->[1]) };
        }
    }
    print to_json(\%report);
}

run_benchmark() unless caller;
1;
