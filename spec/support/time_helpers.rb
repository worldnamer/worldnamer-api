require "active_support/testing/time_helpers"

# rspec-rails does not include the Rails time helpers (travel, freeze_time) in request specs.
RSpec.configure do |config|
  config.include ActiveSupport::Testing::TimeHelpers, type: :request
end
