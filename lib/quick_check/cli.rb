# frozen_string_literal: true

require "optparse"
require "open3"
require "yaml"
require "shellwords"

module QuickCheck
  class CLI
    DEFAULT_BASE_BRANCHES = ["main", "master"].freeze

    def self.start(argv)
      new(argv).run
    end

    def initialize(argv)
      @argv = argv
      @options = {
        base_branch: nil,
        include_committed_diff: true,
        include_staged: true,
        include_unstaged: true,
        custom_command: nil,
        print_only: false,
        dry_run: false,
        debug: false
      }
    end

    def run
      parse_options!

      changed = determine_changed_test_files
      if changed[:rspec].empty? && changed[:minitest].empty?
        $stdout.puts("No changed/added test files detected.")
        return 0
      end

      if @options[:print_only]
        (changed[:rspec] + changed[:minitest]).each { |f| $stdout.puts(f) }
        return 0
      end

      exit_status = 0

      # Run RSpec files if any
      unless changed[:rspec].empty?
        cmd = build_command_for(:rspec, changed[:rspec])
        print_and_maybe_run(cmd)
        exit_status = nonzero_status(exit_status)
      end

      # Run Minitest files if any
      unless changed[:minitest].empty?
        minitest_cmd = build_command_for(:minitest, changed[:minitest])
        if minitest_cmd == :per_file_minitest
          changed[:minitest].each do |file|
            cmd = ["ruby", "-I", "test", file]
            print_and_maybe_run(cmd)
            exit_status = nonzero_status(exit_status)
          end
        else
          print_and_maybe_run(minitest_cmd)
          exit_status = nonzero_status(exit_status)
        end
      end

      exit_status
    end

    private

    def parse_options!
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: qc [options]"

        opts.on("--base BRANCH", "Base branch to diff against (overrides config)") do |v|
          @options[:base_branch] = v
        end

        opts.on("--no-committed", "Do not include committed changes vs base branch") do
          @options[:include_committed_diff] = false
        end

        opts.on("--committed", "Include committed changes vs base branch") do
          @options[:include_committed_diff] = true
        end

        opts.on("--no-staged", "Ignore staged changes") do
          @options[:include_staged] = false
        end

        opts.on("--no-unstaged", "Ignore unstaged changes") do
          @options[:include_unstaged] = false
        end

        opts.on("--cmd CMD", "Override test command (auto-detected when omitted)") do |v|
          @options[:custom_command] = Shellwords.split(v)
        end

        opts.on("-p", "--print", "Only print matched spec files, do not run") do
          @options[:print_only] = true
        end

        opts.on("-n", "--dry-run", "Print command that would run") do
          @options[:dry_run] = true
        end

        opts.on("-v", "--verbose", "Verbose/debug output") do
          @options[:debug] = true
        end

        opts.on("-h", "--help", "Show help") do
          $stdout.puts(opts)
          exit 0
        end
      end

      parser.parse!(@argv)
    end

    def determine_changed_test_files
      ensure_git_repo!

      base_branch = resolve_base_branch
      files = []

      if @options[:include_unstaged]
        files.concat(git_diff_name_only(["--name-only", "-M", "-C", "--diff-filter=ACMR"]))
        files.concat(git_untracked_files)
      end

      if @options[:include_staged]
        files.concat(git_diff_name_only(["--name-only", "--cached", "-M", "-C", "--diff-filter=ACMR"]))
      end

      if @options[:include_committed_diff]
        current_branch = git_current_branch
        if current_branch && base_branch && current_branch != base_branch
          # Include files changed on this branch vs base
          range = diff_range_against_base(base_branch)
          files.concat(git_diff_name_only(["--name-only", "-M", "-C", "--diff-filter=ACMR", range])) if range
        end
      end

      files = files.compact.uniq
      rspec_specs = files.select { |f| f.match?(%r{\Aspec/.+_spec\.rb\z}) }
      rspec_specs += infer_rspec_from_source(files)
      minitest_tests = files.select { |f| f.match?(%r{\Atest/.+_test\.rb\z}) }

      { rspec: rspec_specs.uniq, minitest: minitest_tests.uniq }
    end

    def infer_rspec_from_source(files)
      candidates = []
      files.each do |path|
        next unless path.end_with?(".rb")

        if path =~ %r{\Aapp/models/(.+)\.rb\z}
          spec_path = File.join("spec", "models", "#{$1}_spec.rb")
          candidates << spec_path if File.file?(spec_path)
          next
        end

        if path =~ %r{\Aapp/controllers/(.+?)(?:_controller)?\.rb\z}
          controller_path = Regexp.last_match(1)
          req_base = File.join("spec", "requests", controller_path)
          req_variants = [
            "#{req_base}_spec.rb",
            "#{req_base}_controller_spec.rb"
          ].select { |p| File.file?(p) }
          if req_variants.any?
            candidates.concat(req_variants)
          else
            ctrl_spec = File.join("spec", "controllers", "#{controller_path}_controller_spec.rb")
            candidates << ctrl_spec if File.file?(ctrl_spec)
          end
          next
        end

        if path =~ %r{\Alib/(.+)\.rb\z}
          spec_path = File.join("spec", "lib", "#{$1}_spec.rb")
          candidates << spec_path if File.file?(spec_path)
          next
        end
      end
      candidates
    end

    def ensure_git_repo!
      run_cmd(["git", "rev-parse", "--is-inside-work-tree"]).tap do |ok, out, _err|
        unless ok && out.to_s.strip == "true"
          $stderr.puts("qc must be run inside a git repository")
          exit 2
        end
      end
    end

    def resolve_base_branch
      return @options[:base_branch] if @options[:base_branch]&.strip&.length&.positive?

      # Load from config file if present
      cfg = read_config
      if cfg && cfg["base_branch"]&.strip&.length&.positive?
        return cfg["base_branch"].strip
      end

      # Default to first existing branch from defaults
      DEFAULT_BASE_BRANCHES.find { |b| branch_exists?(b) } || DEFAULT_BASE_BRANCHES.first
    end

    def read_config
      paths = possible_config_paths
      paths.each do |path|
        next unless File.file?(path)
        begin
          data = YAML.safe_load(File.read(path))
          return data if data.is_a?(Hash)
        rescue StandardError
          # Ignore malformed config
        end
      end
      nil
    end

    def possible_config_paths
      cwd = Dir.pwd
      repo_root = git_repo_root || cwd
      [
        File.join(cwd, ".quick_check.yml"),
        File.join(repo_root, ".quick_check.yml")
      ].uniq
    end

    def branch_exists?(name)
      local_branch_exists?(name) || remote_branch_exists?(name)
    end

    def local_branch_exists?(name)
      ok, _out, _err = run_cmd(["git", "show-ref", "--verify", "--quiet", "refs/heads/#{name}"])
      ok
    end

    def remote_branch_exists?(name)
      ok, out, _err = run_cmd(["git", "ls-remote", "--heads", "origin", name])
      ok && !out.to_s.strip.empty?
    end

    def git_current_branch
      ok, out, _err = run_cmd(["git", "rev-parse", "--abbrev-ref", "HEAD"])
      ok ? out.to_s.strip : nil
    end

    def git_repo_root
      ok, out, _err = run_cmd(["git", "rev-parse", "--show-toplevel"])
      ok ? out.to_s.strip : nil
    end

    def diff_range_against_base(base)
      # Prefer the symmetric range base...HEAD if base exists locally,
      # otherwise fall back to origin/base...HEAD when only remote exists.
      if local_branch_exists?(base)
        "#{base}...HEAD"
      elsif remote_branch_exists?(base)
        "origin/#{base}...HEAD"
      else
        nil
      end
    end

    def git_diff_name_only(args)
      cmd = ["git", "diff"] + args
      ok, out, _err = run_cmd(cmd)
      return [] unless ok

      out.split("\n").map(&:strip).reject(&:empty?)
    end

    def git_untracked_files
      ok, out, _err = run_cmd(["git", "ls-files", "--others", "--exclude-standard"])
      return [] unless ok

      out.split("\n").map(&:strip).reject(&:empty?)
    end

    def build_command_for(framework, files)
      return (@options[:custom_command] + files) if @options[:custom_command]

      case framework
      when :rspec
        ["bundle", "exec", "rspec"] + files
      when :minitest
        if rails_available?
          rails_cmd + ["test"] + files
        else
          # Fallback: run per-file using ruby -Itest
          :per_file_minitest
        end
      else
        files
      end
    end

    def rails_available?
      File.executable?(File.join(Dir.pwd, "bin", "rails")) || gemfile_includes?("rails")
    end

    def rails_cmd
      if File.executable?(File.join(Dir.pwd, "bin", "rails"))
        [File.join("bin", "rails")]
      else
        ["bundle", "exec", "rails"]
      end
    end

    def gemfile_includes?(gem_name)
      gemfile_paths = [File.join(Dir.pwd, "Gemfile"), File.join(Dir.pwd, "gems.rb")]
      gemfile_paths.any? do |path|
        next false unless File.file?(path)
        begin
          content = File.read(path)
          content.match?(/\bgem\s+["']#{Regexp.escape(gem_name)}["']/)
        rescue StandardError
          false
        end
      end
    end

    def print_and_maybe_run(cmd)
      if cmd.is_a?(Array)
        $stdout.puts(cmd.shelljoin)
        return if @options[:dry_run]
        system(*cmd)
      else
        # no-op for symbols like :per_file_minitest (handled by caller)
      end
    end

    def nonzero_status(current_status)
      return current_status if @options[:dry_run]
      last = $?.exitstatus
      if last && last != 0
        last
      else
        current_status
      end
    end

    def run_cmd(cmd)
      stdout, stderr, status = Open3.capture3(*cmd)
      [status.success?, stdout, stderr]
    end
  end
end
