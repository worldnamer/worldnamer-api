require "rails_helper"

# Google's refresh and access tokens, and this app's client secret, must never reach the Rails log, OpenTelemetry
# spans, Sentry events or the response body during a status check. Every check first asserts that the request really
# was logged, traced or reported, so an empty capture cannot pass.
#
# The client secret is set for the whole suite in spec/rails_helper.rb. captured_spans and captured_sentry_events come
# from spec/support/telemetry_helpers.rb.
RSpec.describe "Google token leak checks on GET /api/v1/google_calendar_connection", type: :request do
  let(:stored_refresh_token) { "1//SENTINEL-stored-refresh-9a41-do-not-leak" }
  let(:rotated_refresh_token) { "1//SENTINEL-rotated-refresh-3e07-do-not-leak" }
  let(:access_token) { "ya29.SENTINEL-access-c2b8-do-not-leak" }
  let(:client_secret) { ENV.fetch("GOOGLE_CLIENT_SECRET") }
  let(:sentinels) { [ stored_refresh_token, rotated_refresh_token, access_token, client_secret ] }

  let!(:user) { create(:user, username: "john") }
  let!(:connection) { create(:google_calendar_connection, user: user, refresh_token: stored_refresh_token) }
  let!(:bearer_token) do
    login(username: "john")
    response.parsed_body.fetch("access_token")
  end

  before do
    stub_google_tokens(access_token: access_token, refresh_token: rotated_refresh_token)
    TelemetryHelpers.reset # drop the login's spans
  end

  def check_status
    get "/api/v1/google_calendar_connection", headers: bearer(bearer_token)
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

  def expect_no_sentinel_in(text)
    sentinels.each { |sentinel| expect(text).not_to include(sentinel) }
  end

  it "keeps the tokens and the client secret out of the Rails log" do
    log = request_logging { check_status }

    expect(response).to have_http_status(:ok)
    # Non-vacuous: the request and the token rotation's SQL were logged.
    expect(log).to include("Started GET \"/api/v1/google_calendar_connection\"")
    expect(log).to include("Completed 200")
    expect(log).to match(/UPDATE "google_calendar_connections"/)
    expect(connection.reload.refresh_token).to eq(rotated_refresh_token) # the rotation really happened
    expect_no_sentinel_in(log)
  end

  # WebMock replaces Net::HTTP's request method, so the Net::HTTP instrumentation records no span for the call to
  # Google here. In production that span holds the scheme, host, port, path and status only, never the form body
  # where the tokens and the secret travel.
  it "keeps the tokens and the client secret out of the spans" do
    check_status

    spans = captured_spans
    dump = dump_spans(spans)
    # Non-vacuous: the request and its SQL were traced.
    expect(dump).to include("/api/v1/google_calendar_connection")
    expect(dump).to include("google_calendar_connections")
    expect_no_sentinel_in(dump)
  end

  it "keeps the tokens and the client secret out of the response body" do
    check_status

    expect(response.parsed_body).to eq("google_calendar_connection" => { "status" => "connected" })
    expect_no_sentinel_in(response.body)
  end

  it "keeps them out of a Sentry event for an error forced during the check" do
    allow_any_instance_of(GoogleCalendar::OauthClient).to receive(:refresh_access_token).and_wrap_original do |original, *args|
      original.call(*args) # Google really answers with the tokens first
      raise "forced check failure"
    end

    begin
      check_status
    rescue RuntimeError
      # Rails re-raises in the test environment; Sentry's middleware captured it first.
    end

    events = captured_sentry_events
    expect(events).not_to be_empty
    dump = events.map(&:to_h).inspect
    expect(dump).to include("forced check failure") # non-vacuous: our error, with content
    expect_no_sentinel_in(dump)
  end

  it "keeps them out of a Sentry event when a client error escapes unrescued, even if Google's body quotes them" do
    stub_request(:post, google_token_endpoint)
      .to_return(status: 401, body: { error: "invalid_client", error_description: "#{client_secret} #{access_token}" }.to_json)
    # Let the client's error escape the check instead of being rescued, so Sentry reports it.
    allow_any_instance_of(GoogleCalendarConnection).to receive(:check) do
      GoogleCalendar::OauthClient.new.refresh_access_token(stored_refresh_token)
    end

    begin
      check_status
    rescue GoogleCalendar::OauthClient::Error
      # see above
    end

    events = captured_sentry_events
    expect(events).not_to be_empty
    dump = events.map(&:to_h).inspect
    expect(dump).to include("invalid_client")
    expect_no_sentinel_in(dump)
  end
end
