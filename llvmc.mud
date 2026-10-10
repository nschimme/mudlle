/*
 * Load the LLVM IR compiler.
 *
 * After loading this file, mc:compile returns LLVM IR text (or writes it to w).
 * The result is IR, not a linked executable module.
 */

| srcdir |
srcdir = dirname(loading_file()) + "/";

load(srcdir + "lib.mud") &&
load(srcdir + "noinf.mud") &&
load(srcdir + "llvmcompile.mud");

mc:verbose = 0;
