# Spinel v2: Ruby Subset Self-Hosting Compiler

## Goal

Rewrite the Spinel AOT compiler in a Ruby subset that Spinel itself can
compile. The compiler takes Ruby source, parses it with Prism, infers
types, and generates standalone C code.

## Architecture

```
Ruby Source (.rb)
    |
    v
[Prism Frontend]        -- CRuby + Prism gem (thin wrapper)
    |                       Parses Ruby, serializes AST to text format
    v
AST Text File (.ast)
    |
    v
[Spinel Backend]         -- Written in Spinel-compilable Ruby subset
    |                       Reads AST, infers types, generates C
    v
C Source (.c)
    |
    v
cc -O2 -lm              -- Native C compiler
    |
    v
Native Binary
```

Two executables:
- `spinel-parse`: CRuby script (~700 lines), requires Prism. Outputs .ast file.
- `spinel-codegen`: Written in Ruby subset. Can run under CRuby OR as
  compiled native binary. Reads .ast, writes .c.

One-command wrapper for convenience:
```bash
spinel input.rb -o output.c
# equivalent to:
spinel-parse input.rb > /tmp/ast && spinel-codegen /tmp/ast output.c
```

## Ruby Subset ("Spinel Ruby")

The compiler is written using ONLY these Ruby features:

### Allowed
- `class`, `def`, `attr_accessor`, `attr_reader`
- `if`/`elsif`/`else`, `unless`, `case`/`when`, `while`, `until`
- `return`, `break`, `next`
- `begin`/`rescue`/`ensure`
- `yield`, `block_given?`, blocks with `do..end` or `{..}`
- Integer, Float, String (immutable `const char *`)
- Mutable string via `"".dup` + `<<`
- Array (homogeneous: Integer or String element)
- Hash (string keys, integer or string values)
- `puts`, `print`, `$stderr.puts`
- `File.read`, `File.write`
- `ARGV`, `ARGV.length`, `ARGV[i]`
- String methods: `length`, `+`, `==`, `!=`, `include?`, `start_with?`,
  `end_with?`, `index`, `split`, `gsub`, `sub`, `strip`, `chomp`,
  `to_i`, `to_f`, `[]`, `upcase`, `downcase`
- Integer methods: `+`, `-`, `*`, `/`, `%`, `==`, `<`, `>`, `to_s`
- Array methods: `push`, `pop`, `length`, `[]`, `[]=`, `include?`,
  `each`, `empty?`
- Hash methods: `[]`, `[]=`, `has_key?`, `length`, `each`, `delete`
- `nil` comparisons: `x == nil`, `x != nil`
- Constants: `FOO = value`
- String interpolation: `"hello #{x}"`

### NOT Allowed
- `require` (except in parse frontend)
- `Struct.new`, `OpenStruct`
- `method_missing`, `respond_to_missing?`, `define_method`
- `eval`, `instance_eval`, `class_eval`, `send`
- `Symbol` literals (use strings: `"name"` not `:name`)
- `||=` (use explicit nil check)
- `lambda`, `->`, `proc {}`, `Proc.new`
- `Set`, `Comparable`, `Enumerable`
- `map`, `select`, `reject`, `reduce` (use `while` loops)
- `&:method` shorthand
- `.last`, `.first` (use `arr[arr.length - 1]`, `arr[0]`)
- Monkey patching, open classes on built-in types
- Multiple return values
- Splat args `*args`
- `freeze`, `frozen?`
- Regular expressions (in backend; parse frontend handles regex patterns)

### Rationale

Every feature in this subset has a direct, efficient C translation:
- `class` → C struct + functions
- `Array` → `sp_IntArray` or `sp_StrArray`
- `Hash` → `sp_StrIntHash` or `sp_StrStrHash`
- `while` → C `while`
- `yield` → function pointer callback
- `String` → `const char *`

No dynamic dispatch, no metaprogramming, no closures needed.

## AST Text Format

Line-based, parseable with `split` and `to_i`:

```
ROOT 0
N 0 ProgramNode
N 1 StatementsNode
N 2 CallNode
S 2 name puts
I 2 flags 0
R 2 receiver -1
R 2 arguments 3
N 3 ArgumentsNode
A 3 arguments 4
N 4 IntegerNode
I 4 value 42
A 1 body 2
R 0 statements 1
```

Line types:
- `ROOT id` — root node ID
- `N id TypeName` — declare node
- `S id field value` — string field (percent-encoded)
- `I id field value` — integer field
- `F id field value` — float field
- `R id field ref_id` — node reference (-1 = nil)
- `A id field id1,id2,...` — array of node references

## AST Node Class

Single class with all possible fields:

