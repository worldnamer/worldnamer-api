require "rails_helper"

# A video title, Google's refresh and access tokens and this app's client secret must never reach the Rails log,
# OpenTelemetry spans (the outgoing call to YouTube included) or Sentry events while a playlist's videos are fetched.
# The title is meant to reach the response body; nothing else here is. Every check first asserts that the request
# really was logged, traced or reported, so an empty capture cannot pass.
RSpec.describe "Leak checks on GET /api/v1/youtube_connection/playlist/items", type: :request do
  let(:title) { "SENTINEL-yt-video-title-6a2e-do-not-leak" }
  let(:playlist_title) { "SENTINEL-yt-playlist-title-c81b-do-not-leak" }
  let(:stored_refresh_token) { "1//SENTINEL-yt-items-refresh-17f0-do-not-leak" }
  let(:rotated_refresh_token) { "1//SENTINEL-yt-items-rotated-b3d6-do-not-leak" }
  let(:access_token) { "ya29.SENTINEL-yt-items-access-49ca-do-not-leak" }
  let(:client_secret) { ENV.fetch("GOOGLE_CLIENT_SECRET") }
  let(:secrets) { [ stored_refresh_token, rotated_refresh_token, access_token, client_secret ] }
  let(:sentinels) { [ title, playlist_title, *secrets ] }
  let(:items) { [ youtube_item(id: "item0", title: title, position: 0) ] }

  let!(:user) { create(:user, username: "john") }
  let!(:connection) do
    create(:youtube_connection, user: user, refresh_token: stored_refresh_token,
      playlist_id: "PLchosen01", playlist_title: playlist_title)
  end
  let!(:bearer_token) do
    login(username: "john")
    response.parsed_body.fetch("access_token")
  end

  before do
    stub_google_tokens(access_token: access_token, refresh_token: rotated_refresh_token)
    stub_youtube_playlist_items("PLchosen01", items)
    TelemetryHelpers.reset # drop the login's spans
  end

  def fetch_items
    get "/api/v1/youtube_connection/playlist/items", headers: bearer(bearer_token)
  end

  it "keeps the titles and tokens out of the Rails log" do
    log = request_logging { fetch_items }

    expect(response).to have_http_status(:ok)
    expect(log).to include("Started GET \"/api/v1/youtube_connection/playlist/items\"")
    expect(log).to include("Completed 200")
    expect(log).to match(/UPDATE "youtube_connections"/)
    expect(response.body).to include(title)
    expect_none_of(sentinels, log)
  end

  it "keeps them out of a failure's log line" do
    stub_request(:get, YoutubeDataHelpers::YOUTUBE_PLAYLIST_ITEMS_ENDPOINT).with(query: hash_including({})).to_return(
      youtube_json(youtube_error_body(500, "backendError", message: "#{title} #{access_token}"), status: 500)
    )

    log = request_logging { fetch_items }

    expect(response).to have_http_status(:bad_gateway)
    expect(log).to include("YouTube unavailable: Youtube::DataClient::Error status=500")
    expect_none_of(sentinels, log)
  end

  it "keeps them out of the spans" do
    fetch_items

    dump = dump_spans
    expect(dump).to include("/api/v1/youtube_connection/playlist/items")
    expect(dump).to include("youtube_connections")
    expect_none_of(sentinels, dump)
  end

  # WebMock answers stubbed requests before Net::HTTP sends anything, so the Net::HTTP instrumentation records no span
  # for them. Here PlaylistItems: list goes over a real socket to a local server playing YouTube, so the outgoing span
  # is recorded as in production. Its target holds the playlist id and the fields filter, never the token.
  it "keeps them out of the outgoing Net::HTTP span for PlaylistItems: list" do
    received = nil
    with_local_http_server(->(_request) { local_json_response({ pageInfo: { totalResults: 1 }, items: items }) }) do |base_url, requests|
      allow(Youtube::DataClient).to receive(:new).and_wrap_original do |original, **kwargs|
        original.call(**kwargs, base_url: URI("#{base_url}/youtube/v3/"))
      end

      fetch_items
      received = requests.pop
    end

    expect(response).to have_http_status(:ok)
    expect(received).to include("Authorization: Bearer #{access_token}") # the token really travelled, in a header
    outgoing = captured_spans.select { |span| span.kind == :client && span.attributes["server.address"] == "127.0.0.1" }
    expect(outgoing).not_to be_empty
    dump = dump_spans(outgoing)
    expect(dump).to include("/youtube/v3/playlistItems")
    expect_none_of(sentinels, dump)
  end

  it "keeps them out of a Sentry event for an error forced after the videos were fetched" do
    allow_any_instance_of(Youtube::DataClient).to receive(:list_playlist_items).and_wrap_original do |original, *args|
      original.call(*args) # the videos really were fetched first
      raise "forced youtube items failure"
    end

    begin
      fetch_items
    rescue RuntimeError
      # Rails re-raises in the test environment; Sentry's middleware captured it first.
    end

    expect(a_request(:get, /playlistItems/)).to have_been_made.once
    dump = dump_sentry_events
    expect(dump).to include("forced youtube items failure")
    expect_none_of(sentinels, dump)
  end

  it "keeps them out of a Sentry event when a client error escapes unrescued, even if YouTube's body quotes them" do
    stub_request(:get, YoutubeDataHelpers::YOUTUBE_PLAYLIST_ITEMS_ENDPOINT).with(query: hash_including({})).to_return(
      youtube_json(youtube_error_body(500, "backendError", message: "#{title} #{access_token}"), status: 500)
    )
    # Let the client's error escape instead of answering 502, so Sentry reports it. $! is the error being rescued.
    allow_any_instance_of(Api::V1::YoutubeConnections::PlaylistItemsController)
      .to receive(:render_youtube_unavailable) { raise $! }

    begin
      fetch_items
    rescue Youtube::DataClient::Error
      # see above
    end

    dump = dump_sentry_events
    expect(dump).to include("YouTube answered 500")
    expect_none_of(sentinels, dump)
  end

  it "keeps the tokens out of the response body, which holds the titles" do
    fetch_items

    expect(response.parsed_body.dig("videos", "items", 0, "title")).to eq(title)
    expect_none_of(secrets, response.body)
  end
end
