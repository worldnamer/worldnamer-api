require "rails_helper"

# Plan section 6, scenario 13, and the Login bullets in plan section 2.
RSpec.describe "Login with an existing refresh cookie", type: :request do
  let!(:user) { create(:user, username: "john") }

  it "deletes the old family of that cookie, then creates a new one" do
    old_token = login_and_get_refresh_token
    refresh(old_token)                      # old family: two rows
    cookie_token = refresh_token_from
    old_family = row_for(cookie_token).family_id

    login_with_cookie(cookie_token)

    expect(response).to have_http_status(:ok)
    expect(RefreshToken.where(family_id: old_family)).to be_empty
    new_token = refresh_token_from
    expect(new_token).to be_present
    expect(RefreshToken.count).to eq(1)
    expect(row_for(new_token).family_id).not_to eq(old_family)
    expect(row_for(new_token).user_id).to eq(user.id)
  end

  it "makes the old cookie useless" do
    old_token = login_and_get_refresh_token

    login_with_cookie(old_token)
    refresh(old_token)

    expect(response).to have_http_status(:unauthorized)
  end

  it "leaves the user's other families (other browsers) alone" do
    other_browser = create(:refresh_token, user: user)
    old_token = login_and_get_refresh_token

    login_with_cookie(old_token)

    expect(RefreshToken.exists?(other_browser.id)).to be(true)
    expect(RefreshToken.count).to eq(2)
  end

  it "does not delete anything for a cookie that belongs to a different user's family" do
    stranger_row = create(:refresh_token)

    login_with_cookie(stranger_row.token)

    expect(response).to have_http_status(:ok)
    expect(RefreshToken.exists?(stranger_row.id)).to be(true)
  end

  it "deletes nothing and still logs in when the cookie is unknown" do
    login_with_cookie("this-token-was-never-issued")

    expect(response).to have_http_status(:ok)
    expect(RefreshToken.count).to eq(1)
  end

  it "keeps the old family when the login fails" do
    old_token = login_and_get_refresh_token

    send_cookie(old_token)
    login(password: "wrong password")

    expect(response).to have_http_status(:unauthorized)
    expect(row_for(old_token)).to be_present
  end

  it "purges the user's expired rows at login" do
    expired = create_list(:refresh_token, 2, :expired, user: user)
    active = create(:refresh_token, user: user)

    login

    expect(RefreshToken.where(id: expired.map(&:id))).to be_empty
    expect(RefreshToken.exists?(active.id)).to be(true)
  end

  it "does not purge other users' expired rows" do
    other_expired = create(:refresh_token, :expired)

    login

    expect(RefreshToken.exists?(other_expired.id)).to be(true)
  end

  it "does not purge on refresh (only at login)" do
    token = login_and_get_refresh_token
    expired = create(:refresh_token, :expired, user: user)

    refresh(token)

    expect(RefreshToken.exists?(expired.id)).to be(true)
  end

  def login_with_cookie(token)
    send_cookie(token)
    login
  end
end
