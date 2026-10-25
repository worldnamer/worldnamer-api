# Reports unhandled exceptions to Sentry. With no SENTRY_DSN set (specs, CI, local development) it stays off and
# sends nothing. Errors only: tracing, logs and replay are Honeycomb's and Rails' job, so they stay off.
# sentry-rails already ignores routine 404s such as ActionController::RoutingError (scanner probes).
if ENV["SENTRY_DSN"].present?
  Sentry.init do |config|
    config.dsn = ENV["SENTRY_DSN"]
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
  end
end
