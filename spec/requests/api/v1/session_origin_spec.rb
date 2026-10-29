require "rails_helper"

# Plan section 6, scenario 12 (CSRF defense in depth, plan section 3).
RSpec.describe "Origin check on the session endpoints", type: :request do
  let!(:user) { create(:user, username: "john") }
  let(:foreign_origins) do
    [
      "https://evil.example",
      "http://localhost:5174",                # right host, wrong port
      "https://localhost:5173",               # right host and port, wrong scheme
      "http://localhost:5173.evil.example",   # allowed origin as a prefix
      "http://localhost:5173/",               # not an exact origin
      "null"                                  # sandboxed iframes and some redirects send this
    ]
  end

  describe "POST /api/v1/session" do
    it "passes with the allowed origin" do
      login

      expect(response).to have_http_status(:ok)
    end

    it "answers 403 forbidden_origin, sets no cookie and creates no row for a foreign origin, even with the right password" do
      foreign_origins.each do |origin|
        login(origin: origin)

        expect_forbidden_origin
        expect(raw_set_cookie).to be_empty
        expect(response.parsed_body).not_to have_key("access_token")
      end
      expect(RefreshToken.count).to eq(0)
    end

    it "answers 403 forbidden_origin when there is no Origin header" do
      login(origin: nil)

      expect_forbidden_origin
      expect(raw_set_cookie).to be_empty
      expect(RefreshToken.count).to eq(0)
    end

    it "answers 403 (not 401) before even looking at the credentials" do
      login(password: "wrong", origin: "https://evil.example")

      expect_forbidden_origin
    end

    it "does not delete the old family when the origin is foreign" do
      token = login_and_get_refresh_token

      login(origin: "https://evil.example")

      expect_forbidden_origin
      expect(row_for(token)).to be_present
    end
  end

  describe "POST /api/v1/session/refresh" do
    let!(:token) { login_and_get_refresh_token }

    it "passes with the allowed origin" do
      refresh(token)

      expect(response).to have_http_status(:ok)
    end

    it "answers 403 and does nothing else for a foreign origin or none (no rotation, no deletion, no cookie)" do
      (foreign_origins + [ nil ]).each do |origin|
        refresh(token, origin: origin)

        expect_forbidden_origin
        expect(raw_set_cookie).to be_empty
      end
      expect(RefreshToken.count).to eq(1)
      expect(row_for(token).used_at).to be_nil
    end

    it "does not clear a good session when the origin is foreign, even for a reused token" do
      refresh(token)
      travel 31.seconds

      refresh(token, origin: "https://evil.example")

      expect_forbidden_origin
      expect(RefreshToken.count).to eq(2)
    end
  end

  describe "DELETE /api/v1/session" do
    let!(:token) { login_and_get_refresh_token }

    it "passes with the allowed origin" do
      logout(token)

      expect(response).to have_http_status(:no_content)
    end

    it "answers 403 and does nothing else for a foreign origin or none (no deletion, no cookie)" do
      (foreign_origins + [ nil ]).each do |origin|
        logout(token, origin: origin)

        expect_forbidden_origin
        expect(raw_set_cookie).to be_empty
      end
      expect(RefreshToken.count).to eq(1)
      refresh(token)
      expect(response).to have_http_status(:ok)
    end
  end

  describe "outside the session endpoints" do
    it "does not apply to GET /api/v1/me (no Origin header needed)" do
      login
      token = response.parsed_body["access_token"]

      get "/api/v1/me", headers: bearer(token)

      expect(response).to have_http_status(:ok)
    end

    it "does not apply to GET /api/v1/me with a foreign Origin either" do
      login
      token = response.parsed_body["access_token"]

      get "/api/v1/me", headers: bearer(token).merge("Origin" => "https://evil.example")

      expect(response).to have_http_status(:ok)
    end

    it "does not apply to the health endpoints" do
      get "/api/v1/health"
      expect(response).to have_http_status(:ok)

      get "/up"
      expect(response).to have_http_status(:ok)

      get "/api/v1/health", headers: { "Origin" => "https://evil.example" }
      expect(response).to have_http_status(:ok)
    end
  end
end
