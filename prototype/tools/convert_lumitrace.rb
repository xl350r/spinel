#!/usr/bin/env ruby
# frozen_string_literal: true

# convert_lumitrace.rb - Convert LumiTrace JSON output to Spinel trace format
#
# LumiTrace's --collect-mode=types produces per-expression type distributions.
# This tool filters and transforms that data into the Spinel call-site trace
# format expected by the downstream AOT pipeline.
#
# LumiTrace output format (per entry):
#   {
#     "file": "/path/app.rb",
#     "start_line": 10, "start_col": 2, "end_line": 10, "end_col": 9,
#     "kind": "expr",
#     "types": { "Integer": 9950, "Float": 50 },
#     "total": 10000
#   }
#
# Spinel trace format (output):
#   {
#     "version": 1,
#     "source_hash": "sha256:...",
#     "call_sites": {
#       "app.rb:10:5": {
#         "method": "+",
#         "receiver_types": { "Integer": 9950 },
#         "arg_types": [{ "Integer": 9800 }],
#         "return_types": { "Integer": 9900 },
#         "total_calls": 10000
#       }
#     }
#   }
#
# Usage:
#   ruby convert_lumitrace.rb --input=trace_raw.json --output=trace.json
#   ruby convert_lumitrace.rb --input=trace_raw.json --mruby-classes=method_map.json --output=trace.json

require "json"
require "optparse"
require "digest"

