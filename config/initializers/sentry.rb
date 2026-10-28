# Reports unhandled exceptions to Sentry. WorldnamerTelemetry.configure_sentry holds the one set of settings; only the
# DSN and transport differ by environment:
#
# - production and development: reports only when SENTRY_DSN is set. With no DSN (CI, local development) it stays off
#   and sends nothing.
# - test: always on, with a dummy DSN and Sentry's DummyTransport, which keeps events in memory and sends nothing, so
#   the leak specs check the real data_collection settings (spec/support/telemetry_helpers.rb reads the events).
#
# Errors only: tracing, logs and replay are Honeycomb's and Rails' job, so they stay off.
# sentry-rails already ignores routine 404s such as ActionController::RoutingError (scanner probes).
module WorldnamerTelemetry
  def self.configure_sentry(dsn:)
    Sentry.init do |config|
      config.dsn = dsn
      config.environment = Rails.env.to_s

      # sentry-ruby 7 collects user info, cookies, headers, bodies and query params unless told otherwise (the older
      # send_default_pii switch is deprecated). Turn all of that off: the stack trace and the error are what we need.
      config.data_collection.user_info = false
      config.data_collection.cookies = false
      config.data_collection.http_headers.request.mode = :off
      config.data_collection.http_headers.response.mode = :off
      config.data_collection.http_bodies = []
      config.data_collection.url_query_params = false
      config.data_collection.database_query_data = false

      yield config if block_given?
    end
  end
end

if Rails.env.test?
  WorldnamerTelemetry.configure_sentry(dsn: "http://12345:67890@sentry.localdomain/sentry/42") do |config|
    config.transport.transport_class = Sentry::DummyTransport
    # No background thread: the event is in the transport when the request returns.
    config.background_worker_threads = 0
  end
elsif ENV["SENTRY_DSN"].present?
  WorldnamerTelemetry.configure_sentry(dsn: ENV["SENTRY_DSN"])
end
