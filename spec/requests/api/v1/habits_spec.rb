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

  def expect_not_found
    expect(response).to have_http_status(:not_found)
    expect(response.parsed_body).to eq("error" => { "code" => "not_found", "message" => "Habit not found." })
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

  describe "POST /api/v1/habits" do
    def post_habit(body, token: token_for)
      post "/api/v1/habits", params: body, as: :json, headers: bearer(token)
    end

    def expect_error(status, code, message)
      expect(response).to have_http_status(status)
      expect(response.parsed_body).to eq("error" => { "code" => code, "message" => message })
    end

    it "returns 401 unauthenticated with no token or a bad token, and creates nothing" do
      expect {
        post "/api/v1/habits", params: { habit: { name: "Stretch" } }, as: :json
        expect_unauthenticated

        post "/api/v1/habits", params: { habit: { name: "Stretch" } }, as: :json, headers: bearer("this.is.notajwt")
        expect_unauthenticated
      }.not_to change(Habit, :count)
    end

    it "creates the habit for the caller and returns 201 with its id and name" do
      post_habit({ habit: { name: "Stretch" } })

      habit = Habit.last
      expect(response).to have_http_status(:created)
      expect(response.parsed_body).to eq("habit" => { "id" => habit.id, "name" => "Stretch" })
      expect(response.headers["Location"]).to be_nil
      expect(habit.user).to eq(user)
    end

    it "lists the new habit last" do
      create(:habit, user: user, name: "Older", created_at: 1.day.ago)
      token = token_for

      post_habit({ habit: { name: "Stretch" } }, token: token)
      get "/api/v1/habits", headers: bearer(token)

      expect(response.parsed_body["habits"].map { |habit| habit["name"] }).to eq([ "Older", "Stretch" ])
    end

    it "strips spaces at the start and end of the name" do
      post_habit({ habit: { name: "  Stretch  " } })

      expect(response).to have_http_status(:created)
      expect(response.parsed_body["habit"]["name"]).to eq("Stretch")
      expect(Habit.last.name).to eq("Stretch")
    end

    it "refuses an empty, whitespace-only or missing name with 422 and creates nothing" do
      token = token_for

      expect {
        [ { name: "" }, { name: "   " }, { name: nil }, { name: "\u00A0" } ].each do |habit|
          post_habit({ habit: habit }, token: token)
          expect_error(:unprocessable_content, "validation_failed", "Name can't be blank.")
        end
      }.not_to change(Habit, :count)
    end

    it "returns 400 for a habit hash that has no name key at all" do
      # params.expect treats a hash with none of the permitted keys as a malformed body, so this is not a 422.
      post_habit({ habit: { other: "x" } })

      expect_error(:bad_request, "bad_request", "Request body is malformed.")
    end

    it "accepts 100 characters and 100 multibyte characters, and refuses 101" do
      token = token_for

      post_habit({ habit: { name: "a" * 100 } }, token: token)
      expect(response).to have_http_status(:created)

      post_habit({ habit: { name: "é" * 100 } }, token: token)
      expect(response).to have_http_status(:created)

      expect {
        post_habit({ habit: { name: "a" * 101 } }, token: token)
      }.not_to change(Habit, :count)
      expect_error(:unprocessable_content, "validation_failed", "Name is too long (maximum is 100 characters).")
    end

    it "creates two habits when the same name is posted twice" do
      token = token_for

      expect {
        2.times { post_habit({ habit: { name: "Stretch" } }, token: token) }
      }.to change(Habit, :count).by(2)
    end

    it "ignores user_id and id in the body" do
      other = create(:user)

      post_habit({ habit: { name: "Stretch", user_id: other.id, id: 999_999 } })

      habit = Habit.last
      expect(response).to have_http_status(:created)
      expect(habit.user).to eq(user)
      expect(habit.id).not_to eq(999_999)
      expect(other.habits).to be_empty
    end

    it "puts the habit name in no span attribute or event" do
      name = "SENTINEL-habit-3c9e1b7a-do-not-trace"
      token = token_for
      TelemetryHelpers.reset

      post_habit({ habit: { name: name } }, token: token)

      expect(response).to have_http_status(:created)
      spans = captured_spans
      # Non-vacuous: the request and its insert were traced.
      expect(spans).not_to be_empty
      dumped = spans.map { |span| [ span.name, span.attributes, Array(span.events).map { |e| [ e.name, e.attributes ] } ] }.inspect
      expect(dumped).to include("/api/v1/habits")
      expect(dumped).not_to include(name)
    end

    it "returns 400 bad_request when the habit key is missing, even if name is at the top level" do
      token = token_for

      expect {
        post_habit({ name: "Stretch" }, token: token)
        expect_error(:bad_request, "bad_request", "Request body is malformed.")

        post_habit({ habit: "Stretch" }, token: token)
        expect_error(:bad_request, "bad_request", "Request body is malformed.")
      }.not_to change(Habit, :count)
    end
  end

  describe "DELETE /api/v1/habits/:id" do
    it "returns 401 unauthenticated with no token or a bad token, and leaves the habit" do
      habit = create(:habit, user: user)

      expect {
        delete "/api/v1/habits/#{habit.id}"
        expect_unauthenticated

        delete "/api/v1/habits/#{habit.id}", headers: bearer("this.is.notajwt")
        expect_unauthenticated
      }.not_to change(Habit, :count)
    end

    it "deletes your own habit with 204 and no body, and the list no longer has it" do
      keep = create(:habit, user: user, name: "Keep")
      gone = create(:habit, user: user, name: "Gone")
      token = token_for

      delete "/api/v1/habits/#{gone.id}", headers: bearer(token)

      expect(response).to have_http_status(:no_content)
      expect(response.body).to be_empty
      get "/api/v1/habits", headers: bearer(token)
      expect(response.parsed_body["habits"]).to eq([ { "id" => keep.id, "name" => "Keep" } ])
    end

    it "returns 404 not_found for another user's habit and leaves it" do
      theirs = create(:habit, user: create(:user))
      token = token_for

      expect {
        delete "/api/v1/habits/#{theirs.id}", headers: bearer(token)
      }.not_to change(Habit, :count)

      expect_not_found
      expect(Habit.exists?(theirs.id)).to be(true)
    end

    it "returns the same body for another user's habit as for a missing one" do
      theirs = create(:habit, user: create(:user))
      token = token_for

      delete "/api/v1/habits/#{theirs.id}", headers: bearer(token)
      other_users_body = response.parsed_body
      delete "/api/v1/habits/#{theirs.id + 1000}", headers: bearer(token)

      expect(response.parsed_body).to eq(other_users_body)
    end

    it "returns 404 for a missing, non-numeric or out-of-range id" do
      token = token_for

      [ "999999", "abc", "1.5", "-1", "99999999999999999999999999" ].each do |id|
        delete "/api/v1/habits/#{id}", headers: bearer(token)
        expect_not_found
      end
    end

    it "returns 404 on a second delete of the same id" do
      habit = create(:habit, user: user)
      token = token_for

      delete "/api/v1/habits/#{habit.id}", headers: bearer(token)
      expect(response).to have_http_status(:no_content)

      delete "/api/v1/habits/#{habit.id}", headers: bearer(token)
      expect_not_found
    end
  end
end