module Spinel
  class LumiTraceConverter
    # CRuby-only types that don't exist in mruby
    CRUBY_ONLY_TYPES = Set.new(%w[
      Complex Rational
      Encoding
      Thread Mutex ConditionVariable Queue SizedQueue
      Ractor
      Socket TCPSocket TCPServer UDPSocket UNIXSocket
      Set
      Data
      Refinement
      Dir
      TracePoint
      RubyVM
      Process::Status
    ]).freeze

    def initialize(input:, output:, mruby_classes: nil, source_root: nil)
      @input = input
      @output = output
      @mruby_classes = mruby_classes
      @source_root = source_root
      @allowed_classes = nil
    end

    def run
      validate_input!
      load_allowed_classes
      raw_entries = load_lumitrace_data
      call_sites = build_call_sites(raw_entries)
      write_output(call_sites)
      report_stats(raw_entries, call_sites)
    end

    private

    def validate_input!
      unless File.exist?(@input)
        $stderr.puts "ERROR: Input file not found: #{@input}"
        exit 1
      end
    end

    def load_allowed_classes
      if @mruby_classes
        data = JSON.parse(File.read(@mruby_classes))
        @allowed_classes = Set.new(data.keys)
      end
    end

    def load_lumitrace_data
      content = File.read(@input)
      data = JSON.parse(content)

      # LumiTrace may output as array or as object with "entries" key
      entries = case data
                when Array then data
                when Hash then data["entries"] || data["traces"] || []
                else []
                end

      entries
    end

    # Build call sites from LumiTrace entries.
    #
    # LumiTrace traces expression *results*, not call-site info directly.
    # We reconstruct call-site information by:
    # 1. Finding entries that correspond to method call expressions
    # 2. Using the entry's type distribution as the return type
    # 3. Looking for nearby variable-read entries for receiver types
    #
    # For a call like `x.foo(y)`, LumiTrace records:
    #   - The type of `x` (variable read) -> receiver type
    #   - The type of `x.foo(y)` (call result) -> return type
    #   - The type of `y` (variable read or expression) -> argument type
    def build_call_sites(entries)
      call_sites = {}

      # Index entries by location for cross-referencing
      location_index = {}
      entries.each do |entry|
        key = location_key(entry)
        location_index[key] = entry
      end

      entries.each do |entry|
        next unless call_expression?(entry)

        site_key = format_site_key(entry)
        next unless site_key

        types = filter_types(entry["types"] || {})
        next if types.empty?

        total = entry["total"] || types.values.sum

        # The entry's types represent the return type of the call
        call_site = {
          "method" => extract_method_name(entry),
          "receiver_types" => extract_receiver_types(entry, location_index),
          "return_types" => types,
          "total_calls" => total,
        }

        # Extract argument types if available
        arg_types = extract_arg_types(entry, location_index)
        call_site["arg_types"] = arg_types unless arg_types.empty?

        call_sites[site_key] = call_site
      end

      call_sites
    end

    def call_expression?(entry)
      # LumiTrace marks entries with "kind"
      # We look for call-like expressions
      kind = entry["kind"]
      return true if kind == "call" || kind == "send"

      # For "expr" kind, check if it looks like a method call
      # (has method_name or node_type indicating a call)
      if kind == "expr"
        return true if entry["node_type"] == "CallNode" ||
                       entry["node_type"] == "call_node" ||
                       entry["method_name"]
      end

      false
    end

    def location_key(entry)
      file = normalize_path(entry["file"] || "")
      "#{file}:#{entry["start_line"]}:#{entry["start_col"]}"
    end

    def format_site_key(entry)
      file = normalize_path(entry["file"] || "")
      return nil if file.empty?

      line = entry["start_line"]
      col = entry["start_col"]
      return nil unless line && col

      "#{file}:#{line}:#{col}"
    end

    def normalize_path(path)
      if @source_root && path.start_with?(@source_root)
        path.sub("#{@source_root}/", "")
      elsif path.start_with?("/")
        # Keep relative if possible
        File.basename(path)
      else
        path
      end
    end

    def extract_method_name(entry)
      entry["method_name"] || entry["method"] || entry["name"] || "unknown"
    end

    def extract_receiver_types(entry, location_index)
      # If LumiTrace provides receiver info directly, use it
      if entry["receiver_types"]
        return filter_types(entry["receiver_types"])
      end

      # Otherwise, look for a variable read at the receiver position
      # (the expression just before the call in the same line)
      if entry["receiver_location"]
        loc = entry["receiver_location"]
        key = "#{normalize_path(loc["file"] || entry["file"])}:#{loc["start_line"]}:#{loc["start_col"]}"
        recv_entry = location_index[key]
        if recv_entry
          return filter_types(recv_entry["types"] || {})
        end
      end

      # Fallback: return types from the call itself as a hint
      # (this is approximate - the actual receiver type may differ)
      {}
    end

    def extract_arg_types(entry, location_index)
      return entry["arg_types"].map { |at| filter_types(at) } if entry["arg_types"]

      # If LumiTrace provides argument locations, look them up
      if entry["argument_locations"]
        return entry["argument_locations"].map do |loc|
          key = "#{normalize_path(loc["file"] || entry["file"])}:#{loc["start_line"]}:#{loc["start_col"]}"
          arg_entry = location_index[key]
          arg_entry ? filter_types(arg_entry["types"] || {}) : {}
        end
      end

      []
    end

    def filter_types(types)
      filtered = {}
      types.each do |type_name, count|
        next if CRUBY_ONLY_TYPES.include?(type_name)
        next if @allowed_classes && !@allowed_classes.include?(type_name)
        filtered[type_name] = count
      end
      filtered
    end

    def write_output(call_sites)
      source_hash = compute_source_hash

      output_data = {
        "version" => 1,
        "source_hash" => source_hash,
        "call_sites" => call_sites,
      }

      File.write(@output, JSON.pretty_generate(output_data))
      puts "Wrote Spinel trace to #{@output}"
    end

    def compute_source_hash
      # Hash the input trace file for reproducibility tracking
      digest = Digest::SHA256.file(@input)
      "sha256:#{digest.hexdigest}"
    end

    def report_stats(raw_entries, call_sites)
      puts "Raw LumiTrace entries: #{raw_entries.size}"
      puts "Call-site entries extracted: #{call_sites.size}"

      # Count monomorphic vs polymorphic sites
      mono = 0
      poly = 0
      mega = 0
      call_sites.each_value do |site|
        n = site["return_types"].size
        case n
        when 1 then mono += 1
        when 2..4 then poly += 1
        else mega += 1
        end
      end

      puts "Monomorphic sites: #{mono}"
      puts "Polymorphic sites (2-4 types): #{poly}"
      puts "Megamorphic sites (5+ types): #{mega}"
    end
  end
end

if __FILE__ == $0
  options = {}

  OptionParser.new do |opts|
    opts.banner = "Usage: convert_lumitrace.rb [options]"

    opts.on("--input=FILE", "LumiTrace JSON output file") do |v|
      options[:input] = v
    end

    opts.on("--mruby-classes=FILE", "method_map.json for class filtering (optional)") do |v|
      options[:mruby_classes] = v
    end

    opts.on("--source-root=DIR", "Source root for path normalization (optional)") do |v|
      options[:source_root] = v
    end

    opts.on("--output=FILE", "Output Spinel trace JSON file") do |v|
      options[:output] = v
    end
  end.parse!

  unless options[:input] && options[:output]
    $stderr.puts "ERROR: --input and --output are required"
    exit 1
  end

  converter = Spinel::LumiTraceConverter.new(**options)
  converter.run
end
