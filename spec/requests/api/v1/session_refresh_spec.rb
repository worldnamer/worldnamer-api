require "rails_helper"

# Plan section 6, scenarios 5 to 10, against the state table in plan section 2.
RSpec.describe "POST /api/v1/session/refresh", type: :request do
  let!(:user) { create(:user, username: "john") }
  let(:login_body_keys) { %w[access_token token_type expires_in user] }

  # Logs in and returns the first raw token (T1). The cookie jar holds it too.
  let(:first_token) { login_and_get_refresh_token }

  def family_rows(token)
    RefreshToken.where(family_id: row_for(token).family_id)
  end

  describe "scenario 5: active token" do
    it "answers 200 with the login body shape and a new, different access token" do
      freeze_time
      login
      old_access = response.parsed_body["access_token"]
      token = refresh_token_from

      travel 5.minutes
      refresh(token)

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body.keys).to match_array(login_body_keys)
      expect(body).to include("token_type" => "Bearer", "expires_in" => 900, "user" => { "username" => "john" })
      expect(body["access_token"]).not_to eq(old_access)
      expect(decode_jwt(body["access_token"])["sub"]).to eq(user.id.to_s)
      expect(response.headers["Cache-Control"]).to include("no-store")
    end

    it "gives an access token that /me accepts" do
      refresh(first_token)

      get "/api/v1/me", headers: bearer(response.parsed_body["access_token"])

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq("user" => { "username" => "john" })
    end

    it "sets a new, different cookie with the full set of attributes" do
      refresh(first_token)

      new_token = refresh_token_from
      expect(new_token).to be_present
      expect(new_token).not_to eq(first_token)
      line = raw_set_cookie.lines.find { |l| l.start_with?("wn_refresh=") }
      expect(line).to match(/;\s*httponly/i)
      expect(line).to match(/;\s*samesite=strict/i)
      expect(line).to match(%r{;\s*path=/api/v1/session\s*(;|$)}i)
      expect(line).to match(/;\s*max-age=5184000\b/i)
      expect(line).not_to match(/domain=/i)
    end

    it "marks the old row used, and inserts one new active row in the same family" do
      freeze_time
      first_token
      old_row = row_for(first_token)

      expect { refresh(first_token) }.to change(RefreshToken, :count).by(1)

      expect(old_row.reload.used_at).to be_within(1.second).of(Time.current)
      new_row = row_for(refresh_token_from)
      expect(new_row.family_id).to eq(old_row.family_id)
      expect(new_row.user_id).to eq(user.id)
      expect(new_row.used_at).to be_nil
      expect(new_row.id).not_to eq(old_row.id)
    end

    it "stores only the digest of the new token" do
      refresh(first_token)

      new_token = refresh_token_from
      expect(RefreshToken.pluck(:token_digest)).to include(digest_of(new_token))
      expect(RefreshToken.pluck(:token_digest)).not_to include(new_token)
    end

    it "lets the new token be rotated in turn (a chain of refreshes)" do
      token = first_token
      3.times do
        travel 31.seconds
        refresh(token)
        expect(response).to have_http_status(:ok)
        token = refresh_token_from
        expect(token).to be_present
      end

      expect(RefreshToken.count).to eq(4)
      expect(RefreshToken.distinct.pluck(:family_id).size).to eq(1)
    end

    it "uses the cookie jar the browser would: a refresh straight after login works with no cookie argument" do
      login

      refresh

      expect(response).to have_http_status(:ok)
    end
  end

  describe "scenario 6: used token within the 30 second grace window" do
    before do
      freeze_time
      first_token
      refresh(first_token) # T1 -> T2
      @second_token = refresh_token_from
    end

    it "answers 200 with a new access token and the login body shape" do
      travel 29.seconds
      refresh(first_token)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.keys).to match_array(login_body_keys)
      expect(response.parsed_body).to include("user" => { "username" => "john" })
      get "/api/v1/me", headers: bearer(response.parsed_body["access_token"])
      expect(response).to have_http_status(:ok)
    end

    it "sets no cookie, creates no row, and the family survives" do
      travel 10.seconds
      count_before = RefreshToken.count

      refresh(first_token)

      expect(raw_set_cookie).to be_empty
      expect(RefreshToken.count).to eq(count_before)
      expect(family_rows(first_token).count).to eq(2)
    end

    it "leaves the successor token usable afterwards" do
      travel 10.seconds
      refresh(first_token)

      refresh(@second_token)

      expect(response).to have_http_status(:ok)
      expect(refresh_token_from).to be_present
    end

    it "does not push the used row's used_at forward (the window is measured from the rotation)" do
      used_at = row_for(first_token).used_at
      travel 20.seconds
      refresh(first_token)
      expect(row_for(first_token).used_at).to be_within(1.second).of(used_at)

      travel 11.seconds # 31 s after the rotation, 11 s after the grace use
      refresh(first_token)

      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "scenario 7: used token past the grace window (reuse)" do
    before do
      freeze_time
      first_token
      refresh(first_token) # T1 -> T2
      @second_token = refresh_token_from
    end

    it "answers 401 unauthenticated with a cookie-clearing Set-Cookie" do
      travel 31.seconds
      refresh(first_token)

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body).to match("error" => { "code" => "unauthenticated", "message" => a_kind_of(String) })
      expect(response.parsed_body).not_to have_key("access_token")
      expect_cleared_cookie
    end

    it "deletes every row in the family" do
      expect(RefreshToken.count).to eq(2)
      travel 31.seconds

      refresh(first_token)

      expect(RefreshToken.count).to eq(0)
    end

    it "makes the successor token fail afterwards" do
      travel 31.seconds
      refresh(first_token)

      refresh(@second_token)

      expect(response).to have_http_status(:unauthorized)
      expect_cleared_cookie
    end

    it "leaves another family of the same user, and other users' families, alone" do
      other_family = create(:refresh_token, user: user)
      stranger = create(:refresh_token)
      travel 31.seconds

      refresh(first_token)

      expect(RefreshToken.all).to contain_exactly(other_family, stranger)
    end
  end

  describe "expired token" do
    it "answers 401, clears the cookie and deletes the family" do
      freeze_time
      first_token
      refresh(first_token)
      expired_token = refresh_token_from
      family_id = row_for(expired_token).family_id
      survivor = create(:refresh_token, user: user)

      travel 61.days
      refresh(expired_token)

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body).to match("error" => { "code" => "unauthenticated", "message" => a_kind_of(String) })
      expect_cleared_cookie
      expect(RefreshToken.where(family_id: family_id)).to be_empty
      expect(RefreshToken.all).to contain_exactly(survivor)
    end

    it "treats a row expiring exactly now as expired" do
      token = create(:refresh_token, user: user, expires_at: 1.second.ago).token

      refresh(token)

      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "scenario 8: unknown or missing cookie" do
    it "answers 401 and clears the cookie when the cookie is unknown" do
      refresh("this-token-was-never-issued")

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body).to match("error" => { "code" => "unauthenticated", "message" => a_kind_of(String) })
      expect_cleared_cookie
    end

    it "answers 401 and clears the cookie when there is no cookie at all" do
      send_cookie(nil)

      refresh

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body["error"]["code"]).to eq("unauthenticated")
      expect_cleared_cookie
    end

    it "answers 401 when the cookie holds the stored digest instead of the token" do
      record = create(:refresh_token, user: user)

      refresh(record.token_digest)

      expect(response).to have_http_status(:unauthorized)
      expect(RefreshToken.exists?(record.id)).to be(true)
    end

    it "answers 401 for an empty cookie value" do
      refresh("")

      expect(response).to have_http_status(:unauthorized)
      expect_cleared_cookie
    end

    it "deletes nothing for an unknown cookie" do
      create(:refresh_token, user: user)

      expect { refresh("unknown") }.not_to change(RefreshToken, :count)
    end
  end

  describe "scenario 9: sliding expiry" do
    it "pushes expires_at out to 60 days from the time of each refresh" do
      freeze_time
      token = first_token

      travel 10.days
      refresh(token)
      token = refresh_token_from
      expect(row_for(token).expires_at).to be_within(1.second).of(60.days.from_now)

      travel 40.days
      refresh(token)
      token = refresh_token_from
      expect(row_for(token).expires_at).to be_within(1.second).of(60.days.from_now)
    end

    it "keeps a session alive past the original 60 days while it is used" do
      freeze_time
      token = first_token
      4.times do
        travel 20.days
        refresh(token)
        expect(response).to have_http_status(:ok)
        token = refresh_token_from
      end
    end
  end

  describe "scenario 10: two refreshes with the same token, back to back" do
    it "both return 200 and only one new row exists" do
      token = first_token

      refresh(token)
      first_status = response.status
      first_cookie = refresh_token_from
      refresh(token)

      expect(first_status).to eq(200)
      expect(response).to have_http_status(:ok)
      expect(RefreshToken.count).to eq(2)
      expect(first_cookie).to be_present
    end

    it "sets a cookie on exactly the first, and none on the second" do
      token = first_token

      refresh(token)
      expect(refresh_token_from).to be_present
      refresh(token)

      expect(raw_set_cookie).to be_empty
    end

    it "leaves the family alive and the winner's token usable" do
      token = first_token
      refresh(token)
      winner = refresh_token_from
      refresh(token)

      refresh(winner)

      expect(response).to have_http_status(:ok)
    end
  end
end
