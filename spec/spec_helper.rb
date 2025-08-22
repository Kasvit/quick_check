# frozen_string_literal: true

require "bundler/setup"
require "quick_check"
require "open3"

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed
end
