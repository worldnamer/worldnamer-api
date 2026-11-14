require "rails_helper"

RSpec.describe "DELETE /api/v1/youtube_connection/playlist/items/:id", type: :request do
  let!(:user) { create(:user, username: "john") }

  def token_for(account = user)
    login(username: account.username)
    response.parsed_body.fetch("access_token")
  end

  def remove(item_id, account = user)
    delete "/api/v1/youtube_connection/playlist/items/#{item_id}", headers: bearer(token_for(account))
  end

  def expect_error(status, code)
    expect(response).to have_http_status(status)
    expect(response.parsed_body).to match("error" => { "code" => code, "message" => a_kind_of(String) })
  end

  def connect_with_playlist(account = user, playlist_id: "PLchosen01")
    create(:youtube_connection, user: account, playlist_id: playlist_id, playlist_title: "Chosen")
  end

  def expect_no_delete
    expect(a_request(:delete, /youtube/)).not_to have_been_made
  end

  it "returns 401 unauthenticated without a valid token, and calls nothing" do
    delete "/api/v1/youtube_connection/playlist/items/item0"

    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body).to match(expected_unauthenticated_body)
    expect(a_request(:any, /google/)).not_to have_been_made
  end

  it "removes an item of the chosen playlist after checking it belongs there, and answers 204" do
    connect_with_playlist
    stub_google_tokens(access_token: "ya29.yt")
    find = stub_youtube_find_item("UExpdGVtMA==", "PLchosen01")
    removal = stub_youtube_delete_item("UExpdGVtMA==")

    remove("UExpdGVtMA==")

    expect(response).to have_http_status(:no_content)
    expect(response.body).to be_empty
    expect(response.headers["Cache-Control"]).to eq("no-store")
    expect(find).to have_been_requested.once
    expect(removal).to have_been_requested.once
  end

  it "answers 404 and sends no DELETE for an item in another of the user's playlists" do
    connect_with_playlist
    stub_google_tokens
    stub_youtube_find_item("item0", "PLanother1")

    remove("item0")

    expect_error(:not_found, "not_found")
    expect_no_delete
  end

  it "answers 404 and sends no DELETE for an item YouTube does not know" do
    connect_with_playlist
    stub_google_tokens
    stub_youtube_find_item("item0", nil)

    remove("item0")

    expect_error(:not_found, "not_found")
    expect_no_delete
  end

  it "answers 404 without calling Google when no playlist is chosen" do
    create(:youtube_connection, user: user)

    remove("item0")

    expect_error(:not_found, "not_found")
    expect(a_request(:any, /google/)).not_to have_been_made
  end

  [ "a" * 129, "item%20zero", "item%2Bplus", "item%26id%3Dx" ].each do |bad|
    it "answers 404 for the malformed id #{bad.inspect} without calling Google" do
      connect_with_playlist

      remove(bad)

      expect_error(:not_found, "not_found")
      expect(a_request(:any, /google/)).not_to have_been_made
    end
  end

  it "does not route an id with a dot or a slash" do
    connect_with_playlist

    [ "item.zero", "item/zero" ].each do |bad|
      remove(bad)
      expect(response).to have_http_status(:not_found)
    end
    expect(a_request(:any, /google/)).not_to have_been_made
  end

  {
    "the lookup answers 404" => -> { stub_youtube_find_item_error("item0", 404, "playlistItemNotFound") },
    "the lookup answers 403 playlistItemsNotAccessible" =>
      -> { stub_youtube_find_item_error("item0", 403, "playlistItemsNotAccessible") },
    "the delete answers 404" => -> {
      stub_youtube_find_item("item0", "PLchosen01")
      stub_youtube_delete_item("item0", status: 404, reason: "playlistItemNotFound")
    }
  }.each do |label, stub|
    it "answers 404 when #{label}" do
      connect_with_playlist
      stub_google_tokens
      instance_exec(&stub)

      remove("item0")

      expect_error(:not_found, "not_found")
    end
  end

  {
    "the lookup answers 403 quotaExceeded" => -> { stub_youtube_find_item_error("item0", 403, "quotaExceeded") },
    "the delete answers 403 insufficientPermissions" => -> {
      stub_youtube_find_item("item0", "PLchosen01")
      stub_youtube_delete_item("item0", status: 403, reason: "insufficientPermissions")
    },
    "the delete answers 500" => -> {
      stub_youtube_find_item("item0", "PLchosen01")
      stub_youtube_delete_item("item0", status: 500, reason: "backendError")
    },
    "the token endpoint fails" => -> { stub_google_token_server_error }
  }.each do |label, stub|
    it "answers 502 youtube_unavailable when #{label}" do
      connect_with_playlist
      stub_google_tokens unless label.include?("token endpoint")
      instance_exec(&stub)

      remove("item0")

      expect_error(:bad_gateway, "youtube_unavailable")
    end
  end

  it "answers 409 youtube_not_connected with no connection or a lost one, without calling Google" do
    remove("item0")
    expect_error(:conflict, "youtube_not_connected")

    create(:youtube_connection, :lost, user: user, playlist_id: "PLchosen01")
    remove("item0")
    expect_error(:conflict, "youtube_not_connected")

    expect(a_request(:any, /google/)).not_to have_been_made
  end

  it "marks the connection lost and answers 409 when Google rejects the token, sending no DELETE" do
    connection = connect_with_playlist
    stub_google_token_error("invalid_grant")

    remove("item0")

    expect_error(:conflict, "youtube_not_connected")
    expect(connection.reload.lost_at).to be_present
    expect_no_delete
  end

  it "answers 502 when the user reconnected while the rejected token was on its way" do
    connection = connect_with_playlist
    connection.update!(connected_at: 1.hour.ago)
    stub_request(:post, google_token_endpoint).to_return do
      YouTubeConnection.connect!(user_id: connection.user_id, refresh_token: "1//after-reconnect")
      { status: 400, body: { error: "invalid_grant" }.to_json }
    end

    remove("item0")

    expect_error(:bad_gateway, "youtube_unavailable")
    expect(connection.reload.lost_at).to be_nil
  end

  it "checks against the caller's chosen playlist, never another user's" do
    connect_with_playlist(user, playlist_id: "PLjohns001")
    other = create(:user, username: "bea")
    connect_with_playlist(other, playlist_id: "PLbeas0001")
    stub_google_tokens
    stub_youtube_find_item("item0", "PLjohns001") # an item in John's playlist

    remove("item0", other)

    expect_error(:not_found, "not_found")
    expect_no_delete
  end
end
