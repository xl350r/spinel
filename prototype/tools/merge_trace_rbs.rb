#!/usr/bin/env ruby
# frozen_string_literal: true

# merge_trace_rbs.rb - Integration demo: merge trace data with RBS type info
#
# Loads the Spinel trace JSON (from convert_lumitrace.rb) and the RBS type
# database (from extract_rbs.rb), then for each call site:
#   1. Classifies as PROVEN / LIKELY / UNRESOLVED
#   2. Computes the reachable method set
#   3. Reports reachable vs total methods and potential binary size reduction
#
# Usage:
#   ruby merge_trace_rbs.rb \
#     --trace=trace.json \
#     --type-db=type_db/core.json \
#     --method-map=method_map.json \
#     --output=analysis.json

require "json"
require "optparse"

module Spinel
  class TraceRBSMerger
    # Resolution levels matching the C enum in the design doc
    PROVEN     = "PROVEN"      # CHA-proven, guard-free direct call
    LIKELY     = "LIKELY"      # Type-guarded fast path + fallback
    UNRESOLVED = "UNRESOLVED"  # Full mruby dispatch

    # Threshold for megamorphic (give up on specialization)
    MEGA_THRESHOLD = 5

    def initialize(trace:, type_db:, method_map: nil, output: nil)
      @trace_path = trace
      @type_db_path = type_db
      @method_map_path = method_map
      @output_path = output

      @trace = nil
      @type_db = nil
      @method_map = nil
      @resolutions = {}
      @reachable_methods = Set.new
      @all_methods = Set.new
    end

    def run
      load_data
      build_all_methods_set
      resolve_call_sites
      compute_reachability
      report
      write_output if @output_path
    end

    private

    def load_data
      @trace = JSON.parse(File.read(@trace_path))
      @type_db = JSON.parse(File.read(@type_db_path))
      @method_map = @method_map_path ? JSON.parse(File.read(@method_map_path)) : {}
    end

    def build_all_methods_set
      # Build set of all known methods from method_map and type_db
      [@method_map, @type_db].each do |db|
        db.each do |class_name, info|
          (info["instance_methods"] || {}).each_key do |method_name|
            @all_methods << "#{class_name}##{method_name}"
          end
          (info["class_methods"] || {}).each_key do |method_name|
            @all_methods << "#{class_name}.#{method_name}"
          end
        end
      end
    end

    def resolve_call_sites
      call_sites = @trace["call_sites"] || {}

      call_sites.each do |site_key, site_data|
        resolution = resolve_site(site_key, site_data)
        @resolutions[site_key] = resolution
      end
    end

    def resolve_site(site_key, site_data)
      method_name = site_data["method"]
      receiver_types = site_data["receiver_types"] || {}
      return_types = site_data["return_types"] || {}
      total = site_data["total_calls"] || 0

      # Determine type distribution from receiver or return types
      type_dist = receiver_types.empty? ? return_types : receiver_types
      type_count = type_dist.size

      result = {
        "site" => site_key,
        "method" => method_name,
        "resolution" => UNRESOLVED,
        "receiver_types" => receiver_types,
        "return_types" => return_types,
        "total_calls" => total,
        "resolved_targets" => [],
        "reason" => "",
      }

      if type_count == 0
        result["resolution"] = UNRESOLVED
        result["reason"] = "no type information"
        return result
      end

      if type_count >= MEGA_THRESHOLD
        result["resolution"] = UNRESOLVED
        result["reason"] = "megamorphic (#{type_count} types)"
        return result
      end

      # Check each receiver type
      dominant_type = type_dist.max_by { |_, count| count }&.first
      targets = []

      type_dist.each_key do |recv_class|
        target = "#{recv_class}##{method_name}"
        targets << target

        # Check if method exists in type_db (RBS confirms the signature)
        rbs_info = lookup_rbs(recv_class, method_name)
        target_info = { "target" => target, "rbs_confirmed" => !rbs_info.nil? }
        result["resolved_targets"] << target_info
      end

      if type_count == 1
        # Monomorphic - check CHA
        if cha_proven?(dominant_type, method_name)
          result["resolution"] = PROVEN
          result["reason"] = "monomorphic + CHA proven (no redefinition of #{dominant_type}##{method_name})"
        else
          result["resolution"] = LIKELY
          result["reason"] = "monomorphic but CHA not proven"
        end
      elsif type_count <= 4
        # Polymorphic
        result["resolution"] = LIKELY
        result["reason"] = "polymorphic (#{type_count} types)"
      end

      result
    end

    # Simple CHA check: a method is "proven" if:
    # 1. The receiver class is a core class (Integer, String, etc.)
    # 2. No subclass overrides are known for that method
    # In this prototype, we assume core class methods are not redefined
    # (the real implementation will scan the source for redefinitions)
    def cha_proven?(class_name, method_name)
      core_classes = %w[
        Integer Float String Symbol NilClass TrueClass FalseClass
        Array Hash Range Regexp
      ]
      core_classes.include?(class_name)
    end

    def lookup_rbs(class_name, method_name)
      class_info = @type_db[class_name]
      return nil unless class_info

      methods = class_info["instance_methods"] || {}
      methods[method_name]
    end

    def compute_reachability
      # Start from all call sites and mark their targets as reachable
      worklist = []

      @resolutions.each_value do |res|
        res["resolved_targets"].each do |target_info|
          target = target_info["target"]
          unless @reachable_methods.include?(target)
            @reachable_methods << target
            worklist << target
          end
        end
      end

      # Fixed-point iteration: for each reachable method,
      # check if it has call sites that lead to more methods
      # (In this prototype, we only have one level of call sites)
      # The real implementation would walk the AST of reachable methods

      # Also add methods implied by return types (conservative)
      @resolutions.each_value do |res|
        (res["return_types"] || {}).each_key do |return_class|
          # The return value might have methods called on it elsewhere
          # For now, just track the class as reachable
        end
      end
    end

    def report
      puts "=" * 60
      puts "Spinel AOT Analysis Report"
      puts "=" * 60
      puts

      # Per-site resolution details
      puts "Call Site Resolutions:"
      puts "-" * 60

      proven_count = 0
      likely_count = 0
      unresolved_count = 0

      @resolutions.each do |site_key, res|
        level = res["resolution"]
        case level
        when PROVEN then proven_count += 1
        when LIKELY then likely_count += 1
        when UNRESOLVED then unresolved_count += 1
        end

        puts "  #{site_key}: #{res["method"]}"
        puts "    Resolution: #{level}"
        puts "    Reason: #{res["reason"]}"
        puts "    Receiver types: #{res["receiver_types"]}"
        puts "    Return types: #{res["return_types"]}"
        puts "    Calls: #{res["total_calls"]}"
        puts
      end

      total_sites = @resolutions.size
      puts "-" * 60
      puts "Summary:"
      puts "  Total call sites: #{total_sites}"
      puts "  PROVEN:     #{proven_count} (#{pct(proven_count, total_sites)})"
      puts "  LIKELY:     #{likely_count} (#{pct(likely_count, total_sites)})"
      puts "  UNRESOLVED: #{unresolved_count} (#{pct(unresolved_count, total_sites)})"
      puts

      puts "Reachability:"
      puts "  Reachable methods: #{@reachable_methods.size}"
      puts "  Total known methods: #{@all_methods.size}"
      if @all_methods.size > 0
        unreachable = @all_methods.size - @reachable_methods.size
        puts "  Unreachable methods: #{unreachable} (#{pct(unreachable, @all_methods.size)})"
        puts "  Potential binary size reduction: ~#{pct(unreachable, @all_methods.size)} of method code"
      end
      puts
    end

    def pct(n, total)
      return "0%" if total == 0
      "#{(n.to_f / total * 100).round(1)}%"
    end

    def write_output
      output_data = {
        "version" => 1,
        "resolutions" => @resolutions,
        "reachable_methods" => @reachable_methods.to_a.sort,
        "all_methods" => @all_methods.to_a.sort,
        "summary" => {
          "total_sites" => @resolutions.size,
          "proven" => @resolutions.count { |_, r| r["resolution"] == PROVEN },
          "likely" => @resolutions.count { |_, r| r["resolution"] == LIKELY },
          "unresolved" => @resolutions.count { |_, r| r["resolution"] == UNRESOLVED },
          "reachable_methods" => @reachable_methods.size,
          "total_methods" => @all_methods.size,
        },
      }

      File.write(@output_path, JSON.pretty_generate(output_data))
      puts "Wrote analysis to #{@output_path}"
    end
  end
end

if __FILE__ == $0
  options = {}

  OptionParser.new do |opts|
    opts.banner = "Usage: merge_trace_rbs.rb [options]"

    opts.on("--trace=FILE", "Spinel trace JSON (from convert_lumitrace.rb)") do |v|
      options[:trace] = v
    end

    opts.on("--type-db=FILE", "RBS type database JSON (from extract_rbs.rb)") do |v|
      options[:type_db] = v
    end

    opts.on("--method-map=FILE", "Method map JSON (from scan_mruby_methods.rb, optional)") do |v|
      options[:method_map] = v
    end

    opts.on("--output=FILE", "Output analysis JSON (optional)") do |v|
      options[:output] = v
    end
  end.parse!

  unless options[:trace] && options[:type_db]
    $stderr.puts "ERROR: --trace and --type-db are required"
    exit 1
  end

  merger = Spinel::TraceRBSMerger.new(**options)
  merger.run
end
