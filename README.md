# quick_check

Run only the tests that changed (RSpec or Minitest). Fast.

`quick_check` installs a `qc` command that finds changed/added test files (staged, unstaged, and untracked by default) and runs them using the appropriate test runner automatically.

## Basic Usage

Install the gem and run `qc` to run the tests that changed.

```bash
gem install quick_check
qc
```

## Features

- Detects changed test files under:
  - RSpec: `spec/**/*_spec.rb`
  - Minitest: `test/**/*_test.rb`
  - Also maps changed source files to their tests:
    - `app/models/user.rb` -> `spec/models/user_spec.rb` / `test/models/user_test.rb`
    - `app/controllers/home_controller.rb` -> `spec/requests/home_spec.rb` or `spec/requests/home_controller_spec.rb` (fallbacks), and controller tests as fallback; similarly for Minitest under `test/integration` and `test/controllers`
    - `lib/foo/bar.rb` -> `spec/lib/foo/bar_spec.rb` / `test/lib/foo/bar_test.rb`
- Includes (by default):
  - Unstaged working tree changes
  - Staged (index) changes
  - Untracked files (new specs not yet added)
  - All committed changes on your branch vs base (`main`/`master`)
  - Renames and copies are tracked so moved tests still run
- You can disable branch commits with `--no-committed`
- Auto-detects base branch (`main` or `master`) or configure via `.quick_check.yml`
- Auto-detects framework and command:
  - RSpec: `bundle exec rspec <files>`
  - Rails + Minitest: `bin/rails test <files>` (or `bundle exec rails test <files>`)
  - Plain Minitest: per-file `ruby -I test <file>`
- Always prints the full command(s) before executing
- `--cmd` to override the command for advanced use-cases

## Install

From source:

```bash
gem install quick_check
```

Once installed, the `qc` executable will be available in your shell.

## Usage

```bash
# Run all changed tests in your branch (default: committed + staged + unstaged + untracked)
qc

# Print matching spec file paths only (no execution)
qc --print

# Dry-run: print the exact command that would run
qc --dry-run

# Only current edits (ignore previously committed changes in this branch)
qc --no-committed

# Specify/override the base branch
qc --base main

# Only committed changes vs base (ignore working tree)
qc --no-staged --no-unstaged

# Use a custom test command
qc --cmd "bundle exec rspec --fail-fast"

# Verbose output
qc --verbose
```

## Options

- `--base BRANCH`: Base branch to diff against (overrides config)
- `--committed` / `--no-committed`: Include or exclude committed changes vs base (default: include)
- `--no-staged`: Ignore staged changes
- `--no-unstaged`: Ignore unstaged changes
- `--cmd CMD`: Override test command (default: auto-detected runner)
- `-p`, `--print`: Only print matched files, do not run
- `-n`, `--dry-run`: Print the command that would run and exit
- `-v`, `--verbose`: Verbose/debug output
- `-h`, `--help`: Show help

## Configuration

Create `.quick_check.yml` in the repo root (or current directory) to set defaults:

```yml
# .quick_check.yml
base_branch: main
```

If no config is present, `qc` will use the first existing branch among `main` or `master`.

## How it works

- Unstaged: `git diff --name-only -M -C --diff-filter=ACMR`
- Staged: `git diff --name-only --cached -M -C --diff-filter=ACMR`
- Untracked: `git ls-files --others --exclude-standard`
- Committed vs base: `git diff --name-only -M -C --diff-filter=ACMR <base>...HEAD`

Files are filtered to `spec/**/*_spec.rb` and/or `test/**/*_test.rb`, de-duplicated, sorted, and then:

- For RSpec: run once via `bundle exec rspec <files>`
- For Rails + Minitest: run once via `rails test <files>`
- For plain Minitest: run each file via `ruby -I test <file>`

The CLI prints each full command before executing. With `--dry-run`, it only prints and exits.

Notes:
- We intentionally exclude deletions (`D`) so removed tests are not attempted to run.
- Renames (`R`) and copies (`C`) are included, so moved tests are still executed.

## Exit status

- Returns non-zero if any executed command fails
- Returns `0` if no changed/added spec files are detected

## License

MIT
