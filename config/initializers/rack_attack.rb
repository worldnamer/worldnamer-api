# Throttling. Each login attempt costs a bcrypt comparison (about 250 ms of CPU at cost 12) and the app has one vCPU,
# so POST /api/v1/session is limited to 10 requests a minute per IP. Nothing else is throttled yet (the health
# endpoints run SELECT 1 per request; that is for the later pass).

# Counters live in a dedicated in-process store. Rails.cache is Solid Cache in production (a database write per hit,
# on the same database the flood is aimed at) and a null store in test and usually in development. Trade-off: the
# count is per Puma process, so running several workers or instances multiplies the real limit. Specs replace this
# store per example (spec/support/rack_attack.rb).
Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new

# The route also answers /api/v1/session.json, so match the path with an optional format and trailing slash.
LOGIN_PATH = %r{\A/api/v1/session(\.\w+)?/?\z}

Rack::Attack.throttle("logins/ip", limit: 10, period: 60) do |request|
  request.ip if request.post? && LOGIN_PATH.match?(request.path)
end

Rack::Attack.throttled_responder = lambda do |request|
  period = request.env["rack.attack.match_data"][:period]
  body = { error: { code: "rate_limited", message: "Too many attempts. Try again in a few minutes." } }.to_json
  [ 429, { "Content-Type" => "application/json", "Retry-After" => period.to_s, "Cache-Control" => "no-store" }, [ body ] ]
end
