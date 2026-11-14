require "rails_helper"

RSpec.describe "PUT /api/v1/youtube_connection/playlist", type: :request do
  let!(:user) { create(:user, username: "john") }
  let(:path) { "/api/v1/youtube_connection/playlist" }
  let(:mine) { [ { id: "PLmine0001", title: "Mine" }, { id: "PLmine0002", title: "Also mine" } ] }

  def token_for(account = user)
    login(username: account.username)
    response.parsed_body.fetch("access_token")
  end

  def choose(id, account = user)
    put path, params: { playlist: { id: id } }, as: :json, headers: bearer(token_for(account))
  end

  def expect_error(status, code)
    expect(response).to have_http_status(status)
    expect(response.parsed_body).to match("error" => { "code" => code, "message" => a_kind_of(String) })
  end

  it "returns 401 unauthenticated without a valid token" do
    put path, params: { playlist: { id: "PLmine0001" } }, as: :json
    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body).to match(expected_unauthenticated_body)
  end

  it "chooses one of the user's playlists, with YouTube's title, and answers like GET /youtube_connection" do
    connection = create(:youtube_connection, user: user)
    stub_google_tokens
    stub_youtube_playlists(mine)

    choose("PLmine0002")

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq(
      "youtube_connection" => { "status" => "connected", "playlist" => { "id" => "PLmine0002", "title" => "Also mine" } }
    )
    expect(response.headers["Cache-Control"]).to eq("no-store")
    expect(connection.reload).to have_attributes(playlist_id: "PLmine0002", playlist_title: "Also mine")
  end

  it "replaces an earlier choice" do
    connection = create(:youtube_connection, user: user, playlist_id: "PLmine0001", playlist_title: "Mine")
    stub_google_tokens
    stub_youtube_playlists(mine)

    choose("PLmine0002")

    expect(connection.reload.playlist_id).to eq("PLmine0002")
  end

  it "takes the title from YouTube, never from the request" do
    connection = create(:youtube_connection, user: user)
    stub_google_tokens
    stub_youtube_playlists(mine)

    put path, params: { playlist: { id: "PLmine0001", title: "Injected" } }, as: :json, headers: bearer(token_for)

    expect(connection.reload.playlist_title).to eq("Mine")
  end

  it "answers 422 invalid_playlist for a playlist that is not among the user's, keeping the earlier choice" do
    connection = create(:youtube_connection, user: user, playlist_id: "PLmine0001", playlist_title: "Mine")
    stub_google_tokens
    stub_youtube_playlists(mine)

    choose("PLsomeoneelse")

    expect_error(:unprocessable_content, "invalid_playlist")
    expect(connection.reload.playlist_id).to eq("PLmine0001")
  end

  [ "x", "a" * 65, "PL with space", "PL/../x", "PL&mine=false", 12345 ].each do |bad|
    it "answers 422 for the malformed id #{bad.inspect} without calling Google" do
      create(:youtube_connection, user: user)

      choose(bad)

      expect_error(:unprocessable_content, "invalid_playlist")
      expect(a_request(:any, /google/)).not_to have_been_made
    end
  end

  it "answers 400 for a body without a playlist" do
    create(:youtube_connection, user: user)

    put path, params: { id: "PLmine0001" }, as: :json, headers: bearer(token_for)

    expect_error(:bad_request, "bad_request")
  end

  it "answers 409 youtube_not_connected with no connection or a lost one, without calling Google" do
    choose("PLmine0001")
    expect_error(:conflict, "youtube_not_connected")

    create(:youtube_connection, :lost, user: user)
    choose("PLmine0001")
    expect_error(:conflict, "youtube_not_connected")

    expect(a_request(:any, /google/)).not_to have_been_made
  end

  it "marks the connection lost and answers 409 when Google rejects the token" do
    connection = create(:youtube_connection, user: user)
    stub_google_token_error("invalid_grant")

    choose("PLmine0001")

    expect_error(:conflict, "youtube_not_connected")
    expect(connection.reload.lost_at).to be_present
  end

  it "answers 502 when the user reconnected while the rejected token was on its way" do
    connection = create(:youtube_connection, user: user, connected_at: 1.hour.ago)
    stub_request(:post, google_token_endpoint).to_return do
      YoutubeConnection.connect!(user_id: connection.user_id, refresh_token: "1//after-reconnect")
      { status: 400, body: { error: "invalid_grant" }.to_json }
    end

    choose("PLmine0001")

    expect_error(:bad_gateway, "youtube_unavailable")
    expect(connection.reload.lost_at).to be_nil
  end

  it "answers 502 and keeps the earlier choice when YouTube fails" do
    connection = create(:youtube_connection, user: user, playlist_id: "PLmine0001", playlist_title: "Mine")
    stub_google_tokens
    stub_youtube_playlists_error(403, "quotaExceeded")

    choose("PLmine0002")

    expect_error(:bad_gateway, "youtube_unavailable")
    expect(connection.reload.playlist_id).to eq("PLmine0001")
  end

  it "changes only the caller's connection" do
    other = create(:user, username: "bea")
    a_connection = create(:youtube_connection, :with_playlist, user: user)
    create(:youtube_connection, user: other)
    stub_google_tokens
    stub_youtube_playlists(mine)

    expect { choose("PLmine0002", other) }.not_to change { a_connection.reload.attributes }
    expect(other.reload.youtube_connection.playlist_id).to eq("PLmine0002")
  end
end
