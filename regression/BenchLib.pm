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

# Shared helpers for the regression benchmark and test scripts.

package BenchLib;

use strict;
use warnings;
use Digest::SHA;
use Exporter 'import';
use File::Temp qw(tempfile);
use JSON::PP ();
use POSIX qw(uname WIFEXITED WEXITSTATUS WIFSIGNALED WTERMSIG);
use Time::HiRes qw(time);

our @EXPORT_OK = qw(slurp spew sha256_file sha256_hex median round6 host_info
                    to_json run_command run_timed child_cpu
                    sample_summary paired_log_ratio_summary
                    independent_median_ratio_summary);

sub slurp {
    my ($path) = @_;
    open(my $fh, '<:raw', $path) or die "$path: $!\n";
    local $/;
    my $content = <$fh>;
    close($fh);
    return $content;
}

sub spew {
    my ($path, $content) = @_;
    open(my $fh, '>:raw', $path) or die "$path: $!\n";
    print $fh $content;
    close($fh) or die "$path: $!\n";
}

sub sha256_file { return Digest::SHA->new(256)->addfile($_[0], 'b')->hexdigest }
sub sha256_hex { return Digest::SHA::sha256_hex($_[0]) }

sub median {
    my @sorted = sort { $a <=> $b } @_;
    my $n = @sorted;
    return $sorted[$n >> 1] if $n % 2;
    return ($sorted[$n / 2 - 1] + $sorted[$n / 2]) / 2;
}

sub sample_summary {
    my ($values) = @_;
    @$values or die "sample_summary requires at least one value\n";
    my $med = median(@$values);
    return {
        n => scalar(@$values), min => (sort { $a <=> $b } @$values)[0],
        max => (sort { $b <=> $a } @$values)[0], median => $med,
        mad => median(map { abs($_ - $med) } @$values),
    };
}

# Summarize round-matched LLVM/x64 timings. Positive samples are represented
# as log ratios so reciprocal changes are symmetric. Non-positive pairs are
# counted and excluded rather than divided by zero. Bootstrap resampling uses
# a local Park-Miller generator so reports are deterministic across Perl runs.
sub paired_log_ratio_summary {
    my ($llvm, $x64, %opt) = @_;
    @$llvm == @$x64 && @$llvm or die "paired samples must have equal nonzero length\n";
    my $resamples = $opt{resamples} // 5000;
    my $seed = $opt{seed} // 20261012;
    $resamples > 0 or die "resamples must be positive\n";
    my (@logs, $zero_pairs);
    $zero_pairs = 0;
    for my $i (0 .. $#$llvm) {
        if ($llvm->[$i] <= 0 || $x64->[$i] <= 0) {
            ++$zero_pairs;
            next;
        }
        push @logs, log($llvm->[$i] / $x64->[$i]);
    }
    my $result = {
        rounds => scalar(@$llvm), valid_pairs => scalar(@logs),
        zero_or_nonpositive_pairs => $zero_pairs,
        bootstrap_resamples => 0, bootstrap_seed => 0 + $seed,
    };
    return $result unless @logs;
    my $observed = median(@logs);
    my @boot;
    my $state = $seed % 2147483647;
    $state = 1 if $state <= 0;
    for (1 .. $resamples) {
        my @draw;
        for (1 .. @logs) {
            $state = (48271 * $state) % 2147483647;
            push @draw, $logs[$state % @logs];
        }
        push @boot, median(@draw);
    }
    @boot = sort { $a <=> $b } @boot;
    my $lo = $boot[int(0.025 * ($resamples - 1))];
    my $hi = $boot[int(0.975 * ($resamples - 1))];
    $result->{median_log_ratio} = $observed;
    $result->{median_ratio} = exp($observed);
    $result->{bootstrap_resamples} = $resamples;
    $result->{bootstrap_95pct_ci_ratio} = [ exp($lo), exp($hi) ];
    return $result;
}

