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
use Getopt::Long;
use Time::HiRes qw(time);
use JSON::PP ();
use lib dirname(abs_path(__FILE__));
use BenchLib qw(spew sha256_file median round6 host_info to_json run_command);

my @WORKLOADS = qw(scalar-alloc vector-walk vector-find-absent
                   vector-find-late-hit vector-find-early-hit);

sub provenance {
    my ($directory) = @_;
    my %files = (
        mudlle => "$directory/mudlle",
        genllvm_mud => "$directory/genllvm.mud",
        benchmark_mud => "$directory/regression/benchmark-llvm-gc.mud",
    );
    -f $_ or die "required provenance file missing: $_\n" for values %files;
    my $arch_path = "$directory/.mudlle-arch";
    -f $arch_path or die "missing $arch_path\n";
    open(my $arch_fh, '<', $arch_path) or die "$arch_path: $!\n";
    my $arch = do { local $/; <$arch_fh> };
    close($arch_fh);
    $arch =~ s/^\s+|\s+$//g;
    return {
        path => $directory,
        mudlle_arch => $arch,
        map { $_ . '_sha256' => sha256_file($files{$_}) } keys %files,
    };
}

sub parse_output {
    my ($stdout, $directory) = @_;
    my (%cpu_ms, %backend);
    for my $line (split /\n/, $stdout) {
        next unless $line =~ /^backend=/;
        if ($line =~ /^backend=(\w+) workload=scalar-alloc work=(\d+) runs=(\d+) cpu_ms=(\d+)$/) {
            $backend{$1} = 1;
            exists $cpu_ms{'scalar-alloc'} and die "duplicate scalar-alloc output from $directory\n";
            $cpu_ms{'scalar-alloc'} = $4;
        } elsif ($line =~ /^backend=(\w+) workload=vector-walk work=(\d+) runs=(\d+) cpu_ms=(\d+)$/) {
            $backend{$1} = 1;
            exists $cpu_ms{'vector-walk'} and die "duplicate vector-walk output from $directory\n";
            $cpu_ms{'vector-walk'} = $4;
        } elsif ($line =~ /^backend=(\w+) workload=vector-find case=(absent|late-hit|early-hit) needle=(-?\d+) work=(\d+) runs=(\d+) cpu_ms=(\d+) checksum=(-?\d+)$/) {
            my ($name, $ms) = ("vector-find-$2", $6);
            $backend{$1} = 1;
            exists $cpu_ms{$name} and die "duplicate $name output from $directory\n";
            $cpu_ms{$name} = $ms;
        } else {
            die "unexpected benchmark output from $directory: $line\n";
        }
    }
    keys(%backend) == 1 or die "benchmark output from $directory used inconsistent backends\n";
    my ($backend) = keys %backend;
    for my $workload (@WORKLOADS) {
        exists $cpu_ms{$workload} or die "missing $workload output from $directory\n";
    }
    keys(%cpu_ms) == @WORKLOADS
        or die "expected exactly five workload lines from $directory\n";
    return ($backend, \%cpu_ms);
}

sub measure {
    my ($label, $directory, $optimization) = @_;
    my %env = %ENV;
    delete $env{MUDLLE_LLVM_OPT};
    $env{MUDLLE_LLVM_OPT} = $optimization if defined $optimization;
    $env{MUDLLE_LLVM_CACHE} = '';
    delete $env{MUDLLE_LLVM_CACHE_TRACE};
    my $started = time();
    my ($code, $stdout, $stderr) = run_command(
        ['./mudlle', '-c', 'silent=true', '-e', 'xc.mud', '-e',
         'regression/benchmark-llvm-gc.mud'],
        cwd => $directory, env => \%env);
    my $wall_s = round6(time() - $started);
    die "$label failed in $directory (exit $code):\n$stdout$stderr"
        if $code != 0;
    my ($backend, $cpu_ms) = parse_output($stdout, $directory);
    my $expected = $label eq 'x64' ? 'x64' : 'llvm';
    $backend eq $expected
        or die "$directory reported backend=$backend; expected $expected\n";
    return { backend => $backend, wall_s => $wall_s, cpu_ms => $cpu_ms };
}

sub medians {
    my ($samples) = @_;
    my %result = (wall_s => median(map { $_->{wall_s} } @$samples));
    for my $workload (@WORKLOADS) {
        $result{$workload . '_cpu_ms'} = median(
            map { $_->{cpu_ms}{$workload} } @$samples);
    }
    return \%result;
}

sub main {
    my ($baseline, $llvm, $x64, $output);
    my $runs = 3;
    GetOptions('baseline=s' => \$baseline, 'llvm=s' => \$llvm,
               'x64=s' => \$x64, 'runs=i' => \$runs,
               'output=s' => \$output)
        or die "usage: $0 --baseline D --llvm D --x64 D [--runs N] --output F\n";
    defined $baseline && defined $llvm && defined $x64 && defined $output
        or die "--baseline, --llvm, --x64, and --output are required\n";
    $runs >= 1 or die "--runs must be positive\n";

    my @configurations = (
        ['baseline', abs_path($baseline), 'O2'],
        ['llvm', abs_path($llvm), 'O2'],
    );
    push @configurations, ['x64', abs_path($x64), undef];
    my %report = (
        runs => $runs + 0,
        workloads => \@WORKLOADS,
        cache_state => 'fresh serial processes; LLVM object cache disabled; OS filesystem cache not flushed',
        host => host_info(),
        builds => {},
        results => {},
    );

    for my $configuration (@configurations) {
        my ($label, $directory, $optimization) = @$configuration;
        defined $directory && -d $directory or die "invalid $label directory\n";
        -f "$directory/mudlle" or die "Mudlle executable not found in $directory\n";
        $report{builds}{$label} = provenance($directory);
        my @samples;
        for my $run (1 .. $runs) {
            my $sample = measure($label, $directory, $optimization);
            push @samples, $sample;
            print STDERR "$label $run/$runs: ",
                JSON::PP->new->canonical->encode($sample), "\n";
        }
        $report{results}{$label} = { samples => \@samples,
                                     medians => medians(\@samples) };
    }

    my $absolute_output = File::Spec->rel2abs($output);
    make_path(dirname($absolute_output));
    spew($absolute_output, to_json(\%report));
    print STDERR "wrote $absolute_output\n";
}

main();
