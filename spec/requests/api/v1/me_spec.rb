require "rails_helper"

# Plan section 6, API scenario 4.
RSpec.describe "GET /api/v1/me", type: :request do
  let!(:user) { create(:user, username: "john") }

  def fresh_token
    login
    response.parsed_body.fetch("access_token")
  end

  def expect_unauthenticated
    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body).to match(expected_unauthenticated_body)
    expect(response.parsed_body["error"]["message"]).to be_present
    expect(response.parsed_body.keys).to eq([ "error" ])
    expect(response.parsed_body["error"].keys).to contain_exactly("code", "message")
  end

  it "returns the user for a valid token" do
    get "/api/v1/me", headers: bearer(fresh_token)

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq("user" => { "username" => "john" })
  end

  it "still accepts the token 14 minutes after login" do
    token = fresh_token

    travel 14.minutes do
      get "/api/v1/me", headers: bearer(token)
    end

    expect(response).to have_http_status(:ok)
  end

  it "returns 401 unauthenticated when the token is expired (past 15 minutes)" do
    token = fresh_token

    travel 16.minutes do
      get "/api/v1/me", headers: bearer(token)
    end

    expect_unauthenticated
  end

  it "returns 401 unauthenticated with no Authorization header" do
    get "/api/v1/me"

    expect_unauthenticated
  end

  it "returns 401 unauthenticated with an empty bearer token" do
    get "/api/v1/me", headers: { "Authorization" => "Bearer " }

    expect_unauthenticated
  end

  it "returns 401 unauthenticated with a malformed token" do
    get "/api/v1/me", headers: bearer("this.is.notajwt")

    expect_unauthenticated
  end

  it "returns 401 unauthenticated with a token that is not even dotted" do
    get "/api/v1/me", headers: bearer("garbage")

    expect_unauthenticated
  end

  it "returns 401 unauthenticated with the wrong auth scheme" do
    get "/api/v1/me", headers: { "Authorization" => "Basic #{fresh_token}" }

    expect_unauthenticated
  end

  it "returns 401 unauthenticated for a token signed with the wrong key" do
    claims = decode_jwt(fresh_token)

    # Control: the same claims signed with the real key are accepted.
    get "/api/v1/me", headers: bearer(JWT.encode(claims, jwt_secret, "HS256"))
    expect(response).to have_http_status(:ok)

    get "/api/v1/me", headers: bearer(JWT.encode(claims, "some-other-key", "HS256"))
    expect_unauthenticated
  end

  it "returns 401 unauthenticated for an unsigned (alg none) token" do
    claims = decode_jwt(fresh_token)

    get "/api/v1/me", headers: bearer(JWT.encode(claims, nil, "none"))

    expect_unauthenticated
  end

  it "returns 401 unauthenticated when the user no longer exists" do
    token = fresh_token
    user.destroy!

    get "/api/v1/me", headers: bearer(token)

    expect_unauthenticated
  end
end
