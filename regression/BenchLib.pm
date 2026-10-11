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
                    to_json run_command run_timed child_cpu);

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
