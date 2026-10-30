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

  describe "POST /api/v1/task_lists" do
    def post_list(body, token: token_for)
      post "/api/v1/task_lists", params: body, as: :json, headers: bearer(token)
    end

    def expect_error(status, code, message)
      expect(response).to have_http_status(status)
      expect(response.parsed_body).to eq("error" => { "code" => code, "message" => message })
    end

    it "returns 401 unauthenticated with no token or a bad token, and creates nothing" do
      expect {
        post "/api/v1/task_lists", params: { task_list: { name: "Errands" } }, as: :json
        expect_unauthenticated

        post "/api/v1/task_lists", params: { task_list: { name: "Errands" } }, as: :json,
                                   headers: bearer("this.is.notajwt")
        expect_unauthenticated
      }.not_to change(TaskList, :count)
    end

    it "creates the list for the caller and returns 201 with its id and name" do
      post_list({ task_list: { name: "Errands" } })

      list = TaskList.last
      expect(response).to have_http_status(:created)
      expect(response.parsed_body).to eq("task_list" => { "id" => list.id, "name" => "Errands" })
      expect(list.user).to eq(user)
    end

    it "lists the new list last" do
      create(:task_list, user: user, name: "Older", position: 5)
      token = token_for

      post_list({ task_list: { name: "Errands" } }, token: token)
      get "/api/v1/task_lists", headers: bearer(token)

      expect(response.parsed_body["task_lists"].map { |list| list["name"] }).to eq([ "Older", "Errands" ])
    end

    it "accepts an empty, whitespace-only or nil name and stores an empty string" do
      token = token_for

      expect {
        [ { name: "" }, { name: "   " }, { name: nil } ].each do |list|
          post_list({ task_list: list }, token: token)
          expect(response).to have_http_status(:created)
          expect(response.parsed_body["task_list"]["name"]).to eq("")
        end
      }.to change(TaskList, :count).by(3)
      expect(TaskList.pluck(:name)).to all(eq(""))
    end

    it "strips spaces at the start and end of the name" do
      post_list({ task_list: { name: "  Errands  " } })

      expect(response.parsed_body["task_list"]["name"]).to eq("Errands")
      expect(TaskList.last.name).to eq("Errands")
    end

    it "accepts 100 characters and refuses 101 with 422 and the exact message" do
      token = token_for

      post_list({ task_list: { name: "a" * 100 } }, token: token)
      expect(response).to have_http_status(:created)

      expect {
        post_list({ task_list: { name: "a" * 101 } }, token: token)
      }.not_to change(TaskList, :count)
      expect_error(:unprocessable_content, "validation_failed", "Name is too long (maximum is 100 characters).")
    end

    it "returns 400 when the task_list key is missing, even if name is at the top level" do
      token = token_for

      expect {
        post_list({ name: "Errands" }, token: token)
        expect_error(:bad_request, "bad_request", "Request body is malformed.")

        post_list({ task_list: "Errands" }, token: token)
        expect_error(:bad_request, "bad_request", "Request body is malformed.")
      }.not_to change(TaskList, :count)
    end

    it "ignores user_id, id and position in the body" do
      other = create(:user)

      post_list({ task_list: { name: "Errands", user_id: other.id, id: 999_999, position: 50 } })

      list = TaskList.last
      expect(response).to have_http_status(:created)
      expect(list.user).to eq(user)
      expect(list.id).not_to eq(999_999)
      expect(list.position).to eq(0)
      expect(other.task_lists).to be_empty
    end

    it "creates two lists when the same name is posted twice" do
      token = token_for

      expect {
        2.times { post_list({ task_list: { name: "Errands" } }, token: token) }
      }.to change(TaskList, :count).by(2)
    end

    it "puts the list name in no span attribute or event" do
      name = "SENTINEL-task-list-5d2f8a64-do-not-trace"
      token = token_for
      TelemetryHelpers.reset

      post_list({ task_list: { name: name } }, token: token)

      expect(response).to have_http_status(:created)
      spans = captured_spans
      # Non-vacuous: the request and its insert were traced.
      expect(spans).not_to be_empty
      dumped = spans.map { |span| [ span.name, span.attributes, Array(span.events).map { |e| [ e.name, e.attributes ] } ] }.inspect
      expect(dumped).to include("/api/v1/task_lists")
      expect(dumped).not_to include(name)
    end

    it "puts the list name in no Sentry event" do
      name = "SENTINEL-task-list-7b1e3c95-do-not-report"
      token = token_for
      TelemetryHelpers.reset

      # A failure after the name is read is captured by Sentry; the name must not be in the event.
      allow_any_instance_of(TaskList).to receive(:save).and_raise(RuntimeError, "forced save failure")
      begin
        post_list({ task_list: { name: name } }, token: token)
      rescue RuntimeError
        # In the test environment Rails re-raises unrescued errors; Sentry's middleware has already captured it.
      end

      dumped = captured_sentry_events.map(&:to_h).inspect
      # Non-vacuous: it is our forced error.
      expect(dumped).to include("forced save failure")
      expect(dumped).not_to include(name)
    end
  end
end
