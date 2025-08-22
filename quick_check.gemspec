# frozen_string_literal: true

require_relative "lib/quick_check/version"

Gem::Specification.new do |spec|
  spec.name          = "quick_check"
  spec.version       = QuickCheck::VERSION
  spec.authors       = ["Kasvit"]
  spec.email         = ["kasvit93@gmail.com"]

  spec.summary       = "Run changed/added RSpec specs quickly"
  spec.description   = "Adds the `qc` command to run only changed or newly added RSpec files from uncommitted changes and vs base branch (main/master)."
  spec.homepage      = "https://github.com/kasvit/quick_check"
  spec.license       = "MIT"

  spec.required_ruby_version = ">= 2.6"

  spec.files         = Dir.glob("lib/**/*.rb") + [
    "bin/qc",
    ".rspec",
    "spec/spec_helper.rb",
    "spec/quick_check/cli_spec.rb",
    "README.md",
    "LICENSE.txt"
  ]
  spec.bindir        = "bin"
  spec.executables   = ["qc"]
  spec.require_paths = ["lib"]
end
