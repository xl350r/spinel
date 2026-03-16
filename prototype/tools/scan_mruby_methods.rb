#!/usr/bin/env ruby
# frozen_string_literal: true

# scan_mruby_methods.rb - Scan mruby source to build Ruby name -> C function mapping
#
# Scans mruby's C source files for mrb_define_method, mrb_define_class_method,
# mrb_define_module_function, and mrb_define_class calls to produce a mapping
# from Ruby names to C function names.
#
# Usage:
#   ruby scan_mruby_methods.rb --mruby-dir=path/to/mruby --output=method_map.json

require "json"
require "optparse"

module Spinel
  class MRubyMethodScanner
    # Patterns to match mrb_define_* calls in C source
    # These handle multi-line calls by reading ahead
    DEFINE_PATTERNS = {
      instance_method: /\bmrb_define_method\s*\(\s*mrb\s*,\s*(\w+)\s*,\s*"([^"]+)"\s*,\s*(\w+)\s*,\s*(MRB_ARGS_\w+\([^)]*\))/,
      class_method: /\bmrb_define_class_method\s*\(\s*mrb\s*,\s*(\w+)\s*,\s*"([^"]+)"\s*,\s*(\w+)\s*,\s*(MRB_ARGS_\w+\([^)]*\))/,
      module_function: /\bmrb_define_module_function\s*\(\s*mrb\s*,\s*(\w+)\s*,\s*"([^"]+)"\s*,\s*(\w+)\s*,\s*(MRB_ARGS_\w+\([^)]*\))/,
    }.freeze

    DEFINE_CLASS_PATTERN = /\bmrb_define_class\s*\(\s*mrb\s*,\s*"([^"]+)"\s*,\s*(\w+)/
    DEFINE_MODULE_PATTERN = /\bmrb_define_module\s*\(\s*mrb\s*,\s*"([^"]+)"/

    # Pattern to resolve local variable assignments like:
    #   struct RClass *str = mrb_define_class(mrb, "String", mrb->object_class);
    CLASS_VAR_PATTERN = /\b(?:struct\s+RClass\s*\*|mrb_class\s*)\s*(\w+)\s*=\s*mrb_define_(?:class|module)\s*\(\s*mrb\s*,\s*"([^"]+)"/

    def initialize(mruby_dir:, output:)
      @mruby_dir = mruby_dir
      @output = output
      @method_map = {}
      @class_vars = {} # variable name -> Ruby class name (per file)
    end

    def run
      validate_mruby_dir!
      scan_source_files
      write_output
      report_stats
    end

    private

    def validate_mruby_dir!
      unless File.directory?(@mruby_dir)
        $stderr.puts "ERROR: mruby directory not found: #{@mruby_dir}"
        exit 1
      end
    end

    def source_files
      patterns = [
        File.join(@mruby_dir, "src", "*.c"),
        File.join(@mruby_dir, "mrbgems", "*", "src", "*.c"),
        File.join(@mruby_dir, "mrbgems", "*", "core", "*.c"),
      ]
      patterns.flat_map { |p| Dir.glob(p) }.sort
    end

    def scan_source_files
      source_files.each do |file|
        scan_file(file)
      end
    end

    def scan_file(file)
      content = File.read(file)
      relative = file.sub("#{@mruby_dir}/", "")

      # First pass: resolve class variable names
      file_class_vars = {}
      content.scan(CLASS_VAR_PATTERN) do |var_name, class_name|
        file_class_vars[var_name] = class_name
      end

      # Also handle common patterns like mrb->object_class, mrb->string_class
      # These are well-known mruby globals
      builtin_vars = {
        "mrb->object_class" => "Object",
        "mrb->class_class" => "Class",
        "mrb->module_class" => "Module",
        "mrb->string_class" => "String",
        "mrb->array_class" => "Array",
        "mrb->hash_class" => "Hash",
        "mrb->range_class" => "Range",
        "mrb->float_class" => "Float",
        "mrb->fixnum_class" => "Integer",
        "mrb->true_class" => "TrueClass",
        "mrb->false_class" => "FalseClass",
        "mrb->nil_class" => "NilClass",
        "mrb->symbol_class" => "Symbol",
        "mrb->kernel_module" => "Kernel",
        "mrb->exc_class" => "Exception",
      }

      # Scan for method definitions
      DEFINE_PATTERNS.each do |kind, pattern|
        content.scan(pattern) do |class_var, ruby_name, c_func, args_macro|
          class_name = file_class_vars[class_var] || builtin_vars[class_var] || resolve_class_name(class_var)
          next unless class_name

          @method_map[class_name] ||= { "instance_methods" => {}, "class_methods" => {} }

          line_num = content[0...($~.begin(0))].count("\n") + 1

          entry = {
            "c_func" => c_func,
            "file" => relative,
            "line" => line_num,
            "args" => args_macro,
          }

          case kind
          when :instance_method
            @method_map[class_name]["instance_methods"][ruby_name] = entry
          when :class_method, :module_function
            @method_map[class_name]["class_methods"][ruby_name] = entry
          end
        end
      end
    end

    # Try to resolve a class variable name to a Ruby class name using common patterns
    def resolve_class_name(var_name)
      # Common mruby naming: str -> String, ary -> Array, etc.
      known_abbrevs = {
        "str" => "String", "string" => "String",
        "ary" => "Array", "array" => "Array",
        "hsh" => "Hash", "hash" => "Hash",
        "num" => "Numeric", "numeric" => "Numeric",
        "int" => "Integer", "integer" => "Integer", "fixnum" => "Integer",
        "flt" => "Float", "float" => "Float",
        "sym" => "Symbol", "symbol" => "Symbol",
        "rng" => "Range", "range" => "Range",
        "re" => "Regexp", "regexp" => "Regexp",
        "exc" => "Exception", "exception" => "Exception",
        "obj" => "Object", "object" => "Object",
        "mod" => "Module", "module" => "Module",
        "cls" => "Class",
        "io" => "IO",
        "proc" => "Proc",
        "fiber" => "Fiber",
        "enum" => "Enumerator",
        "time" => "Time",
        "struct" => "Struct",
        "random" => "Random",
        "comparable" => "Comparable",
        "enumerable" => "Enumerable",
        "kernel" => "Kernel",
        "gc" => "GC",
        "mat" => "MatchData",
      }
      known_abbrevs[var_name.downcase]
    end

    def write_output
      File.write(@output, JSON.pretty_generate(@method_map))
      puts "Wrote method map to #{@output}"
    end

    def report_stats
      total_classes = @method_map.size
      total_instance = @method_map.sum { |_, v| v["instance_methods"].size }
      total_class = @method_map.sum { |_, v| v["class_methods"].size }

      puts "Classes: #{total_classes}"
      puts "Instance methods: #{total_instance}"
      puts "Class methods: #{total_class}"
      puts "Total: #{total_instance + total_class}"
    end
  end
end

if __FILE__ == $0
  options = {}

  OptionParser.new do |opts|
    opts.banner = "Usage: scan_mruby_methods.rb [options]"

    opts.on("--mruby-dir=DIR", "Path to mruby source directory") do |v|
      options[:mruby_dir] = v
    end

    opts.on("--output=FILE", "Output JSON file path") do |v|
      options[:output] = v
    end
  end.parse!

  unless options[:mruby_dir] && options[:output]
    $stderr.puts "ERROR: --mruby-dir and --output are required"
    exit 1
  end

  scanner = Spinel::MRubyMethodScanner.new(**options)
  scanner.run
end
