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

# Measure serial bootstrap stages, closure churn, startup, or full validation.
#
# Use a separately built tree. Bootstrap mode refuses existing stage markers;
# each invocation writes raw logs beside its JSON report. Peak RSS is the
# per-command maximum reported by /usr/bin/time (the largest child for make),
# not a sum across processes.

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Spec;
use Getopt::Long;
use JSON::PP ();
use POSIX qw(uname);
use lib dirname(abs_path(__FILE__));
use BenchLib qw(slurp spew sha256_file sha256_hex round6 host_info to_json
                run_timed child_cpu);

sub with_suffix {
    my ($path, $suffix) = @_;
    $path =~ s/\.[^.\/]*$//;
    return $path . $suffix;
}

sub trimmed_output {
    my $text = `@_`;
    $? == 0 or die "@_ failed\n";
    $text =~ s/\s+$//;
    return $text;
}

sub main {
    my ($mode, $optimization, $runs, $iterations, $output) =
        (undef, 'none', 1, 20000, undef);
    GetOptions('mode=s' => \$mode, 'optimization=s' => \$optimization,
               'runs=i' => \$runs, 'iterations=i' => \$iterations,
               'output=s' => \$output)
        or die "usage: $0 DIRECTORY --mode M --output F [--optimization O] "
             . "[--runs N] [--iterations N]\n";
    my $directory_arg = shift @ARGV // die "directory is required\n";
    ($mode // '') =~ /^(?:bootstrap|closures|startup|validation)$/
        or die "--mode must be bootstrap, closures, startup or validation\n";
    defined $output or die "--output is required\n";
    my $directory = abs_path($directory_arg);
    $output = File::Spec->rel2abs($output);
    ($runs >= 1 && $iterations >= 1)
        or die "runs and iterations must be positive\n";
    if ($mode eq 'bootstrap') {
        $runs == 1 or die "bootstrap requires a fresh tree for each run\n";
        -e "$directory/build$_" and
            die "bootstrap requires absent build0/build1/build2 directories\n"
            for 0 .. 2;
    }
    make_path(dirname($output));
    my %env = %ENV;
    delete $env{MAKEFLAGS};
    delete $env{MUDLLE_LLVM_CACHE_TRACE};
    @env{qw(MUDLLE_LLVM_OPT MUDLLE_LLVM_CACHE MUDLLE_LLVM_VERIFY_EACH
            MUDLLE_LLVM_TIMING)} = ($optimization, '', '0', '1');
    my %report = (
        host => host_info(),
        binary_sha256 => sha256_file("$directory/mudlle"),
        llvm_cache_abi_header => do {
            my $header = slurp("$directory/runtime/llvm-cache-abi.h");
            $header =~ s/^\s+|\s+$//g;
            $header;
        },
        llvm_version => trimmed_output('llvm-config', '--version'),
        cc_version => (split /\n/, trimmed_output('gcc', '--version'))[0],
        directory => $directory,
        mode => $mode,
        environment => { map { $_ => $env{$_} } qw(MUDLLE_LLVM_OPT
            MUDLLE_LLVM_CACHE MUDLLE_LLVM_VERIFY_EACH MUDLLE_LLVM_TIMING) },
        rss_definition => '/usr/bin/time maximum resident set size converted to bytes; make reports largest child, serial -j1',
        samples => [],
    );

    my (@commands, %caches);
    if ($mode eq 'bootstrap') {
        @commands = map { ["stage$_", ['make', '-j1', "build$_/.compiler",
                                       'USE_LLVM=yes'], undef] } 0 .. 2;
    } elsif ($mode eq 'closures') {
        @commands = (['closures', ['./mudlle', '-c', 'silent=true', '-c',
                                   "closure_iterations=$iterations", '-e',
                                   'regression/benchmark-llvm-closures.mud'],
                      'LLVM_CLOSURES_OK']);
    } elsif ($mode eq 'startup') {
        @commands = (['startup', ['./mudlle', '-c', 'silent=true', '-e',
                                  'icxc.mud', '-c',
                                  'assert(car(eval("iadd(20,22)")) == 42); '
                                  . 'display("compiler-load-ok\n")'],
                      'compiler-load-ok']);
    } else {
        %caches = map { $_ => with_suffix($output, ".$_.cache") } qw(xc icxc);
        -e $_ and die "validation requires fresh cache paths beside the report\n"
            for values %caches;
        $env{MUDLLE_LLVM_CACHE_TRACE} = '1';
        $report{environment}{MUDLLE_LLVM_CACHE} = { %caches };
        $report{environment}{MUDLLE_LLVM_CACHE_TRACE} = '1';
        @commands = map { my $loader = $_;
                          map { ["$loader-$_", ['./mudlle', '-c', 'silent=true',
                                 '-e', "$loader.mud", '-e', 'regression/all.mud'],
                                 'SUCCESS'] } qw(cold warm) } qw(xc icxc);
    }

    for my $run (1 .. $runs) {
        for my $entry (@commands) {
            my ($label, $command, $sentinel) = @$entry;
            $env{MUDLLE_LLVM_CACHE} = $caches{(split /-/, $label)[0]}
                if $mode eq 'validation';
            my $stem = with_suffix($output, ".$label-$run");
            my ($stdout_path, $stderr_path) = ("$stem.stdout", "$stem.stderr");
            my ($user0, $system0) = child_cpu();
            my ($code, $stdout, $stderr, $usage) = run_timed(
                $command, cwd => $directory, env => \%env,
                stdout => $stdout_path, stderr => $stderr_path);
            my ($user1, $system1) = child_cpu();
            my $wall = $usage->{wall};

            my (%totals, $modules);
            my @keys = qw(ir_bytes prepare_parse_s optimize_s codegen_link_s);
            @totals{@keys} = (0) x @keys;
            while ($stderr =~ /^LLVM timing bytes=(\d+) prepare_parse=([\d.]+) optimize=([\d.]+) codegen_link=([\d.]+)$/mg) {
                my @record = ($1, $2, $3, $4);
                $totals{$keys[$_]} += $record[$_] for 0 .. 3;
                $modules++;
            }
            $totals{$_} = round6($totals{$_}) for @keys;
            my %sample = (
                label => $label, run => $run + 0, command => $command,
                returncode => $code + 0,
                sentinel => $sentinel,
                sentinel_found => (!defined $sentinel
                    || scalar(grep { $_ eq $sentinel } split /\n/, $stdout))
                    ? JSON::PP::true : JSON::PP::false,
                wall_s => round6($wall),
                user_s => round6($user1 - $user0),
                system_s => round6($system1 - $system0),
                peak_rss_bytes => $usage->{rss},
                llvm_modules => $modules // 0,
                llvm_totals => \%totals,
                remaining_wall_s => round6($wall - $totals{prepare_parse_s}
                    - $totals{optimize_s} - $totals{codegen_link_s}),
                cache_hits => scalar(() = $stderr =~ /LLVM object cache hit\n/g),
                cache_misses => scalar(() = $stderr =~ /LLVM object cache miss\n/g),
                stdout_sha256 => sha256_file($stdout_path),
                stderr_sha256 => sha256_file($stderr_path),
            );
            $sample{iterations} = $iterations + 0 if $mode eq 'closures';
            if ($mode eq 'bootstrap') {
                my $stage = substr($label, -1);
                $sample{stage_marker_exists} =
                    -e "$directory/build$stage/.compiler"
                    ? JSON::PP::true : JSON::PP::false;
                my $objects = $label eq 'stage2' ? $directory
                                                 : "$directory/build$stage";
                $sample{objects_sha256} = {
                    map { (substr($_, rindex($_, '/') + 1) => sha256_file($_)) }
                    sort glob("$objects/*.obj") };
            }
            push @{$report{samples}}, \%sample;
            spew($output, to_json(\%report));
            printf "%s: %.3fs, peak RSS %.1f MiB\n", $label, $wall,
                $sample{peak_rss_bytes} / 2**20;
            $| = 1;
            die "failed; see $stdout_path and $stderr_path\n"
                if $code != 0 || !$sample{sentinel_found}
                   || ($mode eq 'bootstrap' && !$sample{stage_marker_exists});
        }
    }
}

main();
