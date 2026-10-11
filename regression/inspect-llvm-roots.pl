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
use Digest::SHA qw(sha256_hex);
use FindBin;
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use Getopt::Long;
use JSON::PP ();
use lib $FindBin::Bin;
use RootsBench qw(identity_probe_source);

sub slurp {
    my ($path) = @_;
    open(my $fh, '<:raw', $path) or die "$path: $!\n";
    local $/;
    my $text = <$fh>;
    close($fh) or die "$path: $!\n";
    return $text;
}

sub spew {
    my ($path, $text) = @_;
    open(my $fh, '>:raw', $path) or die "$path: $!\n";
    print {$fh} $text or die "$path: $!\n";
    close($fh) or die "$path: $!\n";
}

sub run_to_files {
    my ($stdout_path, $stderr_path, @command) = @_;
    my $pid = fork() // die "fork: $!\n";
    if ($pid == 0) {
        open(STDOUT, '>', $stdout_path) or die "$stdout_path: $!\n";
        open(STDERR, '>', $stderr_path) or die "$stderr_path: $!\n";
        exec { $command[0] } @command or die "exec $command[0]: $!\n";
    }
    waitpid($pid, 0);
    my $status = $?;
    return $status == 0 ? 0 : $status;
}

sub command_output {
    my (@command) = @_;
    open(my $fh, '-|', @command) or die "run @command: $!\n";
    local $/;
    my $output = <$fh>;
    close($fh) or die "command failed: @command\n";
    $output =~ s/\s+\z//;
    return $output;
}

sub export_cache_objects {
    my ($cache, $out) = @_;
    my @entries = sort glob("$cache/*.cache");
    @entries or die "LLVM cache contains no native objects: $cache\n";
    my $index = 0;
    for my $path (@entries) {
        my $data = slurp($path);
        length($data) >= 24 or die "cache entry is shorter than its 24-byte header: $path\n";
        my ($key_size, $object_size, $checksum) = unpack('Q Q Q', substr($data, 0, 24));
        my $expected_length = 24 + $key_size + $object_size;
        length($data) == $expected_length
            or die "cache entry lengths disagree with its header: $path\n";
        $key_size > 0 && $object_size > 0
            or die "cache entry has an empty key or object: $path\n";
        my $object = substr($data, 24 + $key_size, $object_size);
        my $stem = sprintf('native-%03d', ++$index);
        my $object_path = "$out/$stem.o";
        spew($object_path, $object);
        my $disassembly = "$out/$stem.objdump.txt";
        my $status = run_to_files($disassembly, "$out/$stem.objdump.stderr",
                                  'objdump', '-dr', $object_path);
        $status == 0 or die "objdump failed for $object_path; see $out/$stem.objdump.stderr\n";
    }
    return scalar @entries;
}

sub main {
    my ($llvm, $output, $identity_only);
    GetOptions('llvm=s' => \$llvm, 'output=s' => \$output,
               'identity-only' => \$identity_only)
        or die "usage: $0 --llvm D --output D [--identity-only]\n";
    defined $llvm && defined $output
        or die "--llvm and --output are required\n";
    my $llvm_dir = abs_path($llvm);
    defined $llvm_dir && -d $llvm_dir or die "invalid LLVM directory\n";
    -x "$llvm_dir/mudlle" or die "Mudlle executable not found in $llvm_dir\n";
    my $source_path = "$llvm_dir/regression/benchmark-llvm-roots.mud";
    my $source = slurp($source_path);
    $source = identity_probe_source($source) if $identity_only;
    my $workload_source_sha256 = sha256_hex($source);
    my $output_dir = File::Spec->rel2abs($output);
    make_path($output_dir);
    $output_dir = abs_path($output_dir);
    my $cache_dir = tempdir('cache-XXXXXX', DIR => $output_dir);

    my $parse_line = '    tree = mudlle_parse(source, name, false);';
    my $instrument = <<'MUDLLE';
    tree = mudlle_parse(source, name, false);
    if (string_equal?(mc:archname, "llvm")) [ | ir, w |
      ir = mc:compile_llvm(tree, 1, mc:source_code(source));
      w = writer:new_file(roots_profile_ir_dir + "/" + name + ".ll");
      writer:write(w, ir);
      writer:close(w);
      tree = mudlle_parse(source, name, false);
    ];
MUDLLE
    my $count = () = $source =~ /\Q$parse_line\E/g;
    $count == 1 or die "expected one compile callback parse line in $source_path, found $count\n";
    $source =~ s/\Q$parse_line\E/$instrument/;
    my $workload_path = "$output_dir/benchmark-llvm-roots-inspect.mud";
    spew($workload_path, $source);

    my $mudlle_output_dir = $output_dir;
    $mudlle_output_dir =~ s/([\\"])/\\$1/g;
    my $run_log = "$output_dir/workload.log";
    my $run_err = "$output_dir/workload.stderr";
    my %env = %ENV;
    $env{MUDLLE_LLVM_OPT} = 'O2';
    $env{MUDLLE_LLVM_CACHE} = $cache_dir;
    delete $env{MUDLLE_LLVM_CACHE_TRACE};
    delete $env{MUDLLE_LLVM_VERIFY_EACH};
    delete $env{MUDLLE_LLVM_TIMING};
    local %ENV = %env;
    my $pid = fork() // die "fork: $!\n";
    if ($pid == 0) {
        chdir($llvm_dir) or die "$llvm_dir: $!\n";
        open(STDOUT, '>', $run_log) or die "$run_log: $!\n";
        open(STDERR, '>', $run_err) or die "$run_err: $!\n";
        exec "$llvm_dir/mudlle", '-c', 'silent=true', '-e', 'xc.mud',
             '-c', "roots_profile_ir_dir = \"$mudlle_output_dir\";",
             '-e', $workload_path or die "exec $llvm_dir/mudlle: $!\n";
    }
    waitpid($pid, 0);
    my $status = $?;
    my $stdout = slurp($run_log);
    my $stderr = slurp($run_err);
    ($status == 0) or die "instrumented workload failed (status $status):\n$stdout$stderr";
    $stdout =~ /^benchmark-llvm-roots-success$/m
        or die "workload exited without its success marker:\n$stdout$stderr";

    my @ir_files = sort grep { !/\.opt\.ll$/ } glob("$output_dir/*.ll");
    @ir_files or die "instrumentation emitted no LLVM IR files\n";
    my $opt = $ENV{LLVM_OPT} || 'opt-19';
    my $triple = command_output('llvm-config', '--host-target');
    for my $ir (@ir_files) {
        my $optimized = $ir;
        $optimized =~ s/\.ll\z/.opt.ll/;
        my $err = $optimized . '.stderr';
        my $opt_status = run_to_files('/dev/null', $err, $opt, '-passes=default<O2>',
                                      "-mtriple=$triple", '-S', $ir, '-o', $optimized);
        $opt_status == 0 or die "$opt failed for $ir; see $err\n";
    }
    my $objects = export_cache_objects($cache_dir, $output_dir);
    spew("$output_dir/inspection.json", JSON::PP->new->canonical->pretty->encode({
        llvm_directory => $llvm_dir,
        workload => $workload_path,
        mode => $identity_only ? 'identity-only' : 'default',
        instrumented_source_sha256 => $workload_source_sha256,
        ir_files => [map { (File::Spec->splitpath($_))[2] } @ir_files],
        cached_native_objects => $objects,
        llvm_host_target => $triple,
        optimized_ir_tool => $opt,
        optimization_pipeline => 'default<O2>',
    }));
    print "LLVM roots inspection artifacts: $output_dir\n";
}

main();
