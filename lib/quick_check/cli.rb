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
        files.concat(git_diff_name_only(["--name-only", "--diff-filter=ACMR"]))
        files.concat(git_untracked_files)
      end

      if @options[:include_staged]
        files.concat(git_diff_name_only(["--name-only", "--cached", "--diff-filter=ACMR"]))
      end

      if @options[:include_committed_diff]
        current_branch = git_current_branch
        if current_branch && base_branch && current_branch != base_branch
          # Include files changed on this branch vs base
          range = diff_range_against_base(base_branch)
          files.concat(git_diff_name_only(["--name-only", "--diff-filter=ACMR", range])) if range
        end
      end

      files = files.compact.uniq
      rspec_specs = files.select { |f| f.match?(%r{\Aspec/.+_spec\.rb\z}) }
      minitest_tests = files.select { |f| f.match?(%r{\Atest/.+_test\.rb\z}) }

      # Infer tests from source changes (e.g., app/models/user.rb -> spec/models/user_spec.rb)
      source_files = files.reject { |f| f.match?(%r{\A(spec/|test/)}) }
      unless source_files.empty?
        inferred_rspec = source_files.flat_map { |src| infer_rspec_paths_for_source(src) }
        inferred_minitest = source_files.flat_map { |src| infer_minitest_paths_for_source(src) }
        rspec_specs.concat(inferred_rspec)
        minitest_tests.concat(inferred_minitest)
      end

      { rspec: rspec_specs.uniq, minitest: minitest_tests.uniq }
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
      ok, _out, _err = run_cmd(["git", "show-ref", "--verify", "--quiet", "refs/heads/#{name}"])
      return true if ok

      # fall back to remote branch
      ok, _out, _err = run_cmd(["git", "ls-remote", "--heads", "origin", name])
      ok && !_out.to_s.strip.empty?
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
      return nil unless branch_exists?(base)
      # If upstream exists, prefer merge-base to HEAD to include all branch commits
      # The symmetric range base...HEAD ensures we include commits unique to the branch
      "#{base}...HEAD"
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

    def infer_rspec_paths_for_source(source_path)
      candidates = []
      if source_path.start_with?("app/")
        rel = source_path.sub(/^app\//, "")
        # Prefer request specs for controllers
        if rel.start_with?("controllers/")
          sub_rel = rel.sub(/^controllers\//, "")
          dir = File.dirname(sub_rel)
          dir = "" if dir == "."
          base_with_controller = File.basename(sub_rel, ".rb")
          base_without_controller = base_with_controller.sub(/_controller\z/, "")
          # Common conventions for request specs
          candidates << File.join("spec", "requests", dir, "#{base_without_controller}_spec.rb")
          candidates << File.join("spec", "requests", dir, "#{base_with_controller}_spec.rb")
        end
        candidates << File.join("spec", rel).sub(/\.rb\z/, "_spec.rb")
      elsif source_path.start_with?("lib/")
        rel = source_path.sub(/^lib\//, "")
        candidates << File.join("spec", "lib", rel).sub(/\.rb\z/, "_spec.rb")
      end

      candidates.select { |p| File.file?(p) }
    end

    def infer_minitest_paths_for_source(source_path)
      candidates = []
      if source_path.start_with?("app/")
        rel = source_path.sub(/^app\//, "")
        # Prefer integration/request-style tests for controllers when present
        if rel.start_with?("controllers/")
          sub_rel = rel.sub(/^controllers\//, "")
          dir = File.dirname(sub_rel)
          dir = "" if dir == "."
          base = File.basename(sub_rel, ".rb").sub(/_controller\z/, "")
          integration_test = File.join("test", "integration", dir, "#{base}_test.rb")
          candidates << integration_test
        end
        candidates << File.join("test", rel).sub(/\.rb\z/, "_test.rb")
      elsif source_path.start_with?("lib/")
        rel = source_path.sub(/^lib\//, "")
        candidates << File.join("test", "lib", rel).sub(/\.rb\z/, "_test.rb")
      end

      candidates.select { |p| File.file?(p) }
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
      bin_rails = File.join(Dir.pwd, "bin", "rails")
      File.executable?(bin_rails) || File.file?(bin_rails) || gemfile_includes?("rails")
    end

    def rails_cmd
      bin_rails = File.join(Dir.pwd, "bin", "rails")
      if File.executable?(bin_rails) || File.file?(bin_rails)
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
