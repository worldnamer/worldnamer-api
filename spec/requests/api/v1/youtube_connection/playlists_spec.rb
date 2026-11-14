require "rails_helper"

RSpec.describe "GET /api/v1/youtube_connection/playlists", type: :request do
  let!(:user) { create(:user, username: "john") }
  let(:path) { "/api/v1/youtube_connection/playlists" }

  def token_for(account = user)
    login(username: account.username)
    response.parsed_body.fetch("access_token")
  end

  def list(account = user)
    get path, headers: bearer(token_for(account))
  end

  def expect_answer(status, playlists)
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq("youtube_connection" => { "status" => status }, "playlists" => playlists)
  end

  it "returns 401 unauthenticated without a valid token" do
    get path
    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body).to match(expected_unauthenticated_body)
  end

  it "lists the user's own playlists, with the token minted from the stored refresh token, never cached" do
    create(:youtube_connection, user: user, refresh_token: "1//stored")
    stub_request(:post, google_token_endpoint).with(body: hash_including("refresh_token" => "1//stored"))
      .to_return(status: 200, body: { access_token: "ya29.yt" }.to_json)
    stub = stub_youtube_playlists([ { id: "PLone", title: "One" }, { id: "PLtwo", title: "Two" } ], access_token: "ya29.yt")

    list

    expect_answer("connected", [ { "id" => "PLone", "title" => "One" }, { "id" => "PLtwo", "title" => "Two" } ])
    expect(response.headers["Cache-Control"]).to eq("no-store")
    expect(stub).to have_been_requested.once
  end

  it "is an empty list when the user has no playlists" do
    create(:youtube_connection, user: user)
    stub_google_tokens
    stub_youtube_playlists([])

    list

    expect_answer("connected", [])
  end

  it "answers not_connected and lost with null, without calling Google" do
    list
    expect_answer("not_connected", nil)

    create(:youtube_connection, :lost, user: user)
    list
    expect_answer("lost", nil)

    expect(a_request(:any, /googleapis/)).not_to have_been_made
  end

  it "marks the connection lost and answers lost when Google rejects the token" do
    connection = create(:youtube_connection, user: user)
    stub_google_token_error("invalid_grant")

    list

    expect_answer("lost", nil)
    expect(connection.reload.lost_at).to be_present
  end

  it "answers 502 when the user reconnected while the rejected token was on its way" do
    connection = create(:youtube_connection, user: user, connected_at: 1.hour.ago)
    stub_request(:post, google_token_endpoint).to_return do
      YoutubeConnection.connect!(user_id: connection.user_id, refresh_token: "1//after-reconnect")
      { status: 400, body: { error: "invalid_grant" }.to_json }
    end

    list

    expect(response).to have_http_status(:bad_gateway)
    expect(connection.reload.lost_at).to be_nil
  end

  {
    "a token endpoint 5xx" => -> { stub_google_token_server_error },
    "a 401 from YouTube" => -> { stub_google_tokens && stub_youtube_playlists_error(401, "authError") },
    "a 403 from YouTube" => -> { stub_google_tokens && stub_youtube_playlists_error(403, "insufficientPermissions") },
    "a YouTube timeout" => -> { stub_google_tokens && stub_request(:get, /youtube\/v3\/playlists/).to_timeout }
  }.each do |failure, stub|
    it "answers 502 youtube_unavailable and changes nothing after #{failure}" do
      connection = create(:youtube_connection, :with_playlist, user: user)
      instance_exec(&stub)

      expect { list }.not_to change { YoutubeConnection.find(connection.id).attributes }
      expect(response).to have_http_status(:bad_gateway)
      expect(response.parsed_body).to match("error" => { "code" => "youtube_unavailable", "message" => a_kind_of(String) })
    end
  end

  it "logs a failure with its class and status only" do
    create(:youtube_connection, user: user)
    stub_google_tokens
    stub_request(:get, /youtube\/v3\/playlists/).to_return(
      youtube_json(youtube_error_body(500, "backendError", message: "SENTINEL-playlist-title"), status: 500)
    )

    log = request_logging { list }

    expect(log).to include("YouTube unavailable: Youtube::DataClient::Error status=500")
    expect(log).not_to include("SENTINEL-playlist-title")
  end

  it "uses only the caller's connection" do
    other = create(:user, username: "bea")
    create(:youtube_connection, user: user, refresh_token: "1//a-token")

    list(other)

    expect_answer("not_connected", nil)
    expect(a_request(:any, /google/)).not_to have_been_made
  end
end
