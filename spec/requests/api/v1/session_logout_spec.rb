require "rails_helper"

# Plan section 6, scenario 11, and the DELETE /session contract (plan section 3).
RSpec.describe "DELETE /api/v1/session", type: :request do
  let!(:user) { create(:user, username: "john") }

  it "answers 204 with no body, deletes the whole family and clears the cookie" do
    token = login_and_get_refresh_token
    refresh(token)                     # the family now has two rows
    current = refresh_token_from
    survivor = create(:refresh_token, user: user) # a different family (another browser)

    logout(current)

    expect(response).to have_http_status(:no_content)
    expect(response.body).to be_empty
    expect_cleared_cookie
    expect(RefreshToken.all).to contain_exactly(survivor)
  end

  it "works with a used (rotated) token's cookie too, deleting the family" do
    token = login_and_get_refresh_token
    refresh(token)

    logout(token)

    expect(response).to have_http_status(:no_content)
    expect(RefreshToken.count).to eq(0)
  end

  it "needs only the cookie: no access token is sent" do
    token = login_and_get_refresh_token

    logout(token)

    expect(response).to have_http_status(:no_content)
    expect(request.headers["Authorization"]).to be_nil
    expect(RefreshToken.count).to eq(0)
  end

  it "works after the access token has expired" do
    freeze_time
    token = login_and_get_refresh_token
    travel 20.minutes

    logout(token)

    expect(response).to have_http_status(:no_content)
    expect(RefreshToken.count).to eq(0)
  end

  it "makes refresh with that cookie answer 401 afterwards" do
    token = login_and_get_refresh_token
    logout(token)

    refresh(token)

    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body["error"]["code"]).to eq("unauthenticated")
  end

  it "answers 204 and clears the cookie with no cookie sent" do
    create(:refresh_token, user: user)
    send_cookie(nil)

    logout

    expect(response).to have_http_status(:no_content)
    expect_cleared_cookie
    expect(RefreshToken.count).to eq(1)
  end

  it "answers 204, clears the cookie and deletes nothing for an unknown cookie" do
    create(:refresh_token, user: user)

    logout("this-token-was-never-issued")

    expect(response).to have_http_status(:no_content)
    expect_cleared_cookie
    expect(RefreshToken.count).to eq(1)
  end

  it "answers 204 for an expired token's cookie and clears it" do
    token = create(:refresh_token, :expired, user: user).token

    logout(token)

    expect(response).to have_http_status(:no_content)
    expect_cleared_cookie
  end

  it "answers 204 when logging out twice" do
    token = login_and_get_refresh_token
    logout(token)

    logout(token)

    expect(response).to have_http_status(:no_content)
  end
end
