# Sends traces to Honeycomb over OpenTelemetry (OTLP). The key decides which Honeycomb environment receives them
# (worldnamer-local or worldnamer-production). With no key set (specs, CI, a laptop without .env.development.local)
# tracing stays off and nothing is sent.
honeycomb_api_key = ENV["HONEYCOMB_API_KEY"]

if honeycomb_api_key.present?
  require "opentelemetry/sdk"
  require "opentelemetry/exporter/otlp"
  require "opentelemetry/instrumentation/all"

  OpenTelemetry::SDK.configure do |c|
    c.service_name = "worldnamer-api"
    c.resource = OpenTelemetry::SDK::Resources::Resource.create("deployment.environment" => Rails.env.to_s)

    # Batches spans and sends them from a background thread, so a request never waits on Honeycomb.
    c.add_span_processor(
      OpenTelemetry::SDK::Trace::Export::BatchSpanProcessor.new(
        OpenTelemetry::Exporter::OTLP::Exporter.new(
          endpoint: "https://api.honeycomb.io/v1/traces",
          headers: { "x-honeycomb-team" => honeycomb_api_key }
        )
      )
    )

    c.use_all
  end
end
