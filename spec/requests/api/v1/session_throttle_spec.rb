require "rails_helper"

# Decided by John: rack-attack allows 10 POST /api/v1/session requests a minute
# per IP. The 11th gets 429. Nothing else is throttled.
#
# Needs a real cache: spec/support/rack_attack.rb swaps in a MemoryStore per
# example because the test environment uses :null_store.
RSpec.describe "POST /api/v1/session throttle", type: :request do
  before do
    create(:user, username: "john")
    # Freeze the clock so the 11 requests cannot straddle a minute boundary.
    freeze_time
  end

  it "allows 10 requests a minute and answers the 11th with 429 rate_limited" do
    10.times do
      login(password: "wrong password")
      expect(response).to have_http_status(:unauthorized)
    end

    login(password: "wrong password")

    expect(response).to have_http_status(:too_many_requests)
    expect(response.parsed_body).to match(
      "error" => { "code" => "rate_limited", "message" => a_kind_of(String) }
    )
    expect(response.parsed_body["error"]["message"]).to be_present
  end

  it "counts successful logins too, and keeps refusing a correct password once over the limit" do
    10.times do
      login
      expect(response).to have_http_status(:ok)
    end

    login

    expect(response).to have_http_status(:too_many_requests)
  end

  it "lets requests through again when the minute has passed" do
    11.times { login(password: "wrong password") }
    expect(response).to have_http_status(:too_many_requests)

    travel 61.seconds
    login

    expect(response).to have_http_status(:ok)
  end

  it "counts per IP: another address is not affected" do
    11.times { login(password: "wrong password") }
    expect(response).to have_http_status(:too_many_requests)

    login(env: { "REMOTE_ADDR" => "203.0.113.7" })

    expect(response).to have_http_status(:ok)
  end

  it "does not throttle GET /api/v1/health" do
    15.times do
      get "/api/v1/health"
      expect(response).to have_http_status(:ok)
    end
  end

  it "does not throttle GET /api/v1/me" do
    login
    token = response.parsed_body["access_token"]

    15.times do
      get "/api/v1/me", headers: bearer(token)
      expect(response).to have_http_status(:ok)
    end
  end

  it "does not count other endpoints against the login limit" do
    15.times { get "/api/v1/health" }

    login

    expect(response).to have_http_status(:ok)
  end
end
