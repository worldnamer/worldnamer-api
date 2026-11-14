require "rails_helper"

# Google's refresh and access tokens, this app's client secret and the chosen playlist's title must never reach the
# Rails log, OpenTelemetry spans or Sentry events during a YouTube status check, and only the title may reach the
# response body. Every check first asserts that the request really was logged, traced or reported.
RSpec.describe "Token leak checks on GET /api/v1/youtube_connection", type: :request do
  let(:stored_refresh_token) { "1//SENTINEL-yt-stored-refresh-4c19-do-not-leak" }
  let(:rotated_refresh_token) { "1//SENTINEL-yt-rotated-refresh-a7e2-do-not-leak" }
  let(:access_token) { "ya29.SENTINEL-yt-access-58bd-do-not-leak" }
  let(:client_secret) { ENV.fetch("GOOGLE_CLIENT_SECRET") }
  let(:title) { "SENTINEL-yt-playlist-title-0d3f-do-not-leak" }
  let(:secrets) { [ stored_refresh_token, rotated_refresh_token, access_token, client_secret ] }

  let!(:user) { create(:user, username: "john") }
  let!(:connection) do
    create(:youtube_connection, user: user, refresh_token: stored_refresh_token, playlist_id: "PLchosen1", playlist_title: title)
  end
  let!(:bearer_token) do
    login(username: "john")
    response.parsed_body.fetch("access_token")
  end

  before do
    stub_google_tokens(access_token: access_token, refresh_token: rotated_refresh_token)
    TelemetryHelpers.reset # drop the login's spans
  end

  def check_status
    get "/api/v1/youtube_connection", headers: bearer(bearer_token)
  end

  it "keeps the tokens, the client secret and the title out of the Rails log" do
    log = request_logging { check_status }

    expect(response).to have_http_status(:ok)
    expect(log).to include("Started GET \"/api/v1/youtube_connection\"")
    expect(log).to include("Completed 200")
    expect(log).to match(/UPDATE "youtube_connections"/)
    expect(connection.reload.refresh_token).to eq(rotated_refresh_token) # the rotation really happened
    expect_none_of([ *secrets, title ], log)
  end

  it "keeps them out of the spans" do
    check_status

    dump = dump_spans
    expect(dump).to include("/api/v1/youtube_connection")
    expect(dump).to include("youtube_connections")
    expect_none_of([ *secrets, title ], dump)
  end

  it "keeps the tokens and the secret out of the response body, which holds the title" do
    check_status

    expect(response.parsed_body.dig("youtube_connection", "playlist", "title")).to eq(title)
    expect_none_of(secrets, response.body)
  end

  it "keeps them out of a Sentry event for an error forced during the check" do
    allow_any_instance_of(GoogleCalendar::OauthClient).to receive(:refresh_access_token).and_wrap_original do |original, *args|
      original.call(*args) # Google really answers with the tokens first
      raise "forced youtube check failure"
    end

    begin
      check_status
    rescue RuntimeError
      # Rails re-raises in the test environment; Sentry's middleware captured it first.
    end

    dump = dump_sentry_events
    expect(dump).to include("forced youtube check failure")
    expect_none_of([ *secrets, title ], dump)
  end
end
