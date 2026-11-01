require "rails_helper"

RSpec.describe "/api/v1/task_list_order", type: :request do
  let!(:user) { create(:user, username: "john") }
  let!(:first) { create(:task_list, user: user, name: "First") }
  let!(:second) { create(:task_list, user: user, name: "Second") }
  let!(:third) { create(:task_list, user: user, name: "Third") }

  def token_for(account = user)
    login(username: account.username)
    response.parsed_body.fetch("access_token")
  end

  def put_order(body, token: token_for)
    put "/api/v1/task_list_order", params: body, as: :json, headers: bearer(token)
  end

  def expect_unauthenticated
    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body).to match(expected_unauthenticated_body)
  end

  def expect_conflict
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body).to eq(
      "error" => { "code" => "conflict", "message" => "The lists have changed. Reload and try again." }
    )
  end

  def expect_bad_request
    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body["error"]["code"]).to eq("bad_request")
  end

  def current_order(account = user)
    account.task_lists.in_order.map(&:id)
  end

  # The UPDATE statements a block runs.
  def update_statements
    statements = []
    callback = lambda do |*, payload|
      statements << payload[:sql] if payload[:sql].start_with?("UPDATE")
    end
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    statements.grep(/task_lists/)
  end

  it "returns 401 unauthenticated with no token or a bad token, before it looks at ids, and changes nothing" do
    put "/api/v1/task_list_order", params: { ids: [ third.id, second.id, first.id ] }, as: :json
    expect_unauthenticated

    put "/api/v1/task_list_order", params: { nonsense: true }, as: :json, headers: bearer("this.is.notajwt")
    expect_unauthenticated

    expect(current_order).to eq([ first.id, second.id, third.id ])
  end

  it "reorders the lists and returns them in the new order" do
    token = token_for

    put_order({ ids: [ third.id, first.id, second.id ] }, token: token)

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq(
      "task_lists" => [ third, first, second ].map { |list| { "id" => list.id, "name" => list.name } }
    )
    get "/api/v1/task_lists", headers: bearer(token)
    expect(response.parsed_body["task_lists"].map { |list| list["id"] }).to eq([ third.id, first.id, second.id ])
  end

  it "works when deletes have left gaps in the positions" do
    first.destroy!

    put_order({ ids: [ third.id, second.id ] })

    expect(response).to have_http_status(:ok)
    expect(current_order).to eq([ third.id, second.id ])
  end

  it "issues two UPDATEs for a swap" do
    token = token_for

    statements = update_statements { put_order({ ids: [ second.id, first.id, third.id ] }, token: token) }

    expect(response).to have_http_status(:ok)
    expect(statements.size).to eq(2)
  end

  it "is harmless to repeat, and a repeat writes nothing" do
    token = token_for
    put_order({ ids: [ third.id, second.id, first.id ] }, token: token)

    statements = update_statements { put_order({ ids: [ third.id, second.id, first.id ] }, token: token) }

    expect(response).to have_http_status(:ok)
    expect(statements).to be_empty
    expect(current_order).to eq([ third.id, second.id, first.id ])
  end

  it "answers 409 and changes nothing for a missing, extra, repeated, foreign or nonexistent id" do
    theirs = create(:task_list, user: create(:user))
    theirs_before = theirs.position
    token = token_for
    bad_orders = [
      [ first.id, second.id ],
      [ first.id, second.id, third.id, theirs.id + 1000 ],
      [ first.id, first.id, second.id, third.id ],
      [ first.id, second.id, first.id ],
      [ first.id, second.id, theirs.id ],
      [ first.id, second.id, third.id, theirs.id ],
      [ first.id, second.id, third.id + 1000 ],
      [ 99_999_999_999_999_999_999_999 ]
    ]

    bad_orders.each do |ids|
      put_order({ ids: ids.reverse }, token: token)

      expect_conflict
    end

    expect(current_order).to eq([ first.id, second.id, third.id ])
    expect(theirs.reload.position).to eq(theirs_before)
  end

  it "gives the same 409 body for a foreign id as for a nonexistent one" do
    theirs = create(:task_list, user: create(:user))
    token = token_for

    put_order({ ids: [ third.id, second.id, theirs.id ] }, token: token)
    foreign_body = response.parsed_body
    put_order({ ids: [ third.id, second.id, theirs.id + 1000 ] }, token: token)

    expect(response.parsed_body).to eq(foreign_body)
  end

  it "never moves another user's lists" do
    other = create(:user)
    theirs = create_list(:task_list, 2, user: other)
    before = theirs.map { |list| list.reload.position }

    put_order({ ids: [ third.id, second.id, first.id ] })

    expect(theirs.map { |list| list.reload.position }).to eq(before)
    expect(current_order(other)).to eq(theirs.map(&:id))
  end

  it "answers 400 for missing, non-array, empty or non-integer ids" do
    token = token_for
    bad_bodies = [
      {}, { ids: nil }, { ids: first.id }, { ids: "1,2,3" }, { ids: {} }, { ids: { "0" => first.id } }, { ids: [] },
      { ids: [ "1", "2" ] }, { ids: [ first.id, "x" ] }, { ids: [ 1.5 ] }, { ids: [ nil ] }, { ids: [ [ first.id ] ] },
      { ids: [ { "a" => 1 } ] }, { list_ids: [ first.id ] }
    ]

    bad_bodies.each do |body|
      put_order(body, token: token)

      expect_bad_request
    end
    expect(current_order).to eq([ first.id, second.id, third.id ])
  end

  it "lets a list created afterwards land last" do
    token = token_for
    put_order({ ids: [ third.id, second.id, first.id ] }, token: token)

    post "/api/v1/task_lists", params: { task_list: { name: "Newest" } }, as: :json, headers: bearer(token)
    created = response.parsed_body["task_list"]["id"]

    expect(current_order).to eq([ third.id, second.id, first.id, created ])
  end

  it "is routed at /task_list_order and not at /task_lists/order" do
    expect(Rails.application.routes.recognize_path("/api/v1/task_list_order", method: :put))
      .to include(controller: "api/v1/task_list_orders", action: "update")
  end
end
