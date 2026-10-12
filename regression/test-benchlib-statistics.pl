#!/usr/bin/perl

# Copyright (c) 2026 Nils Schimmelmann
# All rights reserved.
#
# Permission to use, copy, modify, and distribute this software for any
# purpose, without fee, and without written agreement is hereby granted,
# provided that the above copyright notice and the following two paragraphs
# appear in all copies of this software and its documentation.
#
# IN NO EVENT SHALL NILS SCHIMMELMANN BE LIABLE TO ANY PARTY FOR DIRECT,
# INDIRECT, SPECIAL, INCIDENTAL, OR CONSEQUENTIAL DAMAGES ARISING OUT OF THE
# USE OF THIS SOFTWARE AND ITS DOCUMENTATION, EVEN IF NILS SCHIMMELMANN HAS
# BEEN ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
#
# NILS SCHIMMELMANN SPECIFICALLY DISCLAIMS ANY WARRANTIES, INCLUDING, BUT NOT
# LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A
# PARTICULAR PURPOSE. THE SOFTWARE PROVIDED HEREUNDER IS PROVIDED ON AN "AS
# IS" BASIS, AND NILS SCHIMMELMANN HAS NO OBLIGATION TO PROVIDE MAINTENANCE,
# SUPPORT, UPDATES, ENHANCEMENTS, OR MODIFICATIONS.

use strict;
use warnings;
use FindBin;
use lib $FindBin::Bin;
use Test::More;
use BenchLib qw(sample_summary paired_log_ratio_summary
                independent_median_ratio_summary);

my $summary = sample_summary([1, 2, 3, 4, 100]);
is($summary->{n}, 5, 'sample count');
is($summary->{min}, 1, 'minimum');
is($summary->{median}, 3, 'median');
is($summary->{max}, 100, 'maximum');
is($summary->{mad}, 1, 'median absolute deviation');

my $constant = paired_log_ratio_summary([20, 40, 60], [10, 20, 30],
                                         resamples => 5000, seed => 17);
is($constant->{median_ratio}, 2, 'paired median ratio');
is_deeply($constant->{bootstrap_95pct_ci_ratio}, [2, 2],
          'constant paired ratios have a point bootstrap interval');
is($constant->{valid_pairs}, 3, 'all positive pairs used');

my $varying = paired_log_ratio_summary([1, 2, 4], [1, 1, 1],
                                        resamples => 5000, seed => 29);
is($varying->{median_ratio}, 2, 'nonconstant paired median ratio');
is_deeply($varying->{bootstrap_95pct_ci_ratio}, [1, 4],
          'nonconstant pairs produce the expected bootstrap interval');
my $repeated = paired_log_ratio_summary([1, 2, 4], [1, 1, 1],
                                         resamples => 5000, seed => 29);
is_deeply($repeated, $varying, 'bootstrap result is deterministic for a fixed seed');

eval {
    paired_log_ratio_summary([1, 2], [1]);
    1;
};
like($@, qr/equal nonzero length/, 'mismatched paired samples are rejected');

my $with_zero = paired_log_ratio_summary([0, 20, 40], [0, 10, 20],
                                          resamples => 100, seed => 17);
is($with_zero->{zero_or_nonpositive_pairs}, 1, 'zero pair counted');
is($with_zero->{valid_pairs}, 2, 'zero pair excluded safely');
is($with_zero->{median_ratio}, 2, 'valid pairs summarized');

my $all_zero = paired_log_ratio_summary([0, 0], [0, 0]);
is($all_zero->{valid_pairs}, 0, 'all-zero input has no valid pairs');
ok(!exists $all_zero->{median_ratio}, 'all-zero input avoids division');
ok(!exists $all_zero->{bootstrap_95pct_ci_ratio},
   'all-zero input has no bootstrap interval');

my $independent_constant = independent_median_ratio_summary(
    [20, 20, 20], [10, 10], resamples => 100, seed => 17);
is($independent_constant->{median_ratio}, 2,
   'independent median ratio for constant samples');
is_deeply($independent_constant->{bootstrap_95pct_ci_ratio}, [2, 2],
          'constant independent samples have a point interval');

my $independent_varying = independent_median_ratio_summary(
    [1, 2, 4], [1, 1, 1], resamples => 5000, seed => 29);
is($independent_varying->{median_ratio}, 2,
   'independent median ratio with varying timings');
is_deeply($independent_varying->{bootstrap_95pct_ci_ratio}, [1, 4],
          'independent bootstrap samples each backend distribution');
my $independent_unequal = independent_median_ratio_summary(
    [1, 2, 4, 8], [2, 4], resamples => 5000, seed => 29);
is($independent_unequal->{llvm_samples}, 4,
   'independent samples permit unequal round counts');
is($independent_unequal->{x64_samples}, 2,
   'x64 count is recorded separately');

eval {
    independent_median_ratio_summary([1, 0], [1, 1]);
    1;
};
like($@, qr/timings must be positive/, 'invalid independent timings are rejected');

done_testing();
