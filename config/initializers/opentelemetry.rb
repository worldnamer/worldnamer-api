# Traces go through OpenTelemetry. WorldnamerTelemetry.configure_opentelemetry holds the one set of settings
# (service name, instrumentation options); only the span processor differs by environment:
#
# - production and development: spans are batched and sent to Honeycomb over OTLP, but only when HONEYCOMB_API_KEY is
#   set. The key decides which Honeycomb environment receives them (worldnamer-local or worldnamer-production). With no
#   key (a laptop without .env.development.local, CI) tracing stays off and nothing is sent.
# - test: always on, with an in-memory exporter and nothing sent anywhere, so the leak specs
#   (spec/requests/api/v1/session_leak_spec.rb) check the real instrumentation. It must be set up here, at boot,
#   because the Rack instrumentation adds its middleware while the app starts.
require "opentelemetry/sdk"
require "opentelemetry/instrumentation/all"

module WorldnamerTelemetry
  # Spans finished so far in the test environment. Specs read and reset it through spec/support/telemetry_helpers.rb.
  mattr_accessor :span_exporter

  # Options for instrumentation that could otherwise record sensitive data (plan section 5). The values are the gem
  # defaults today; they are stated here so an upgrade that changes a default cannot leak silently.
  INSTRUMENTATION_OPTIONS = {
    # SQL text is recorded with literals replaced by "?", never the values.
    "OpenTelemetry::Instrumentation::PG" => { db_statement: :obfuscate },
    # Record no request or response headers (Authorization, Cookie).
    "OpenTelemetry::Instrumentation::Rack" => { allowed_request_headers: [], allowed_response_headers: [] }
  }.freeze

  def self.configure_opentelemetry(span_processor)
    OpenTelemetry::SDK.configure do |c|
      c.service_name = "worldnamer-api"
      c.resource = OpenTelemetry::SDK::Resources::Resource.create("deployment.environment" => Rails.env.to_s)
      c.add_span_processor(span_processor)
      c.use_all(INSTRUMENTATION_OPTIONS)
    end
  end
end

if Rails.env.test?
  # Keep the instrumentation start-up chatter out of the rspec output (it goes to log/test.log).
  OpenTelemetry.logger = Rails.logger
  WorldnamerTelemetry.span_exporter = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
  WorldnamerTelemetry.configure_opentelemetry(
    # Simple (not batching): each span reaches the exporter the moment it finishes, so a spec can read it straight away.
    OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(WorldnamerTelemetry.span_exporter)
  )
elsif ENV["HONEYCOMB_API_KEY"].present?
  require "opentelemetry/exporter/otlp"

  WorldnamerTelemetry.configure_opentelemetry(
    # Batches spans and sends them from a background thread, so a request never waits on Honeycomb.
    OpenTelemetry::SDK::Trace::Export::BatchSpanProcessor.new(
      OpenTelemetry::Exporter::OTLP::Exporter.new(
        endpoint: "https://api.honeycomb.io/v1/traces",
        headers: { "x-honeycomb-team" => ENV["HONEYCOMB_API_KEY"] }
      )
    )
  )
end
