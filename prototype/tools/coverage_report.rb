#!/usr/bin/env ruby
# frozen_string_literal: true

# coverage_report.rb - Measure RBS coverage of mruby core methods
#
# Compares the RBS type database (from extract_rbs.rb) against the mruby
# method map (from scan_mruby_methods.rb) to determine what percentage
# of mruby's core methods have RBS type signatures.
#
# Usage:
#   ruby coverage_report.rb \
#     --type-db=type_db/core.json \
#     --method-map=method_map.json

require "json"
require "optparse"

module Spinel
  class CoverageReport
    def initialize(type_db:, method_map:, output: nil)
      @type_db_path = type_db
      @method_map_path = method_map
      @output_path = output

      @type_db = nil
      @method_map = nil
    end

    def run
      load_data
      report = analyze_coverage
      print_report(report)
      write_output(report) if @output_path
    end

    private

    def load_data
      @type_db = JSON.parse(File.read(@type_db_path))
      @method_map = JSON.parse(File.read(@method_map_path))
    end

    def analyze_coverage
      report = {
        "classes" => {},
        "summary" => {
          "total_mruby_classes" => 0,
          "covered_classes" => 0,
          "total_mruby_methods" => 0,
          "covered_methods" => 0,
          "uncovered_methods" => [],
          "mruby_only_classes" => [],
          "rbs_only_classes" => [],
        },
      }

      all_classes = Set.new(@method_map.keys) | Set.new(@type_db.keys)

      all_classes.sort.each do |class_name|
        mruby_info = @method_map[class_name]
        rbs_info = @type_db[class_name]

        class_report = analyze_class(class_name, mruby_info, rbs_info)
        report["classes"][class_name] = class_report

        # Update summary
        if mruby_info && !rbs_info
          report["summary"]["mruby_only_classes"] << class_name
        elsif rbs_info && !mruby_info
          report["summary"]["rbs_only_classes"] << class_name
        end
      end

      # Compute totals
      total_mruby = 0
      covered = 0

      report["classes"].each do |class_name, cr|
        total_mruby += cr["mruby_instance_methods"]
        total_mruby += cr["mruby_class_methods"]
        covered += cr["covered_instance_methods"]
        covered += cr["covered_class_methods"]
        report["summary"]["uncovered_methods"].concat(cr["uncovered"].map { |m| "#{class_name}##{m}" })
      end

      report["summary"]["total_mruby_classes"] = @method_map.size
      report["summary"]["covered_classes"] = report["classes"].count { |_, cr| cr["coverage_pct"] > 0 }
      report["summary"]["total_mruby_methods"] = total_mruby
      report["summary"]["covered_methods"] = covered

      report
    end

    def analyze_class(class_name, mruby_info, rbs_info)
      mruby_instance = (mruby_info && mruby_info["instance_methods"]) || {}
      mruby_class = (mruby_info && mruby_info["class_methods"]) || {}
      rbs_instance = (rbs_info && rbs_info["instance_methods"]) || {}
      rbs_class = (rbs_info && rbs_info["class_methods"]) || {}

      covered_instance = (mruby_instance.keys & rbs_instance.keys)
      covered_class = (mruby_class.keys & rbs_class.keys)
      uncovered_instance = mruby_instance.keys - rbs_instance.keys
      uncovered_class = mruby_class.keys - rbs_class.keys

      total_mruby = mruby_instance.size + mruby_class.size
      total_covered = covered_instance.size + covered_class.size

      {
        "mruby_instance_methods" => mruby_instance.size,
        "mruby_class_methods" => mruby_class.size,
        "rbs_instance_methods" => rbs_instance.size,
        "rbs_class_methods" => rbs_class.size,
        "covered_instance_methods" => covered_instance.size,
        "covered_class_methods" => covered_class.size,
        "coverage_pct" => total_mruby > 0 ? (total_covered.to_f / total_mruby * 100).round(1) : 0.0,
        "uncovered" => uncovered_instance + uncovered_class,
        "rbs_only" => (rbs_instance.keys - mruby_instance.keys) + (rbs_class.keys - mruby_class.keys),
      }
    end

    def print_report(report)
      puts "=" * 70
      puts "RBS Coverage Report for mruby Core Methods"
      puts "=" * 70
      puts

      # Per-class coverage
      puts "Per-class Coverage:"
      puts "-" * 70
      puts format("%-20s %8s %8s %8s %8s", "Class", "mruby", "RBS", "Covered", "Coverage")
      puts "-" * 70

      report["classes"].sort_by { |_, cr| -cr["coverage_pct"] }.each do |class_name, cr|
        total_mruby = cr["mruby_instance_methods"] + cr["mruby_class_methods"]
        total_rbs = cr["rbs_instance_methods"] + cr["rbs_class_methods"]
        total_covered = cr["covered_instance_methods"] + cr["covered_class_methods"]
        next if total_mruby == 0 && total_rbs == 0

        puts format("%-20s %8d %8d %8d %7.1f%%",
          class_name, total_mruby, total_rbs, total_covered, cr["coverage_pct"])
      end

      puts
      puts "-" * 70

      # Summary
      s = report["summary"]
      total = s["total_mruby_methods"]
      covered = s["covered_methods"]
      pct = total > 0 ? (covered.to_f / total * 100).round(1) : 0.0

      puts "Summary:"
      puts "  mruby classes: #{s["total_mruby_classes"]}"
      puts "  Classes with RBS coverage: #{s["covered_classes"]}"
      puts "  Total mruby methods: #{total}"
      puts "  Methods with RBS types: #{covered} (#{pct}%)"
      puts "  Methods without RBS types: #{total - covered}"
      puts

      if s["mruby_only_classes"].any?
        puts "  mruby-only classes (no RBS):"
        s["mruby_only_classes"].each { |c| puts "    - #{c}" }
        puts
      end

      if s["rbs_only_classes"].any?
        puts "  RBS-only classes (not in mruby):"
        s["rbs_only_classes"].each { |c| puts "    - #{c}" }
        puts
      end

      # Top uncovered methods
      if s["uncovered_methods"].any?
        puts "  Top uncovered methods (first 20):"
        s["uncovered_methods"].first(20).each { |m| puts "    - #{m}" }
        puts "  ..." if s["uncovered_methods"].size > 20
      end
    end

    def write_output(report)
      File.write(@output_path, JSON.pretty_generate(report))
      puts "\nWrote coverage report to #{@output_path}"
    end
  end
end

if __FILE__ == $0
  options = {}

  OptionParser.new do |opts|
    opts.banner = "Usage: coverage_report.rb [options]"

    opts.on("--type-db=FILE", "RBS type database JSON (from extract_rbs.rb)") do |v|
      options[:type_db] = v
    end

    opts.on("--method-map=FILE", "Method map JSON (from scan_mruby_methods.rb)") do |v|
      options[:method_map] = v
    end

    opts.on("--output=FILE", "Output coverage report JSON (optional)") do |v|
      options[:output] = v
    end
  end.parse!

  unless options[:type_db] && options[:method_map]
    $stderr.puts "ERROR: --type-db and --method-map are required"
    exit 1
  end

  reporter = Spinel::CoverageReport.new(**options)
  reporter.run
end
