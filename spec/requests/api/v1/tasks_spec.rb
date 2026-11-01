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

  describe "POST /api/v1/task_lists/:task_list_id/tasks" do
    def post_task(list_id, body, token: token_for)
      post "/api/v1/task_lists/#{list_id}/tasks", params: body, as: :json, headers: bearer(token)
    end

    def expect_error(status, code, message)
      expect(response).to have_http_status(status)
      expect(response.parsed_body).to eq("error" => { "code" => code, "message" => message })
    end

    it "returns 401 unauthenticated with no token or a bad token, and creates nothing" do
      expect {
        post "/api/v1/task_lists/#{list.id}/tasks", params: { task: { text: "Milk" } }, as: :json
        expect_unauthenticated

        post "/api/v1/task_lists/#{list.id}/tasks", params: { task: { text: "Milk" } }, as: :json,
                                                    headers: bearer("this.is.notajwt")
        expect_unauthenticated
      }.not_to change(Task, :count)
    end

    it "creates the task in the list and returns 201 with its id, text and done false" do
      post_task(list.id, { task: { text: "Milk" } })

      task = Task.last
      expect(response).to have_http_status(:created)
      expect(response.parsed_body).to eq("task" => { "id" => task.id, "text" => "Milk", "done" => false })
      expect(task.task_list).to eq(list)
    end

    it "lists the new task last" do
      create(:task, task_list: list, text: "Older", done: true)
      token = token_for

      post_task(list.id, { task: { text: "Milk" } }, token: token)
      get "/api/v1/task_lists/#{list.id}/tasks", headers: bearer(token)

      expect(response.parsed_body["tasks"].map { |task| task["text"] }).to eq([ "Older", "Milk" ])
    end

    it "accepts an empty, whitespace-only or nil text and stores an empty string" do
      token = token_for

      expect {
        [ { text: "" }, { text: "   " }, { text: nil } ].each do |task|
          post_task(list.id, { task: task }, token: token)
          expect(response).to have_http_status(:created)
          expect(response.parsed_body["task"]["text"]).to eq("")
        end
      }.to change(Task, :count).by(3)
      expect(Task.pluck(:text)).to all(eq(""))
    end

    it "strips spaces at the start and end of the text" do
      post_task(list.id, { task: { text: "  Milk  " } })

      expect(response.parsed_body["task"]["text"]).to eq("Milk")
      expect(Task.last.text).to eq("Milk")
    end

    it "accepts 100 characters and refuses 101 with 422 and the exact message, creating nothing" do
      token = token_for

      post_task(list.id, { task: { text: "a" * 100 } }, token: token)
      expect(response).to have_http_status(:created)

      expect {
        post_task(list.id, { task: { text: "a" * 101 } }, token: token)
      }.not_to change(Task, :count)
      expect_error(:unprocessable_content, "validation_failed", "Text is too long (maximum is 100 characters).")
    end

    it "creates two tasks for the same text sent twice" do
      token = token_for

      expect {
        2.times { post_task(list.id, { task: { text: "Milk" } }, token: token) }
      }.to change(Task, :count).by(2)
    end

    it "returns 400 when the task key is missing, and for a top-level text" do
      expect {
        post_task(list.id, { text: "Milk" })
        expect_error(:bad_request, "bad_request", "Request body is malformed.")

        post_task(list.id, {})
        expect_error(:bad_request, "bad_request", "Request body is malformed.")
      }.not_to change(Task, :count)
    end

    it "ignores done, task_list_id and id in the body" do
      other_list = create(:task_list, user: user)

      post_task(list.id, { task: { text: "Milk", done: true, task_list_id: other_list.id, id: 999_999 } })

      task = Task.last
      expect(response).to have_http_status(:created)
      expect(task.done).to be(false)
      expect(task.task_list).to eq(list)
      expect(task.id).not_to eq(999_999)
      expect(response.parsed_body["task"]).to eq("id" => task.id, "text" => "Milk", "done" => false)
    end

    # params.expect(task: [ :text ]) permits scalars only. A hash or an array in text is dropped, which leaves nothing
    # permitted, and params.expect treats that like a missing key: 400, not an empty task. Pinned here so a change of
    # behavior shows up in review.
    it "returns 400 and creates nothing for a non-scalar text" do
      token = token_for

      expect {
        [ { "a" => "b" }, [ "Milk" ], [ { "a" => "b" } ], {}, [] ].each do |text|
          post_task(list.id, { task: { text: text } }, token: token)

          expect_error(:bad_request, "bad_request", "Request body is malformed.")
        end
      }.not_to change(Task, :count)
    end

    it "returns 400 for a task body with no text key, such as only unpermitted keys" do
      post_task(list.id, { task: { done: true } })

      expect_error(:bad_request, "bad_request", "Request body is malformed.")
      expect(Task.count).to eq(0)
    end

    it "returns 400 when task itself is not a hash" do
      post_task(list.id, { task: "Milk" })

      expect_error(:bad_request, "bad_request", "Request body is malformed.")
      expect(Task.count).to eq(0)
    end

    it "returns the same 404 for another user's, a missing, a non-numeric and an out-of-range list, creating nothing" do
      theirs = create(:task_list, user: create(:user))
      token = token_for

      expect {
        [ theirs.id.to_s, (theirs.id + 1000).to_s, "abc", "-1", "99999999999999999999999999" ].each do |id|
          post_task(id, { task: { text: "Milk" } }, token: token)
          expect_not_found
        end
      }.not_to change(Task, :count)
    end

    it "returns 404 for another user's list even when the body is malformed" do
      theirs = create(:task_list, user: create(:user))

      post_task(theirs.id, { text: "Milk" })

      expect_not_found
    end

    it "returns 404, not 500, when the list is deleted between the lookup and the insert" do
      token = token_for
      allow_any_instance_of(Task).to receive(:save).and_wrap_original do |original, *args|
        TaskList.where(id: list.id).delete_all
        original.call(*args)
      end

      post_task(list.id, { task: { text: "Milk" } }, token: token)

      expect_not_found
      expect(Task.count).to eq(0)
    end

    it "puts the task text in no span attribute or event" do
      text = "SENTINEL-task-4d8a2f60-do-not-trace"
      token = token_for
      TelemetryHelpers.reset

      post_task(list.id, { task: { text: text } }, token: token)

      expect(response).to have_http_status(:created)
      spans = captured_spans
      # Non-vacuous: the request and its insert were traced.
      expect(spans).not_to be_empty
      dumped = spans.map { |span| [ span.name, span.attributes, Array(span.events).map { |e| [ e.name, e.attributes ] } ] }.inspect
      expect(dumped).to include("/api/v1/task_lists")
      expect(dumped).not_to include(text)
    end

    it "puts the task text in no Sentry event" do
      text = "SENTINEL-task-8c15e7b3-do-not-report"
      token = token_for
      TelemetryHelpers.reset

      # A failure after the text is read is captured by Sentry; the text must not be in the event.
      allow_any_instance_of(Task).to receive(:save).and_raise(RuntimeError, "forced save failure")
      begin
        post_task(list.id, { task: { text: text } }, token: token)
      rescue RuntimeError
        # In the test environment Rails re-raises unrescued errors; Sentry's middleware has already captured it.
      end

      dumped = captured_sentry_events.map(&:to_h).inspect
      # Non-vacuous: it is our forced error.
      expect(dumped).to include("forced save failure")
      expect(dumped).not_to include(text)
    end
  end

  describe "PATCH /api/v1/task_lists/:task_list_id/tasks/:id" do
    let!(:task) { create(:task, task_list: list, text: "Milk", done: true) }

    def patch_task(list_id, id, body, token: token_for)
      patch "/api/v1/task_lists/#{list_id}/tasks/#{id}", params: body, as: :json, headers: bearer(token)
    end

    def expect_error(status, code, message)
      expect(response).to have_http_status(status)
      expect(response.parsed_body).to eq("error" => { "code" => code, "message" => message })
    end

    it "returns 401 unauthenticated with no token or a bad token, and changes nothing" do
      path = "/api/v1/task_lists/#{list.id}/tasks/#{task.id}"

      patch path, params: { task: { text: "Bread" } }, as: :json
      expect_unauthenticated

      patch path, params: { task: { text: "Bread" } }, as: :json, headers: bearer("this.is.notajwt")
      expect_unauthenticated

      expect(task.reload.text).to eq("Milk")
    end

    it "changes the text, returns 200 with id, text and done, and leaves done alone" do
      patch_task(list.id, task.id, { task: { text: "Bread" } })

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq("task" => { "id" => task.id, "text" => "Bread", "done" => true })
      expect(task.reload.text).to eq("Bread")
      expect(task.done).to be(true)
    end

    it "is harmless to repeat" do
      token = token_for

      2.times do
        patch_task(list.id, task.id, { task: { text: "Bread" } }, token: token)
        expect(response).to have_http_status(:ok)
      end
      expect(task.reload.text).to eq("Bread")
    end

    it "accepts a blank text, and strips spaces" do
      patch_task(list.id, task.id, { task: { text: "   " } })
      expect(response).to have_http_status(:ok)
      expect(task.reload.text).to eq("")

      patch_task(list.id, task.id, { task: { text: "  Bread  " } })
      expect(response.parsed_body["task"]["text"]).to eq("Bread")
    end

    it "does not move the task in the list" do
      later = create(:task, task_list: list, text: "Later")
      token = token_for

      patch_task(list.id, task.id, { task: { text: "Edited" } }, token: token)
      get "/api/v1/task_lists/#{list.id}/tasks", headers: bearer(token)

      expect(response.parsed_body["tasks"].map { |t| t["id"] }).to eq([ task.id, later.id ])
    end

    it "refuses 101 characters with 422 and leaves the text unchanged" do
      patch_task(list.id, task.id, { task: { text: "a" * 101 } })

      expect_error(:unprocessable_content, "validation_failed", "Text is too long (maximum is 100 characters).")
      expect(task.reload.text).to eq("Milk")
    end

    it "returns 400 when the task key is missing or empty, and for a non-scalar text" do
      [ { text: "Bread" }, {}, { task: {} }, { task: "Bread" }, { task: { text: { "a" => "b" } } },
        { task: { text: [ "Bread" ] } } ].each do |body|
        patch_task(list.id, task.id, body)

        expect_error(:bad_request, "bad_request", "Request body is malformed.")
      end
      expect(task.reload.text).to eq("Milk")
    end

    it "ignores task_list_id and id in the body, so a task cannot be moved" do
      other_list = create(:task_list, user: user)

      patch_task(list.id, task.id, { task: { text: "Bread", task_list_id: other_list.id, id: 999_999 } })

      expect(response).to have_http_status(:ok)
      expect(task.reload.task_list).to eq(list)
      expect(response.parsed_body["task"]["id"]).to eq(task.id)
    end

    it "returns the same 404 body, and changes nothing, for every task the caller cannot reach" do
      theirs_list = create(:task_list, user: create(:user))
      theirs = create(:task, task_list: theirs_list, text: "Theirs")
      my_other_list = create(:task_list, user: user)
      in_other = create(:task, task_list: my_other_list, text: "Other list")
      token = token_for
      body = { task: { text: "Hacked" } }

      [
        [ theirs_list.id, theirs.id ],             # another user's list
        [ list.id, in_other.id ],                  # the caller's own list, a task from another of their lists
        [ list.id, theirs.id ],                    # another user's task through the caller's list
        [ list.id, theirs.id + 1000 ],             # missing task
        [ list.id, "abc" ],                        # non-numeric task id
        [ list.id, "99999999999999999999999999" ], # out-of-range task id
        [ theirs_list.id + 1000, task.id ],        # missing list
        [ "abc", task.id ]                         # non-numeric list id
      ].each do |list_id, id|
        patch_task(list_id, id, body, token: token)
        expect_not_found
      end
      expect(theirs.reload.text).to eq("Theirs")
      expect(in_other.reload.text).to eq("Other list")
      expect(task.reload.text).to eq("Milk")
    end

    it "returns 404, not 400, when a bad body is sent to a task that is not the caller's" do
      theirs = create(:task, task_list: create(:task_list, user: create(:user)))

      patch_task(theirs.task_list_id, theirs.id, { text: "Hacked" })
      expect_not_found

      patch_task(list.id, theirs.id, {})
      expect_not_found
    end

    it "puts the task text in no span attribute or event" do
      text = "SENTINEL-task-edit-b2e46a17-do-not-trace"
      token = token_for
      TelemetryHelpers.reset

      patch_task(list.id, task.id, { task: { text: text } }, token: token)

      expect(response).to have_http_status(:ok)
      spans = captured_spans
      # Non-vacuous: the request and its update were traced.
      expect(spans).not_to be_empty
      dumped = spans.map { |span| [ span.name, span.attributes, Array(span.events).map { |e| [ e.name, e.attributes ] } ] }.inspect
      expect(dumped).to include("/api/v1/task_lists")
      expect(dumped).not_to include(text)
    end
  end
end
