# Spinel AOT Compiler — Step 0 Prototype

Prototype tools for the Spinel AOT compiler pipeline. These tools demonstrate
the end-to-end flow: LumiTrace type profiling -> RBS type extraction -> trace
format conversion -> integration analysis.

## Overview

```
Ruby Source
    |
    v
CRuby + LumiTrace          ruby/rbs core defs       mruby source
(--collect-mode types)      |                        |
    |                       v                        v
    v                  extract_rbs.rb          scan_mruby_methods.rb
lumitrace output            |                        |
    |                       v                        v
    v                  type_db.json            method_map.json
convert_lumitrace.rb        |                        |
    |                       +------------------------+
    v                       |
trace.json                  v
    |               coverage_report.rb
    |                       |
    +-------+---------------+
            |
            v
     merge_trace_rbs.rb
            |
            v
     Analysis report
     (PROVEN / LIKELY / UNRESOLVED per call site)
```

## Prerequisites

- CRuby 3.2+
- `gem install rbs` (for extract_rbs.rb)
- LumiTrace gem v0.7.0+ (for trace collection): `gem install lumitrace`

## Quick Start

### 1. Collect type traces with LumiTrace

```bash
# Trace a Ruby program
lumitrace --collect-mode types -j --json trace_raw.json app.rb

# Or trace a test suite
lumitrace --collect-mode types -j --json trace_raw.json exec rake test

# Key environment variables:
#   LUMITRACE_MAX_SAMPLES=10000   -- higher sample limit for AOT accuracy
#   LUMITRACE_ROOT=./lib          -- scope to application code
```

### 2. Extract RBS type signatures

```bash
ruby tools/extract_rbs.rb \
  --rbs-dir=/path/to/ruby/rbs/core \
  --output=output/type_db.json
```

### 3. Scan mruby methods

```bash
ruby tools/scan_mruby_methods.rb \
  --mruby-dir=/path/to/mruby \
  --output=output/method_map.json
```

### 4. Convert LumiTrace output to Spinel format

```bash
ruby tools/convert_lumitrace.rb \
  --input=trace_raw.json \
  --mruby-classes=output/method_map.json \
  --output=output/trace.json
```

### 5. Measure RBS coverage

```bash
ruby tools/coverage_report.rb \
  --type-db=output/type_db.json \
  --method-map=output/method_map.json
```

### 6. Run integration analysis

```bash
ruby tools/merge_trace_rbs.rb \
  --trace=output/trace.json \
  --type-db=output/type_db.json \
  --method-map=output/method_map.json \
  --output=output/analysis.json
```

## Tools

### extract_rbs.rb

Reads RBS core type definitions and produces a JSON type database filtered to
mruby-compatible classes. Handles overloads, generics, and block parameters.

### scan_mruby_methods.rb

Scans mruby C source for `mrb_define_method` / `mrb_define_class_method` calls
and builds a Ruby name -> C function name mapping.

### convert_lumitrace.rb

Converts LumiTrace's per-expression type distributions into the Spinel
call-site trace format. Filters out CRuby-only types and normalizes paths.

### merge_trace_rbs.rb

Integration demo. Merges trace data with RBS type info to classify each call
site as PROVEN / LIKELY / UNRESOLVED, then computes the reachable method set
and reports potential binary size reduction.

### coverage_report.rb

Measures what percentage of mruby's core methods have RBS type signatures,
identifying gaps that may need manual annotation or fallback handling.

## Output Format

### Spinel Trace Format (trace.json)

```json
{
  "version": 1,
  "source_hash": "sha256:...",
  "call_sites": {
    "app.rb:10:5": {
      "method": "+",
      "receiver_types": { "Integer": 9950, "Float": 50 },
      "arg_types": [{ "Integer": 9800, "Float": 200 }],
      "return_types": { "Integer": 9900, "Float": 100 },
      "total_calls": 10000
    }
  }
}
```

### Resolution Levels

| Level | Meaning | Code Generation |
|-------|---------|-----------------|
| PROVEN | CHA-proven monomorphic | Guard-free direct call |
| LIKELY | Monomorphic or polymorphic (2-4 types) | Type guard + fast path + fallback |
| UNRESOLVED | Unknown or megamorphic | Full mruby dispatch (mrb_funcall) |

## Sample Output Files

The `output/` directory contains sample files for demonstration:

- `type_db.json` — Sample RBS type database (Integer, String, Array, etc.)
- `method_map.json` — Sample mruby method mapping
- `trace.json` — Sample Spinel trace data

## Validation Criteria

- [ ] LumiTrace types mode produces stable type distributions for test programs
- [ ] CallNode expressions give usable receiver/return type info
- [ ] RBS coverage of mruby core methods measured
- [ ] Integration demo shows meaningful reachable/unreachable split
- [ ] CRuby-only types (Complex, Thread, Socket, etc.) correctly filtered out
