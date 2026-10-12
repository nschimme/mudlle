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
use POSIX qw(strftime);
use Time::HiRes qw(time);
use JSON::PP ();
use lib $FindBin::Bin;
use BenchLib qw(slurp spew sha256_file sha256_hex median round6 host_info to_json run_command
                sample_summary paired_log_ratio_summary
                independent_median_ratio_summary);

my ($llvm, $x64, $output, $llvm_revision, $x64_revision, $baseline_report_path);
my $runs = 15;
my $timed_calls = 50;
my $suite = 'all';
GetOptions('llvm=s' => \$llvm, 'x64=s' => \$x64, 'output=s' => \$output,
           'runs=i' => \$runs, 'timed-calls=i' => \$timed_calls,
           'llvm-revision=s' => \$llvm_revision, 'x64-revision=s' => \$x64_revision,
           'baseline-report=s' => \$baseline_report_path,
           'suite=s' => \$suite)
    or die "invalid options\n";
my $reuse_baseline = defined $baseline_report_path;
defined $llvm && defined $output && $runs > 0
    && $timed_calls >= 1 && $timed_calls <= 1000
    && (($reuse_baseline && !defined $x64) || (!$reuse_baseline && defined $x64))
    or die "usage: $0 --llvm DIR (--x64 DIR | --baseline-report FILE) --output FILE [--runs 15] [--timed-calls 50] [--suite all|numeric|sequences|tables|calls|integer]\n";
