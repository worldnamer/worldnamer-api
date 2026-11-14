require "rails_helper"

# Google's one-time code, the OAuth state, the PKCE verifier, the refresh and access tokens and the client secret must
# never reach the Rails log, OpenTelemetry spans, Sentry events, the callback's response body or its Location header
# during a YouTube sign-in. Each check first asserts that something really was captured, so an empty capture cannot
# pass.
#
# The callback path is deliberately not traced (the code and state are in its query string), so the span checks prove
# tracing was live through the sign-in start in the same example.
RSpec.describe "Code and state leak checks on the YouTube sign-in", type: :request do
  let(:code) { "4/SENTINEL-yt-code-2b7a-do-not-leak" }
  let(:refresh_token) { "1//SENTINEL-yt-callback-refresh-e413-do-not-leak" }
  let(:access_token) { "ya29.SENTINEL-yt-callback-access-91cf-do-not-leak" }
  let(:client_secret) { ENV.fetch("GOOGLE_CLIENT_SECRET") }
  let(:callback_path) { "/api/v1/youtube_connection/callback" }

  let!(:user) { create(:user, username: "john") }

  # Filled in by start_sign_in: the raw state and the verifier are random, so the spec learns them as they are made.
  let(:secrets) { { code: code, refresh_token: refresh_token, access_token: access_token, client_secret: client_secret } }

  before do
    stub_google_tokens(access_token: access_token, refresh_token: refresh_token, scope: Youtube::Oauth::SCOPE)
  end

  def start_sign_in
    login(username: "john")
    post "/api/v1/youtube_connection/authorization", headers: bearer(response.parsed_body.fetch("access_token"))
    state = URI.decode_www_form(URI(response.parsed_body.fetch("authorization_url")).query).to_h.fetch("state")
    secrets[:state] = state
    secrets[:code_verifier] = YoutubeOauthState.find_by!(user: user).code_verifier
    state
  end

  def complete_sign_in(state)
    get callback_path, params: { code: code, state: state }
  end

  def expect_no_secret_in(text)
    expect(secrets.keys).to include(:state, :code_verifier) # the random ones were captured
    expect_none_of(secrets.values, text)
  end

  describe "the Rails log" do
    it "filters the code and state from the callback's request line and parameters" do
      log = request_logging { complete_sign_in(start_sign_in) }

      expect(YoutubeConnection.find_by!(user: user).refresh_token).to eq(refresh_token) # the sign-in worked
      expect(log).to include("Started GET \"#{callback_path}?code=[FILTERED]&state=[FILTERED]\"")
      expect(log).to match(/Parameters: \{.*"code" => "\[FILTERED\]".*"state" => "\[FILTERED\]"/)
      expect(log).to include("Redirected to http://localhost:5173/youtube?youtube=connected")
      expect_no_secret_in(log)
    end

    it "keeps them out on a failed callback too" do
      state = start_sign_in
      stub_google_token_error("invalid_grant")

      log = request_logging { complete_sign_in(state) }

      expect(log).to include("Started GET \"#{callback_path}?code=[FILTERED]&state=[FILTERED]\"")
      expect(log).to include("youtube=failed")
      expect_no_secret_in(log)
    end
  end

  describe "OpenTelemetry spans" do
    it "records the sign-in start, holding none of them, and nothing at all for the callback" do
      state = start_sign_in
      start_dump = dump_spans
      TelemetryHelpers.reset

      complete_sign_in(state)
      callback_spans = captured_spans.dup # before the spec's own queries below add spans

      # Non-vacuous: tracing is live in this example and recorded the start, and the callback really ran.
      expect(start_dump).to include("/api/v1/youtube_connection/authorization")
      expect(start_dump).to include("youtube_oauth_states")
      expect(YoutubeConnection.find_by!(user: user).refresh_token).to eq(refresh_token)
      expect_no_secret_in(start_dump)
      # The callback, its SQL and its call to Google left no span.
      expect(callback_spans).to be_empty
    end

    it "leaves no span for a failed callback either" do
      state = start_sign_in
      TelemetryHelpers.reset

      get callback_path, params: { code: code, state: "#{state}-wrong" }

      expect(response.headers["Location"]).to eq("http://localhost:5173/youtube?youtube=failed")
      expect(captured_spans).to be_empty
    end

    it "matches only the exact callback path" do
      filter = OpenTelemetry::Instrumentation::Rack::Instrumentation.instance.config[:untraced_requests]

      expect(filter.call("PATH_INFO" => callback_path)).to be(true)
      expect(filter.call("PATH_INFO" => "/api/v1/youtube_connection")).to be(false)
      expect(filter.call("PATH_INFO" => "#{callback_path}/extra")).to be(false)
    end
  end

  describe "Sentry" do
    it "keeps them out of an event for an error forced during the code exchange" do
      state = start_sign_in
      allow_any_instance_of(GoogleCalendar::OauthClient).to receive(:exchange_code).and_wrap_original do |original, **kwargs|
        original.call(**kwargs) # Google really answers with the tokens first
        raise "forced youtube exchange failure"
      end

      begin
        complete_sign_in(state)
      rescue RuntimeError
        # Rails re-raises in the test environment; Sentry's middleware captured it first.
      end

      dump = dump_sentry_events
      expect(dump).to include("forced youtube exchange failure")
      expect(dump).to include(callback_path)
      expect_no_secret_in(dump)
    end

    it "keeps them out of an event for an error forced while storing the connection" do
      state = start_sign_in
      allow(YoutubeConnection).to receive(:connect!).and_raise(RuntimeError, "forced youtube store failure")

      begin
        complete_sign_in(state)
      rescue RuntimeError
        # see above
      end

      dump = dump_sentry_events
      expect(dump).to include("forced youtube store failure")
      expect_no_secret_in(dump)
    end
  end

  describe "the callback response" do
    it "holds none of them in the body or the Location header" do
      complete_sign_in(start_sign_in)

      expect(response).to have_http_status(:see_other)
      expect(response.headers["Location"]).to eq("http://localhost:5173/youtube?youtube=connected")
      expect_no_secret_in(response.body)
      expect_no_secret_in(response.headers["Location"])
    end
  end
end
