require "rails_helper"

# One describe per endpoint.
RSpec.describe "/api/v1/task_lists", type: :request do
  let!(:user) { create(:user, username: "john") }

  def token_for(account = user)
    login(username: account.username)
    response.parsed_body.fetch("access_token")
  end

  def expect_unauthenticated
    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body).to match(expected_unauthenticated_body)
  end

  describe "GET /api/v1/task_lists" do
    it "returns 401 unauthenticated with no token, a malformed token or an expired token" do
      get "/api/v1/task_lists"
      expect_unauthenticated

      get "/api/v1/task_lists", headers: bearer("this.is.notajwt")
      expect_unauthenticated

      token = token_for
      travel 16.minutes do
        get "/api/v1/task_lists", headers: bearer(token)
      end
      expect_unauthenticated
    end

    it "returns an empty list when there are no lists" do
      get "/api/v1/task_lists", headers: bearer(token_for)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq("task_lists" => [])
    end

    it "returns the caller's lists by position, each with only id and name" do
      last = create(:task_list, user: user, name: "Last", position: 9)
      first = create(:task_list, user: user, name: "First", position: 1)
      middle = create(:task_list, user: user, name: "Middle", position: 4)

      get "/api/v1/task_lists", headers: bearer(token_for)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq(
        "task_lists" => [ first, middle, last ].map { |list| { "id" => list.id, "name" => list.name } }
      )
    end

    it "breaks a position tie by id" do
      first = create(:task_list, user: user, position: 3)
      second = create(:task_list, user: user, position: 3)

      get "/api/v1/task_lists", headers: bearer(token_for)

      expect(response.parsed_body["task_lists"].map { |list| list["id"] }).to eq([ first.id, second.id ])
    end

    it "never includes another user's lists" do
      create(:task_list, user: create(:user), name: "Not yours")
      mine = create(:task_list, user: user, name: "Mine")

      get "/api/v1/task_lists", headers: bearer(token_for)

      expect(response.parsed_body["task_lists"]).to eq([ { "id" => mine.id, "name" => "Mine" } ])
    end

    it "is not shared or public: Cache-Control contains private" do
      get "/api/v1/task_lists", headers: bearer(token_for)

      expect(response.headers["Cache-Control"]).to include("private")
    end
  end
end