$suite =~ /\A(?:all|numeric|sequences|tables|calls|integer)\z/ or die "unknown suite $suite\n";
for my $revision ($llvm_revision, $x64_revision) {
    !defined $revision || $revision =~ /\A[0-9a-f]{40}\z/
        or die "revision must be a full Git SHA\n";
}
my ($baseline, $baseline_bytes);
if ($reuse_baseline) {
    -r $baseline_report_path or die "cannot read baseline report $baseline_report_path\n";
    $baseline_report_path = abs_path($baseline_report_path);
    $baseline_bytes = slurp($baseline_report_path);
    $baseline = eval { JSON::PP->new->decode($baseline_bytes) };
    $baseline && ref($baseline) eq 'HASH' or die "invalid baseline report JSON: $@\n";
    if (($baseline->{schema} // '') eq 'mudlle-benchmark-baseline-v1') {
        defined($baseline->{backend}) && $baseline->{backend} eq 'x64'
            or die "baseline fixture backend must be x64\n";
        defined($baseline->{suite}) && defined($baseline->{timed_calls_per_sample})
            && $baseline->{timed_calls_per_sample} =~ /\A\d+\z/
            or die "baseline fixture lacks suite/timed-call configuration\n";
        ref($baseline->{workloads}) eq 'HASH' or die "baseline fixture workloads must be an object\n";
        my (@samples, $sample_count);
        for my $name (sort keys %{$baseline->{workloads}}) {
            my $workload = $baseline->{workloads}{$name};
            ref($workload) eq 'HASH' && ref($workload->{cpu_ms}) eq 'ARRAY'
                or die "invalid baseline fixture workload $name\n";
            @{$workload->{cpu_ms}} or die "baseline fixture workload $name has no CPU samples\n";
            defined($sample_count) && $sample_count != @{$workload->{cpu_ms}}
                and die "baseline fixture workloads have different sample counts\n";
            $sample_count = scalar @{$workload->{cpu_ms}};
            defined($workload->{work}) && $workload->{work} =~ /\A\d+\z/
                && defined($workload->{timed_calls}) && $workload->{timed_calls} =~ /\A\d+\z/
                && defined($workload->{checksum})
                or die "invalid baseline fixture metadata for $name\n";
            defined($workload->{width}) && $workload->{width} !~ /\A\d+\z/
                and die "invalid baseline fixture width for $name\n";
            for my $cpu (@{$workload->{cpu_ms}}) {
                defined($cpu) && $cpu =~ /\A\d+\z/ && $cpu > 0
                    or die "baseline fixture CPU samples must be positive integers\n";
            }
        }
        for my $round (0 .. $sample_count - 1) {
            my %round_workloads;
            for my $name (keys %{$baseline->{workloads}}) {
                my $w = $baseline->{workloads}{$name};
                my $expected_calls = $name eq 'loop-sum' ? 2000 : $baseline->{timed_calls_per_sample};
                $w->{timed_calls} == $expected_calls
                    or die "baseline fixture $name timed-call count is invalid\n";
                $round_workloads{$name} = {
                    work => 0 + $w->{work}, timed_calls => 0 + $w->{timed_calls},
                    checksum => $w->{checksum}, cpu_ms => 0 + $w->{cpu_ms}[$round],
                };
                $round_workloads{$name}{width} = 0 + $w->{width} if defined $w->{width};
            }
            push @samples, { round => $round + 1, workloads => \%round_workloads };
        }
        $baseline = {
            schema => 'mudlle-benchmark-baseline-v1', backend => 'x64',
            host => $baseline->{host}, cache_state => $baseline->{cache_state},
            started_at_utc => $baseline->{started_at_utc},
            finished_at_utc => $baseline->{finished_at_utc},
            suite => $baseline->{suite},
            timed_calls_per_sample => $baseline->{timed_calls_per_sample},
            workloads => [sort keys %{$baseline->{workloads}}],
            runs => scalar(@samples), builds => { x64 => $baseline->{build} },
            results => { x64 => { samples => \@samples } },
        };
    }
    defined $baseline->{builds}{x64} && ref($baseline->{builds}{x64}) eq 'HASH'
        or die "baseline report has no x64 build metadata\n";
    defined $baseline->{results}{x64}{samples}
        && ref($baseline->{results}{x64}{samples}) eq 'ARRAY'
        or die "baseline report has no x64 samples\n";
    defined $baseline->{host}{machine} && defined $baseline->{host}{platform}
        or die "baseline report lacks host identity\n";
    defined $baseline->{cache_state}
        or die "baseline report lacks cache state\n";
}
my @suites = $suite eq 'all' ? qw(numeric sequences tables calls integer) : ($suite);
my @files = map { $_ eq 'integer' ? 'regression/benchmark.mud' : "regression/benchmark-$_.mud" } @suites;
my @workloads;
push @workloads, qw(float-primitives bigint-primitives mixed)
    if grep { $_ eq 'numeric' } @suites;
push @workloads, qw(list-vector-library-32 list-vector-native-32 list-vector-native-257)
    if grep { $_ eq 'sequences' } @suites;
push @workloads, qw(table-mixed-32 table-mixed-257)
    if grep { $_ eq 'tables' } @suites;
push @workloads, qw(calls-fib-27 calls-closure-loop)
    if grep { $_ eq 'calls' } @suites;
push @workloads, 'loop-sum' if grep { $_ eq 'integer' } @suites;
my %workload_parameters = (
    numeric_iterations => { float => 100_000, bigint => 20_000, mixed => 20_000 },
    call_iterations_per_kernel => { fibonacci_argument => 27, closure_loop => 2_000_000 },
    integer_iterations_per_kernel => 50_000, integer_timed_calls_per_sample => 2000,
    sequence_iterations_per_kernel => { width_32 => 10_000, width_257 => 2_000 },
    table_iterations_per_kernel => { keys_32 => 32 * 256, keys_257 => 257 * 32,
                                     rounds_per_call => { keys_32 => 256, keys_257 => 32 },
                                     timed_calls_per_sample => $timed_calls },
    table_operations => [qw(insert lookup replace_twice delete_every_third reinsert iterate)],
    table_key_mix => 'even indexes inserted as string keys; odd indexes inserted as symbols; case-sensitive table',
    table_payload => '[integer, shared-child-vector]',
    sequence_collection_stress => 'checked outside CPU timers; identity/content guards remain inside timed loop',
    table_collection_stress => 'checked outside CPU timers; identity/content guards remain inside timed loop',
);
if ($reuse_baseline) {
    ($baseline->{suite} // '') eq $suite or die "baseline suite does not match requested suite\n";
    ($baseline->{timed_calls_per_sample} // 0) == $timed_calls
        or die "baseline timed-call count does not match requested count\n";
    ($baseline->{runs} // 0) == @{$baseline->{results}{x64}{samples}}
        or die "baseline x64 sample count does not match its run count\n";
    my @baseline_workloads = $baseline->{workloads} && ref($baseline->{workloads}) eq 'HASH'
        ? sort keys %{$baseline->{workloads}} : sort @{$baseline->{workloads} // []};
    JSON::PP->new->canonical->encode(\@baseline_workloads)
        eq JSON::PP->new->canonical->encode([sort @workloads])
        or die "baseline workloads do not match requested suite\n";
    my $baseline_samples = $baseline->{results}{x64}{samples};
    my $baseline_reference = $baseline_samples->[0]{workloads};
    ref($baseline_reference) eq 'HASH'
        && keys(%$baseline_reference) == @workloads
        or die "baseline x64 sample has an invalid workload set\n";
    for my $name (@workloads) {
        my $reference = $baseline_reference->{$name};
        ref($reference) eq 'HASH' or die "baseline x64 sample is missing $name\n";
        my $expected_calls = $name eq 'loop-sum' ? 2000 : $timed_calls;
        ($reference->{timed_calls} // 0) == $expected_calls
            or die "baseline x64 $name has the wrong timed-call count\n";
        defined($reference->{work}) && defined($reference->{checksum})
            or die "baseline x64 $name lacks work/checksum metadata\n";
        for my $sample (@$baseline_samples) {
            ref($sample->{workloads}) eq 'HASH'
                && keys(%{$sample->{workloads}}) == @workloads
                or die "baseline x64 sample has an invalid workload set\n";
            my $actual = $sample->{workloads}{$name};
            ref($actual) eq 'HASH' && defined($actual->{cpu_ms}) && $actual->{cpu_ms} > 0
                or die "baseline x64 $name has an invalid CPU sample\n";
            for my $key (qw(work timed_calls checksum width)) {
                ($actual->{$key} // '') eq ($reference->{$key} // '')
                    or die "baseline x64 $name $key differs between samples\n";
            }
        }
    }
    if (($baseline->{schema} // '') ne 'mudlle-benchmark-baseline-v1') {
        JSON::PP->new->canonical->encode($baseline->{workload_parameters} // {})
            eq JSON::PP->new->canonical->encode(\%workload_parameters)
            or die "baseline workload parameters do not match requested configuration\n";
    }
    my $host = host_info();
    $baseline->{host}{machine} eq $host->{machine}
        && $baseline->{host}{platform} eq $host->{platform}
        or die "baseline host platform/machine does not match current host\n";
    $baseline->{cache_state} eq 'fresh serial processes; native object cache disabled; filesystem cache not flushed'
        or die "baseline cache state does not match runner configuration\n";
    my $base_revision = $baseline->{builds}{x64}{base_git_revision};
    defined($base_revision) && $base_revision =~ /\A[0-9a-f]{40}\z/
        or die "baseline x64 revision must be a full Git SHA\n";
    !defined($x64_revision) || (defined($base_revision) && $base_revision eq $x64_revision)
        or die "requested x64 revision does not match baseline report\n";
}
my %directories = (llvm => abs_path($llvm));
$directories{x64} = abs_path($x64) unless $reuse_baseline;
my %report = (
    started_at_utc => strftime('%Y-%m-%dT%H:%M:%SZ', gmtime()),
    runs => $runs, timed_calls_per_sample => $timed_calls,
    suite => $suite, workloads => \@workloads, host => host_info(),
    cache_state => 'fresh serial processes; native object cache disabled; filesystem cache not flushed',
    sampling_order => $reuse_baseline
        ? 'fresh LLVM rounds; x64 timings reused from the recorded baseline; no round pairing'
        : 'alternate backend order in successive rounds; no concurrent validation; pair backends by round',
    statistics_method => {
        per_backend => $reuse_baseline
            ? 'min, median, max, and median absolute deviation (MAD); LLVM uses fresh-process rounds and x64 reuses recorded baseline samples'
            : 'min, median, max, and median absolute deviation (MAD) over fresh-process rounds',
        limitations => $reuse_baseline
            ? 'Unpaired interval independently resamples each backend sample distribution and assumes within-host IID rounds; it does not capture temporal drift between the baseline and new run, and does not establish general platform parity.'
            : 'Interval assumes round-pairs are independent and identically distributed on this host; it describes these builds and workloads, not general platform parity.',
    },
    interpretation => 'Kernel compilation, warmup, interpreter numeric references, explicit collection stress, and post-call oracle/aggregate checks are outside kernel CPU timers. Sequence and table kernels keep identity/content guards inside timed loops. Library conversions call loaded misc/sequences closures; native conversions compile the same loops locally. Floating-point comparisons use 1e-10 * (1 + abs(reference)); bigint, sequence, and table checksums are exact. Timed kernels retain ordinary loop accounting.',
    workload_parameters => \%workload_parameters,
    builds => {}, results => {},
);
if ($reuse_baseline) {
    $report{statistics_method}{unpaired} = 'ratio of independent backend medians; deterministic percentile bootstrap 95% interval independently resampling each backend; 5000 resamples; Park-Miller seed 20261012';
    $report{signed_cpu_time_percent} = '100 * (LLVM median / x64 median - 1); negative means faster, positive means slower';
    $report{baseline} = {
        source_report => $baseline_report_path,
        source_report_sha256 => sha256_hex($baseline_bytes),
        started_at_utc => $baseline->{started_at_utc},
        finished_at_utc => $baseline->{finished_at_utc},
        runs => $baseline->{runs},
        base_git_revision => $baseline->{builds}{x64}{base_git_revision},
    };
} else {
    $report{statistics_method}{paired} = 'median LLVM/x64 log-ratio; deterministic percentile bootstrap 95% interval over round-paired log-ratios; 5000 resamples; Park-Miller seed 20261012';
}
if (-r '/proc/cpuinfo') {
    my $cpuinfo = slurp('/proc/cpuinfo');
    $report{host}{cpu_model} = $1 if $cpuinfo =~ /^model name\s*:\s*(.+)$/m;
}
if ($reuse_baseline && defined($baseline->{host}{cpu_model})) {
    defined($report{host}{cpu_model})
        && $report{host}{cpu_model} eq $baseline->{host}{cpu_model}
        or die "baseline CPU model does not match current host\n";
}
my @measured_backends = $reuse_baseline ? qw(llvm) : qw(llvm x64);
for my $backend (@measured_backends) {
    my $dir = $directories{$backend};
    defined $dir && -f "$dir/mudlle" or die "invalid $backend build\n";
    my $arch = slurp("$dir/.mudlle-arch"); $arch =~ s/\s+\z//;
    $arch =~ /\Q$backend\E\z/ or ($backend eq 'x64' && $arch eq 'amd64')
        or die "$dir architecture $arch does not match $backend\n";
    my %hashes;
    for my $file ('mudlle', 'Makefile', 'genllvm.mud', 'genx64.mud', 'alloc.c', 'alloc.h', 'runtime/llvm.c',
                  'misc.mud', 'sequences.mud', 'regression/benchmark-rich.mud', @files) {
        if ($backend eq 'x64' && !-f "$dir/$file"
            && ($file eq 'genllvm.mud' || $file eq 'runtime/llvm.c')) {
            $hashes{$file} = undef; # Upstream x64 may predate the LLVM backend.
        } else {
            $hashes{$file} = sha256_file("$dir/$file");
        }
    }
    $report{builds}{$backend} = { path => $dir, mudlle_arch => $arch, sha256 => \%hashes,
        kernel_optimization => $backend eq 'llvm' ? 'default<O2>' : 'default x64 generator' };
    my $revision = $backend eq 'llvm' ? $llvm_revision : $x64_revision;
    $report{builds}{$backend}{base_git_revision} = $revision if defined $revision;
    $report{results}{$backend} = { samples => [] };
}
if ($reuse_baseline) {
    $report{builds}{x64} = $baseline->{builds}{x64};
    $report{results}{x64} = { samples => $baseline->{results}{x64}{samples} };
}
for my $file ('regression/benchmark-rich.mud', @files) {
    defined($report{builds}{llvm}{sha256}{$file})
        && defined($report{builds}{x64}{sha256}{$file})
        && $report{builds}{llvm}{sha256}{$file} eq $report{builds}{x64}{sha256}{$file}
        or die "workload differs between builds: $file\n";
}
for my $round (1 .. $runs) {
    my @round_backends = $reuse_baseline ? qw(llvm)
        : ($round % 2 ? qw(llvm x64) : qw(x64 llvm));
    for my $backend (@round_backends) {
        my %env = %ENV;
        $env{MUDLLE_LLVM_OPT} = 'O2'; $env{MUDLLE_LLVM_CACHE} = '';
        $env{MUDLLE_BENCH_TIMED_CALLS} = "$timed_calls";
        delete @env{qw(MUDLLE_LLVM_CACHE_TRACE MUDLLE_LLVM_VERIFY_EACH MUDLLE_LLVM_TIMING)};
        my @args = ('./mudlle', '-c', 'silent=true', '-e', 'xc.mud');
        if ($suite eq 'all') {
            push @args, ('-e', 'regression/benchmark-rich.mud',
                         '-e', 'regression/benchmark-calls.mud', '-e', 'regression/benchmark.mud');
        } else {
            push @args, ('-e', $files[0]);
        }
        my $start = time();
        my $load_average = -r '/proc/loadavg' ? slurp('/proc/loadavg') : undef;
        $load_average =~ s/\s+\z// if defined $load_average;
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
            my $expected_calls = $name eq 'loop-sum' ? 2000 : $timed_calls;
            $calls == $expected_calls or die "$name reported $calls timed calls; expected $expected_calls\n";
            $records{$name} = { work => 0+$work, timed_calls => 0+$calls, cpu_ms => 0+$cpu,
                               checksum => $checksum };
            $records{$name}{width} = 0+$width if defined $width;
        }
        for my $name (@workloads) { exists $records{$name} or die "missing $name:\n$stdout$stderr\n"; }
        keys(%records) == @workloads or die "unexpected workload count\n";
        for my $s (@suites) { $stdout =~ /^benchmark-\Q$s\E-success$/m or die "missing $s success marker\n$stdout$stderr\n"; }
        my $sample = { round => $round, wall_s => $wall, workloads => \%records };
        $sample->{load_average_before} = $load_average if defined $load_average;
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
        $report{results}{$backend}{statistics}{$name} = sample_summary([
            map { $_->{workloads}{$name}{cpu_ms} } @{$report{results}{$backend}{samples}}]);
    }
    my @llvm = map { $_->{workloads}{$name}{cpu_ms} }
        @{$report{results}{llvm}{samples}};
    my @x64 = map { $_->{workloads}{$name}{cpu_ms} }
        @{$report{results}{x64}{samples}};
    if ($reuse_baseline) {
        my $summary = independent_median_ratio_summary(
            \@llvm, \@x64, resamples => 5000, seed => 20261012);
        $summary->{median_cpu_time_percent} = 100 * ($summary->{median_ratio} - 1);
        $summary->{bootstrap_95pct_ci_cpu_time_percent} = [
            map { 100 * ($_ - 1) } @{$summary->{bootstrap_95pct_ci_ratio}}
        ];
        $report{unpaired_comparisons}{$name} = $summary;
    } else {
        $report{paired_comparisons}{$name} = paired_log_ratio_summary(\@llvm, \@x64,
            resamples => 5000, seed => 20261012);
    }
}
make_path(dirname($output));
$report{finished_at_utc} = strftime('%Y-%m-%dT%H:%M:%SZ', gmtime());
spew($output, to_json(\%report));
print STDERR "wrote $output\n";
