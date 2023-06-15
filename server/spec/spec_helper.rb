# spec/spec_helper.rb

# Default inter-command delay to 0 in specs so apply_plan tests don't sleep
# 1s between fixture commands. Set BEFORE requiring tools that read it.
ENV['POOLPUMP_INTER_CMD_DELAY_SEC'] ||= '0'

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
$LOAD_PATH.unshift File.expand_path('..', __dir__)

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed
end
