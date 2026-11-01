require "rails_helper"

RSpec.describe "POST /api/v1/google_calendar_connection/authorization", type: :request do
  let!(:user) { create(:user, username: "john") }
  let(:path) { "/api/v1/google_calendar_connection/authorization" }
  let(:cookie_name) { "wn_google_oauth" }

  def token_for(account = user)
    login(username: account.username)
    response.parsed_body.fetch("access_token")
  end

  def start(account = user)
    post path, headers: bearer(token_for(account))
  end

  def cookie_line
    raw_set_cookie.lines.find { |line| line.start_with?("#{cookie_name}=") }
  end

  def authorization_query
    URI.decode_www_form(URI(response.parsed_body.fetch("authorization_url")).query).to_h
  end

  it "returns 401 unauthenticated with no token, a malformed token or an expired token, and starts nothing" do
    post path
    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body).to match(expected_unauthenticated_body)

    post path, headers: bearer("this.is.notajwt")
    expect(response).to have_http_status(:unauthorized)

    token = token_for
    travel 16.minutes do
      post path, headers: bearer(token)
    end
    expect(response).to have_http_status(:unauthorized)

    expect(GoogleOauthState.count).to eq(0)
    expect(raw_set_cookie).not_to include(cookie_name)
  end

  it "answers 201 with only Google's consent URL, never cached" do
    start

    expect(response).to have_http_status(:created)
    expect(response.parsed_body.keys).to eq([ "authorization_url" ])
    expect(response.parsed_body["authorization_url"]).to start_with("https://accounts.google.com/o/oauth2/v2/auth?")
    expect(response.headers["Cache-Control"]).to eq("no-store")
  end

  it "asks for exactly the one scope, offline access and consent, with an S256 challenge and no client secret" do
    start

    query = authorization_query
    expect(query["scope"]).to eq("https://www.googleapis.com/auth/calendar.events.owned.readonly")
    expect(query).to include("access_type" => "offline", "prompt" => "consent", "code_challenge_method" => "S256",
      "response_type" => "code", "client_id" => "spec-client-id.apps.googleusercontent.com")
    expect(query).not_to include("include_granted_scopes", "login_hint")
    expect(response.body).not_to include(ENV.fetch("GOOGLE_CLIENT_SECRET"))
  end

  it "stores one pending sign-in for the caller, matching the URL's state and challenge" do
    start

    row = GoogleOauthState.find_by!(user: user)
    query = authorization_query
    expect(row.state_digest).to eq(Digest::SHA256.hexdigest(query["state"]))
    expect(query["code_challenge"]).to eq(row.code_challenge)
    expect(response.body).not_to include(row.code_verifier)
  end

  it "sets the wn_google_oauth cookie to the URL's state with the agreed attributes" do
    start

    line = cookie_line
    expect(line).to be_present
    expect(line[/\A#{cookie_name}=([^;]+)/, 1]).to eq(authorization_query["state"])
    expect(line).to match(/httponly/i)
    expect(line).to match(/samesite=lax/i)
    expect(line).to match(%r{path=/api/v1/google_calendar_connection/callback(;|\s|$)}i)
    expect(line).to match(/max-age=600(;|\s|$)/i)
    expect(line).not_to match(/domain=/i)
    expect(line).not_to match(/secure/i) # Secure in production only
  end

  it "replaces the pending sign-in when started again" do
    start
    first_state = authorization_query["state"]
    start
    second_state = authorization_query["state"]

    expect(second_state).not_to eq(first_state)
    expect(GoogleOauthState.where(user: user).pluck(:state_digest)).to eq([ Digest::SHA256.hexdigest(second_state) ])
  end

  it "is allowed while connected, and does not touch the connection" do
    connection = create(:google_calendar_connection, user: user, refresh_token: "1//kept")

    expect { start }.not_to change { connection.reload.attributes }
    expect(response).to have_http_status(:created)
  end

  it "never touches another user's pending sign-in" do
    other = create(:user, username: "bea")
    start(other)
    other_digest = GoogleOauthState.find_by!(user: other).state_digest

    start(user)

    expect(GoogleOauthState.find_by!(user: other).state_digest).to eq(other_digest)
    expect(GoogleOauthState.count).to eq(2)
  end

  it "does not call Google" do
    start

    expect(a_request(:any, /google/)).not_to have_been_made
  end
end
