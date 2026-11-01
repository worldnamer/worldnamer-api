require "rails_helper"

# A completion is one (habit, date) pair. PUT and DELETE are idempotent and always answer 204.
RSpec.describe "/api/v1/habits/:habit_id/completions/:date", type: :request do
  let!(:user) { create(:user, username: "john") }
  let(:habit) { create(:habit, user: user, name: "Stretch") }

  def token_for(account = user)
    login(username: account.username)
    response.parsed_body.fetch("access_token")
  end

  def completion_path(habit_or_id, date)
    id = habit_or_id.respond_to?(:id) ? habit_or_id.id : habit_or_id
    "/api/v1/habits/#{id}/completions/#{date}"
  end

  def expect_unauthenticated
    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body).to match(expected_unauthenticated_body)
  end

  def expect_not_found
    expect(response).to have_http_status(:not_found)
    expect(response.parsed_body).to eq("error" => { "code" => "not_found", "message" => "Not found." })
  end

  def expect_bad_date
    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body).to eq(
      "error" => { "code" => "bad_request", "message" => "Date must be a real date in the form YYYY-MM-DD." }
    )
  end

  def rows
    HabitCompletion.order(:id).pluck(:habit_id, :date)
  end

  describe "PUT" do
    it "creates the completion and answers 204 with no body" do
      put completion_path(habit, "2026-10-28"), headers: bearer(token_for)

      expect(response).to have_http_status(:no_content)
      expect(response.body).to be_empty
      expect(rows).to eq([ [ habit.id, Date.new(2026, 10, 28) ] ])
    end

    it "sets created_at and updated_at on the row" do
      put completion_path(habit, "2026-10-28"), headers: bearer(token_for)

      completion = HabitCompletion.sole
      expect(completion.created_at).to be_within(1.minute).of(Time.current)
      expect(completion.updated_at).to be_within(1.minute).of(Time.current)
    end

    it "answers 204 again for a repeat and still has one row" do
      token = token_for

      put completion_path(habit, "2026-10-28"), headers: bearer(token)
      expect {
        put completion_path(habit, "2026-10-28"), headers: bearer(token)
      }.not_to change(HabitCompletion, :count)

      expect(response).to have_http_status(:no_content)
      expect(HabitCompletion.count).to eq(1)
    end

    it "shows up in the following GET for that week" do
      token = token_for

      put completion_path(habit, "2026-10-28"), headers: bearer(token)
      get "/api/v1/habits", params: { week_start: "2026-10-26" }, headers: bearer(token)

      expect(response.parsed_body["habits"]).to eq(
        [ { "id" => habit.id, "name" => "Stretch", "completed_dates" => [ "2026-10-28" ] } ]
      )
    end

    it "accepts any real date in range, past or future, whatever the weekday" do
      token = token_for
      dates = %w[1900-01-01 2000-02-29 2026-10-28 2026-10-31 2028-02-29 9999-12-31]

      dates.each do |date|
        put completion_path(habit, date), headers: bearer(token)
        expect(response).to have_http_status(:no_content), "expected #{date} to be accepted"
      end

      expect(HabitCompletion.pluck(:date)).to match_array(dates.map { |date| IsoDate.parse(date) })
    end

    it "is routed for PATCH too, with the same effect" do
      patch completion_path(habit, "2026-10-28"), headers: bearer(token_for)

      expect(response).to have_http_status(:no_content)
      expect(rows).to eq([ [ habit.id, Date.new(2026, 10, 28) ] ])
    end

    it "answers 404 for another user's habit and leaves their rows alone" do
      theirs = create(:habit, user: create(:user))
      existing = create(:habit_completion, habit: theirs, date: Date.new(2026, 10, 27))
      token = token_for

      expect {
        put completion_path(theirs, "2026-10-28"), headers: bearer(token)
      }.not_to change(HabitCompletion, :count)

      expect_not_found
      expect(HabitCompletion.all).to contain_exactly(existing)
    end

    it "gives the same body for another user's habit as for a missing one" do
      theirs = create(:habit, user: create(:user))
      token = token_for

      put completion_path(theirs, "2026-10-28"), headers: bearer(token)
      other_users_body = response.parsed_body
      put completion_path(theirs.id + 1000, "2026-10-28"), headers: bearer(token)

      expect(response.parsed_body).to eq(other_users_body)
    end

    it "answers 404 for a missing, non-numeric or out-of-range habit id" do
      token = token_for

      [ "999999", "abc", "-1", "99999999999999999999999999" ].each do |id|
        put completion_path(id, "2026-10-28"), headers: bearer(token)
        expect_not_found
      end

      # A dot ends the id segment, so this never reaches the controller: Rails' routing answers 404 without our body.
      put completion_path("1.5", "2026-10-28"), headers: bearer(token)
      expect(response).to have_http_status(:not_found)
      expect(HabitCompletion.count).to eq(0)
    end

    it "answers 400 for a bad date and writes nothing" do
      token = token_for
      bad_dates = %w[abc 2026-02-30 2026-13-01 20261026 2026-10-5 2026-W44-1 1899-12-31 0000-01-03 99999-01-01
                     2026-10-26T00:00:00 2026-10-26%0A %202026-10-26 2026-10-26%20]

      bad_dates.each do |date|
        put completion_path(habit, date), headers: bearer(token)

        expect_bad_date
      end
      expect(HabitCompletion.count).to eq(0)
    end

    it "checks the habit before the date: another user's habit with a bad date is a 404" do
      theirs = create(:habit, user: create(:user))

      put completion_path(theirs, "not-a-date"), headers: bearer(token_for)

      expect_not_found
    end

    it "answers 401 with no token or a bad token, and changes nothing, even for another user's habit" do
      theirs = create(:habit, user: create(:user))

      expect {
        [ habit, theirs ].each do |target|
          put completion_path(target, "2026-10-28")
          expect_unauthenticated

          put completion_path(target, "2026-10-28"), headers: bearer("this.is.notajwt")
          expect_unauthenticated
        end
      }.not_to change(HabitCompletion, :count)
    end

    it "answers 401 before it looks at the date" do
      put completion_path(habit, "not-a-date")

      expect_unauthenticated
    end

    it "answers 401 for an expired token" do
      token = token_for

      travel 16.minutes do
        put completion_path(habit, "2026-10-28"), headers: bearer(token)
      end

      expect_unauthenticated
      expect(HabitCompletion.count).to eq(0)
    end

    it "ignores user_id, habit_id and date in a JSON body" do
      other_user = create(:user)
      other_habit = create(:habit, user: other_user)

      put completion_path(habit, "2026-10-28"),
          params: { user_id: other_user.id, habit_id: other_habit.id, date: "2020-01-01", completion: { habit_id: other_habit.id } },
          as: :json, headers: bearer(token_for)

      expect(response).to have_http_status(:no_content)
      expect(rows).to eq([ [ habit.id, Date.new(2026, 10, 28) ] ])
    end

    it "ignores a body that is not JSON" do
      put completion_path(habit, "2026-10-28"), params: "date=2020-01-01&habit_id=#{habit.id + 1}", headers: bearer(token_for)

      expect(response).to have_http_status(:no_content)
      expect(rows).to eq([ [ habit.id, Date.new(2026, 10, 28) ] ])
    end

    it "answers 404, not 500, when the habit is deleted between the lookup and the insert" do
      token = token_for
      allow(HabitCompletion).to receive(:insert).and_raise(ActiveRecord::InvalidForeignKey)

      put completion_path(habit, "2026-10-28"), headers: bearer(token)

      expect_not_found
      expect(captured_sentry_events).to be_empty
    end

    it "produces no Sentry event for a bad date" do
      put completion_path(habit, "not-a-date"), headers: bearer(token_for)

      expect_bad_date
      expect(captured_sentry_events).to be_empty
    end
  end

  describe "DELETE" do
    it "removes only that date's row and answers 204 with no body" do
      other_habit = create(:habit, user: user)
      create(:habit_completion, habit: habit, date: Date.new(2026, 10, 27))
      create(:habit_completion, habit: habit, date: Date.new(2026, 10, 28))
      create(:habit_completion, habit: other_habit, date: Date.new(2026, 10, 28))

      delete completion_path(habit, "2026-10-28"), headers: bearer(token_for)

      expect(response).to have_http_status(:no_content)
      expect(response.body).to be_empty
      expect(rows).to contain_exactly([ habit.id, Date.new(2026, 10, 27) ], [ other_habit.id, Date.new(2026, 10, 28) ])
    end

    it "answers 204 again for a repeat, and for a date that was never ticked, and changes nothing else" do
      kept = create(:habit_completion, habit: habit, date: Date.new(2026, 10, 27))
      create(:habit_completion, habit: habit, date: Date.new(2026, 10, 28))
      token = token_for

      delete completion_path(habit, "2026-10-28"), headers: bearer(token)
      delete completion_path(habit, "2026-10-28"), headers: bearer(token)
      expect(response).to have_http_status(:no_content)

      delete completion_path(habit, "2026-11-30"), headers: bearer(token)
      expect(response).to have_http_status(:no_content)
      expect(HabitCompletion.all).to contain_exactly(kept)
    end

    it "no longer lists the date in the following GET" do
      create(:habit_completion, habit: habit, date: Date.new(2026, 10, 28))
      token = token_for

      delete completion_path(habit, "2026-10-28"), headers: bearer(token)
      get "/api/v1/habits", params: { week_start: "2026-10-26" }, headers: bearer(token)

      expect(response.parsed_body["habits"]).to eq([ { "id" => habit.id, "name" => "Stretch", "completed_dates" => [] } ])
    end

    it "undoes a PUT" do
      token = token_for

      put completion_path(habit, "2026-10-28"), headers: bearer(token)
      delete completion_path(habit, "2026-10-28"), headers: bearer(token)

      expect(response).to have_http_status(:no_content)
      expect(HabitCompletion.count).to eq(0)
    end

    it "answers 404 for another user's habit and leaves their rows alone" do
      theirs = create(:habit, user: create(:user))
      existing = create(:habit_completion, habit: theirs, date: Date.new(2026, 10, 28))

      expect {
        delete completion_path(theirs, "2026-10-28"), headers: bearer(token_for)
      }.not_to change(HabitCompletion, :count)

      expect_not_found
      expect(HabitCompletion.all).to contain_exactly(existing)
    end

    it "answers 404 for a missing, non-numeric or out-of-range habit id" do
      token = token_for

      [ "999999", "abc", "-1", "99999999999999999999999999" ].each do |id|
        delete completion_path(id, "2026-10-28"), headers: bearer(token)
        expect_not_found
      end
    end

    it "answers 400 for a bad date and deletes nothing" do
      create(:habit_completion, habit: habit, date: Date.new(2026, 10, 28))
      token = token_for

      %w[abc 2026-02-30 20261026 1899-12-31 2026-10-26%0A].each do |date|
        delete completion_path(habit, date), headers: bearer(token)

        expect_bad_date
      end
      expect(HabitCompletion.count).to eq(1)
    end

    it "checks the habit before the date: another user's habit with a bad date is a 404" do
      theirs = create(:habit, user: create(:user))

      delete completion_path(theirs, "not-a-date"), headers: bearer(token_for)

      expect_not_found
    end

    it "answers 401 with no token or a bad token, and changes nothing, even for another user's habit" do
      theirs = create(:habit, user: create(:user))
      create(:habit_completion, habit: habit, date: Date.new(2026, 10, 28))
      create(:habit_completion, habit: theirs, date: Date.new(2026, 10, 28))

      expect {
        [ habit, theirs ].each do |target|
          delete completion_path(target, "2026-10-28")
          expect_unauthenticated

          delete completion_path(target, "2026-10-28"), headers: bearer("this.is.notajwt")
          expect_unauthenticated
        end
      }.not_to change(HabitCompletion, :count)
    end

    it "ignores user_id, habit_id and date in a JSON body" do
      other_habit = create(:habit, user: create(:user))
      create(:habit_completion, habit: other_habit, date: Date.new(2026, 10, 28))
      create(:habit_completion, habit: habit, date: Date.new(2026, 10, 28))
      create(:habit_completion, habit: habit, date: Date.new(2020, 1, 1))

      delete completion_path(habit, "2026-10-28"),
             params: { user_id: other_habit.user_id, habit_id: other_habit.id, date: "2020-01-01" },
             as: :json, headers: bearer(token_for)

      expect(response).to have_http_status(:no_content)
      expect(rows).to contain_exactly([ other_habit.id, Date.new(2026, 10, 28) ], [ habit.id, Date.new(2020, 1, 1) ])
    end

    it "produces no Sentry event for a bad date" do
      delete completion_path(habit, "not-a-date"), headers: bearer(token_for)

      expect_bad_date
      expect(captured_sentry_events).to be_empty
    end
  end
end
