require "rails_helper"

RSpec.describe "GET /api/v1/google_calendar_connection", type: :request do
  let!(:user) { create(:user, username: "john") }
  let(:path) { "/api/v1/google_calendar_connection" }

  def token_for(account = user)
    login(username: account.username)
    response.parsed_body.fetch("access_token")
  end

  def get_status(account = user)
    get path, headers: bearer(token_for(account))
  end

  def expect_status(status)
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq("google_calendar_connection" => { "status" => status })
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

  it "is not_connected with no row, without calling Google" do
    get_status

    expect_status("not_connected")
    expect(a_request(:any, google_token_endpoint)).not_to have_been_made
  end

  it "is connected when Google accepts the stored token, which it sent with the client credentials" do
    create(:google_calendar_connection, user: user, refresh_token: "1//stored")
    stub = stub_request(:post, google_token_endpoint)
      .with(body: hash_including("grant_type" => "refresh_token", "refresh_token" => "1//stored",
        "client_secret" => "SENTINEL-google-client-secret-5d1c-do-not-leak"))
      .to_return(status: 200, body: { access_token: "ya29.discarded" }.to_json)

    get_status

    expect_status("connected")
    expect(stub).to have_been_requested.once
  end

  it "keeps a new refresh token Google sends with the check" do
    connection = create(:google_calendar_connection, user: user, refresh_token: "1//stored")
    stub_google_tokens(refresh_token: "1//rotated")

    get_status

    expect_status("connected")
    expect(connection.reload.refresh_token).to eq("1//rotated")
  end

  it "is lost on invalid_grant, clearing the token and setting lost_at, and later requests do not call Google" do
    connection = create(:google_calendar_connection, user: user)
    stub = stub_google_token_error("invalid_grant")

    get_status
    expect_status("lost")
    connection.reload
    expect(connection.refresh_token).to be_nil
    expect(connection.lost_at).to be_present

    get_status
    expect_status("lost")
    expect(stub).to have_been_requested.once
  end

  {
    "a timeout" => -> { stub_google_token_timeout },
    "a 5xx" => -> { stub_google_token_server_error },
    "invalid_client" => -> { stub_google_token_error("invalid_client", status: 401) }
  }.each do |failure, stub|
    it "is connected and changes nothing after #{failure}" do
      connection = create(:google_calendar_connection, user: user, refresh_token: "1//stored")
      instance_exec(&stub)

      expect { get_status }.not_to change { GoogleCalendarConnection.find(connection.id).attributes }
      expect_status("connected")
    end
  end

  it "answers only for the caller: user B's status never reads or changes user A's connection" do
    other = create(:user, username: "bea")
    a_connection = create(:google_calendar_connection, user: user, refresh_token: "1//a-token")

    get_status(other)
    expect_status("not_connected")
    expect(a_request(:any, google_token_endpoint)).not_to have_been_made

    b_connection = create(:google_calendar_connection, user: other, refresh_token: "1//b-token")
    stub = stub_request(:post, google_token_endpoint)
      .with(body: hash_including("refresh_token" => "1//b-token"))
      .to_return(status: 400, body: { error: "invalid_grant" }.to_json)

    get_status(other)
    expect_status("lost")
    expect(stub).to have_been_requested.once
    expect(b_connection.reload.lost_at).to be_present
    expect(a_connection.reload.lost_at).to be_nil
    expect(a_connection.refresh_token).to eq("1//a-token")
  end

  it "fails with a server error, not lost, when the stored token cannot be decrypted" do
    connection = create(:google_calendar_connection, user: user)
    ActiveRecord::Base.connection.execute(
      "UPDATE google_calendar_connections SET refresh_token = 'not-ciphertext' WHERE id = #{Integer(connection.id)}"
    )
    token = token_for

    expect { get path, headers: bearer(token) }.to raise_error(ActiveRecord::Encryption::Errors::Decryption)
    expect(connection.reload.lost_at).to be_nil
  end
end
