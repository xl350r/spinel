# Spinel -- Ruby AOT Compiler

Spinel compiles Ruby source code into standalone native executables.
It performs whole-program type inference and generates optimized C code,
achieving significant speedups over CRuby.

Spinel is **self-hosting**: the compiler backend is written in Ruby and
compiles itself into a native binary.

## How It Works

```
Ruby (.rb)
    |
    v
spinel_parse           Parse with Prism (libprism), serialize AST
    |                  (C binary, or CRuby + Prism gem as fallback)
    v
AST text file
    |
    v
spinel_codegen         Type inference + C code generation
    |                  (self-hosted native binary)
    v
C source (.c)
    |
    v
cc -O2 -Ilib -lm      Standard C compiler + runtime header
    |
    v
Native binary           Standalone, no runtime dependencies
```

## Quick Start

```bash
# Build everything:
make

# Write a Ruby program:
cat > hello.rb <<'RUBY'
def fib(n)
  if n < 2
    n
  else
    fib(n - 1) + fib(n - 2)
  end
end

puts fib(34)
RUBY

# Compile and run:
./spinel hello.rb
./hello               # prints 5702887 (instantly)
```

### Options

```bash
./spinel app.rb              # compiles to ./app
./spinel app.rb -o myapp     # compiles to ./myapp
./spinel app.rb -c           # generates app.c only
./spinel app.rb -S           # prints C to stdout
```

## Self-Hosting

Spinel compiles its own backend. The bootstrap chain:

```
CRuby + spinel_parse.rb → AST
CRuby + spinel_codegen.rb → gen1.c → bin1
bin1 + AST → gen2.c → bin2
bin2 + AST → gen3.c
gen2.c == gen3.c   (bootstrap loop closed)
```

## Benchmarks

74 tests pass. 55 benchmarks pass.
Geometric mean: **~49x faster** than CRuby across 50 benchmarks.

### Computation