```ruby
class Node
  attr_accessor :type      # String: "CallNode" etc
  attr_accessor :name      # String
  attr_accessor :value     # Integer or Float
  attr_accessor :content   # String (for StringNode)
  attr_accessor :receiver  # Node or nil
  attr_accessor :arguments # Node or nil (ArgumentsNode wrapper)
  attr_accessor :body      # Node or nil
  attr_accessor :stmts     # Array of Node (for StatementsNode.body)
  attr_accessor :args      # Array of Node (for ArgumentsNode.arguments)
  attr_accessor :block     # Node or nil
  attr_accessor :parameters # Node or nil
  attr_accessor :predicate # Node or nil
  attr_accessor :conditions # Array of Node
  attr_accessor :subsequent # Node or nil
  attr_accessor :else_clause # Node or nil
  attr_accessor :left      # Node or nil
  attr_accessor :right     # Node or nil
  attr_accessor :elements  # Array of Node
  attr_accessor :parts     # Array of Node
  attr_accessor :constant_path # Node or nil
  attr_accessor :superclass # Node or nil
  attr_accessor :requireds # Array of Node
  attr_accessor :optionals # Array of Node
  attr_accessor :keywords  # Array of Node
  attr_accessor :rest      # Node or nil
  attr_accessor :exceptions # Array of Node
  attr_accessor :rescue_clause # Node or nil
  attr_accessor :ensure_clause # Node or nil
  attr_accessor :expression # Node or nil
  attr_accessor :target    # Node or nil
  attr_accessor :targets   # Array of Node
  attr_accessor :pattern   # Node or nil
  attr_accessor :key       # Node or nil
  attr_accessor :reference # Node or nil
  attr_accessor :flags     # Integer
  attr_accessor :depth     # Integer
  attr_accessor :operator  # String
  attr_accessor :binary_operator # String
  attr_accessor :call_operator # String
  attr_accessor :unescaped # String
  attr_accessor :collection # Node or nil

  def initialize
    @type = ""
    @name = ""
    @value = 0
    @content = ""
    @flags = 0
    @depth = 0
    @operator = ""
    @binary_operator = ""
    @call_operator = ""
    @unescaped = ""
  end
end
```

Note: Node-typed fields are initialized to nil by default in the
initializer (Spinel infers their type from external setter calls).
Array-typed fields are initialized to empty arrays `[]` when first
needed. This means Spinel needs to track that `node.receiver = x`
(where x is a Node) implies receiver's type is Node*.

## Compiler Data Structures

All written as regular classes with attr_accessor:

```ruby
class VarInfo
  attr_accessor :name, :type, :c_name, :declared
end

class ParamInfo
  attr_accessor :name, :type, :default_node
end

class MethodInfo
  attr_accessor :name, :params, :return_type, :body_node
  attr_accessor :has_yield, :is_class_method
end

class ClassInfo
  attr_accessor :name, :parent_name
  attr_accessor :ivar_names, :ivar_types   # parallel arrays
  attr_accessor :method_names, :method_infos # parallel arrays
  attr_accessor :attr_readers, :attr_writers, :attr_accessors
  attr_accessor :includes  # array of module names
end
```

Key design: **NO hash-of-objects**. Use parallel arrays:
- `@class_names` + `@class_infos` instead of `@classes = {}`
- `method_names` + `method_infos` instead of `methods = {}`
- Lookup: `find_class(name)` scans `@class_names` array

This avoids Spinel's type inference problem with Hash values being
`mrb_int` when they should be object pointers.

## Compiler Structure

```
spinel_codegen.rb
├── Node (AST node)
├── VarInfo, ParamInfo, MethodInfo, ClassInfo
├── Type module (constants: INTEGER, FLOAT, STRING, ...)
├── AstReader
│   └── read_text_ast(data) → Node
├── TypeInferrer
│   ├── infer(node) → type string
│   └── resolve_class_types()
├── ClassAnalyzer
│   ├── collect_classes(root)
│   ├── collect_methods(root)
│   └── collect_ivars()
├── CodeEmitter
│   ├── emit_header()
│   ├── emit_struct(class_info)
│   ├── emit_method(class_info, method_info)
│   └── emit_runtime_helpers()
├── ExprCompiler
│   └── compile(node) → string (C expression)
├── StmtCompiler
│   └── compile(node) (emits C statements)
└── main
    ├── read AST from file
    ├── analyze classes
    ├── infer types
    ├── generate C
    └── write output
```

## Implementation Phases

### Phase 1: Skeleton + fib (Day 1)
- Node class, AstReader (text format)
- ExprCompiler: IntegerNode, CallNode (+, -, <), LocalVariableReadNode
- StmtCompiler: LocalVariableWriteNode, IfNode, ReturnNode
- Top-level def: DefNode with parameters
- puts with integer
- Test: fib(34) = 5702887
- Self-compile test: compile spinel_codegen.rb → C → binary

