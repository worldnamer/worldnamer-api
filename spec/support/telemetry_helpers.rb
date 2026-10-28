# Test helpers for the leak specs. The interface is described at the top of
# spec/requests/api/v1/session_leak_spec.rb.
#
# OpenTelemetry and Sentry are configured at boot in the test environment (config/initializers/opentelemetry.rb and
# sentry.rb) with in-memory destinations. Both stores are emptied before and after every example, so spans and events
# from one example never reach another and memory does not grow over the suite.
module TelemetryHelpers
  # Every OpenTelemetry span (SpanData) that finished during the current example.
  def captured_spans
    WorldnamerTelemetry.span_exporter.finished_spans
  end

  # Every Sentry::Event captured during the current example.
  def captured_sentry_events
    Sentry.get_current_client.transport.events
  end

  def self.reset
    WorldnamerTelemetry.span_exporter.reset
    Sentry.get_current_client.transport.clear
  end
end

RSpec.configure do |config|
  config.include TelemetryHelpers, type: :request

  config.before(:each) { TelemetryHelpers.reset }
  config.after(:each) { TelemetryHelpers.reset }
end