| Benchmark | Spinel | CRuby | Speedup |
|---|---|---|---|
| ackermann | 5 ms | 394 ms | 78.8x |
| life (Conway's GoL) | 22 ms | 1,525 ms | 69.3x |
| fib (recursive) | 11 ms | 560 ms | 50.9x |
| mandelbrot | 24 ms | 1,187 ms | 49.5x |
| matmul | 9 ms | 329 ms | 36.6x |
| fasta (DNA seq gen) | 2 ms | 72 ms | 36.0x |
| fannkuch | 2 ms | 71 ms | 35.5x |
| nqueens | 777 ms | 24,912 ms | 32.1x |
| tarai | 16 ms | 423 ms | 26.4x |
| tak | 20 ms | 499 ms | 24.9x |
| sudoku | 6 ms | 148 ms | 24.7x |
| partial_sums | 81 ms | 1,282 ms | 15.8x |
| sieve | 38 ms | 435 ms | 11.4x |

### Data Structures & GC

| Benchmark | Spinel | CRuby | Speedup |
|---|---|---|---|
| rbtree (red-black tree) | 23 ms | 571 ms | 24.8x |
| huffman (encoding) | 10 ms | 200 ms | 20.0x |
| splay tree | 14 ms | 241 ms | 17.2x |
| binary_trees | 11 ms | 105 ms | 9.5x |
| so_lists | 74 ms | 510 ms | 6.9x |
| linked_list | 101 ms | 455 ms | 4.5x |
| gcbench | 1,634 ms | 4,247 ms | 2.6x |

### Real-World Programs

| Benchmark | Spinel | CRuby | Speedup |
|---|---|---|---|
| bigint_fib (1000 digits) | 2 ms | 66 ms | 33.0x |
| pidigits (bigint) | 2 ms | 65 ms | 32.5x |
| str_concat | 2 ms | 67 ms | 33.5x |
| json_parse | 38 ms | 436 ms | 11.5x |
| ao_render (ray tracer) | 409 ms | 3,674 ms | 9.0x |
| template engine | 137 ms | 961 ms | 7.0x |
| io_wordcount | 26 ms | 153 ms | 5.9x |
| csv_process | 229 ms | 936 ms | 4.1x |

## Supported Ruby Features

**Core**: Classes, inheritance, `super`, `include` (mixin), `attr_accessor`,
`Struct.new`, `alias`, module constants, open classes for built-in types.

**Control Flow**: `if`/`elsif`/`else`, `unless`, `case`/`when`,
`case`/`in` (pattern matching), `while`, `until`, `loop`, `for..in`
(range and array), `break`, `next`, `return`, `catch`/`throw`,
`&.` (safe navigation).

**Blocks**: `yield`, `block_given?`, `&block`, `proc {}`, `Proc.new`,
lambda `-> x { }`, `method(:name)`. Block methods: `each`,
`each_with_index`, `map`, `select`, `reject`, `reduce`, `sort_by`,
`any?`, `all?`, `none?`, `times`, `upto`, `downto`.

**Exceptions**: `begin`/`rescue`/`ensure`/`retry`, `raise`,
custom exception classes.

**Types**: Integer, Float, String (immutable + mutable), Array, Hash,
Range, Time, StringIO, File, Regexp, Bigint (auto-promoted), Fiber.
Polymorphic values via tagged unions. Nullable object types (`T?`)
for self-referential data structures (linked lists, trees).

**Global Variables**: `$name` compiled to static C variables with
type-mismatch detection at compile time.

**Strings**: `<<` automatically promotes to mutable strings (`sp_String`)
for O(n) in-place append. `+`, interpolation, `tr`, `ljust`/`rjust`/`center`,
and all standard methods work on both. Character comparisons like
`s[i] == "c"` are optimized to direct char array access (zero allocation).
Chained concatenation (`a + b + c + d`) collapses to a single malloc
via `sp_str_concat4` / `sp_str_concat_arr` -- N-1 fewer allocations.
Loop-local `str.split(sep)` reuses the same `sp_StrArray` across
iterations (csv_process: 4 M allocations eliminated).

**Regexp**: Built-in NFA regexp engine (no external dependency).
`=~`, `$1`-`$9`, `match?`, `gsub(/re/, str)`, `sub(/re/, str)`,
`scan(/re/)`, `split(/re/)`.

**Bigint**: Arbitrary precision integers via mruby-bigint. Auto-promoted
from loop multiplication patterns (e.g. `q = q * k`). Linked as static
library -- only included when used.

**Fiber**: Cooperative concurrency via `ucontext_t`. `Fiber.new`,
`Fiber#resume`, `Fiber.yield` with value passing. Captures free
variables via heap-promoted cells.

**Memory**: Mark-and-sweep GC with size-segregated free lists, non-recursive
marking, and sticky mark bits. Small classes (≤8 scalar fields, no
inheritance, no mutation through parameters) are automatically
stack-allocated as **value types** -- 1M allocations of a 5-field class
drop from 85 ms to 2 ms. Programs using only value types emit no GC
runtime at all.

**Symbols**: Separate `sp_sym` type, distinct from strings (`:a != "a"`).
Symbol literals are interned at compile time (`SPS_name` constants);
`String#to_sym` uses a dynamic pool only when needed. Symbol-keyed
hashes (`{a: 1}`) use a dedicated `sp_SymIntHash` that stores
`sp_sym` (integer) keys directly rather than strings -- no strcmp, no
dynamic string allocation.

**I/O**: `puts`, `print`, `printf`, `p`, `gets`, `ARGV`, `ENV[]`,
`File.read/write/open` (with blocks), `system()`, backtick.

## Optimizations

Whole-program type inference drives several compile-time optimizations:

- **Value-type promotion**: small immutable classes (≤8 scalar fields)
  become C structs on the stack, eliminating GC overhead entirely.
- **Constant propagation**: simple literal constants (`N = 100`) are
  inlined at use sites instead of going through `cst_N` runtime lookup.
- **Loop-invariant length hoisting**: `while i < arr.length` evaluates
  `arr.length` once before the loop; `while i < str.length` hoists
  `strlen`. Mutation of the receiver inside the body (e.g. `arr.push`)
  correctly disables the hoist.
- **Method inlining**: short methods (≤3 statements, non-recursive)
  get `static inline` so gcc can inline them at call sites.
- **String concat chain flattening**: `a + b + c + d` compiles to a
  single `sp_str_concat4` / `sp_str_concat_arr` call -- one malloc
  instead of N-1 intermediate strings.
- **Bigint auto-promotion**: loops with `x = x * y` or fibonacci-style
  `c = a + b` self-referential addition auto-promote to bigint.
- **Bigint `to_s`**: divide-and-conquer O(n log²n) via mruby-bigint's
  `mpz_get_str` instead of naive O(n²).
- **Static symbol interning**: `"literal".to_sym` resolves to a
  compile-time `SPS_<name>` constant; the runtime dynamic pool is
  only emitted when dynamic interning is actually used.
- **`strlen` caching in sub_range**: when a string's length is
  hoisted, `str[i]` accesses use `sp_str_sub_range_len` to skip the
  internal strlen call.
- **split reuse**: `fields = line.split(",")` inside a loop reuses
  the existing `sp_StrArray` rather than allocating a new one.
- **Dead-code elimination**: compiled with `-ffunction-sections
  -fdata-sections` and linked with `--gc-sections`; each unused
  runtime function is stripped from the final binary.

## Architecture

```
spinel                One-command wrapper script (POSIX shell)
spinel_parse.c        C frontend: libprism → text AST (1,061 lines)
spinel_codegen.rb     Compiler backend: AST → C code (20,851 lines)
lib/sp_runtime.h      Runtime library header (581 lines)
lib/sp_bigint.c       Arbitrary precision integers (5,394 lines)
lib/regexp/           Built-in regexp engine (1,626 lines)
test/                 74 feature tests
benchmark/            55 benchmarks
Makefile              Build automation
```

The compiler backend (`spinel_codegen.rb`) is written in a Ruby subset
that Spinel itself can compile: classes, `def`, `attr_accessor`,
`if`/`case`/`while`, `each`/`map`/`select`, `yield`, `begin`/`rescue`,
String/Array/Hash operations, File I/O.

No metaprogramming, no `eval`, no `require` in the backend.

The runtime (`lib/sp_runtime.h`) contains GC, array/hash/string
implementations, and all runtime support as a single header file.
Generated C includes this header, and the linker pulls only the
needed parts from `libspinel_rt.a` (bigint + regexp engine).

The parser has two implementations:
- **spinel_parse.c** links libprism directly (no CRuby needed)
- **spinel_parse.rb** uses the Prism gem (CRuby fallback)

Both produce identical AST output. The `spinel` wrapper prefers the
C binary if available. `require_relative` is resolved at parse time
by inlining the referenced file.

## Building

```bash
make              # build parser + regexp library + bootstrap compiler
make test         # run 74 feature tests (requires bootstrap)
make bench        # run 55 benchmarks (requires bootstrap)
make bootstrap    # rebuild compiler from source
sudo make install # install to /usr/local (spinel in PATH)
make clean        # remove build artifacts
```

Override install prefix: `make install PREFIX=$HOME/.local`

Requires [Prism](https://github.com/ruby/prism) gem installed (for
libprism source). Override with `PRISM_DIR=/path/to/prism`.

CRuby is needed only for the initial bootstrap. After `make`, the
entire pipeline runs without Ruby.

## Limitations

- **No eval**: `eval`, `instance_eval`, `class_eval`
- **No metaprogramming**: `send`, `method_missing`, `define_method` (dynamic)
- **No threads**: `Thread`, `Mutex` (Fiber is supported)
- **No encoding**: assumes UTF-8/ASCII
- **No general lambda calculus**: deeply nested `-> x { }` with `[]` calls

## Dependencies

- **Build time**: [libprism](https://github.com/ruby/prism) (C library),
  CRuby (bootstrap only)
- **Run time**: None. Generated binaries need only libc + libm.
- **Regexp**: Built-in engine, no external library needed.
- **Bigint**: Built-in (from mruby-bigint), linked only when used.

## History

Spinel was originally implemented in C (18K lines, branch `c-version`),
then rewritten in Ruby (branch `ruby-v1`), and finally rewritten in a
self-hosting Ruby subset (current `master`).

## License

MIT License. See [LICENSE](LICENSE).
