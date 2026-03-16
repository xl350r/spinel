#!/usr/bin/env ruby
# frozen_string_literal: true

# extract_rbs.rb - Extract type signatures from ruby/rbs core definitions
#
# Reads RBS core type definitions and produces a JSON type database
# filtered to classes/methods that exist in mruby.
#
# Usage:
#   ruby extract_rbs.rb --rbs-dir=path/to/ruby/rbs/core --output=type_db/core.json
#   ruby extract_rbs.rb --rbs-dir=path/to/ruby/rbs/core --mruby-classes=method_map.json --output=type_db/core.json

require "json"
require "optparse"

begin
  require "rbs"
rescue LoadError
  $stderr.puts "ERROR: rbs gem required. Install with: gem install rbs"
  exit 1
end

module Spinel
  class RBSExtractor
    # mruby core classes (default set when no method_map is provided)
    MRUBY_CORE_CLASSES = %w[
      BasicObject Object Module Class
      NilClass TrueClass FalseClass
      Numeric Integer Float
      String Symbol
      Array Hash Range
      Regexp MatchData
      Proc Method UnboundMethod
      Enumerator
      Comparable Enumerable Kernel
      IO
      Exception StandardError RuntimeError TypeError ArgumentError
      NameError NoMethodError IndexError KeyError RangeError
      StopIteration
      IOError
      Struct
      Time
      Random
      Fiber
      GC
      ObjectSpace
    ].freeze

    # CRuby-only classes to always exclude (not in mruby)
    CRUBY_ONLY_CLASSES = %w[
      Socket TCPSocket TCPServer UDPSocket UNIXSocket UNIXServer
      Addrinfo
      Process
      Signal
      Thread Mutex ConditionVariable Queue SizedQueue
      TracePoint
      Ractor
      Dir
      Encoding
      Complex Rational
      Set
      Data
      Refinement
      RubyVM
    ].freeze

    def initialize(rbs_dir:, mruby_classes: nil, output:)
      @rbs_dir = rbs_dir
      @output = output
      @mruby_classes = mruby_classes
      @type_db = {}
    end

    def run
      validate_rbs_dir!
      allowed = load_allowed_classes

      loader = RBS::EnvironmentLoader.new
      loader.add(path: Pathname(@rbs_dir))
      env = RBS::Environment.from_loader(loader).resolve_type_names

      env.class_decls.each do |type_name, entry|
        class_name = type_name.to_s.delete_prefix("::")
        next unless allowed.include?(class_name)
        next if CRUBY_ONLY_CLASSES.include?(class_name)

        @type_db[class_name] = extract_class(entry, env)
      end

      write_output
      report_stats
    end

    private

    def validate_rbs_dir!
      unless File.directory?(@rbs_dir)
        $stderr.puts "ERROR: RBS directory not found: #{@rbs_dir}"
        exit 1
      end
    end

    def load_allowed_classes
      if @mruby_classes
        data = JSON.parse(File.read(@mruby_classes))
        Set.new(data.keys)
      else
        Set.new(MRUBY_CORE_CLASSES)
      end
    end

    def extract_class(entry, env)
      result = {
        "instance_methods" => {},
        "class_methods" => {},
        "type_params" => []
      }

      entry.decls.each do |d|
        decl = d.decl

        # Extract type parameters
        if decl.respond_to?(:type_params)
          decl.type_params.each do |tp|
            result["type_params"] << tp.name.to_s
          end
        end

        decl.members.each do |member|
          case member
          when RBS::AST::Members::MethodDefinition
            method_info = extract_method(member)
            target = member.singleton? ? "class_methods" : "instance_methods"
            result[target][member.name.to_s] = method_info
          end
        end
      end

      # Remove empty sections
      result.delete("type_params") if result["type_params"].empty?
      result.delete("class_methods") if result["class_methods"].empty?

      result
    end

    def extract_method(member)
      overloads = member.overloads.map do |overload|
        extract_overload(overload)
      end

      { "overloads" => overloads }
    end

    def extract_overload(overload)
      method_type = overload.method_type
      result = {}

      # Parameters
      params = extract_params(method_type.type)
      result["params"] = params unless params.empty?

      # Block
      if method_type.block
        block_info = extract_block(method_type.block)
        result["block"] = block_info
      end

      # Return type
      result["return"] = type_to_s(method_type.type.return_type)

      result
    end

    def extract_params(func_type)
      params = []

      func_type.required_positionals.each do |p|
        params << { "name" => p.name&.to_s || "_", "type" => type_to_s(p.type), "required" => true }
      end

      func_type.optional_positionals.each do |p|
        params << { "name" => p.name&.to_s || "_", "type" => type_to_s(p.type), "optional" => true }
      end

      if func_type.rest_positionals
        p = func_type.rest_positionals
        params << { "name" => p.name&.to_s || "_", "type" => type_to_s(p.type), "rest" => true }
      end

      params
    end

    def extract_block(block)
      result = {}
      if block.type.respond_to?(:type)
        func = block.type.type
        params = func.required_positionals.map { |p| type_to_s(p.type) }
        result["params"] = params unless params.empty?
        result["return"] = type_to_s(func.return_type)
      end
      result
    end

    def type_to_s(type)
      case type
      when RBS::Types::ClassInstance
        name = type.name.to_s.delete_prefix("::")
        if type.args.empty?
          name
        else
          "#{name}[#{type.args.map { |a| type_to_s(a) }.join(", ")}]"
        end
      when RBS::Types::Union
        type.types.map { |t| type_to_s(t) }.join(" | ")
      when RBS::Types::Intersection
        type.types.map { |t| type_to_s(t) }.join(" & ")
      when RBS::Types::Optional
        "#{type_to_s(type.type)} | nil"
      when RBS::Types::Bases::Self
        "self"
      when RBS::Types::Bases::Void
        "void"
      when RBS::Types::Bases::Any
        "untyped"
      when RBS::Types::Bases::Nil
        "nil"
      when RBS::Types::Bases::Bool
        "bool"
      when RBS::Types::Bases::Instance
        "instance"
      when RBS::Types::Bases::Class
        "class"
      when RBS::Types::Bases::Top
        "top"
      when RBS::Types::Bases::Bottom
        "bot"
      when RBS::Types::Tuple
        "[#{type.types.map { |t| type_to_s(t) }.join(", ")}]"
      when RBS::Types::Variable
        type.name.to_s
      when RBS::Types::Literal
        type.literal.inspect
      when RBS::Types::Proc
        "Proc"
      when RBS::Types::Alias
        type.name.to_s.delete_prefix("::")
      else
        type.to_s
      end
    end

    def write_output
      File.write(@output, JSON.pretty_generate(@type_db))
      puts "Wrote type database to #{@output}"
    end

    def report_stats
      total_classes = @type_db.size
      total_methods = @type_db.sum { |_, v| v["instance_methods"].size + (v["class_methods"]&.size || 0) }
      total_overloads = @type_db.sum do |_, v|
        (v["instance_methods"].values + (v["class_methods"]&.values || [])).sum do |m|
          m["overloads"].size
        end
      end

      puts "Classes: #{total_classes}"
      puts "Methods: #{total_methods}"
      puts "Overloads: #{total_overloads}"
    end
  end
end

if __FILE__ == $0
  options = {}

  OptionParser.new do |opts|
    opts.banner = "Usage: extract_rbs.rb [options]"

    opts.on("--rbs-dir=DIR", "Path to ruby/rbs core directory") do |v|
      options[:rbs_dir] = v
    end

    opts.on("--mruby-classes=FILE", "Path to method_map.json (optional, for filtering)") do |v|
      options[:mruby_classes] = v
    end

    opts.on("--output=FILE", "Output JSON file path") do |v|
      options[:output] = v
    end
  end.parse!

  unless options[:rbs_dir] && options[:output]
    $stderr.puts "ERROR: --rbs-dir and --output are required"
    exit 1
  end

  extractor = Spinel::RBSExtractor.new(**options)
  extractor.run
end
