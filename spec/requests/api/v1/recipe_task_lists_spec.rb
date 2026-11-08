require "rails_helper"

RSpec.describe "POST /api/v1/recipes/:recipe_id/task_list", type: :request do
  let!(:user) { create(:user, username: "john") }
  let!(:recipe) { create(:recipe, user: user, title: "Bread") }

  def token_for(account = user)
    login(username: account.username)
    response.parsed_body.fetch("access_token")
  end

  def make_list(recipe_id, token: token_for, **options)
    post "/api/v1/recipes/#{recipe_id}/task_list", headers: bearer(token), **options
  end

  def expect_not_found
    expect(response).to have_http_status(:not_found)
    expect(response.parsed_body).to eq("error" => { "code" => "not_found", "message" => "Not found." })
  end

  def dumped_telemetry
    captured_spans.map { |span| [ span.name, span.attributes, Array(span.events).map { |e| [ e.name, e.attributes ] } ] }.inspect
  end

  it "creates a list named for the recipe with one task per ingredient, in order, and answers 201 with id and name" do
    create(:recipe_ingredient, recipe: recipe, name: "salt", amount: "1 tsp", position: 2)
    create(:recipe_ingredient, recipe: recipe, name: "flour", amount: "500 g", position: 0)
    create(:recipe_ingredient, recipe: recipe, name: "water", amount: "300 ml", position: 1)

    expect { make_list(recipe.id) }.to change(TaskList, :count).by(1).and change(Task, :count).by(3)

    list = TaskList.order(:id).last
    expect(response).to have_http_status(:created)
    expect(response.parsed_body).to eq("task_list" => { "id" => list.id, "name" => "Bread" })
    expect(list.user).to eq(user)
    expect(list.tasks.in_order.map(&:text)).to eq([ "500 g flour", "300 ml water", "1 tsp salt" ])
    expect(list.tasks.pluck(:done)).to all(be(false))
  end

  it "uses just the name for an ingredient with no amount" do
    create(:recipe_ingredient, recipe: recipe, name: "salt", amount: "", position: 0)
    create(:recipe_ingredient, recipe: recipe, name: "pepper", amount: "a pinch", position: 1)

    make_list(recipe.id)

    expect(TaskList.order(:id).last.tasks.in_order.map(&:text)).to eq([ "salt", "a pinch pepper" ])
  end

  it "fits the longest ingredient in a task with no truncation" do
    create(:recipe_ingredient, recipe: recipe, name: "n" * 50, amount: "a" * 49)

    make_list(recipe.id)

    expect(response).to have_http_status(:created)
    expect(TaskList.order(:id).last.tasks.first.text).to eq("#{'a' * 49} #{'n' * 50}")
  end

  it "fits the longest recipe title in the list name" do
    recipe.update!(title: "t" * 100)

    make_list(recipe.id)

    expect(response).to have_http_status(:created)
    expect(response.parsed_body.dig("task_list", "name")).to eq("t" * 100)
  end

  it "puts the new list after the caller's existing lists" do
    existing = create(:task_list, user: user)

    make_list(recipe.id)

    expect(TaskList.order(:id).last.position).to be > existing.position
  end

  it "makes an empty list for a recipe with no ingredients" do
    expect { make_list(recipe.id) }.to change(TaskList, :count).by(1)

    expect(response).to have_http_status(:created)
    expect(Task.count).to eq(0)
    expect(TaskList.order(:id).last.tasks).to be_empty
  end

  it "makes a second list when asked twice" do
    create(:recipe_ingredient, recipe: recipe, name: "salt")
    token = token_for

    expect {
      make_list(recipe.id, token: token)
      make_list(recipe.id, token: token)
    }.to change(TaskList, :count).by(2).and change(Task, :count).by(2)
  end

  it "leaves the recipe and its ingredients unchanged" do
    create(:recipe_ingredient, recipe: recipe, name: "salt", amount: "1 tsp")
    before = [ recipe.reload.attributes, recipe.recipe_ingredients.in_order.map(&:attributes) ]

    make_list(recipe.id)

    expect([ recipe.reload.attributes, recipe.recipe_ingredients.in_order.map(&:attributes) ]).to eq(before)
  end

  it "leaves nothing behind when a task cannot be saved" do
    create(:recipe_ingredient, recipe: recipe, name: "salt")
    allow_any_instance_of(Task).to receive(:_create_record).and_raise(ActiveRecord::StatementInvalid)
    token = token_for

    expect {
      expect { make_list(recipe.id, token: token) }.to raise_error(ActiveRecord::StatementInvalid)
    }.not_to change(TaskList, :count)
  end

  it "returns 404 for another user's recipe and creates nothing" do
    theirs = create(:recipe, user: create(:user))
    create(:recipe_ingredient, recipe: theirs, name: "secret")
    token = token_for

    expect { make_list(theirs.id, token: token) }.not_to change { [ TaskList.count, Task.count ] }

    expect_not_found
    expect(response.body).not_to include("secret")
  end

  it "returns the same 404 for a missing, a non-numeric and an out-of-range recipe id, and creates nothing" do
    token = token_for

    expect {
      [ (recipe.id + 1000).to_s, "abc", "-1", "99999999999999999999999999" ].each do |id|
        make_list(id, token: token)
        expect_not_found
      end
    }.not_to change { [ TaskList.count, Task.count ] }
  end

  it "returns 401 unauthenticated with no token, a malformed token or an expired token, and creates nothing" do
    path = "/api/v1/recipes/#{recipe.id}/task_list"
    token = token_for

    expect {
      post path
      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body).to match(expected_unauthenticated_body)

      post path, headers: bearer("this.is.notajwt")
      expect(response).to have_http_status(:unauthorized)

      travel 16.minutes do
        post path, headers: bearer(token)
      end
      expect(response).to have_http_status(:unauthorized)
    }.not_to change(TaskList, :count)
  end

  it "returns 401, not 404, for a recipe that does not exist when there is no token" do
    post "/api/v1/recipes/999999/task_list"

    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body).to match(expected_unauthenticated_body)
  end

  it "ignores a name, a recipe_id and a user_id in the body" do
    theirs = create(:recipe, user: create(:user))
    other_user = create(:user)

    make_list(recipe.id, params: { name: "Mine", task_list: { name: "Mine" }, recipe_id: theirs.id, user_id: other_user.id }.to_json,
                         as: :json)

    list = TaskList.order(:id).last
    expect(response).to have_http_status(:created)
    expect(list.name).to eq("Bread")
    expect(list.user).to eq(user)
  end

  describe "telemetry" do
    let(:body_sentinel) { "SENTINEL-recipe-task-list-body-6c2f9e14" }
    let(:recipe_sentinel) { "SENTINEL-recipe-task-list-text-b81d37a5" }

    it "puts no body text in spans, Sentry events or the response, and no recipe text in spans or Sentry events" do
      recipe.update!(title: "#{recipe_sentinel}-title")
      create(:recipe_ingredient, recipe: recipe, name: "#{recipe_sentinel}-name", amount: "1")
      token = token_for
      TelemetryHelpers.reset

      make_list(recipe.id, token: token, params: { name: body_sentinel, task_list: { name: body_sentinel } }.to_json, as: :json)

      expect(response).to have_http_status(:created)
      # Non-vacuous: the request was traced.
      expect(captured_spans).not_to be_empty
      expect(dumped_telemetry).to include("/api/v1/recipes")
      sentry = captured_sentry_events.map(&:to_h).inspect
      [ dumped_telemetry, sentry ].each do |dump|
        expect(dump).not_to include(body_sentinel)
        expect(dump).not_to include(recipe_sentinel)
      end
      expect(response.body).not_to include(body_sentinel)
    end
  end
end
