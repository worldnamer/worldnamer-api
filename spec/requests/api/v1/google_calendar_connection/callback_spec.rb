require "rails_helper"

RSpec.describe "GET /api/v1/google_calendar_connection/callback", type: :request do
  let!(:user) { create(:user, username: "john") }
  let(:callback_path) { "/api/v1/google_calendar_connection/callback" }
  let(:cookie_name) { "wn_google_oauth" }
  let(:web_origin) { "http://localhost:5173" }

  def token_for(account = user)
    login(username: account.username)
    response.parsed_body.fetch("access_token")
  end

  # Starts a sign-in as the account, as the web app would. The test client keeps the wn_google_oauth cookie, like the
  # browser. Returns the raw state.
  def start_sign_in(account = user)
    post "/api/v1/google_calendar_connection/authorization", headers: bearer(token_for(account))
    expect(response).to have_http_status(:created)
    URI.decode_www_form(URI(response.parsed_body.fetch("authorization_url")).query).to_h.fetch("state")
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
    expect(response.headers["Location"]).to eq("#{web_origin}/?google_calendar=#{outcome}")
  end

  def expect_cookie_cleared
    line = raw_set_cookie.lines.find { |l| l.start_with?("#{cookie_name}=") }
    expect(line).to be_present
    expect(line).to match(/max-age=0/i)
    expect(line).to match(%r{path=/api/v1/google_calendar_connection/callback(;|\s|$)}i)
  end

  def expect_nothing_stored
    expect(GoogleCalendarConnection.count).to eq(0)
  end

  def expect_google_not_called
    expect(a_request(:any, google_token_endpoint)).not_to have_been_made
  end

  describe "a successful sign-in" do
    it "exchanges the code with the user's own verifier and the client secret, stores the connection, and redirects connected" do
      state = start_sign_in
      verifier = GoogleOauthState.find_by!(user: user).code_verifier
      exchange = stub_request(:post, google_token_endpoint)
        .with(body: hash_including(
          "grant_type" => "authorization_code", "code" => "the-code", "code_verifier" => verifier,
          "client_secret" => ENV.fetch("GOOGLE_CLIENT_SECRET"),
          "redirect_uri" => "http://www.example.com/api/v1/google_calendar_connection/callback"
        ))
        .to_return(status: 200, body: { access_token: "ya29.x", refresh_token: "1//new-refresh",
          scope: GoogleOauthHelpers::GOOGLE_SCOPE }.to_json)

      callback(code: "the-code", state: state)

      expect(exchange).to have_been_requested.once
      expect_outcome("connected")
      connection = GoogleCalendarConnection.find_by!(user: user)
      expect(connection.refresh_token).to eq("1//new-refresh")
      expect(connection.lost_at).to be_nil
      expect(stored_refresh_token_ciphertext(connection)).not_to include("1//new-refresh")
      expect(GoogleOauthState.count).to eq(0)
    end

    it "clears the cookie, is never cached and sends no referrer" do
      state = start_sign_in
      stub_google_tokens(refresh_token: "1//new-refresh")

      callback(code: "the-code", state: state)

      expect_cookie_cleared
      expect(response.headers["Cache-Control"]).to eq("no-store")
      expect(response.headers["Referrer-Policy"]).to eq("no-referrer")
    end

    it "is followed by a status of connected" do
      state = start_sign_in
      stub_google_tokens(refresh_token: "1//new-refresh", grant_type: "authorization_code")
      callback(code: "the-code", state: state)
      stub_google_tokens(grant_type: "refresh_token")

      get "/api/v1/google_calendar_connection", headers: bearer(token_for)

      expect(response.parsed_body).to eq("google_calendar_connection" => { "status" => "connected" })
    end

    it "reconnecting from lost replaces the token and clears lost_at" do
      create(:google_calendar_connection, :lost, user: user, connected_at: 1.day.ago)
      state = start_sign_in
      stub_google_tokens(refresh_token: "1//reconnected")

      callback(code: "the-code", state: state)

      expect_outcome("connected")
      connection = GoogleCalendarConnection.find_by!(user: user)
      expect(connection.refresh_token).to eq("1//reconnected")
      expect(connection.lost_at).to be_nil
      expect(connection.connected_at).to be > 1.minute.ago
      expect(GoogleCalendarConnection.count).to eq(1)
    end

    it "needs no bearer token" do
      state = start_sign_in
      stub_google_tokens(refresh_token: "1//new-refresh")

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
      expect(GoogleOauthState.count).to eq(0) # the sign-in is used up
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
    it "fails without a state, storing nothing and not calling Google" do
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
      expect(GoogleOauthState.count).to eq(1)
    end

    it "fails for an unknown state even when the cookie matches it" do
      start_sign_in
      set_oauth_cookie("unknown-state-value")

      callback(code: "the-code", state: "unknown-state-value")

      expect_outcome("failed")
      expect_nothing_stored
      expect_google_not_called
    end

    it "fails once the sign-in is more than ten minutes old" do
      state = start_sign_in

      travel 11.minutes do
        set_oauth_cookie(state) # the browser would have dropped it; send it anyway
        callback(code: "the-code", state: state)
      end

      expect_outcome("failed")
      expect_nothing_stored
      expect_google_not_called
      expect(GoogleOauthState.count).to eq(0)
    end

    it "fails when the callback is replayed" do
      state = start_sign_in
      exchange = stub_google_tokens(refresh_token: "1//first")
      callback(code: "the-code", state: state)
      expect_outcome("connected")
      GoogleCalendarConnection.delete_all

      set_oauth_cookie(state)
      callback(code: "the-code", state: state)

      expect_outcome("failed")
      expect_nothing_stored
      expect(exchange).to have_been_requested.once
    end

    it "fails in a browser without the cookie, so a link to someone else's sign-in attaches nothing" do
      state = start_sign_in
      set_oauth_cookie(nil)

      callback(code: "the-code", state: state)

      expect_outcome("failed")
      expect_nothing_stored
      expect_google_not_called
      expect(GoogleOauthState.count).to eq(1)
    end

    it "fails for the first state once a second start has replaced it" do
      first_state = start_sign_in
      start_sign_in
      set_oauth_cookie(first_state)

      callback(code: "the-code", state: first_state)

      expect_outcome("failed")
      expect_nothing_stored
      expect_google_not_called
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
      stub_google_tokens(refresh_token: nil)

      callback(code: "the-code", state: state)

      expect_outcome("failed")
      expect_nothing_stored
    end

    it "fails without the calendar scope" do
      state = start_sign_in
      stub_google_tokens(refresh_token: "1//new-refresh", scope: "openid")

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
    it "user B's sign-in stores B's connection and never touches A's" do
      a_connection = create(:google_calendar_connection, user: user, refresh_token: "1//a-token")
      other = create(:user, username: "bea")
      state = start_sign_in(other)
      stub_google_tokens(refresh_token: "1//b-token")

      callback(code: "the-code", state: state)

      expect_outcome("connected")
      expect(GoogleCalendarConnection.find_by!(user: other).refresh_token).to eq("1//b-token")
      expect(a_connection.reload.refresh_token).to eq("1//a-token")
    end

    it "A's state in B's browser fails and leaves A's sign-in pending" do
      a_state = start_sign_in(user)
      other = create(:user, username: "bea")
      start_sign_in(other) # B's browser now holds B's cookie

      callback(code: "the-code", state: a_state)

      expect_outcome("failed")
      expect_nothing_stored
      expect_google_not_called
      expect(GoogleOauthState.find_by(user: user)).to be_present
    end
  end

  describe "the redirect target" do
    it "always uses the first configured origin, whatever the request says" do
      state = start_sign_in
      stub_google_tokens(refresh_token: "1//new-refresh")
      # After the sign-in starts, because logging in checks Origin against the same list.
      allow(Rails.configuration.x).to receive(:allowed_origins).and_return([ "https://first.example", "https://second.example" ])

      get callback_path,
        params: { code: "the-code", state: state, redirect_uri: "https://evil.example", google_calendar: "evil" },
        headers: { "Host" => "evil.example", "Origin" => "https://evil.example", "Referer" => "https://evil.example/" }

      expect(response).to have_http_status(:see_other)
      expect(response.headers["Location"]).to eq("https://first.example/?google_calendar=connected")
    end
  end
end