### Phase 2: Strings + control flow (Day 2)
- StringNode, InterpolatedStringNode, SymbolNode
- String methods: length, +, ==, include?, split, gsub, to_i
- case/when (with strcmp for strings)
- while, unless, for..in
- break, next
- Constants
- Tests: bm_strings, bm_case, bm_control

### Phase 3: Classes + OOP (Day 3)
- ClassNode with constructor, instance variables
- attr_accessor/reader/writer
- Inheritance, super
- Type inference for class instances
- Class method calls: obj.method(args)
- Tests: bm_inherit, bm_attr, bm_comparable

### Phase 4: Arrays + Hashes (Day 4)
- Array literals, push, pop, [], []=, length, each
- Hash literals, [], []=, has_key?, each, delete
- Type inference for collections
- for..in with arrays
- Integer#times, upto, downto
- Tests: bm_array2, bm_hash, bm_sort_reduce

### Phase 5: Blocks + yield (Day 5)
- yield, block_given?
- Block parameter passing (function pointer + env)
- Array#each, map, select with block
- Tests: bm_yield, bm_block2, bm_enumerable

### Phase 6: Exceptions + I/O (Day 6)
- begin/rescue/ensure, raise
- File.read, File.write, File.exist?
- ARGV processing
- system(), backtick
- Tests: bm_rescue, bm_fileio, bm_system

### Phase 7: Advanced features (Day 7)
- Mutable strings (sp_String)
- Struct.new
- Pattern matching (case/in)
- catch/throw
- Regular expressions (via runtime)
- Tests: bm_struct, bm_pattern, bm_mutable_str

### Phase 8: Polymorphism (Day 8)
- NaN-boxed values for mixed-type variables
- 3-tier dispatch (mono/bi/mega)
- Heterogeneous arrays and hashes
- Tests: bm_poly, bm_mega, bm_poly_hash

### Phase 9: Self-hosting (Day 9)
- Compile spinel_codegen.rb with itself
- Fix type inference issues iteratively
- Verify: self-compiled binary produces identical output
- Performance comparison with CRuby-compiled binary

### Phase 10: Polish (Day 10)
- Benchmark all 39 programs
- Fix remaining edge cases
- Performance optimization (conditional emission)
- README and documentation

## Key Design Decisions

### Parallel arrays instead of Hash-of-objects
```ruby
# NOT this (Spinel can't type-infer Hash values):
@classes = {}  # string → ClassInfo

# THIS:
@class_names = []   # Array of String
@class_infos = []   # Array of ClassInfo

def find_class(name)
  i = 0
  while i < @class_names.length
    if @class_names[i] == name
      return @class_infos[i]
    end
    i = i + 1
  end
  nil
end
```

### No iterators, use while loops
```ruby
# NOT this:
arr.each { |x| puts x }
arr.map { |x| x * 2 }

# THIS:
i = 0
while i < arr.length
  puts arr[i]
  i = i + 1
end
```

Exception: `yield` blocks ARE supported for user-defined iterators,
since the compiler emits them as C function pointers.

### Explicit nil checks instead of ||=
```ruby
# NOT this:
@foo ||= []

# THIS:
if @foo == nil
  @foo = []
end
```

### String keys only in Hash
```ruby
# NOT this:
{name: "Alice", age: 30}

# THIS:
h = {}
h["name"] = "Alice"  # But value must be same type!
```

Actually for mixed-value hashes, use parallel arrays:
```ruby
@const_names = []
@const_types = []
@const_values = []
```

### Output buffering with StringIO
Spinel supports StringIO as built-in type:
```ruby
out = StringIO.new
out.puts "line 1"
out.puts "line 2"
result = out.string
```

### Node type dispatch with case/when
```ruby
case node.type
when "IntegerNode"
  node.value.to_s
when "CallNode"
  compile_call(node)
when "StringNode"
  c_string_literal(node.content)
end
```

## File Layout

```
spinel-v2/
├── spinel_parse.rb     # CRuby frontend (Prism → AST text)
├── spinel_codegen.rb   # Compiler backend (Spinel Ruby subset)
├── test/               # Test programs
├── benchmark/          # Benchmark programs
└── PLAN.md             # This file
```

## Success Criteria

1. All 59 tests produce identical output
2. All 38+ benchmarks produce correct output
3. spinel_codegen.rb compiles with Spinel (0 C errors)
4. Self-compiled binary produces identical output to CRuby-run version
5. Performance within 2x of C version on all benchmarks
6. Total code < 8,000 lines of Ruby
