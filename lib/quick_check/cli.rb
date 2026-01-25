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
          # Prefer comparing against upstream tracking branch if it exists and has differences.
          # This correctly handles rebases by only showing changes unique to the local branch,
          # not changes that came from the base branch during the rebase.
          upstream_branch = git_upstream_branch(current_branch)
          if upstream_branch
            if upstream_has_differences?(upstream_branch)
              # Compare local branch against its remote tracking branch
              # Use --first-parent to exclude changes from merge commits
              changed_files = diff_range_against_upstream(upstream_branch)
              files.concat(changed_files) if changed_files
            end
            # If upstream is in sync, don't include committed changes (only staged/unstaged)
            # This avoids testing files that were already tested when the branch was pushed
          else
            # Fall back to comparing against base branch if no upstream exists.
            # Use --first-parent to ensure we only get changes from commits directly on this branch,
            # excluding changes from merge commits.
            changed_files = diff_range_against_base(base_branch)
            files.concat(changed_files) if changed_files
          end
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

    def git_upstream_branch(branch)
      # Get the upstream tracking branch for the current branch
      ok, out, _err = run_cmd(["git", "rev-parse", "--abbrev-ref", "--symbolic-full-name", "#{branch}@{u}"])
      if ok && !out.to_s.strip.empty?
        upstream = out.to_s.strip
        # Verify the upstream branch actually exists
        ok_check, _out_check, _err_check = run_cmd(["git", "rev-parse", "--verify", "--quiet", upstream])
        return upstream if ok_check
      end
      nil
    rescue StandardError
      nil
    end

    def upstream_has_differences?(upstream)
      # Check if there are any differences between HEAD and upstream
      # This helps us decide whether to use upstream or fall back to base branch
      ok, out, _err = run_cmd(["git", "rev-list", "--count", "#{upstream}..HEAD"])
      return false unless ok
      count = out.to_s.strip.to_i
      count > 0
    end

    def diff_range_against_upstream(upstream)
      # Use git log --first-parent to get only files changed in commits directly on this branch,
      # excluding changes from merge commits. This correctly handles branches that have merged
      # main into them by only showing changes unique to the branch's own commits.
      files = git_log_first_parent_files(upstream, "HEAD")
      files.empty? ? nil : files
    end

    def diff_range_against_base(base)
      # Use git log --first-parent to get only files changed in commits directly on this branch,
      # excluding changes from merge commits. This correctly handles branches that have merged
      # main into them by only showing changes unique to the branch's own commits.
      base_ref = if local_branch_exists?(base)
                   base
                 elsif remote_branch_exists?(base)
                   "origin/#{base}"
                 else
                   return nil
                 end
      
      # Get files changed in first-parent commits only (excludes merge commits)
      files = git_log_first_parent_files(base_ref, "HEAD")
      files.empty? ? nil : files
    end

    def find_merge_base(base)
      # Try local branch first, then remote
      ref = if local_branch_exists?(base)
              base
            elsif remote_branch_exists?(base)
              "origin/#{base}"
            else
              return nil
            end

      find_merge_base_for_refs(ref, "HEAD")
    end

    def find_merge_base_for_refs(ref1, ref2)
      ok, out, _err = run_cmd(["git", "merge-base", ref1, ref2])
      ok ? out.to_s.strip : nil
    end

    def git_log_first_parent_files(base_ref, head_ref)
      # Get files changed in first-parent commits only (excludes merge commits)
      # This ensures we only get changes from commits directly on the branch
      cmd = ["git", "log", "--first-parent", "--name-only", "--diff-filter=ACMR", "--format=", "#{base_ref}..#{head_ref}"]
      ok, out, _err = run_cmd(cmd)
      return [] unless ok
      
      out.split("\n").map(&:strip).reject(&:empty?).uniq
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
