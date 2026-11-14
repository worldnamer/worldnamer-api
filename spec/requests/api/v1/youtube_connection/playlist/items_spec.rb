require "rails_helper"

RSpec.describe "GET /api/v1/youtube_connection/playlist/items", type: :request do
  let!(:user) { create(:user, username: "john") }
  let(:path) { "/api/v1/youtube_connection/playlist/items" }

  def token_for(account = user)
    login(username: account.username)
    response.parsed_body.fetch("access_token")
  end

  def fetch(account = user)
    get path, headers: bearer(token_for(account))
  end

  def expect_answer(status, playlist: nil, videos: nil)
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq("youtube_connection" => { "status" => status }, "playlist" => playlist, "videos" => videos)
  end

  def chosen(available: true)
    { "id" => "PLchosen01", "title" => "Chosen", "available" => available }
  end

  def connect_with_playlist(account = user)
    create(:youtube_connection, user: account, playlist_id: "PLchosen01", playlist_title: "Chosen")
  end

  it "returns 401 unauthenticated without a valid token" do
    get path
    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body).to match(expected_unauthenticated_body)
  end

  it "lists the chosen playlist's first videos in YouTube's order, with the total, never cached" do
    connect_with_playlist
    stub_google_tokens(access_token: "ya29.yt")
    stub = stub_youtube_playlist_items("PLchosen01", [
      youtube_item(id: "item0", title: "First", position: 0, video_id: "aaaaaaaaaaa"),
      youtube_item(id: "item1", title: "Second", position: 1, video_id: "bbbbbbbbbbb")
    ], total: 73)

    fetch

    expect_answer("connected", playlist: chosen, videos: {
      "total_count" => 73,
      "items" => [
        { "id" => "item0", "video_id" => "aaaaaaaaaaa", "title" => "First", "position" => 0 },
        { "id" => "item1", "video_id" => "bbbbbbbbbbb", "title" => "Second", "position" => 1 }
      ]
    })
    expect(response.headers["Cache-Control"]).to eq("no-store")
    expect(stub).to have_been_requested.once
  end

  it "is an empty list for an empty playlist" do
    connect_with_playlist
    stub_google_tokens
    stub_youtube_playlist_items("PLchosen01", [])

    fetch

    expect_answer("connected", playlist: chosen, videos: { "total_count" => 0, "items" => [] })
  end

  it "answers a null video id for an item whose video id is not valid" do
    connect_with_playlist
    stub_google_tokens
    stub_youtube_playlist_items("PLchosen01", [ youtube_item(id: "item0", title: "Odd", position: 0, video_id: "bad") ])

    fetch

    expect(response.parsed_body.dig("videos", "items", 0, "video_id")).to be_nil
  end

  {
    "404 playlistNotFound" => [ 404, "playlistNotFound" ],
    "403 playlistItemsNotAccessible" => [ 403, "playlistItemsNotAccessible" ]
  }.each do |label, (status, reason)|
    it "answers available false and keeps the choice after #{label}" do
      connection = connect_with_playlist
      stub_google_tokens
      stub_youtube_playlist_items_error(status, reason)

      fetch

      expect_answer("connected", playlist: chosen(available: false))
      expect(connection.reload.playlist_id).to eq("PLchosen01")
    end
  end

  {
    "403 quotaExceeded" => [ 403, "quotaExceeded" ],
    "403 insufficientPermissions" => [ 403, "insufficientPermissions" ],
    "401 authError" => [ 401, "authError" ],
    "500 backendError" => [ 500, "backendError" ]
  }.each do |label, (status, reason)|
    it "answers 502 and changes nothing after #{label}" do
      connection = connect_with_playlist
      stub_google_tokens
      stub_youtube_playlist_items_error(status, reason)

      expect { fetch }.not_to change { YouTubeConnection.find(connection.id).attributes }
      expect(response).to have_http_status(:bad_gateway)
      expect(response.parsed_body).to match("error" => { "code" => "youtube_unavailable", "message" => a_kind_of(String) })
    end
  end

  it "answers with nulls and calls nothing when not connected, lost, or with no playlist chosen" do
    fetch
    expect_answer("not_connected")

    connection = create(:youtube_connection, user: user)
    fetch
    expect_answer("connected")

    connection.update!(lost_at: Time.current, refresh_token: nil, playlist_id: "PLchosen01", playlist_title: "Chosen")
    fetch
    expect_answer("lost")

    expect(a_request(:any, /google/)).not_to have_been_made
  end

  it "marks the connection lost and answers lost when Google rejects the token" do
    connection = connect_with_playlist
    stub_google_token_error("invalid_grant")

    fetch

    expect_answer("lost")
    expect(connection.reload.lost_at).to be_present
    expect(connection.playlist_id).to eq("PLchosen01")
  end

  it "answers 502 when the user reconnected while the rejected token was on its way" do
    connection = connect_with_playlist
    connection.update!(connected_at: 1.hour.ago)
    stub_request(:post, google_token_endpoint).to_return do
      YouTubeConnection.connect!(user_id: connection.user_id, refresh_token: "1//after-reconnect")
      { status: 400, body: { error: "invalid_grant" }.to_json }
    end

    fetch

    expect(response).to have_http_status(:bad_gateway)
    expect(connection.reload.lost_at).to be_nil
  end

  it "reads only the caller's chosen playlist" do
    other = create(:user, username: "bea")
    connect_with_playlist(user)
    create(:youtube_connection, user: other, playlist_id: "PLbeas0001", playlist_title: "Bea's")
    stub_google_tokens
    a_stub = stub_youtube_playlist_items("PLchosen01", [])
    b_stub = stub_youtube_playlist_items("PLbeas0001", [])

    fetch(other)

    expect(response.parsed_body.dig("playlist", "id")).to eq("PLbeas0001")
    expect(b_stub).to have_been_requested.once
    expect(a_stub).not_to have_been_requested
  end
end
