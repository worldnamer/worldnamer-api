require "rails_helper"

# Plan section 6, API scenarios 1 (without the refresh cookie, which is api-2), 2 and 3.
RSpec.describe "POST /api/v1/session", type: :request do
  let!(:user) { create(:user, username: "john", password: AuthHelpers::TEST_PASSWORD) }

  let(:invalid_credentials_body) do
    { "error" => { "code" => "invalid_credentials", "message" => "Invalid username or password." } }
  end

  describe "scenario 1: correct credentials" do
    it "returns 200 with the documented body" do
      login

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to match(
        "access_token" => a_string_matching(/\A[\w-]+\.[\w-]+\.[\w-]+\z/),
        "token_type" => "Bearer",
        "expires_in" => 900,
        "user" => { "username" => "john" }
      )
    end

    it "sends Cache-Control: no-store" do
      login

      expect(response.headers["Cache-Control"]).to include("no-store")
    end

    it "returns an HS256 JWT for the user that lives 15 minutes" do
      login

      header = JWT.decode(response.parsed_body["access_token"], nil, false).last
      claims = decode_jwt(response.parsed_body["access_token"])

      expect(header["alg"]).to eq("HS256")
      expect(claims["sub"]).to eq(user.id.to_s)
      expect(claims["jti"]).to be_present
      expect(claims["exp"] - claims["iat"]).to eq(900)
    end

    it "gives each login a different token" do
      login
      first = response.parsed_body["access_token"]
      login
      second = response.parsed_body["access_token"]

      expect(second).not_to eq(first)
    end

    it "ignores unknown keys in the request body" do
      json_post "/api/v1/session", { username: "john", password: AuthHelpers::TEST_PASSWORD, admin: true, extra: "x" }

      expect(response).to have_http_status(:ok)
    end

    it "never echoes the password back" do
      login

      expect(response.body).not_to include(AuthHelpers::TEST_PASSWORD)
    end
  end

  describe "scenario 2: every failure looks the same" do
    shared_examples "an invalid credentials response" do
      it "returns 401 with the invalid_credentials body and no-store" do
        attempt

        expect(response).to have_http_status(:unauthorized)
        expect(response.parsed_body).to eq(invalid_credentials_body)
        expect(response.headers["Cache-Control"]).to include("no-store")
      end

      it "returns no access token" do
        attempt

        expect(response.body).not_to include("access_token")
      end
    end

    context "with a wrong password" do
      let(:attempt) { login(password: "not the right password") }

      it_behaves_like "an invalid credentials response"
    end

    context "with an unknown username" do
      let(:attempt) { login(username: "nobody") }

      it_behaves_like "an invalid credentials response"
    end

    context "with a missing password" do
      let(:attempt) { json_post "/api/v1/session", { username: "john" } }

      it_behaves_like "an invalid credentials response"
    end

    context "with a missing username" do
      let(:attempt) { json_post "/api/v1/session", { password: AuthHelpers::TEST_PASSWORD } }

      it_behaves_like "an invalid credentials response"
    end

    context "with empty strings" do
      let(:attempt) { login(username: "", password: "") }

      it_behaves_like "an invalid credentials response"
    end

    context "with no body at all" do
      let(:attempt) { post "/api/v1/session", headers: origin_headers }

      it_behaves_like "an invalid credentials response"
    end

    context "with null values" do
      let(:attempt) { json_post "/api/v1/session", { username: nil, password: nil } }

      it_behaves_like "an invalid credentials response"
    end

    context "with a non-string password" do
      let(:attempt) { json_post "/api/v1/session", { username: "john", password: { "$ne" => "x" } } }

      it_behaves_like "an invalid credentials response"
    end

    it "still spends a bcrypt comparison when the username does not exist (no timing oracle)" do
      allow(BCrypt::Engine).to receive(:hash_secret).and_call_original

      login(username: "nobody")

      expect(BCrypt::Engine).to have_received(:hash_secret).at_least(:once)
    end
  end

  describe "scenario 3: username matching" do
    it "matches regardless of case" do
      login(username: "JOHN")

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["user"]).to eq("username" => "john")
    end

    it "matches regardless of surrounding whitespace" do
      login(username: "  john \t")

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["user"]).to eq("username" => "john")
    end

    it "matches with both at once" do
      login(username: " John ")

      expect(response).to have_http_status(:ok)
    end

    it "does not strip or fold the password" do
      login(password: " #{AuthHelpers::TEST_PASSWORD} ")
      expect(response).to have_http_status(:unauthorized)

      login(password: AuthHelpers::TEST_PASSWORD.upcase)
      expect(response).to have_http_status(:unauthorized)
    end
  end
end
