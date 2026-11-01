require "rails_helper"

# One describe per endpoint.
RSpec.describe "/api/v1/task_lists/:task_list_id/tasks", type: :request do
  let!(:user) { create(:user, username: "john") }
  let!(:list) { create(:task_list, user: user) }

  def token_for(account = user)
    login(username: account.username)
    response.parsed_body.fetch("access_token")
  end

  def expect_unauthenticated
    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body).to match(expected_unauthenticated_body)
  end

  def expect_not_found
    expect(response).to have_http_status(:not_found)
    expect(response.parsed_body).to eq("error" => { "code" => "not_found", "message" => "Not found." })
  end

  describe "GET /api/v1/task_lists/:task_list_id/tasks" do
    def get_tasks(list_id, token: token_for)
      get "/api/v1/task_lists/#{list_id}/tasks", headers: bearer(token)
    end

    it "returns 401 unauthenticated with no token, a malformed token or an expired token" do
      get "/api/v1/task_lists/#{list.id}/tasks"
      expect_unauthenticated

      get "/api/v1/task_lists/#{list.id}/tasks", headers: bearer("this.is.notajwt")
      expect_unauthenticated

      token = token_for
      travel 16.minutes do
        get "/api/v1/task_lists/#{list.id}/tasks", headers: bearer(token)
      end
      expect_unauthenticated
    end

    it "returns 401, not 404, for a list that does not exist when there is no token" do
      get "/api/v1/task_lists/999999/tasks"

      expect_unauthenticated
    end

    it "returns the same 404 body for another user's, a missing, a non-numeric and an out-of-range list id" do
      theirs = create(:task_list, user: create(:user))
      create(:task, task_list: theirs)
      token = token_for

      # An id with a dot ("1.5") never reaches the controller: the router refuses it as an unknown path, also a 404.
      [ theirs.id.to_s, (theirs.id + 1000).to_s, "abc", "-1", "99999999999999999999999999" ].each do |id|
        get_tasks(id, token: token)
        expect_not_found
      end
    end

    it "returns an empty array for a list with no tasks" do
      get_tasks(list.id)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq("tasks" => [])
    end

    it "returns the tasks oldest first, each with only id, text and done" do
      first = create(:task, task_list: list, text: "First", done: true)
      second = create(:task, task_list: list, text: "Second")
      third = create(:task, task_list: list, text: "")

      get_tasks(list.id)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq(
        "tasks" => [
          { "id" => first.id, "text" => "First", "done" => true },
          { "id" => second.id, "text" => "Second", "done" => false },
          { "id" => third.id, "text" => "", "done" => false }
        ]
      )
    end

    it "never includes the tasks of another of the caller's lists" do
      other_list = create(:task_list, user: user)
      create(:task, task_list: other_list, text: "Elsewhere")
      mine = create(:task, task_list: list, text: "Here")

      get_tasks(list.id)

      expect(response.parsed_body["tasks"].map { |task| task["id"] }).to eq([ mine.id ])
    end

    it "is not shared or public: Cache-Control contains private" do
      get_tasks(list.id)

      expect(response.headers["Cache-Control"]).to include("private")
    end
  end
end
