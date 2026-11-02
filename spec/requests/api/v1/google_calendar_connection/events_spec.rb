require "rails_helper"

RSpec.describe "GET /api/v1/google_calendar_connection/events", type: :request do
  let!(:user) { create(:user, username: "john") }
  let(:path) { "/api/v1/google_calendar_connection/events" }
  let(:now) { Time.utc(2026, 11, 1, 16, 41, 7) }

  before { travel_to(now) }
  after { travel_back }

  def token_for(account = user)
    login(username: account.username)
    response.parsed_body.fetch("access_token")
  end

  def get_events(account = user, params: {})
    get path, params: params, headers: bearer(token_for(account))
  end

  def expect_status_only(status)
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq("google_calendar_connection" => { "status" => status }, "events" => nil)
  end

  def expect_google_unavailable
    expect(response).to have_http_status(:bad_gateway)
    expect(response.parsed_body).to eq("error" => { "code" => "google_unavailable", "message" => "Couldn't reach Google Calendar." })
  end

  def connect(account = user, **attributes)
    create(:google_calendar_connection, user: account, **attributes)
  end

  it "returns 401 unauthenticated with no token, a malformed token or an expired token, without calling Google" do
    connect

    get path
    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body).to match(expected_unauthenticated_body)

    get path, headers: bearer("this.is.notajwt")
    expect(response).to have_http_status(:unauthorized)

    token = token_for
    travel_to(now + 16.minutes)
    get path, headers: bearer(token)
    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body).to match(expected_unauthenticated_body)
    expect(a_request(:any, /googleapis\.com/)).not_to have_been_made
  end

  it "is not_connected with events: null and no call to Google when there is no connection" do
    get_events

    expect_status_only("not_connected")
    expect(a_request(:any, /googleapis\.com/)).not_to have_been_made
  end

  it "is lost with events: null and no call to Google when the connection is lost" do
    connect(refresh_token: nil, lost_at: 1.day.ago)

    get_events

    expect_status_only("lost")
    expect(a_request(:any, /googleapis\.com/)).not_to have_been_made
  end

  describe "connected" do
    let!(:connection) { connect(refresh_token: "1//stored") }

    it "mints one access token and lists the primary calendar once, with the exact window and bearer header" do
      tokens = stub_request(:post, google_token_endpoint)
        .with(body: hash_including("grant_type" => "refresh_token", "refresh_token" => "1//stored"))
        .to_return(status: 200, body: { access_token: "ya29.minted" }.to_json)
      events = stub_request(:get, google_events_endpoint)
        .with(
          query: {
            "timeMin" => "2026-10-30T10:00:00Z",
            "timeMax" => "2026-11-03T12:00:00Z",
            "singleEvents" => "true",
            "orderBy" => "startTime",
            "showDeleted" => "false",
            "maxResults" => "250",
            "fields" => "nextPageToken,items(id,status,summary,start,end,eventType,attendees(self,responseStatus))"
          },
          headers: { "Authorization" => "Bearer ya29.minted" }
        )
        .to_return(status: 200, body: { items: [] }.to_json)

      get_events

      expect(response).to have_http_status(:ok)
      expect(tokens).to have_been_requested.once
      expect(events).to have_been_requested.once
    end

    it "answers the status with the normalized events and the time of Google's answer" do
      stub_google_tokens
      stub_google_events([
        google_all_day_event(id: "abc", summary: "Holiday", start: "2026-11-01", finish: "2026-11-02"),
        google_timed_event(id: "def_20261101T150000Z", summary: "Dentist",
          start: "2026-11-01T09:00:00-06:00", finish: "2026-11-01T10:00:00-07:00")
      ])

      get_events

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq(
        "google_calendar_connection" => { "status" => "connected" },
        "events" => {
          "fetched_at" => "2026-11-01T16:41:07Z",
          "items" => [
            { "id" => "abc", "title" => "Holiday", "all_day" => true,
              "starts_on" => "2026-11-01", "ends_on" => "2026-11-02", "starts_at" => nil, "ends_at" => nil },
            { "id" => "def_20261101T150000Z", "title" => "Dentist", "all_day" => false,
              "starts_on" => nil, "ends_on" => nil,
              "starts_at" => "2026-11-01T09:00:00-06:00", "ends_at" => "2026-11-01T10:00:00-07:00" }
          ]
        }
      )
    end

    it "leaves out cancelled, declined and working-location entries, gives a null title, and passes on nothing else" do
      stub_google_tokens
      stub_google_events([
        google_timed_event(id: "kept", summary: nil, start: "2026-11-01T09:00:00Z", finish: "2026-11-01T10:00:00Z",
          description: "Leaky description", location: "Leaky street",
          attendees: [ { self: true, responseStatus: "accepted", email: "leaky@example.com" } ]),
        google_timed_event(id: "cancelled", summary: "Gone", start: "2026-11-01T09:00:00Z", finish: "2026-11-01T10:00:00Z",
          status: "cancelled"),
        google_timed_event(id: "declined", summary: "Nope", start: "2026-11-01T09:00:00Z", finish: "2026-11-01T10:00:00Z",
          attendees: [ { self: true, responseStatus: "declined" } ]),
        google_all_day_event(id: "home", summary: "Home", start: "2026-11-01", finish: "2026-11-02",
          eventType: "workingLocation")
      ])

      get_events

      items = response.parsed_body.dig("events", "items")
      expect(items.map { |item| item["id"] }).to eq([ "kept" ])
      expect(items.first["title"]).to be_nil
      expect(items.first.keys).to match_array(%w[id title all_day starts_on ends_on starts_at ends_at])
      expect(response.body).not_to include("Leaky", "leaky")
    end

    it "answers items: [] when Google has no events, and when every event was filtered out" do
      stub_google_tokens
      stub_google_events([])
      get_events
      expect(response.parsed_body.dig("events", "items")).to eq([])

      stub_google_events([
        google_timed_event(id: "x", summary: "Gone", start: "2026-11-01T09:00:00Z", finish: "2026-11-01T10:00:00Z", status: "cancelled")
      ])
      get_events
      expect(response.parsed_body.dig("events", "items")).to eq([])
    end

    it "ignores any parameters" do
      stub_google_tokens
      stub = stub_google_events([])

      get_events(params: { calendarId: "someone-else@example.com", timeMin: "2000-01-01T00:00:00Z" })

      expect(response).to have_http_status(:ok)
      expect(stub).to have_been_requested.once
      expect(a_request(:get, /someone-else|2000-01-01/)).not_to have_been_made
    end

    it "sends Cache-Control: no-store on every answer" do
      stub_google_tokens
      stub_google_events([])
      get_events
      expect(response.headers["Cache-Control"]).to eq("no-store")

      stub_google_token_server_error
      get_events
      expect(response.headers["Cache-Control"]).to eq("no-store")

      connection.update!(refresh_token: nil, lost_at: Time.current)
      get_events
      expect(response.headers["Cache-Control"]).to eq("no-store")
    end

    it "stores a rotated refresh token" do
      stub_google_tokens(refresh_token: "1//rotated")
      stub_google_events([])

      get_events

      expect(response).to have_http_status(:ok)
      expect(connection.reload.refresh_token).to eq("1//rotated")
    end

    it "is lost on invalid_grant, marking the connection lost without listing events" do
      stub_google_token_error("invalid_grant")

      get_events

      expect_status_only("lost")
      connection.reload
      expect(connection.refresh_token).to be_nil
      expect(connection.lost_at).to be_present
      expect(a_request(:get, /#{Regexp.escape(google_events_endpoint)}/)).not_to have_been_made
    end

    it "answers 502 and keeps the new connection when the user reconnected while invalid_grant was on its way" do
      stub_request(:post, google_token_endpoint).to_return do
        GoogleCalendarConnection.find(connection.id).update!(refresh_token: "1//after-reconnect", connected_at: 1.second.from_now)
        { status: 400, body: { error: "invalid_grant" }.to_json }
      end

      get_events

      expect_google_unavailable
      stored = GoogleCalendarConnection.find(connection.id)
      expect(stored.refresh_token).to eq("1//after-reconnect")
      expect(stored.lost_at).to be_nil
    end

    {
      "a token timeout" => -> { stub_google_token_timeout },
      "a token 5xx" => -> { stub_google_token_server_error },
      "invalid_client" => -> { stub_google_token_error("invalid_client", status: 401) }
    }.each do |failure, stub|
      it "answers 502 google_unavailable, does not list events and changes nothing after #{failure}" do
        instance_exec(&stub)

        expect { get_events }.not_to change { GoogleCalendarConnection.find(connection.id).attributes }
        expect_google_unavailable
        expect(a_request(:get, /#{Regexp.escape(google_events_endpoint)}/)).not_to have_been_made
      end
    end

    {
      "an events timeout" => -> { stub_request(:get, google_events_endpoint).with(query: hash_including({})).to_timeout },
      "an events 401" => -> { stub_google_events_error(401, "authError") },
      "an events 403" => -> { stub_google_events_error(403, "insufficientPermissions") },
      "an events 429" => -> { stub_google_events_error(429, "rateLimitExceeded") },
      "an events 5xx" => -> { stub_google_events_error(503, "backendError") },
      "events that are not JSON" => -> {
        stub_request(:get, google_events_endpoint).with(query: hash_including({})).to_return(status: 200, body: "{\"items\": [")
      }
    }.each do |failure, stub|
      it "answers 502 google_unavailable, tries the GET once and changes nothing after #{failure}" do
        stub_google_tokens
        instance_exec(&stub)

        expect { get_events }.not_to change { GoogleCalendarConnection.find(connection.id).attributes }
        expect_google_unavailable
        expect(a_request(:get, /#{Regexp.escape(google_events_endpoint)}/)).to have_been_made.once
      end
    end

    it "fails with a server error, not lost, when the stored token cannot be decrypted" do
      ActiveRecord::Base.connection.execute(
        "UPDATE google_calendar_connections SET refresh_token = 'not-ciphertext' WHERE id = #{Integer(connection.id)}"
      )
      token = token_for

      expect { get path, headers: bearer(token) }.to raise_error(ActiveRecord::Encryption::Errors::Decryption)
      expect(connection.reload.lost_at).to be_nil
    end
  end

  describe "isolation" do
    let(:other) { create(:user, username: "bea") }

    it "answers only for the caller: user B never sees user A's events or touches A's connection" do
      a_connection = connect(refresh_token: "1//a-token")

      get_events(other)
      expect_status_only("not_connected")
      expect(a_request(:any, /googleapis\.com/)).not_to have_been_made

      connect(other, refresh_token: "1//b-token")
      stub_request(:post, google_token_endpoint)
        .with(body: hash_including("refresh_token" => "1//a-token"))
        .to_return(status: 200, body: { access_token: "ya29.for-a" }.to_json)
      stub_request(:post, google_token_endpoint)
        .with(body: hash_including("refresh_token" => "1//b-token"))
        .to_return(status: 200, body: { access_token: "ya29.for-b" }.to_json)
      stub_google_events([ google_all_day_event(id: "a", summary: "A's day", start: "2026-11-01", finish: "2026-11-02") ],
        access_token: "ya29.for-a")
      stub_google_events([ google_all_day_event(id: "b", summary: "B's day", start: "2026-11-01", finish: "2026-11-02") ],
        access_token: "ya29.for-b")

      get_events(other)

      expect(response.parsed_body.dig("events", "items").map { |item| item["title"] }).to eq([ "B's day" ])
      expect(response.body).not_to include("A's day")
      expect(a_connection.reload.refresh_token).to eq("1//a-token")
    end
  end
end
