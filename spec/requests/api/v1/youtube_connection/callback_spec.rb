require "rails_helper"

RSpec.describe "GET /api/v1/youtube_connection/callback", type: :request do
  let!(:user) { create(:user, username: "john") }
  let(:callback_path) { "/api/v1/youtube_connection/callback" }
  let(:cookie_name) { "wn_youtube_oauth" }
  let(:web_origin) { "http://localhost:5173" }
  let(:youtube_scope) { "https://www.googleapis.com/auth/youtube" }

  def token_for(account = user)
    login(username: account.username)
    response.parsed_body.fetch("access_token")
  end

  # Starts a YouTube sign-in as the account, as the web app would. The test client keeps the wn_youtube_oauth cookie,
  # like the browser. Returns the raw state.
  def start_sign_in(account = user)
    post "/api/v1/youtube_connection/authorization", headers: bearer(token_for(account))
    expect(response).to have_http_status(:created)
    URI.decode_www_form(URI(response.parsed_body.fetch("authorization_url")).query).to_h.fetch("state")
  end

  def stub_youtube_tokens(refresh_token: "1//yt-refresh", scope: youtube_scope)
    stub_google_tokens(refresh_token: refresh_token, scope: scope)
  end

  def set_oauth_cookie(value)
    cookies.delete(cookie_name)
    cookies[cookie_name] = value if value
  end

  def callback(params)
    get callback_path, params: params
  end

  def expect_outcome(outcome)
    expect(response).to have_http_status(:see_other)
    expect(response.headers["Location"]).to eq("#{web_origin}/youtube?youtube=#{outcome}")
  end

  def expect_cookie_cleared
    line = raw_set_cookie.lines.find { |l| l.start_with?("#{cookie_name}=") }
    expect(line).to be_present
    expect(line).to match(/max-age=0/i)
    expect(line).to match(%r{path=/api/v1/youtube_connection/callback(;|\s|$)}i)
  end

  def expect_nothing_stored
    expect(YoutubeConnection.count).to eq(0)
  end

  def expect_google_not_called
    expect(a_request(:any, google_token_endpoint)).not_to have_been_made
  end

  describe "a successful sign-in" do
    it "exchanges the code with the user's verifier, the secret and the YouTube callback, and stores the connection" do
      state = start_sign_in
      verifier = YoutubeOauthState.find_by!(user: user).code_verifier
      exchange = stub_request(:post, google_token_endpoint)
        .with(body: hash_including(
          "grant_type" => "authorization_code", "code" => "the-code", "code_verifier" => verifier,
          "client_secret" => ENV.fetch("GOOGLE_CLIENT_SECRET"),
          "redirect_uri" => "http://www.example.com/api/v1/youtube_connection/callback"
        ))
        .to_return(status: 200, body: { access_token: "ya29.x", refresh_token: "1//new-refresh", scope: youtube_scope }.to_json)

      callback(code: "the-code", state: state)

      expect(exchange).to have_been_requested.once
      expect_outcome("connected")
      connection = YoutubeConnection.find_by!(user: user)
      expect(connection.refresh_token).to eq("1//new-refresh")
      expect(connection.lost_at).to be_nil
      stored = ActiveRecord::Base.connection.select_value(
        "SELECT refresh_token FROM youtube_connections WHERE id = #{Integer(connection.id)}"
      )
      expect(stored).not_to include("1//new-refresh")
      expect(YoutubeOauthState.count).to eq(0)
    end

    it "clears the cookie, is never cached and sends no referrer" do
      state = start_sign_in
      stub_youtube_tokens

      callback(code: "the-code", state: state)

      expect_cookie_cleared
      expect(response.headers["Cache-Control"]).to eq("no-store")
      expect(response.headers["Referrer-Policy"]).to eq("no-referrer")
    end

    it "reconnecting from lost replaces the token, clears lost_at and keeps the chosen playlist" do
      create(:youtube_connection, :lost, user: user, connected_at: 1.day.ago, playlist_id: "PLkept1", playlist_title: "Kept")
      state = start_sign_in
      stub_youtube_tokens(refresh_token: "1//reconnected")

      callback(code: "the-code", state: state)

      expect_outcome("connected")
      connection = YoutubeConnection.find_by!(user: user)
      expect(connection.refresh_token).to eq("1//reconnected")
      expect(connection.lost_at).to be_nil
      expect(connection.playlist_id).to eq("PLkept1")
      expect(YoutubeConnection.count).to eq(1)
    end

    it "leaves the Calendar connection alone" do
      calendar = create(:google_calendar_connection, user: user, refresh_token: "1//calendar")
      state = start_sign_in
      stub_youtube_tokens

      expect { callback(code: "the-code", state: state) }.not_to change { calendar.reload.attributes }
      expect_outcome("connected")
    end

    it "needs no bearer token" do
      state = start_sign_in
      stub_youtube_tokens

      get callback_path, params: { code: "the-code", state: state }, headers: { "Authorization" => nil }

      expect_outcome("connected")
    end
  end

  describe "Google reports an error" do
    it "redirects cancelled for access_denied, storing nothing and not calling Google" do
      state = start_sign_in

      callback(error: "access_denied", state: state)

      expect_outcome("cancelled")
      expect_cookie_cleared
      expect_nothing_stored
      expect_google_not_called
      expect(YoutubeOauthState.count).to eq(0)
    end

    it "redirects failed for any other error" do
      state = start_sign_in

      callback(error: "server_error", state: state)

      expect_outcome("failed")
      expect_nothing_stored
      expect_google_not_called
    end
  end

  describe "a bad state" do
    it "fails without a state" do
      start_sign_in

      callback(code: "the-code")

      expect_outcome("failed")
      expect_cookie_cleared
      expect_nothing_stored
      expect_google_not_called
    end

    it "fails when the state does not match the cookie, leaving the pending sign-in unused" do
      start_sign_in

      callback(code: "the-code", state: "a-different-state")

      expect_outcome("failed")
      expect_nothing_stored
      expect_google_not_called
      expect(YoutubeOauthState.count).to eq(1)
    end

    it "fails once the sign-in is more than ten minutes old" do
      state = start_sign_in

      travel 11.minutes do
        set_oauth_cookie(state)
        callback(code: "the-code", state: state)
      end

      expect_outcome("failed")
      expect_nothing_stored
      expect_google_not_called
    end

    it "fails when the callback is replayed" do
      state = start_sign_in
      exchange = stub_youtube_tokens
      callback(code: "the-code", state: state)
      expect_outcome("connected")
      YoutubeConnection.delete_all

      set_oauth_cookie(state)
      callback(code: "the-code", state: state)

      expect_outcome("failed")
      expect_nothing_stored
      expect(exchange).to have_been_requested.once
    end

    it "fails in a browser without the cookie" do
      state = start_sign_in
      set_oauth_cookie(nil)

      callback(code: "the-code", state: state)

      expect_outcome("failed")
      expect_nothing_stored
      expect_google_not_called
    end

    it "fails for a Calendar sign-in's state, even with the state in the YouTube cookie, and leaves it pending" do
      calendar_state, = GoogleOauthState.start!(user)
      set_oauth_cookie(calendar_state)

      callback(code: "the-code", state: calendar_state)

      expect_outcome("failed")
      expect_nothing_stored
      expect_google_not_called
      expect(GoogleOauthState.where(user: user).count).to eq(1)
    end

    it "fails for a state or code sent as an array" do
      state = start_sign_in

      get "#{callback_path}?state[]=#{CGI.escape(state)}&code=the-code"
      expect_outcome("failed")

      get "#{callback_path}?state=#{CGI.escape(state)}&code[]=the-code"
      expect_outcome("failed")

      expect_nothing_stored
      expect_google_not_called
    end
  end

  describe "Google's token response" do
    it "fails without a refresh token" do
      state = start_sign_in
      stub_youtube_tokens(refresh_token: nil)

      callback(code: "the-code", state: state)

      expect_outcome("failed")
      expect_nothing_stored
    end

    it "fails without the YouTube scope, even with the Calendar's" do
      state = start_sign_in
      stub_youtube_tokens(scope: GoogleOauthHelpers::GOOGLE_SCOPE)

      callback(code: "the-code", state: state)

      expect_outcome("failed")
      expect_nothing_stored
    end

    {
      "invalid_grant" => -> { stub_google_token_error("invalid_grant") },
      "a 5xx" => -> { stub_google_token_server_error },
      "a timeout" => -> { stub_google_token_timeout }
    }.each do |failure, stub|
      it "fails on #{failure}" do
        state = start_sign_in
        instance_exec(&stub)

        callback(code: "the-code", state: state)

        expect_outcome("failed")
        expect_cookie_cleared
        expect_nothing_stored
      end
    end
  end

  describe "users" do
    it "A's state in B's browser fails and leaves A's sign-in pending" do
      a_state = start_sign_in(user)
      other = create(:user, username: "bea")
      start_sign_in(other)

      callback(code: "the-code", state: a_state)

      expect_outcome("failed")
      expect_nothing_stored
      expect(YoutubeOauthState.find_by(user: user)).to be_present
    end
  end

  describe "the redirect target" do
    it "always uses the first configured origin and the fixed YouTube path, whatever the request says" do
      state = start_sign_in
      stub_youtube_tokens
      allow(Rails.configuration.x).to receive(:allowed_origins).and_return([ "https://first.example", "https://second.example" ])

      get callback_path,
        params: { code: "the-code", state: state, redirect_uri: "https://evil.example", youtube: "evil" },
        headers: { "Host" => "evil.example", "Origin" => "https://evil.example", "Referer" => "https://evil.example/" }

      expect(response).to have_http_status(:see_other)
      expect(response.headers["Location"]).to eq("https://first.example/youtube?youtube=connected")
    end
  end
end
