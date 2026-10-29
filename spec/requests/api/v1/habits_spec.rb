require "rails_helper"

# Plan section 6, API scenarios 1 to 5 and 10 to 14 (one describe per endpoint).
RSpec.describe "/api/v1/habits", type: :request do
  let!(:user) { create(:user, username: "john") }

  def token_for(account = user)
    login(username: account.username)
    response.parsed_body.fetch("access_token")
  end

  def expect_unauthenticated
    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body).to match(expected_unauthenticated_body)
  end

  describe "GET /api/v1/habits" do
    it "returns 401 unauthenticated with no token, a malformed token or an expired token" do
      get "/api/v1/habits"
      expect_unauthenticated

      get "/api/v1/habits", headers: bearer("this.is.notajwt")
      expect_unauthenticated

      token = token_for
      travel 16.minutes do
        get "/api/v1/habits", headers: bearer(token)
      end
      expect_unauthenticated
    end

    it "returns an empty list when there are no habits" do
      get "/api/v1/habits", headers: bearer(token_for)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq("habits" => [])
    end

    it "returns the caller's habits oldest first, each with only id and name" do
      newest = create(:habit, user: user, name: "Newest", created_at: 1.hour.ago)
      oldest = create(:habit, user: user, name: "Oldest", created_at: 3.hours.ago)
      middle = create(:habit, user: user, name: "Middle", created_at: 2.hours.ago)

      get "/api/v1/habits", headers: bearer(token_for)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq(
        "habits" => [ oldest, middle, newest ].map { |habit| { "id" => habit.id, "name" => habit.name } }
      )
    end

    it "breaks a created_at tie by id" do
      time = Time.current
      first = create(:habit, user: user, created_at: time)
      second = create(:habit, user: user, created_at: time)

      get "/api/v1/habits", headers: bearer(token_for)

      expect(response.parsed_body["habits"].map { |habit| habit["id"] }).to eq([ first.id, second.id ])
    end

    it "never includes another user's habits" do
      create(:habit, user: create(:user), name: "Not yours")
      mine = create(:habit, user: user, name: "Mine")

      get "/api/v1/habits", headers: bearer(token_for)

      expect(response.parsed_body["habits"]).to eq([ { "id" => mine.id, "name" => "Mine" } ])
    end
  end
end
