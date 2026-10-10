# Mudlle LLVM Backend & Assembly Writer Documentation

This document describes the LLVM backend (`genllvm.mud`, `llvm.mud`, `allvm.mud`, `mllvm.mud`) and Assembly Writer abstraction (`asmwriter.mud`) used by the Mudlle compiler.

---

## 1. Overview

The LLVM backend emits LLVM IR for Mudlle functions. ORC LLJIT compiles and loads that IR in process. Optional LLVM command-line tools can validate or inspect emitted IR, but normal execution does not invoke them.

The IR leaves the target triple and data layout unspecified. This lets LLVM select its host target, including 64-bit ARM and RISC-V targets when LLVM provides them. This is code generation coverage, not proof of runtime compatibility or production readiness.

### Native parity contract

LLVM is a native compiler backend only when it can replace the x64 backend in
the normal `mc:compile` → `mc:prelink` → `mc:linkrun` path. Returning IR text or
calling a function through the experimental C ABI bridge does not satisfy this
contract.

The backend must preserve the x64 backend's observable language and runtime
behavior, including:

- Every `ins3` instruction class and every builtin operation, with the same
  tagged values, type checks, errors, security-level checks, and side effects.
- Function calls, closures and captured variables, optional and variadic
  arguments, globals, imported constants, and nested function references.
- Mudlle's compiled-code calling convention, code and closure metadata,
  constants, relocations, function entry points, source locations, and
  serialization rules.
- Garbage-collector correctness while generated code runs, including live
  values in registers and stack slots across allocating calls, stack traces,
  and code movement or unloading.
- The public compiler API and the behavior of interactive evaluation,
  compilation to `.obj`, and loading precompiled modules.

The current x64 runtime makes these requirements explicit: `struct mcode` and
its GC scanner encode x64 machine-code layout (`mvalues.h`, `alloc.c`). The
LLVM path therefore stores IR and constants in an LLVM-specific prelink
descriptor, compiles a shared module at load time, and wraps generated entries
as normal Mudlle closures. This exercises `mc:compile` and `mc:linkrun`, but it
does not make LLVM output compatible with serialized x64 `mcode` objects.

The existing linker in `runtime/support.c` resolves x64 constants, nested code
entries, builtins, globals, primitives, security-level patches, and source
metadata before creating an `mcode`. LLVM uses its own loader and runtime
helpers for those generated modules. Behavioral parity with the x64 linker and
runtime remains an ongoing requirement.

The Assembly Writer (`asmwriter.mud`) provides a writer abstraction that can emit IR and assembly to strings and files.

---

## 2. Assembly & IR Text Writer (`asmwriter.mud`)

The `asmwriter` library provides a uniform interface for outputting formatted text (such as disassemblies, assembly instructions, or LLVM IR).

### Functions

- `writer:new({oport,null} p = null)`
  Creates a writer wrapping output port `p` (defaults to `stdout()` if null).

- `writer:new_file(string filename)`
  Creates a writer that outputs directly to a file `filename`.

- `writer:new_string()`
  Creates a writer capturing output into an in-memory string buffer.

- `writer:get_string(vector w)`
  Returns the captured string from a string writer.

- `writer:write(vector w, string s)`
  Writes string `s` to writer `w`.

- `writer:write_line(vector w, string s)`
  Writes string `s` followed by a newline to writer `w`.

- `writer:format(vector w, string fmt, args...)`
  Formats and writes text to `w` using `pformat`.

- `writer:close(vector w)`
  Closes the underlying file or port if applicable.

---

## 3. LLVM Backend (`genllvm.mud`, `llvm.mud`)

`genllvm.mud` translates Mudlle's Phase 2 / Phase 3 `ins3` 3-address intermediate representation into target-independent LLVM IR (`.ll`).

### Architecture Backend Interface (`mp:`)

`llvm.mud` supplies LLVM instruction generation for the backend interface.
The LLVM loader uses a custom compilation pipeline. `mc:compile_llvm` returns
IR text for inspection; `mc:compile` returns a prelinked LLVM module accepted
by `mc:linkrun`.

### Data Mapping Scheme

- **Tagged Values**: Mudlle uses 64-bit tagged integer pointers (`i64` in LLVM IR).
  - Tagged Integer: `mudlle_int = (c_int << 1) | 1`
  - Untagging: `ashr i64 %val, 1`
  - Boolean `false`: `1` (tagged 0)
  - Boolean `true`: `3` (tagged 1)
- **Local/Temporary Variables**: Allocated as 64-bit stack slots (`alloca i64`) in the function entry block. Reads and writes use `load i64` and `store i64`. LLVM's `mem2reg` pass automatically promotes these slots into pure SSA virtual registers and `phi` nodes.

### Helper Functions

- `mc:gen_llvm_ir(vector mod, {writer,null} w = null)`
  Generates LLVM IR for an entire Mudlle module `mod`. If `w` is omitted or null, returns the generated LLVM IR as a string.


---

## 4. Compiler Integration (`compile.mud`)

The x86-64 compiler's `mc:compile` produces a prelinked x64 code object. The
LLVM loader's `mc:compile` produces an LLVM-specific prelink descriptor, which
`mc:linkrun` compiles and loads at runtime. Both follow the public compile and
run API, but the two prelink formats are not interchangeable and full
behavioral parity is still in progress.

---

## 5. Usage Examples

### Example 1: Unified Compilation (`mc:compile`)

```mudlle
load("xc.mud");

| tree, pmod |
tree = mudlle_parse("fn (a, b) [ if (a < b) a * b else a - b ]", "test.mud", false);
pmod = mc:compile(tree, false, 15, mc:source_code("fn (a, b) [ if (a < b) a * b else a - b ]"));
```

### Example 2: Generate LLVM IR text

```mudlle
load("xc.mud");

| tree, ir |
tree = mudlle_parse("fn (a, b) a + b", "test.mud", false);
ir = mc:gen_llvm_ir(tree);
display(ir);
```
