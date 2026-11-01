require "rails_helper"

# Google's one-time code, the OAuth state, the PKCE verifier, the refresh and access tokens and the client secret must
# never reach the Rails log, OpenTelemetry spans, Sentry events, the callback's response body or its Location header.
# Each check first asserts that something really was captured, so an empty capture cannot pass.
#
# The callback path is deliberately not traced (the code and state are in its query string), so the span checks prove
# tracing was live through the sign-in start in the same example, and show separately that a traced path does record
# its query string.
RSpec.describe "Code and state leak checks on the Google Calendar sign-in", type: :request do
  let(:code) { "4/SENTINEL-code-0f6e-do-not-leak" }
  let(:refresh_token) { "1//SENTINEL-callback-refresh-71d2-do-not-leak" }
  let(:access_token) { "ya29.SENTINEL-callback-access-b9c4-do-not-leak" }
  let(:client_secret) { ENV.fetch("GOOGLE_CLIENT_SECRET") }
  let(:callback_path) { "/api/v1/google_calendar_connection/callback" }

  let!(:user) { create(:user, username: "john") }

  # Filled in by start_sign_in: the raw state and the verifier are random, so the spec learns them as they are made.
  let(:secrets) { { code: code, refresh_token: refresh_token, access_token: access_token, client_secret: client_secret } }

  before do
    stub_google_tokens(access_token: access_token, refresh_token: refresh_token)
  end

  def start_sign_in
    login(username: "john")
    post "/api/v1/google_calendar_connection/authorization", headers: bearer(response.parsed_body.fetch("access_token"))
    state = URI.decode_www_form(URI(response.parsed_body.fetch("authorization_url")).query).to_h.fetch("state")
    secrets[:state] = state
    secrets[:code_verifier] = GoogleOauthState.find_by!(user: user).code_verifier
    state
  end

  def complete_sign_in(state)
    get callback_path, params: { code: code, state: state }
  end

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

  def expect_no_secret_in(text)
    expect(secrets.keys).to include(:state, :code_verifier) # the random ones were captured
    secrets.each { |name, value| expect(text).not_to include(value), "#{name} leaked" }
  end

  describe "the Rails log" do
    it "filters the code and state from the callback's request line and parameters" do
      log = request_logging { complete_sign_in(start_sign_in) }

      expect(GoogleCalendarConnection.find_by!(user: user).refresh_token).to eq(refresh_token) # the sign-in worked
      # Non-vacuous: the callback was logged with its query string and parameters, filtered.
      expect(log).to include("Started GET \"#{callback_path}?code=[FILTERED]&state=[FILTERED]\"")
      expect(log).to match(/Parameters: \{.*"code" => "\[FILTERED\]".*"state" => "\[FILTERED\]"/)
      expect(log).to include("Redirected to http://localhost:5173/?google_calendar=connected")
      expect_no_secret_in(log)
    end

    it "keeps them out on a failed callback too" do
      state = start_sign_in
      stub_google_token_error("invalid_grant")

      log = request_logging { complete_sign_in(state) }

      expect(log).to include("Started GET \"#{callback_path}?code=[FILTERED]&state=[FILTERED]\"")
      expect(log).to include("google_calendar=failed")
      expect_no_secret_in(log)
    end
  end

  describe "OpenTelemetry spans" do
    it "records the sign-in start, holding none of them, and nothing at all for the callback" do
      state = start_sign_in
      start_dump = dump_spans(captured_spans)
      TelemetryHelpers.reset

      complete_sign_in(state)
      callback_spans = captured_spans.dup # before the spec's own queries below add spans

      # Non-vacuous: tracing is live in this example and recorded the start, and the callback really ran.
      expect(start_dump).to include("/api/v1/google_calendar_connection/authorization")
      expect(start_dump).to include("google_oauth_states")
      expect(GoogleCalendarConnection.find_by!(user: user).refresh_token).to eq(refresh_token)
      expect_no_secret_in(start_dump)
      # The callback, its SQL and its call to Google left no span.
      expect(callback_spans).to be_empty
    end

    it "lists the callback as an untraced endpoint of the Rack instrumentation" do
      config = OpenTelemetry::Instrumentation::Rack::Instrumentation.instance.config
      expect(config[:untraced_endpoints]).to eq([ callback_path ])
    end

    # The Rack instrumentation records the raw query string as url.query when the request starts; the ActionPack
    # instrumentation later replaces it with Rails' filtered query if a controller action runs. Without the untraced
    # entry, the parameter filters alone would stand between the code and Honeycomb.
    it "would otherwise record the query string: a traced path keeps url.query" do
      login(username: "john")
      token = response.parsed_body.fetch("access_token")
      TelemetryHelpers.reset

      get "/api/v1/google_calendar_connection?probe=query-string-is-recorded", headers: bearer(token)

      rack_span = captured_spans.find { |span| span.attributes&.dig("url.path") == "/api/v1/google_calendar_connection" }
      expect(rack_span).to be_present
      expect(rack_span.attributes["url.query"]).to eq("probe=query-string-is-recorded")
    end
  end

  describe "Sentry" do
    it "keeps them out of an event for an error forced during the code exchange" do
      state = start_sign_in
      allow_any_instance_of(GoogleCalendar::OauthClient).to receive(:exchange_code).and_wrap_original do |original, **kwargs|
        original.call(**kwargs) # Google really answers with the tokens first
        raise "forced exchange failure"
      end

      begin
        complete_sign_in(state)
      rescue RuntimeError
        # Rails re-raises in the test environment; Sentry's middleware captured it first.
      end

      events = captured_sentry_events
      expect(events).not_to be_empty
      dump = events.map(&:to_h).inspect
      expect(dump).to include("forced exchange failure") # non-vacuous: our error, with content
      expect(dump).to include(callback_path)              # and the request it came from
      expect_no_secret_in(dump)
    end

    it "keeps them out of an event for an error forced while storing the connection" do
      state = start_sign_in
      allow(GoogleCalendarConnection).to receive(:connect!).and_raise(RuntimeError, "forced store failure")

      begin
        complete_sign_in(state)
      rescue RuntimeError
        # see above
      end

      events = captured_sentry_events
      expect(events).not_to be_empty
      dump = events.map(&:to_h).inspect
      expect(dump).to include("forced store failure")
      expect_no_secret_in(dump)
    end
  end

  describe "the callback response" do
    it "holds none of them in the body or the Location header" do
      complete_sign_in(start_sign_in)

      expect(response).to have_http_status(:see_other)
      expect(response.headers["Location"]).to eq("http://localhost:5173/?google_calendar=connected")
      expect_no_secret_in(response.body)
      expect_no_secret_in(response.headers["Location"])
    end
  end
end
