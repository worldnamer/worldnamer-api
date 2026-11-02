require "rails_helper"

# An event's title and description, Google's access and refresh tokens, and this app's client secret must never reach
# the Rails log, OpenTelemetry spans (the outgoing call to Google included) or Sentry events while the Today card's
# events are fetched. The title is meant to reach the response body; nothing else here is. Every check first asserts
# that the request really was logged, traced or reported, so an empty capture cannot pass.
#
# Google's answer here deliberately includes a description, which the fields filter would stop Google sending, to show
# that the server drops it even if it arrives.
RSpec.describe "Leak checks on GET /api/v1/google_calendar_connection/events", type: :request do
  let(:title) { "SENTINEL-title-4b7e-do-not-leak" }
  let(:description) { "SENTINEL-description-81fa-do-not-leak" }
  let(:stored_refresh_token) { "1//SENTINEL-stored-refresh-6c2d-do-not-leak" }
  let(:rotated_refresh_token) { "1//SENTINEL-rotated-refresh-0e95-do-not-leak" }
  let(:access_token) { "ya29.SENTINEL-access-73d1-do-not-leak" }
  let(:client_secret) { ENV.fetch("GOOGLE_CLIENT_SECRET") }
  let(:secrets) { [ description, stored_refresh_token, rotated_refresh_token, access_token, client_secret ] }
  let(:sentinels) { [ title, *secrets ] }

  let(:google_items) do
    [ google_timed_event(id: "evt1", summary: title, description: description,
      start: "2026-11-01T09:00:00-06:00", finish: "2026-11-01T10:00:00-06:00") ]
  end

  let!(:user) { create(:user, username: "john") }
  let!(:connection) { create(:google_calendar_connection, user: user, refresh_token: stored_refresh_token) }
  let!(:bearer_token) do
    login(username: "john")
    response.parsed_body.fetch("access_token")
  end

  before do
    stub_google_tokens(access_token: access_token, refresh_token: rotated_refresh_token)
    stub_google_events(google_items, access_token: access_token)
    TelemetryHelpers.reset # drop the login's spans
  end

  def fetch_events
    get "/api/v1/google_calendar_connection/events", headers: bearer(bearer_token)
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

  def expect_none_of(values, text)
    values.each { |value| expect(text).not_to include(value) }
  end

  it "keeps the title, description and tokens out of the Rails log" do
    log = request_logging { fetch_events }

    expect(response).to have_http_status(:ok)
    # Non-vacuous: the request and the token rotation's SQL were logged, and the title really was fetched.
    expect(log).to include("Started GET \"/api/v1/google_calendar_connection/events\"")
    expect(log).to include("Completed 200")
    expect(log).to match(/UPDATE "google_calendar_connections"/)
    expect(response.body).to include(title)
    expect_none_of(sentinels, log)
  end

  it "keeps them out of a failure's log line" do
    stub_request(:get, google_events_endpoint).with(query: hash_including({})).to_return(
      status: 403, body: { error: { code: 403, message: "#{title} #{access_token}", errors: [ { reason: "forbidden" } ] } }.to_json
    )

    log = request_logging { fetch_events }

    expect(response).to have_http_status(:bad_gateway)
    expect(log).to include("Google Calendar events unavailable: GoogleCalendar::EventsClient::Error status=403")
    expect_none_of(sentinels, log)
  end

  it "keeps them out of the spans" do
    fetch_events

    dump = dump_spans(captured_spans)
    # Non-vacuous: the request and its SQL were traced.
    expect(dump).to include("/api/v1/google_calendar_connection/events")
    expect(dump).to include("google_calendar_connections")
    expect_none_of(sentinels, dump)
  end

  # WebMock answers stubbed requests before Net::HTTP sends anything, so the Net::HTTP instrumentation records no span
  # for them. Here Events: list goes over a real socket to a local server playing Google, so the outgoing span is
  # recorded as in production. Its target holds the query (the window and the fields filter), never the token, which
  # is in a header.
  it "keeps them out of the outgoing Net::HTTP span for Events: list" do
    received = nil
    with_local_http_server(->(_request) { local_json_response({ items: google_items }) }) do |base_url, requests|
      allow(GoogleCalendar::EventsClient).to receive(:new).and_wrap_original do |original|
        original.call(endpoint: URI("#{base_url}/calendar/v3/calendars/primary/events"))
      end

      fetch_events
      received = requests.pop
    end

    expect(response).to have_http_status(:ok)
    expect(received).to include("Authorization: Bearer #{access_token}") # the token really travelled, in a header
    outgoing = captured_spans.select { |span| span.kind == :client && span.attributes["server.address"] == "127.0.0.1" }
    expect(outgoing).not_to be_empty
    dump = dump_spans(outgoing)
    expect(dump).to include("/calendar/v3/calendars/primary/events", "timeMin")
    expect_none_of(sentinels, dump)
  end

  it "keeps them out of a Sentry event for an error forced after the events were fetched" do
    allow(GoogleCalendar::EventNormalizer).to receive(:call).and_wrap_original do |original, *args|
      original.call(*args) # the events really were fetched and normalized first
      raise "forced events failure"
    end

    begin
      fetch_events
    rescue RuntimeError
      # Rails re-raises in the test environment; Sentry's middleware captured it first.
    end

    expect(a_request(:get, /#{Regexp.escape(google_events_endpoint)}/)).to have_been_made.once
    events = captured_sentry_events
    expect(events).not_to be_empty
    dump = events.map(&:to_h).inspect
    expect(dump).to include("forced events failure") # non-vacuous: our error, with content
    expect_none_of(sentinels, dump)
  end

  it "keeps them out of a Sentry event when a client error escapes unrescued, even if Google's body quotes them" do
    stub_request(:get, google_events_endpoint).with(query: hash_including({})).to_return(
      status: 500, body: { error: { message: "#{title} #{description} #{access_token}" } }.to_json
    )
    # Let the client's error escape instead of answering 502, so Sentry reports it. $! is the error being rescued.
    allow_any_instance_of(Api::V1::GoogleCalendarConnections::EventsController)
      .to receive(:render_google_unavailable) { raise $! }

    begin
      fetch_events
    rescue GoogleCalendar::EventsClient::Error
      # see above
    end

    events = captured_sentry_events
    expect(events).not_to be_empty
    dump = events.map(&:to_h).inspect
    expect(dump).to include("Google Calendar answered 500")
    expect_none_of(sentinels, dump)
  end

  it "keeps the description and the tokens out of the response body, which holds the title" do
    fetch_events

    expect(response.parsed_body.dig("events", "items", 0, "title")).to eq(title)
    expect_none_of(secrets, response.body)
  end
end
