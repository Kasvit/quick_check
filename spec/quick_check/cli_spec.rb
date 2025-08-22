# frozen_string_literal: true

require "spec_helper"
require "stringio"

RSpec.describe QuickCheck::CLI do
  def run_cli(argv, git_outputs: {}, existing_files: [])
    stdout_io = StringIO.new
    stderr_io = StringIO.new

    allow($stdout).to receive(:puts) { |msg| stdout_io.puts(msg) }
    allow($stderr).to receive(:puts) { |msg| stderr_io.puts(msg) }

    # Stub filesystem for File.file?
    allow(File).to receive(:file?) do |path|
      existing_files.include?(path)
    end

    # Stub Dir.pwd
    allow(Dir).to receive(:pwd).and_return(Dir.pwd)

    # Stub Open3.capture3 for git commands
    allow(Open3).to receive(:capture3) do |*cmd|
      key = cmd.join(" ")
      if git_outputs.key?(key)
        out = git_outputs[key]
        [out[:stdout] || "", out[:stderr] || "", instance_double(Process::Status, success?: out.fetch(:success, true), exitstatus: out.fetch(:exitstatus, 0))]
      else
        # Default: success with empty output
        ["", "", instance_double(Process::Status, success?: true, exitstatus: 0)]
      end
    end

    status = described_class.start(argv)
    [status, stdout_io.string, stderr_io.string]
  end

  let(:base_git_stubs) do
    {
      "git rev-parse --is-inside-work-tree" => { stdout: "true\n" },
      "git rev-parse --abbrev-ref HEAD" => { stdout: "feature\n" },
      "git rev-parse --show-toplevel" => { stdout: Dir.pwd + "\n" },
      "git show-ref --verify --quiet refs/heads/main" => { success: false, exitstatus: 1 },
      "git ls-remote --heads origin main" => { stdout: "refs/heads/main\n" }
    }
  end

  it "prints and exits when no changed tests" do
    status, out, _err = run_cli([], git_outputs: base_git_stubs)
    expect(status).to eq(0)
    expect(out).to include("No changed/added test files detected.")
  end

  it "runs rspec for changed rspec files" do
    stubs = base_git_stubs.merge(
      "git diff --name-only --diff-filter=ACMR" => { stdout: "spec/models/user_spec.rb\n" }
    )

    status, out, _err = run_cli(["--dry-run"], git_outputs: stubs)
    expect(status).to eq(0)
    expect(out.lines.map(&:strip)).to include("bundle exec rspec spec/models/user_spec.rb")
  end

  it "infers rspec from app source change" do
    stubs = base_git_stubs.merge(
      "git diff --name-only --diff-filter=ACMR" => { stdout: "app/models/user.rb\n" }
    )
    status, out, _err = run_cli(["--dry-run"], git_outputs: stubs, existing_files: [
      File.join("spec", "models", "user_spec.rb")
    ])
    expect(status).to eq(0)
    expect(out).to include("bundle exec rspec spec/models/user_spec.rb")
  end

  it "maps controller to request spec with both base names" do
    stubs = base_git_stubs.merge(
      "git diff --name-only --diff-filter=ACMR" => { stdout: "app/controllers/account/users_controller.rb\n" }
    )
    existing = [
      File.join("spec", "requests", "account", "users_spec.rb"),
      File.join("spec", "requests", "account", "users_controller_spec.rb")
    ]
    status, out, _err = run_cli(["--dry-run"], git_outputs: stubs, existing_files: existing)
    expect(out).to include("bundle exec rspec spec/requests/account/users_spec.rb spec/requests/account/users_controller_spec.rb")
    expect(status).to eq(0)
  end

  it "falls back to controller spec when no request spec exists" do
    stubs = base_git_stubs.merge(
      "git diff --name-only --diff-filter=ACMR" => { stdout: "app/controllers/home_controller.rb\n" }
    )
    existing = [File.join("spec", "controllers", "home_controller_spec.rb")]
    status, out, _err = run_cli(["--dry-run"], git_outputs: stubs, existing_files: existing)
    expect(out).to include("bundle exec rspec spec/controllers/home_controller_spec.rb")
    expect(status).to eq(0)
  end

  it "runs minitest through rails test when test files change and rails present" do
    stubs = base_git_stubs.merge(
      "git diff --name-only --diff-filter=ACMR" => { stdout: "test/models/user_test.rb\n" }
    )
    allow_any_instance_of(QuickCheck::CLI).to receive(:rails_available?).and_return(true)
    status, out, _err = run_cli(["--dry-run"], git_outputs: stubs, existing_files: [File.join("bin", "rails")])
    expect(out).to include("bundle exec rails test test/models/user_test.rb")
    expect(status).to eq(0)
  end

  it "runs per-file minitest when no rails" do
    stubs = base_git_stubs.merge(
      "git diff --name-only --diff-filter=ACMR" => { stdout: "test/models/user_test.rb\n" }
    )

    status, out, _err = run_cli(["--dry-run"], git_outputs: stubs)
    expect(out.lines.map(&:strip)).to include("ruby -I test test/models/user_test.rb")
    expect(status).to eq(0)
  end
end
