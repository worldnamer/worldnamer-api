require "rails_helper"

# One describe per endpoint.
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
    expect(response.parsed_body).to eq("error" => { "code" => "not_found", "message" => "Not found." })
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
      get "/api/v1/habits", params: { week_start: "2026-10-26" }, headers: bearer(token_for)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq("habits" => [])
    end

    it "returns the caller's habits oldest first, each with only id, name and completed_dates" do
      newest = create(:habit, user: user, name: "Newest", created_at: 1.hour.ago)
      oldest = create(:habit, user: user, name: "Oldest", created_at: 3.hours.ago)
      middle = create(:habit, user: user, name: "Middle", created_at: 2.hours.ago)

      get "/api/v1/habits", params: { week_start: "2026-10-26" }, headers: bearer(token_for)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq(
        "habits" => [ oldest, middle, newest ].map do |habit|
          { "id" => habit.id, "name" => habit.name, "completed_dates" => [] }
        end
      )
    end

    it "breaks a created_at tie by id" do
      time = Time.current
      first = create(:habit, user: user, created_at: time)
      second = create(:habit, user: user, created_at: time)

      get "/api/v1/habits", params: { week_start: "2026-10-26" }, headers: bearer(token_for)

      expect(response.parsed_body["habits"].map { |habit| habit["id"] }).to eq([ first.id, second.id ])
    end

    it "never includes another user's habits" do
      create(:habit, user: create(:user), name: "Not yours")
      mine = create(:habit, user: user, name: "Mine")

      get "/api/v1/habits", params: { week_start: "2026-10-26" }, headers: bearer(token_for)

      expect(response.parsed_body["habits"]).to eq([ { "id" => mine.id, "name" => "Mine", "completed_dates" => [] } ])
    end

    describe "completed_dates" do
      let(:monday) { "2026-10-26" }
      # let! so the login (which runs queries of its own) happens before any query counting starts.
      let!(:token) { token_for }

      def complete(habit, *dates)
        dates.each { |date| create(:habit_completion, habit: habit, date: IsoDate.parse(date)) }
      end

      def get_week(week_start, token: self.token)
        get "/api/v1/habits", params: { week_start: week_start }, headers: bearer(token)
      end

      def dates_by_name
        response.parsed_body["habits"].to_h { |habit| [ habit["name"], habit["completed_dates"] ] }
      end

      # Counts the SQL statements a block runs, ignoring schema lookups and transaction control.
      def sql_statements
        statements = []
        callback = lambda do |*, payload|
          next if payload[:name] == "SCHEMA" || payload[:cached]

          statements << payload[:sql]
        end
        ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
        statements
      end

      it "answers 400 when week_start is left out, and reads no completions" do
        habit = create(:habit, user: user, name: "Stretch")
        complete(habit, monday, "2026-10-28")

        statements = sql_statements { get "/api/v1/habits", headers: bearer(token) }

        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body).to eq("error" => { "code" => "bad_request", "message" => "week_start is required." })
        expect(statements.grep(/habit_completions/)).to be_empty
      end

      it "returns only the dates inside the week, ascending, with the Monday and the Sunday included" do
        habit = create(:habit, user: user, name: "Stretch")
        complete(habit, "2026-11-01", "2026-10-28", monday, "2026-10-25", "2026-11-02")

        get_week(monday)

        expect(response).to have_http_status(:ok)
        expect(dates_by_name).to eq("Stretch" => [ monday, "2026-10-28", "2026-11-01" ])
      end

      it "keeps each habit's dates apart" do
        stretch = create(:habit, user: user, name: "Stretch", created_at: 2.hours.ago)
        read = create(:habit, user: user, name: "Read", created_at: 1.hour.ago)
        complete(stretch, monday, "2026-10-27")
        complete(read, "2026-10-27", "2026-10-30")

        get_week(monday)

        expect(dates_by_name).to eq("Stretch" => [ monday, "2026-10-27" ], "Read" => [ "2026-10-27", "2026-10-30" ])
        expect(response.parsed_body["habits"].map { |habit| habit["name"] }).to eq(%w[Stretch Read])
      end

      it "gives an empty list to a habit with no completions that week" do
        busy = create(:habit, user: user, name: "Busy", created_at: 2.hours.ago)
        idle = create(:habit, user: user, name: "Idle", created_at: 1.hour.ago)
        complete(busy, "2026-10-27")
        complete(idle, "2026-11-10")

        get_week(monday)

        expect(dates_by_name).to eq("Busy" => [ "2026-10-27" ], "Idle" => [])
      end

      it "returns one week per request" do
        habit = create(:habit, user: user, name: "Stretch")
        complete(habit, "2026-10-27", "2026-11-03", "2026-11-04")

        get_week(monday)
        expect(dates_by_name).to eq("Stretch" => [ "2026-10-27" ])

        get_week("2026-11-02")
        expect(dates_by_name).to eq("Stretch" => [ "2026-11-03", "2026-11-04" ])
      end

      it "never includes another user's habits or completions, even on the same dates" do
        mine = create(:habit, user: user, name: "Mine")
        theirs = create(:habit, user: create(:user), name: "Theirs")
        complete(mine, "2026-10-27")
        complete(theirs, "2026-10-27", "2026-10-28")

        get_week(monday)

        expect(dates_by_name).to eq("Mine" => [ "2026-10-27" ])
      end

      it "answers an empty list when there are no habits" do
        get_week(monday)

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body).to eq("habits" => [])
      end

      it "runs the same number of queries for one habit as for five, with one for completions" do
        one = create(:habit, user: user)
        complete(one, monday)
        one_habit = sql_statements { get_week(monday) }

        4.times { complete(create(:habit, user: user), monday, "2026-10-29") }
        five_habits = sql_statements { get_week(monday) }

        expect(response.parsed_body["habits"].size).to eq(5)
        expect(five_habits.size).to eq(one_habit.size)
        expect(five_habits.grep(/habit_completions/).size).to eq(1)
      end

      it "reaches the last supported week, whose Sunday is in year 9999" do
        habit = create(:habit, user: user, name: "Stretch")
        complete(habit, "9999-12-27", "9999-12-31")

        get_week("9999-12-27")

        expect(response).to have_http_status(:ok)
        expect(dates_by_name).to eq("Stretch" => [ "9999-12-27", "9999-12-31" ])
      end

      it "reaches the first supported week" do
        get_week("1900-01-01")

        expect(response).to have_http_status(:ok)
      end

      it "is not shared or public: Cache-Control contains private" do
        get_week(monday)

        expect(response.headers["Cache-Control"]).to include("private")
      end

      it "answers 400 for a week_start that is not a Monday in the form YYYY-MM-DD" do
        create(:habit, user: user)
        message = "week_start must be a Monday in the form YYYY-MM-DD."
        bad_values = [
          "abc", "20261026", "2026-10-5", "2026-02-30", "2026-W44-1", "2026-10-26\n", " 2026-10-26",
          "1899-12-31", "0000-01-03", "99999-01-01", "2026-10-27", "",
          [ "2026-10-26" ], [], { "a" => "2026-10-26" }
        ]

        bad_values.each do |value|
          get_week(value)

          expect(response).to have_http_status(:bad_request), "expected #{value.inspect} to be refused"
          expect(response.parsed_body).to eq("error" => { "code" => "bad_request", "message" => message })
        end
      end

      it "answers 400 for a bare week_start key in the query string" do
        get "/api/v1/habits?week_start", headers: bearer(token)

        expect(response).to have_http_status(:bad_request)
      end

      it "answers 401 before it looks at week_start" do
        get "/api/v1/habits", params: { week_start: "garbage" }

        expect_unauthenticated
      end

      it "answers 401 before it notices week_start is missing" do
        get "/api/v1/habits"

        expect_unauthenticated
      end
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
      get "/api/v1/habits", params: { week_start: "2026-10-26" }, headers: bearer(token)

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
      get "/api/v1/habits", params: { week_start: "2026-10-26" }, headers: bearer(token)
      expect(response.parsed_body["habits"]).to eq([ { "id" => keep.id, "name" => "Keep", "completed_dates" => [] } ])
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
