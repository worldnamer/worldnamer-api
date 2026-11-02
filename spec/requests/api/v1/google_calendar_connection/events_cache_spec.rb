require "rails_helper"

# The per-user minute of caching on GET /api/v1/google_calendar_connection/events. The store is replaced before every
# example (spec/support/google_calendar_events_cache.rb).
RSpec.describe "GET /api/v1/google_calendar_connection/events, cached", type: :request do
  let!(:user) { create(:user, username: "john") }
  let(:path) { "/api/v1/google_calendar_connection/events" }
  let(:start) { Time.utc(2026, 11, 1, 16, 41, 7) }
  let(:dentist) do
    google_timed_event(id: "e1", summary: "Dentist", start: "2026-11-01T09:00:00-06:00", finish: "2026-11-01T10:00:00-06:00")
  end
  let(:lunch) do
    google_timed_event(id: "e2", summary: "Lunch", start: "2026-11-01T12:00:00-06:00", finish: "2026-11-01T13:00:00-06:00")
  end

  before { travel_to(start) }
  after { travel_back }

  def get_events(account = user)
    login(username: account.username)
    get path, headers: bearer(response.parsed_body.fetch("access_token"))
  end

  def titles
    response.parsed_body.dig("events", "items").map { |item| item["title"] }
  end

  def google_requests
    a_request(:get, /#{Regexp.escape(google_events_endpoint)}/)
  end

  def token_requests
    a_request(:post, google_token_endpoint)
  end

  describe "connected" do
    let!(:connection) { create(:google_calendar_connection, user: user) }

    before { stub_google_tokens }

    it "answers a second request within a minute from the cache, repeating fetched_at, with no call to Google" do
      stub_google_events([ dentist ])
      get_events
      first_fetched_at = response.parsed_body.dig("events", "fetched_at")

      travel_to(start + 59.seconds)
      stub_google_events([ dentist, lunch ])
      get_events

      expect(response).to have_http_status(:ok)
      expect(titles).to eq([ "Dentist" ])
      expect(response.parsed_body.dig("events", "fetched_at")).to eq(first_fetched_at)
      expect(response.headers["Cache-Control"]).to eq("no-store")
      expect(token_requests).to have_been_made.once
      expect(google_requests).to have_been_made.once
    end

    it "asks Google again after 61 seconds" do
      stub_google_events([ dentist ])
      get_events

      travel_to(start + 61.seconds)
      stub_google_events([ dentist, lunch ])
      get_events

      expect(titles).to eq([ "Dentist", "Lunch" ])
      expect(response.parsed_body.dig("events", "fetched_at")).to eq("2026-11-01T16:42:08Z")
      expect(google_requests).to have_been_made.twice
    end

    it "misses after a reconnect" do
      stub_google_events([ dentist ])
      get_events

      travel_to(start + 10.seconds)
      GoogleCalendarConnection.connect!(user_id: user.id, refresh_token: "1//reconnected")
      stub_google_events([ lunch ])
      get_events

      expect(titles).to eq([ "Lunch" ])
      expect(google_requests).to have_been_made.twice
    end

    it "misses on a new UTC date, and asks for the new date's window" do
      travel_to(Time.utc(2026, 11, 1, 23, 59, 50))
      stub_google_events([ dentist ])
      get_events

      travel_to(Time.utc(2026, 11, 2, 0, 0, 10))
      stub_google_events([ lunch ])
      get_events

      expect(titles).to eq([ "Lunch" ])
      expect(a_request(:get, google_events_endpoint).with(query: hash_including("timeMin" => "2026-10-31T10:00:00Z")))
        .to have_been_made.once
    end

    it "does not cache a token failure or an events failure" do
      stub_google_token_server_error
      get_events
      expect(response).to have_http_status(:bad_gateway)

      stub_google_tokens
      stub_google_events_error(503, "backendError")
      get_events
      expect(response).to have_http_status(:bad_gateway)

      stub_google_events([ dentist ])
      get_events
      expect(response).to have_http_status(:ok)
      expect(titles).to eq([ "Dentist" ])
      expect(google_requests).to have_been_made.twice
    end

    it "does not cache lost: after invalid_grant the next request is lost without calling Google" do
      stub_google_token_error("invalid_grant")
      get_events
      expect(response.parsed_body["google_calendar_connection"]).to eq("status" => "lost")

      get_events
      expect(response.parsed_body).to eq("google_calendar_connection" => { "status" => "lost" }, "events" => nil)
      expect(token_requests).to have_been_made.once
      expect(google_requests).not_to have_been_made
    end

    it "answers lost, not the cached events, once the connection is marked lost" do
      stub_google_events([ dentist ])
      get_events

      connection.mark_lost!
      get_events

      expect(response.parsed_body).to eq("google_calendar_connection" => { "status" => "lost" }, "events" => nil)
    end

    it "never touches Rails.cache" do
      stub_google_events([ dentist ])
      %i[read write fetch exist? delete].each { |method| expect(Rails.cache).not_to receive(method) }

      get_events
      get_events

      expect(response).to have_http_status(:ok)
    end
  end

  it "is per user: user B is never answered from user A's entry, even for the same connection time" do
    other = create(:user, username: "bea")
    connected_at = 1.hour.ago
    create(:google_calendar_connection, user: user, refresh_token: "1//a-token", connected_at: connected_at)
    create(:google_calendar_connection, user: other, refresh_token: "1//b-token", connected_at: connected_at)
    stub_request(:post, google_token_endpoint).with(body: hash_including("refresh_token" => "1//a-token"))
      .to_return(status: 200, body: { access_token: "ya29.for-a" }.to_json)
    stub_request(:post, google_token_endpoint).with(body: hash_including("refresh_token" => "1//b-token"))
      .to_return(status: 200, body: { access_token: "ya29.for-b" }.to_json)
    stub_google_events([ dentist ], access_token: "ya29.for-a")
    stub_google_events([ lunch ], access_token: "ya29.for-b")

    get_events(user) # primes A's entry
    expect(titles).to eq([ "Dentist" ])

    get_events(other)

    expect(titles).to eq([ "Lunch" ])
    expect(response.body).not_to include("Dentist")
    expect(google_requests).to have_been_made.twice
  end
end
