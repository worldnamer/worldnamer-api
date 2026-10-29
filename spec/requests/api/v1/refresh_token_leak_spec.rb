require "rails_helper"

# api-2 additions to plan section 6, scenarios 14, 15 and 16: besides the sentinel
# password, the RAW refresh token must not reach the Rails log, OpenTelemetry spans,
# Sentry events or the database (only its SHA256 digest is stored).
#
# Uses the same support helpers as session_leak_spec.rb (captured_spans,
# captured_sentry_events). Each example first gets a real token, then runs the
# request under test, so that the spec knows the exact string to look for.
RSpec.describe "Refresh token leak checks on login, refresh and logout", type: :request do
  let(:sentinel_password) { "SENTINEL-pw-2b6d8e04-do-not-leak" }
  let!(:user) { create(:user, username: "john", password: sentinel_password) }

  def dump_spans(spans)
    spans.map do |span|
      {
        name: span.name,
        attributes: span.attributes,
        events: Array(span.events).map { |event| { name: event.name, attributes: event.attributes } }
      }
    end.inspect
  end

  def request_logging
    io = StringIO.new
    capture_logger = ActiveSupport::Logger.new(io)
    Rails.logger.broadcast_to(capture_logger)
    yield
    io.string
  ensure
    Rails.logger.stop_broadcasting_to(capture_logger)
  end

  # Runs login, a refresh, a grace-path refresh and logout; returns every raw token seen.
  def full_session_flow
    tokens = []
    login(password: sentinel_password)
    first = refresh_token_from
    tokens << first
    refresh(first)
    second = refresh_token_from
    tokens << second
    refresh(first) # grace path, no cookie
    logout(second)
    tokens
  end

  describe "the database" do
    it "never holds the raw token anywhere, only its SHA256 digest" do
      login(password: sentinel_password)
      token = refresh_token_from
      refresh(token)
      new_token = refresh_token_from

      dump = RefreshToken.connection.select_all("SELECT * FROM refresh_tokens").to_a.inspect
      expect(dump).not_to include(token)
      expect(dump).not_to include(new_token)
      expect(dump).to include(digest_of(token))
      expect(dump).to include(digest_of(new_token))
    end
  end

  describe "scenario 14: Rails log" do
    it "holds no raw refresh token and no password through login, refresh, grace refresh and logout" do
      tokens = nil
      log = request_logging { tokens = full_session_flow }

      expect(tokens.size).to eq(2)
      expect(tokens).to all(be_present)
      expect(tokens.uniq.size).to eq(2)
      # Non-vacuous: all four requests were logged.
      expect(log).to include("Started POST \"/api/v1/session\"")
      expect(log.scan("/api/v1/session/refresh").size).to be >= 2
      expect(log).to include("Started DELETE \"/api/v1/session\"")
      expect(log).to include("[FILTERED]")

      tokens.each { |token| expect(log).not_to include(token) }
      expect(log).not_to include(sentinel_password)
    end

    it "holds no raw token on the failure paths either (reuse, unknown cookie)" do
      login
      first = refresh_token_from
      refresh(first)
      travel 31.seconds
      log = request_logging do
        refresh(first)                       # reuse past grace
        refresh("unknown-cookie-value-1234") # unknown token
      end

      expect(response).to have_http_status(:unauthorized)
      expect(log).to include("/api/v1/session/refresh") # non-vacuous
      expect(log).not_to include(first)
      expect(log).not_to include("unknown-cookie-value-1234")
    end
  end

  describe "scenario 15: OpenTelemetry spans" do
    it "records spans for login, refresh and logout, none holding a raw token or the password" do
      tokens = full_session_flow

      spans = captured_spans
      dump = dump_spans(spans)
      expect(spans).not_to be_empty
      # Non-vacuous: every endpoint was traced.
      expect(dump).to include("/api/v1/session/refresh")
      expect(spans.map(&:attributes).compact.map(&:to_s).join).to include("DELETE")
      expect(spans.map(&:attributes).compact.map(&:to_s).join).to include("POST")

      tokens.each { |token| expect(dump).not_to include(token) }
      expect(dump).not_to include(sentinel_password)
    end

    it "holds no raw token in database spans (SQL is obfuscated, digests are the only stored form)" do
      tokens = full_session_flow

      db_spans = captured_spans.select { |span| span.attributes&.key?("db.system") || span.attributes&.key?("db.system.name") }
      expect(db_spans).not_to be_empty
      expect(db_spans.map(&:attributes).map(&:to_s).join).to match(/refresh_tokens/) # the table was really queried
      tokens.each { |token| expect(dump_spans(db_spans)).not_to include(token) }
    end

    it "does not record the Cookie or Set-Cookie headers" do
      full_session_flow

      dump = dump_spans(captured_spans)
      expect(dump).not_to match(/wn_refresh/)
    end
  end

  describe "scenario 16: Sentry" do
    it "captures an error forced during refresh, holding no raw token and no password" do
      login(password: sentinel_password)
      token = refresh_token_from
      allow_any_instance_of(Warden::JWTAuth::UserEncoder).to receive(:call).and_raise(RuntimeError, "forced refresh failure")

      begin
        refresh(token)
      rescue RuntimeError
        # Rails re-raises in the test environment; Sentry's middleware captured it first.
      end

      events = captured_sentry_events
      expect(events).not_to be_empty
      dump = events.map(&:to_h).inspect
      expect(dump).to include("forced refresh failure")
      expect(dump).not_to include(token)
      expect(dump).not_to include(sentinel_password)
      expect(dump).not_to include(digest_of(token)) # nothing token-derived either
    end

    it "captures an error forced during login with an existing cookie, holding no raw token and no password" do
      login(password: sentinel_password)
      token = refresh_token_from
      allow_any_instance_of(Warden::JWTAuth::UserEncoder).to receive(:call).and_raise(RuntimeError, "forced login failure")

      begin
        login(password: sentinel_password) # the browser still holds the cookie
      rescue RuntimeError
        # see above
      end

      events = captured_sentry_events
      expect(events).not_to be_empty
      dump = events.map(&:to_h).inspect
      expect(dump).to include("forced login failure")
      expect(dump).not_to include(token)
      expect(dump).not_to include(sentinel_password)
    end
  end
end
