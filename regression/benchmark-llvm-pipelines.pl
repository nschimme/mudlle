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

# Compare LLVM optimization and IR verification pipelines sequentially.

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Spec;
use Getopt::Long;
use lib dirname(abs_path(__FILE__));
use BenchLib qw(spew median round6 host_info to_json run_command child_cpu);

require(dirname(abs_path(__FILE__)) . '/benchmark-backends.pl');

my @CONFIGURATIONS = (
    ['O2_verify1', 'O2', '1'],
    ['O2_verify0', 'O2', '0'],
    ['O1_verify0', 'O1', '0'],
    ['fast_verify0', 'fast', '0'],
    ['none_verify0', 'none', '0'],
);

sub compiler_load_command {
    return ('./mudlle', '-c', 'silent=true', '-e', 'icxc.mud', '-c',
            'assert(car(eval("iadd(20,22)")) == 42); '
            . 'display("compiler-load-ok\n")');
}

sub sum_of {
    my ($key, $records) = @_;
    my $sum = 0;
    $sum += $_->{$key} for @$records;
    return $sum;
}

sub run_timing_diagnostic {
    my ($directory, $optimization, $verify) = @_;
    my %env = %ENV;
    $env{MUDLLE_LLVM_OPT} = $optimization;
    $env{MUDLLE_LLVM_VERIFY_EACH} = $verify;
    $env{MUDLLE_LLVM_CACHE} = '';
    delete $env{MUDLLE_LLVM_CACHE_TRACE};
    $env{MUDLLE_LLVM_TIMING} = '1';
    my ($user0, $system0) = child_cpu();
    my $started = Time::HiRes::time();
    my ($code, $stdout, $stderr) =
        run_command([compiler_load_command()], cwd => $directory, env => \%env);
    my $wall_s = Time::HiRes::time() - $started;
    my ($user1, $system1) = child_cpu();
    die $stdout . $stderr
        if $code != 0 || index($stdout, "compiler-load-ok\n") < 0;

    my @records;
    while ($stderr =~ /^LLVM timing bytes=(\d+) prepare_parse=([0-9.]+) optimize=([0-9.]+) codegen_link=([0-9.]+)$/mg) {
        push @records, { ir_bytes => $1 + 0, prepare_parse_s => $2 + 0,
                         optimize_s => $3 + 0, codegen_link_s => $4 + 0 };
    }
    @records or die "no LLVM timing records found in stderr:\n$stderr";
    my $prepare_parse_s = sum_of('prepare_parse_s', \@records);
    my $optimize_s = sum_of('optimize_s', \@records);
    my $codegen_link_s = sum_of('codegen_link_s', \@records);
    my $stage_total_s = $prepare_parse_s + $optimize_s + $codegen_link_s;
    return {
        module_count => scalar(@records),
        process => {
            wall_s => round6($wall_s),
            user_s => round6($user1 - $user0),
            system_s => round6($system1 - $system0),
            remaining_process_s => round6($wall_s - $stage_total_s),
        },
        totals => {
            ir_bytes => sum_of('ir_bytes', \@records),
            prepare_parse_s => round6($prepare_parse_s),
            optimize_s => round6($optimize_s),
            codegen_link_s => round6($codegen_link_s),
        },
        modules => \@records,
    };
}

sub median_summary {
    my ($samples) = @_;
    my %summary;
    for my $key (keys %{$samples->[0]}) {
        next if ref $samples->[0]{$key};
        $summary{$key} = median(map { $_->{$key} } @$samples);
    }
    return \%summary;
}

sub main {
    my $llvm = '.';
    my $runs = 3;
    my ($output, $timing);
    GetOptions('llvm=s' => \$llvm, 'runs=i' => \$runs, 'output=s' => \$output,
               'timing' => \$timing)
        or die "usage: $0 [--llvm D] [--runs N] --output F [--timing]\n";
    defined $output or die "--output is required\n";
    $runs >= 1 or die "--runs must be positive\n";

    my $directory = abs_path($llvm);
    my $provenance = main::build_provenance($directory);
    -f "$directory/mudlle" or die "Mudlle executable not found in $directory\n";
    ($provenance->{mudlle_arch} // '') =~ /-llvm$/
        or die "$directory is not marked as an LLVM build\n";

    my %report = (
        runs => $runs + 0,
        workloads => {
            compiler_load => 'icxc.mud plus checked eval(iadd(20,22))',
            kernel => 'regression/benchmark.mud; 100 million loop-sum iterations',
        },
        cache_state => 'fresh processes; LLVM object cache disabled; OS filesystem cache not flushed',
        host => host_info(),
        build => $provenance,
        results => {},
    );

    for my $configuration (@CONFIGURATIONS) {
        my ($label, $optimization, $verify) = @$configuration;
        my %samples_by_workload;
        for my $workload ('compiler_load', 'kernel') {
            my @samples;
            for my $run (1 .. $runs) {
                local $ENV{MUDLLE_LLVM_OPT} = $optimization;
                local $ENV{MUDLLE_LLVM_VERIFY_EACH} = $verify;
                delete local $ENV{MUDLLE_LLVM_TIMING};
                my $sample = main::measure($directory, $optimization, $workload);
                die "$directory did not run the LLVM backend\n"
                    if $workload eq 'kernel' && ($sample->{backend} // '') ne 'llvm';
                push @samples, $sample;
                print STDERR "$label $workload $run/$runs: ",
                    JSON::PP->new->canonical->encode($sample), "\n";
            }
            $samples_by_workload{$workload} = {
                samples => \@samples, medians => median_summary(\@samples) };
        }
        $report{results}{$label} = {
            optimization => $optimization,
            verify_each => $verify eq "1" ? JSON::PP::true : JSON::PP::false,
            workloads => \%samples_by_workload,
        };
    }

    if ($timing) {
        my %diagnostics = (
            runs_per_configuration => $runs + 0,
            remaining_process_s_definition =>
                'wall_s minus summed LLVM stages; includes source handling, '
                . 'runtime startup and other process work, so it is not pure '
                . 'IR generation',
            configurations => {},
        );
        for my $configuration (@CONFIGURATIONS) {
            my ($label, $optimization, $verify) = @$configuration;
            my @samples;
            for my $run (1 .. $runs) {
                my $sample = run_timing_diagnostic($directory, $optimization, $verify);
                push @samples, $sample;
                print STDERR "$label timing $run/$runs: process=",
                    JSON::PP->new->canonical->encode($sample->{process}),
                    " totals=",
                    JSON::PP->new->canonical->encode($sample->{totals}), "\n";
            }
            $diagnostics{configurations}{$label} = {
                optimization => $optimization,
                verify_each => $verify eq '1' ? JSON::PP::true : JSON::PP::false,
                compiler_load_samples => \@samples,
                medians => median_summary([
                    map { { module_count => $_->{module_count},
                            %{$_->{process}}, %{$_->{totals}} } } @samples ]),
            };
        }
        $report{timing_diagnostics} = \%diagnostics;
    }

    make_path(dirname(File::Spec->rel2abs($output)));
    spew($output, to_json(\%report));
    print STDERR "wrote ", File::Spec->rel2abs($output), "\n";
}

main();
