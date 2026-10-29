require "rails_helper"

# Plan section 6, scenario 1 (cookie part), and the Cookie section of plan section 3.
RSpec.describe "Refresh cookie set by POST /api/v1/session", type: :request do
  let!(:user) { create(:user, username: "john") }

  it "sets wn_refresh with HttpOnly, SameSite=Strict, Path=/api/v1/session and Max-Age=5184000" do
    login

    expect(response).to have_http_status(:ok)
    line = raw_set_cookie.lines.find { |l| l.start_with?("wn_refresh=") }
    expect(line).to be_present
    expect(line).to match(/;\s*httponly/i)
    expect(line).to match(/;\s*samesite=strict/i)
    expect(line).to match(%r{;\s*path=/api/v1/session\s*(;|$)}i)
    expect(line).to match(/;\s*max-age=5184000\b/i)
  end

  it "sets no Domain attribute (host-only cookie)" do
    login

    expect(raw_set_cookie).not_to match(/domain=/i)
  end

  it "is not Secure outside production (plain http works locally)" do
    login

    expect(raw_set_cookie).not_to match(/;\s*secure/i)
  end

  # Assumes the implementation decides with Rails.env.production?, as the plan words it
  # ("Secure in production only"). The test environment cannot boot as production.
  it "sets Secure in production" do
    allow(Rails.env).to receive(:production?).and_return(true)

    login

    expect(raw_set_cookie).to match(/;\s*secure/i)
  end

  it "sends an opaque value that is not the stored digest, and stores only the digest" do
    login

    token = refresh_token_from
    expect(token).to be_present
    expect(token.length).to be >= 43 # urlsafe_base64(32)
    expect(token).not_to match(/\A\h{64}\z/) # not a SHA256 hex digest

    row = RefreshToken.find_by!(user: user)
    expect(row.token_digest).to eq(digest_of(token))
    expect(row.token_digest).not_to eq(token)
    expect(RefreshToken.where(token_digest: token)).to be_empty
  end

  it "creates one active row with a 60 day expiry in a new family" do
    freeze_time
    login

    row = RefreshToken.find_by!(user: user)
    expect(row.used_at).to be_nil
    expect(row.expires_at).to be_within(1.second).of(60.days.from_now)
    expect(row.family_id).to match(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/)
  end

  it "sets no cookie and creates no row when login fails" do
    login(password: "not the right password")

    expect(response).to have_http_status(:unauthorized)
    expect(raw_set_cookie).not_to include("wn_refresh")
    expect(RefreshToken.count).to eq(0)
  end

  it "gives each login a different refresh token" do
    first = login_and_get_refresh_token
    second = login_and_get_refresh_token

    expect(first).not_to eq(second)
  end
end
