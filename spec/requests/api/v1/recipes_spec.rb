require "rails_helper"

# One describe per endpoint.
RSpec.describe "/api/v1/recipes", type: :request do
  let!(:user) { create(:user, username: "john") }

  def token_for(account = user)
    login(username: account.username)
    response.parsed_body.fetch("access_token")
  end

  def expect_unauthenticated
    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body).to match(expected_unauthenticated_body)
  end

  def dumped_telemetry
    captured_spans.map { |span| [ span.name, span.attributes, Array(span.events).map { |e| [ e.name, e.attributes ] } ] }.inspect
  end

  describe "GET /api/v1/recipes" do
    it "returns 401 unauthenticated with no token, a malformed token or an expired token" do
      get "/api/v1/recipes"
      expect_unauthenticated

      get "/api/v1/recipes", headers: bearer("this.is.notajwt")
      expect_unauthenticated

      token = token_for
      travel 16.minutes do
        get "/api/v1/recipes", headers: bearer(token)
      end
      expect_unauthenticated
    end

    it "returns an empty list when there are no recipes" do
      get "/api/v1/recipes", headers: bearer(token_for)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq("recipes" => [])
    end

    it "returns the caller's recipes case-insensitively by title, each with only id and title" do
      bread = create(:recipe, user: user, title: "bread", prep_instructions: "Mix.", prep_minutes: 5)
      apple = create(:recipe, user: user, title: "Apple pie")
      create(:recipe_ingredient, recipe: apple)

      get "/api/v1/recipes", headers: bearer(token_for)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq(
        "recipes" => [ { "id" => apple.id, "title" => "Apple pie" }, { "id" => bread.id, "title" => "bread" } ]
      )
    end

    it "breaks a title tie by id" do
      first = create(:recipe, user: user, title: "Cake")
      second = create(:recipe, user: user, title: "cake")

      get "/api/v1/recipes", headers: bearer(token_for)

      expect(response.parsed_body["recipes"].map { |recipe| recipe["id"] }).to eq([ first.id, second.id ])
    end

    it "never includes another user's recipes" do
      create(:recipe, user: create(:user), title: "Not yours")
      mine = create(:recipe, user: user, title: "Mine")

      get "/api/v1/recipes", headers: bearer(token_for)

      expect(response.parsed_body["recipes"]).to eq([ { "id" => mine.id, "title" => "Mine" } ])
    end

    it "is not shared or public: Cache-Control contains private" do
      get "/api/v1/recipes", headers: bearer(token_for)

      expect(response.headers["Cache-Control"]).to include("private")
    end

    it "puts no recipe text in any span attribute, event or Sentry event" do
      title = "SENTINEL-recipe-title-3c9e1f27-do-not-trace"
      recipe = create(:recipe, user: user, title: title, prep_instructions: "SENTINEL-recipe-prep-8d4b2a61")
      create(:recipe_ingredient, recipe: recipe, name: "SENTINEL-recipe-ingredient-5f7a9c03")
      token = token_for
      TelemetryHelpers.reset

      get "/api/v1/recipes", headers: bearer(token)

      expect(response).to have_http_status(:ok)
      # Non-vacuous: the request was traced.
      expect(captured_spans).not_to be_empty
      dumped = dumped_telemetry
      expect(dumped).to include("/api/v1/recipes")
      expect(dumped).not_to include("SENTINEL-recipe")
      expect(captured_sentry_events.map(&:to_h).inspect).not_to include("SENTINEL-recipe")
    end
  end

  describe "GET /api/v1/recipes/:id" do
    def expect_not_found
      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to eq("error" => { "code" => "not_found", "message" => "Not found." })
    end

    it "returns 401 unauthenticated with no token, a malformed token or an expired token" do
      recipe = create(:recipe, user: user)

      get "/api/v1/recipes/#{recipe.id}"
      expect_unauthenticated

      get "/api/v1/recipes/#{recipe.id}", headers: bearer("this.is.notajwt")
      expect_unauthenticated

      token = token_for
      travel 16.minutes do
        get "/api/v1/recipes/#{recipe.id}", headers: bearer(token)
      end
      expect_unauthenticated
    end

    it "returns the whole recipe with ingredients in position order, and exactly these fields" do
      recipe = create(:recipe, user: user, title: "Bread", prep_instructions: "Mix.\nKnead.", prep_minutes: 20)
      create(:recipe_ingredient, recipe: recipe, name: "salt", amount: "", position: 2)
      create(:recipe_ingredient, recipe: recipe, name: "flour", amount: "500 g", position: 1)

      get "/api/v1/recipes/#{recipe.id}", headers: bearer(token_for)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq(
        "recipe" => {
          "id" => recipe.id,
          "title" => "Bread",
          "ingredients" => [ { "name" => "flour", "amount" => "500 g" }, { "name" => "salt", "amount" => "" } ],
          "prep_instructions" => "Mix.\nKnead.",
          "prep_minutes" => 20,
          "cook_instructions" => "",
          "cook_minutes" => nil
        }
      )
    end

    it "returns an empty ingredient list for a recipe without ingredients" do
      recipe = create(:recipe, user: user)

      get "/api/v1/recipes/#{recipe.id}", headers: bearer(token_for)

      expect(response.parsed_body["recipe"]["ingredients"]).to eq([])
    end

    it "does not return another recipe's ingredients" do
      recipe = create(:recipe, user: user)
      create(:recipe_ingredient, name: "elsewhere")
      create(:recipe_ingredient, recipe: recipe, name: "mine")

      get "/api/v1/recipes/#{recipe.id}", headers: bearer(token_for)

      expect(response.parsed_body["recipe"]["ingredients"]).to eq([ { "name" => "mine", "amount" => "" } ])
    end

    it "is not shared or public: Cache-Control contains private" do
      recipe = create(:recipe, user: user)

      get "/api/v1/recipes/#{recipe.id}", headers: bearer(token_for)

      expect(response.headers["Cache-Control"]).to include("private")
    end

    it "answers another user's, a missing and a non-numeric id with the identical 404, byte for byte" do
      theirs = create(:recipe, user: create(:user), title: "Theirs")
      create(:recipe_ingredient, recipe: theirs, name: "secret")
      token = token_for

      bodies = [ theirs.id.to_s, (theirs.id + 1000).to_s, "abc", "1.5", "-1", "99999999999999999999999999" ].map do |id|
        get "/api/v1/recipes/#{id}", headers: bearer(token)
        expect_not_found
        [ response.status, response.body ]
      end

      expect(bodies.uniq.size).to eq(1)
      expect(bodies.first.last).not_to include("Theirs")
    end

    it "puts no recipe text in any span attribute, event or Sentry event" do
      recipe = create(:recipe, user: user, title: "SENTINEL-recipe-title-3c9e1f27-do-not-trace",
                               prep_instructions: "SENTINEL-recipe-prep-8d4b2a61", cook_instructions: "SENTINEL-recipe-cook-1e6d7b94")
      create(:recipe_ingredient, recipe: recipe, name: "SENTINEL-recipe-ingredient-5f7a9c03", amount: "SENTINEL-recipe-amount-2a8c4e10")
      token = token_for
      TelemetryHelpers.reset

      get "/api/v1/recipes/#{recipe.id}", headers: bearer(token)

      expect(response).to have_http_status(:ok)
      # Non-vacuous: the request was traced.
      expect(captured_spans).not_to be_empty
      dumped = dumped_telemetry
      expect(dumped).to include("/api/v1/recipes")
      expect(dumped).not_to include("SENTINEL-recipe")
      expect(captured_sentry_events.map(&:to_h).inspect).not_to include("SENTINEL-recipe")
    end

    it "puts no recipe text in telemetry when the id belongs to someone else (404)" do
      theirs = create(:recipe, user: create(:user), title: "SENTINEL-recipe-foreign-6b3d9a52-do-not-trace")
      create(:recipe_ingredient, recipe: theirs, name: "SENTINEL-recipe-foreign-ingredient-7c1e4f08")
      token = token_for
      TelemetryHelpers.reset

      get "/api/v1/recipes/#{theirs.id}", headers: bearer(token)

      expect_not_found
      expect(captured_spans).not_to be_empty
      dumped = dumped_telemetry
      expect(dumped).to include("/api/v1/recipes")
      expect(dumped).not_to include("SENTINEL-recipe")
      expect(response.body).not_to include("SENTINEL-recipe")
      expect(captured_sentry_events.map(&:to_h).inspect).not_to include("SENTINEL-recipe")
    end
  end

  describe "POST /api/v1/recipes" do
    let(:new_recipe_fields) do
      { "title" => "New recipe", "ingredients" => [], "prep_instructions" => "", "prep_minutes" => nil,
        "cook_instructions" => "", "cook_minutes" => nil }
    end

    it "returns 401 unauthenticated with no token, a malformed token or an expired token, and creates nothing" do
      token = token_for

      expect do
        post "/api/v1/recipes"
        expect_unauthenticated
        first_body = response.body

        post "/api/v1/recipes", headers: bearer("this.is.notajwt")
        expect_unauthenticated
        expect(response.body).to eq(first_body)

        travel 16.minutes do
          post "/api/v1/recipes", headers: bearer(token)
        end
        expect_unauthenticated
        expect(response.body).to eq(first_body)
      end.not_to change(Recipe, :count)
    end

    it "creates a recipe for the caller and returns exactly the show shape with the default fields" do
      expect { post "/api/v1/recipes", headers: bearer(token_for) }.to change(user.recipes, :count).by(1)

      recipe = user.recipes.last
      expect(response).to have_http_status(:created)
      expect(response.parsed_body).to eq("recipe" => { "id" => recipe.id }.merge(new_recipe_fields))
    end

    it "returns the same body that show returns for the new recipe" do
      token = token_for
      post "/api/v1/recipes", headers: bearer(token)
      created = response.parsed_body

      get "/api/v1/recipes/#{created.dig('recipe', 'id')}", headers: bearer(token)

      expect(response.parsed_body).to eq(created)
    end

    it "does not touch another user's recipes and does not list the new one for them" do
      other = create(:user)
      theirs = create(:recipe, user: other, title: "Theirs")
      before = theirs.reload.attributes

      post "/api/v1/recipes", headers: bearer(token_for)

      expect(theirs.reload.attributes).to eq(before)
      expect(other.recipes.count).to eq(1)
      expect(Recipe.count).to eq(2)
    end

    it "ignores user_id, title, id, prep_minutes and a nested recipe hash in the body and the query string" do
      other = create(:user)
      theirs = create(:recipe, user: other, title: "Theirs")
      before = theirs.reload.attributes
      token = token_for
      hostile = { user_id: other.id, title: "Hijacked", id: theirs.id, prep_minutes: 99, cook_minutes: 5,
                  prep_instructions: "x", recipe: { user_id: other.id, title: "Hijacked", id: theirs.id, prep_minutes: 99 } }

      [
        { params: hostile },
        { params: hostile.to_json, headers: { "CONTENT_TYPE" => "application/json" } },
        { params: nil, query: "user_id=#{other.id}&title=Hijacked&id=#{theirs.id}&prep_minutes=99&recipe[user_id]=#{other.id}&recipe[title]=Hijacked" }
      ].each do |variant|
        path = variant[:query] ? "/api/v1/recipes?#{variant[:query]}" : "/api/v1/recipes"
        expect do
          post path, params: variant[:params], headers: bearer(token).merge(variant[:headers] || {})
        end.to change(Recipe, :count).by(1)

        expect(response).to have_http_status(:created)
        created = Recipe.order(:id).last
        expect(created.user_id).to eq(user.id)
        expect(created.id).not_to eq(theirs.id)
        expect(response.parsed_body).to eq("recipe" => { "id" => created.id }.merge(new_recipe_fields))
        expect(created.prep_minutes).to be_nil
        expect(created.cook_minutes).to be_nil
        expect(theirs.reload.attributes).to eq(before)
      end

      expect(other.recipes.count).to eq(1)
    end

    it "makes a second recipe on a second POST" do
      token = token_for

      expect do
        post "/api/v1/recipes", headers: bearer(token)
        post "/api/v1/recipes", headers: bearer(token)
      end.to change(user.recipes, :count).by(2)

      expect(user.recipes.pluck(:title)).to eq([ "New recipe", "New recipe" ])
    end

    it "is not shared or public: Cache-Control contains private" do
      post "/api/v1/recipes", headers: bearer(token_for)

      expect(response.headers["Cache-Control"]).to include("private")
    end

    it "ignores a malformed JSON body and still creates the recipe" do
      token = token_for

      # The controller never reads params, so Rails never parses the body and the bad JSON goes unnoticed: the request
      # is treated like one without a body.
      expect do
        post "/api/v1/recipes", params: "{not json", headers: bearer(token).merge("CONTENT_TYPE" => "application/json")
      end.to change(user.recipes, :count).by(1)

      expect(response).to have_http_status(:created)
      expect(response.parsed_body).to eq("recipe" => { "id" => user.recipes.last.id }.merge(new_recipe_fields))
    end

    it "puts no request text in any span attribute, event, Sentry event or the response" do
      sentinel = "SENTINEL-recipe-create-9a4e2c71-do-not-trace"
      token = token_for
      TelemetryHelpers.reset

      post "/api/v1/recipes",
           params: { title: "#{sentinel}-title", recipe: { title: "#{sentinel}-nested" } }.to_json,
           headers: bearer(token).merge("CONTENT_TYPE" => "application/json")

      expect(response).to have_http_status(:created)
      # Non-vacuous: the request was traced. The query string is left out on purpose: the Rack span records it raw
      # (url.query) for every traced path, so a sentinel there would always show.
      expect(captured_spans).not_to be_empty
      dumped = dumped_telemetry
      expect(dumped).to include("/api/v1/recipes")
      expect(dumped).not_to include("SENTINEL-recipe-create")
      expect(response.body).not_to include("SENTINEL-recipe-create")
      expect(captured_sentry_events.map(&:to_h).inspect).not_to include("SENTINEL-recipe-create")
    end
  end
end