# Compare medians from independent samples. Each backend's timings are
# resampled independently, so no round-pairing is implied by this interval.
sub independent_median_ratio_summary {
    my ($llvm, $x64, %opt) = @_;
    @$llvm && @$x64 or die "independent samples must both be nonempty\n";
    my $resamples = $opt{resamples} // 5000;
    my $seed = $opt{seed} // 20261012;
    $resamples > 0 or die "resamples must be positive\n";
    for my $samples ($llvm, $x64) {
        for my $value (@$samples) {
            defined($value) && $value =~ /\A(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?\z/
                && $value > 0 or die "independent timings must be positive numbers\n";
        }
    }
    my $llvm_median = median(@$llvm);
    my $x64_median = median(@$x64);
    my $result = {
        llvm_samples => scalar(@$llvm), x64_samples => scalar(@$x64),
        llvm_median_cpu_ms => $llvm_median, x64_median_cpu_ms => $x64_median,
        median_ratio => $llvm_median / $x64_median,
        bootstrap_resamples => $resamples, bootstrap_seed => 0 + $seed,
    };
    my @boot;
    my $state = $seed % 2147483647;
    $state = 1 if $state <= 0;
    for (1 .. $resamples) {
        my (@llvm_draw, @x64_draw);
        for (1 .. @$llvm) {
            $state = (48271 * $state) % 2147483647;
            push @llvm_draw, $llvm->[$state % @$llvm];
        }
        for (1 .. @$x64) {
            $state = (48271 * $state) % 2147483647;
            push @x64_draw, $x64->[$state % @$x64];
        }
        push @boot, median(@llvm_draw) / median(@x64_draw);
    }
    @boot = sort { $a <=> $b } @boot;
    $result->{bootstrap_95pct_ci_ratio} = [
        $boot[int(0.025 * ($resamples - 1))],
        $boot[int(0.975 * ($resamples - 1))],
    ];
    return $result;
}

sub round6 { return 0 + sprintf('%.6f', $_[0]) }

sub host_info {
    my ($sysname, undef, $release, $version, $machine) = uname();
    return { platform => "$sysname-$release-$machine", machine => $machine };
}

sub to_json {
    my ($data) = @_;
    return JSON::PP->new->canonical->indent->space_after->indent_length(2)->encode($data);
}

# Run COMMAND (array ref) in CWD with ENV (hash ref); redirect output to the
# given files, or capture it when they are undef. Returns (exit, stdout, stderr).
sub run_command {
    my ($command, %opt) = @_;
    my $dir = $opt{cwd};
    my $env = $opt{env} || \%ENV;
    my (@temporary, %path);
    for my $stream (qw(stdout stderr)) {
        if (defined $opt{$stream}) {
            $path{$stream} = $opt{$stream};
        } else {
            my ($fh, $name) = tempfile('mudlle-bench-XXXXXX', TMPDIR => 1,
                                       UNLINK => 1);
            close($fh);
            $path{$stream} = $name;
        }
    }
    my $pid = fork() // die "fork: $!\n";
    if ($pid == 0) {
        chdir($dir) or die "$dir: $!\n" if defined $dir;
        %ENV = %$env;
        open(STDOUT, '>', $path{stdout}) or die "$path{stdout}: $!\n";
        open(STDERR, '>', $path{stderr}) or die "$path{stderr}: $!\n";
        exec(@$command) or do { print STDERR "exec $command->[0]: $!\n"; exit 127 };
    }
    waitpid($pid, 0);
    my $status = $?;
    my $code = WIFEXITED($status) ? WEXITSTATUS($status)
             : WIFSIGNALED($status) ? 128 + WTERMSIG($status) : -1;
    my $stdout = slurp($path{stdout});
    my $stderr = slurp($path{stderr});
    return ($code, $stdout, $stderr);
}

# CPU seconds consumed so far by waited-for children: (user, system).
sub child_cpu { my @t = times; return @t[2, 3] }

# Like run_command, but also returns a hash of wall/user/system seconds and
# the command's peak RSS in bytes, measured per command via /usr/bin/time.
sub run_timed {
    my ($command, %opt) = @_;
    my ($fh, $report) = tempfile('mudlle-time-XXXXXX', TMPDIR => 1, UNLINK => 1);
    close($fh);
    my $darwin = (uname())[0] eq 'Darwin';
    my @wrapper = ('/usr/bin/time', $darwin ? ('-l') : ('-f', '%M'),
                   '-o', $report);
    my $started = time;
    my ($code, $stdout, $stderr) = run_command([@wrapper, @$command], %opt);
    my $wall = time - $started;
    my $rss = 0;
    my $text = slurp($report);
    if ($darwin) {
        $rss = $1 if $text =~ /^\s*(\d+)\s+maximum resident set size/m;
    } else {
        $rss = ($text =~ /^(\d+)\s*$/m ? $1 : 0) * 1024;
    }
    return ($code, $stdout, $stderr,
            { wall => $wall, rss => $rss });
}

1;
