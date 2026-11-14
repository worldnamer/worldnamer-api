require "rails_helper"

# Google's refresh and access tokens, this app's client secret and the chosen playlist's title must never reach the
# Rails log, OpenTelemetry spans (the outgoing DELETE included) or Sentry events while an item is removed. Every check
# first asserts that the request really was logged, traced or reported, so an empty capture cannot pass.
RSpec.describe "Leak checks on DELETE /api/v1/youtube_connection/playlist/items/:id", type: :request do
  let(:playlist_title) { "SENTINEL-yt-delete-playlist-title-5e0a-do-not-leak" }
  let(:stored_refresh_token) { "1//SENTINEL-yt-delete-refresh-8f31-do-not-leak" }
  let(:rotated_refresh_token) { "1//SENTINEL-yt-delete-rotated-2c74-do-not-leak" }
  let(:access_token) { "ya29.SENTINEL-yt-delete-access-d6b9-do-not-leak" }
  let(:client_secret) { ENV.fetch("GOOGLE_CLIENT_SECRET") }
  let(:sentinels) { [ playlist_title, stored_refresh_token, rotated_refresh_token, access_token, client_secret ] }
  let(:path) { "/api/v1/youtube_connection/playlist/items/item0" }

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
    stub_youtube_find_item("item0", "PLchosen01")
    stub_youtube_delete_item("item0")
    TelemetryHelpers.reset # drop the login's spans
  end

  def remove
    delete path, headers: bearer(bearer_token)
  end

  it "keeps them out of the Rails log" do
    log = request_logging { remove }

    expect(response).to have_http_status(:no_content)
    expect(log).to include("Started DELETE \"#{path}\"")
    expect(log).to include("Completed 204")
    expect(log).to match(/UPDATE "youtube_connections"/)
    expect_none_of(sentinels, log)
  end

  it "keeps them out of a failure's log line" do
    stub_request(:delete, YouTubeDataHelpers::YOUTUBE_PLAYLIST_ITEMS_ENDPOINT).with(query: { "id" => "item0" }).to_return(
      youtube_json(youtube_error_body(500, "backendError", message: "#{playlist_title} #{access_token}"), status: 500)
    )

    log = request_logging { remove }

    expect(response).to have_http_status(:bad_gateway)
    expect(log).to include("YouTube unavailable: YouTube::DataClient::Error status=500")
    expect_none_of(sentinels, log)
  end

  it "keeps them out of the spans" do
    remove

    dump = dump_spans
    expect(dump).to include(path)
    expect(dump).to include("youtube_connections")
    expect_none_of(sentinels, dump)
  end

  # Over a real socket to a local server playing YouTube, so the outgoing spans are recorded as in production. Their
  # targets hold the item id, never the token, which travels in a header.
  it "keeps them out of the outgoing Net::HTTP spans for the lookup and the DELETE" do
    received = []
    responder = lambda do |request|
      if request.start_with?("DELETE")
        "HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n"
      else
        local_json_response({ items: [ { id: "item0", snippet: { playlistId: "PLchosen01" } } ] })
      end
    end
    with_local_http_server(responder) do |base_url, requests|
      allow(YouTube::DataClient).to receive(:new).and_wrap_original do |original, **kwargs|
        original.call(**kwargs, base_url: URI("#{base_url}/youtube/v3/"))
      end

      remove
      received << requests.pop until requests.empty?
    end

    expect(response).to have_http_status(:no_content)
    expect(received.last).to start_with("DELETE /youtube/v3/playlistItems?id=item0 ")
    expect(received.last).to include("Authorization: Bearer #{access_token}")
    outgoing = captured_spans.select { |span| span.kind == :client && span.attributes["server.address"] == "127.0.0.1" }
    expect(outgoing.size).to eq(2)
    dump = dump_spans(outgoing)
    expect(dump).to include("DELETE")
    expect_none_of(sentinels, dump)
  end

  it "keeps them out of a Sentry event for an error forced after the DELETE" do
    allow_any_instance_of(YouTube::DataClient).to receive(:delete_playlist_item).and_wrap_original do |original, *args|
      original.call(*args) # YouTube really removed the item first
      raise "forced youtube delete failure"
    end

    begin
      remove
    rescue RuntimeError
      # Rails re-raises in the test environment; Sentry's middleware captured it first.
    end

    expect(a_request(:delete, /playlistItems/)).to have_been_made.once
    dump = dump_sentry_events
    expect(dump).to include("forced youtube delete failure")
    expect_none_of(sentinels, dump)
  end

  it "keeps them out of a Sentry event when a client error escapes unrescued, even if YouTube's body quotes them" do
    stub_request(:delete, YouTubeDataHelpers::YOUTUBE_PLAYLIST_ITEMS_ENDPOINT).with(query: { "id" => "item0" }).to_return(
      youtube_json(youtube_error_body(500, "backendError", message: "#{playlist_title} #{access_token}"), status: 500)
    )
    allow_any_instance_of(Api::V1::YouTubeConnections::PlaylistItemsController)
      .to receive(:render_youtube_unavailable) { raise $! }

    begin
      remove
    rescue YouTube::DataClient::Error
      # see above
    end

    dump = dump_sentry_events
    expect(dump).to include("YouTube answered 500")
    expect_none_of(sentinels, dump)
  end

  it "answers with an empty body" do
    remove

    expect(response.body).to be_empty
  end
end
