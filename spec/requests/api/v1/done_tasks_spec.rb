require "rails_helper"

RSpec.describe "DELETE /api/v1/task_lists/:task_list_id/done_tasks", type: :request do
  let!(:user) { create(:user, username: "john") }
  let!(:list) { create(:task_list, user: user) }

  def token_for(account = user)
    login(username: account.username)
    response.parsed_body.fetch("access_token")
  end

  def clear_done(list_id, token: token_for, **options)
    delete "/api/v1/task_lists/#{list_id}/done_tasks", headers: bearer(token), **options
  end

  def expect_no_content
    expect(response).to have_http_status(:no_content)
    expect(response.body).to be_empty
  end

  def expect_not_found
    expect(response).to have_http_status(:not_found)
    expect(response.parsed_body).to eq("error" => { "code" => "not_found", "message" => "Not found." })
  end

  it "deletes every done task of the list, keeps the undone ones and answers 204 with no body" do
    done_a = create(:task, task_list: list, done: true)
    done_b = create(:task, task_list: list, done: true)
    open_task = create(:task, task_list: list, done: false)

    clear_done(list.id)

    expect_no_content
    expect(list.tasks.reload).to contain_exactly(open_task)
    expect(Task.where(id: [ done_a.id, done_b.id ])).to be_empty
  end

  it "leaves the caller's other lists alone" do
    other_list = create(:task_list, user: user)
    other_done = create(:task, task_list: other_list, done: true)
    create(:task, task_list: list, done: true)

    clear_done(list.id)

    expect_no_content
    expect(other_list.tasks.reload).to contain_exactly(other_done)
  end

  it "returns 404 for another user's list and leaves their tasks alone" do
    theirs = create(:task_list, user: create(:user))
    their_done = create(:task, task_list: theirs, done: true)
    their_open = create(:task, task_list: theirs, done: false)
    token = token_for

    clear_done(theirs.id, token: token)

    expect_not_found
    expect(theirs.tasks.reload).to contain_exactly(their_done, their_open)
  end

  it "returns the same 404 for a missing, a non-numeric and an out-of-range list id" do
    token = token_for

    [ (list.id + 1000).to_s, "abc", "-1", "99999999999999999999999999" ].each do |id|
      clear_done(id, token: token)
      expect_not_found
    end
  end

  it "answers 204 when nothing is done" do
    open_task = create(:task, task_list: list, done: false)

    clear_done(list.id)

    expect_no_content
    expect(list.tasks.reload).to contain_exactly(open_task)
  end

  it "answers 204 again on a repeat" do
    create(:task, task_list: list, done: true)
    token = token_for

    clear_done(list.id, token: token)
    expect_no_content
    clear_done(list.id, token: token)
    expect_no_content
    expect(list.tasks.reload).to be_empty
  end

  it "returns 401 unauthenticated with no token, a malformed token or an expired token, and deletes nothing" do
    create(:task, task_list: list, done: true)
    path = "/api/v1/task_lists/#{list.id}/done_tasks"
    token = token_for

    expect {
      delete path
      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body).to match(expected_unauthenticated_body)

      delete path, headers: bearer("this.is.notajwt")
      expect(response).to have_http_status(:unauthorized)

      travel 16.minutes do
        delete path, headers: bearer(token)
      end
      expect(response).to have_http_status(:unauthorized)
    }.not_to change(Task, :count)
  end

  it "returns 401, not 404, for a list that does not exist when there is no token" do
    delete "/api/v1/task_lists/999999/done_tasks"

    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body).to match(expected_unauthenticated_body)
  end

  it "ignores task ids and a task_list_id in the body" do
    theirs = create(:task_list, user: create(:user))
    their_done = create(:task, task_list: theirs, done: true)
    open_task = create(:task, task_list: list, done: false)
    create(:task, task_list: list, done: true)

    clear_done(list.id, params: { task_list_id: theirs.id, ids: [ open_task.id, their_done.id ] }.to_json,
                        as: :json)

    expect_no_content
    expect(list.tasks.reload).to contain_exactly(open_task)
    expect(theirs.tasks.reload).to contain_exactly(their_done)
  end
end
