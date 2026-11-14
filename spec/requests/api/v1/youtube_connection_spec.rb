require "rails_helper"

RSpec.describe "GET /api/v1/youtube_connection", type: :request do
  let!(:user) { create(:user, username: "john") }
  let(:path) { "/api/v1/youtube_connection" }

  def token_for(account = user)
    login(username: account.username)
    response.parsed_body.fetch("access_token")
  end

  def get_status(account = user)
    get path, headers: bearer(token_for(account))
  end

  def expect_answer(status, playlist = nil)
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq("youtube_connection" => { "status" => status, "playlist" => playlist })
  end

  it "returns 401 unauthenticated with no token, a malformed token or an expired token" do
    get path
    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body).to match(expected_unauthenticated_body)

    get path, headers: bearer("this.is.notajwt")
    expect(response).to have_http_status(:unauthorized)

    token = token_for
    travel 16.minutes do
      get path, headers: bearer(token)
    end
    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body).to match(expected_unauthenticated_body)
  end

  it "is not_connected with no playlist and no row, without calling Google, and is never cached" do
    get_status

    expect_answer("not_connected")
    expect(response.headers["Cache-Control"]).to eq("no-store")
    expect(a_request(:any, google_token_endpoint)).not_to have_been_made
  end

  it "is connected when Google accepts the stored token" do
    create(:youtube_connection, user: user, refresh_token: "1//stored")
    stub = stub_request(:post, google_token_endpoint)
      .with(body: hash_including("grant_type" => "refresh_token", "refresh_token" => "1//stored"))
      .to_return(status: 200, body: { access_token: "ya29.discarded" }.to_json)

    get_status

    expect_answer("connected")
    expect(stub).to have_been_requested.once
  end

  it "includes the chosen playlist" do
    create(:youtube_connection, user: user, playlist_id: "PLchosen1", playlist_title: "Chosen")
    stub_google_tokens

    get_status

    expect_answer("connected", { "id" => "PLchosen1", "title" => "Chosen" })
  end

  it "is lost on invalid_grant, keeps the playlist, and later requests do not call Google" do
    connection = create(:youtube_connection, user: user, playlist_id: "PLchosen1", playlist_title: "Chosen")
    stub = stub_google_token_error("invalid_grant")

    get_status
    expect_answer("lost", { "id" => "PLchosen1", "title" => "Chosen" })
    expect(connection.reload.refresh_token).to be_nil

    get_status
    expect_answer("lost", { "id" => "PLchosen1", "title" => "Chosen" })
    expect(stub).to have_been_requested.once
  end

  it "is connected and changes nothing after a 5xx from Google" do
    connection = create(:youtube_connection, user: user)
    stub_google_token_server_error

    expect { get_status }.not_to change { YoutubeConnection.find(connection.id).attributes }
    expect_answer("connected")
  end

  describe "isolation" do
    it "answers only for the caller: user B's status never reads or changes user A's connection" do
      other = create(:user, username: "bea")
      a_connection = create(:youtube_connection, user: user, refresh_token: "1//a-token",
        playlist_id: "PLaaaa", playlist_title: "A's playlist")

      get_status(other)
      expect_answer("not_connected")
      expect(a_request(:any, google_token_endpoint)).not_to have_been_made

      b_connection = create(:youtube_connection, user: other, refresh_token: "1//b-token")
      stub = stub_request(:post, google_token_endpoint)
        .with(body: hash_including("refresh_token" => "1//b-token"))
        .to_return(status: 400, body: { error: "invalid_grant" }.to_json)

      get_status(other)
      expect_answer("lost")
      expect(stub).to have_been_requested.once
      expect(b_connection.reload.lost_at).to be_present
      expect(a_connection.reload.lost_at).to be_nil
      expect(a_connection.refresh_token).to eq("1//a-token")
    end

    it "is not the Calendar connection: a Calendar connection alone is not_connected here" do
      calendar = create(:google_calendar_connection, user: user)

      expect { get_status }.not_to change { calendar.reload.attributes }
      expect_answer("not_connected")
    end

    it "a lost YouTube connection leaves the Calendar status connected" do
      create(:google_calendar_connection, user: user, refresh_token: "1//calendar")
      create(:youtube_connection, user: user, refresh_token: "1//youtube")
      stub_request(:post, google_token_endpoint).with(body: hash_including("refresh_token" => "1//youtube"))
        .to_return(status: 400, body: { error: "invalid_grant" }.to_json)
      stub_request(:post, google_token_endpoint).with(body: hash_including("refresh_token" => "1//calendar"))
        .to_return(status: 200, body: { access_token: "ya29.x" }.to_json)
      token = token_for

      get path, headers: bearer(token)
      expect_answer("lost")

      get "/api/v1/google_calendar_connection", headers: bearer(token)
      expect(response.parsed_body).to eq("google_calendar_connection" => { "status" => "connected" })
    end
  end

  it "fails with a server error, not lost, when the stored token cannot be decrypted" do
    connection = create(:youtube_connection, user: user)
    ActiveRecord::Base.connection.execute(
      "UPDATE youtube_connections SET refresh_token = 'not-ciphertext' WHERE id = #{Integer(connection.id)}"
    )
    token = token_for

    expect { get path, headers: bearer(token) }.to raise_error(ActiveRecord::Encryption::Errors::Decryption)
    expect(connection.reload.lost_at).to be_nil
  end
end
