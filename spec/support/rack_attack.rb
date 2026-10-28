# rack-attack counts requests in Rails.cache, which is :null_store in the test
# environment (config/environments/test.rb), so nothing would ever be counted.
# Give every request example a fresh in-memory store instead. A fresh store per
# example also stops one example's logins from eating the next one's quota.
#
# Guarded with defined? only so the rest of the suite still loads before the
# gem is added; spec/requests/api/v1/session_throttle_spec.rb names Rack::Attack
# directly and fails loudly if it is missing.
RSpec.configure do |config|
  config.before(:each, type: :request) do
    next unless defined?(Rack::Attack)

    Rack::Attack.enabled = true
    Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
  end
end
