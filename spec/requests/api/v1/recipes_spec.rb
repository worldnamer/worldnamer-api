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

  describe "PATCH /api/v1/recipes/:id" do
    let!(:recipe) do
      create(:recipe, user: user, title: "Bread", prep_instructions: "Mix.", prep_minutes: 20, cook_instructions: "Bake.", cook_minutes: 30)
    end

    before do
      create(:recipe_ingredient, recipe: recipe, name: "flour", amount: "500 g", position: 0)
      create(:recipe_ingredient, recipe: recipe, name: "salt", amount: "", position: 1)
    end

    # The body is a hash or a raw JSON string, given as the first argument or as bare keys (patch_recipe(recipe: { ... })).
    def patch_recipe(*body, id: recipe.id, token: token_for, query: nil, **keys)
      body = body.first || keys
      patch "/api/v1/recipes/#{id}#{query}", params: body.is_a?(String) ? body : body.to_json,
                                           headers: bearer(token).merge("CONTENT_TYPE" => "application/json")
    end

    def stored(target = recipe)
      target = Recipe.find(target.id)
      [ target.attributes.except("updated_at"), target.recipe_ingredients.in_order.pluck(:name, :amount, :position) ]
    end

    def field_keys
      response.parsed_body.dig("error", "fields").keys
    end

    def expect_validation_failed(*keys)
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("validation_failed")
      expect(field_keys).to match_array(keys)
    end

    def expect_bad_request
      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq("error" => { "code" => "bad_request", "message" => "Request body is malformed." })
    end

    it "returns 401 unauthenticated with no token, a malformed token or an expired token, and changes nothing" do
      before = stored
      token = token_for
      body = { recipe: { title: "Hijacked" } }.to_json

      patch "/api/v1/recipes/#{recipe.id}", params: body, headers: { "CONTENT_TYPE" => "application/json" }
      expect_unauthenticated
      first_body = response.body

      patch "/api/v1/recipes/#{recipe.id}", params: body, headers: bearer("this.is.notajwt").merge("CONTENT_TYPE" => "application/json")
      expect_unauthenticated
      expect(response.body).to eq(first_body)

      travel 16.minutes do
        patch "/api/v1/recipes/#{recipe.id}", params: body, headers: bearer(token).merge("CONTENT_TYPE" => "application/json")
      end
      expect_unauthenticated
      expect(response.body).to eq(first_body)
      expect(stored).to eq(before)
    end

    it "updates the title, instructions and minutes and answers with exactly the show shape" do
      patch_recipe(recipe: { title: "Rye bread", prep_instructions: "Stir.\nRest.", prep_minutes: 5, cook_instructions: "Bake hot.", cook_minutes: 45 })

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq(
        "recipe" => {
          "id" => recipe.id, "title" => "Rye bread",
          "ingredients" => [ { "name" => "flour", "amount" => "500 g" }, { "name" => "salt", "amount" => "" } ],
          "prep_instructions" => "Stir.\nRest.", "prep_minutes" => 5, "cook_instructions" => "Bake hot.", "cook_minutes" => 45
        }
      )
      patched = response.parsed_body
      get "/api/v1/recipes/#{recipe.id}", headers: bearer(token_for)
      expect(response.parsed_body).to eq(patched)
    end

    it "leaves every other field and the ingredients alone when one key is sent" do
      before = stored

      patch_recipe(recipe: { prep_minutes: 7 })

      expect(response).to have_http_status(:ok)
      after = stored
      expect(after.last).to eq(before.last)
      expect(after.first).to eq(before.first.merge("prep_minutes" => 7))
    end

    it "replaces the whole ingredient list in the sent order, and keeps positions 0..n-1" do
      patch_recipe(recipe: { ingredients: [ { name: "water", amount: "1 l" }, { name: "salt", amount: "" }, { name: "water", amount: "2 l" } ] })

      expect(response).to have_http_status(:ok)
      expect(stored.last).to eq([ [ "water", "1 l", 0 ], [ "salt", "", 1 ], [ "water", "2 l", 2 ] ])
      expect(response.parsed_body.dig("recipe", "ingredients").map { |row| row["name"] }).to eq(%w[water salt water])

      patch_recipe(recipe: { ingredients: [ { name: "salt", amount: "" }, { name: "water", amount: "1 l" } ] })
      expect(stored.last).to eq([ [ "salt", "", 0 ], [ "water", "1 l", 1 ] ])
    end

    it "empties the list with an empty array, and keeps it when the key is omitted" do
      patch_recipe(recipe: { title: "Still there" })
      expect(stored.last.size).to eq(2)

      patch_recipe(recipe: { ingredients: [] })

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("recipe", "ingredients")).to eq([])
      expect(stored.last).to eq([])
      expect(Recipe.find(recipe.id).title).to eq("Still there")
    end

    it "leaves clean positions after two saves of the list in a row" do
      token = token_for
      patch_recipe({ recipe: { ingredients: [ { name: "a" }, { name: "b" }, { name: "c" } ] } }, token: token)
      patch_recipe({ recipe: { ingredients: [ { name: "c" }, { name: "a" } ] } }, token: token)

      expect(response).to have_http_status(:ok)
      expect(stored.last).to eq([ [ "c", "", 0 ], [ "a", "", 1 ] ])
    end

    it "strips the title, names, amounts and instructions, and clears a time with null or an empty string" do
      patch_recipe(recipe: { title: "  Loaf  ", prep_instructions: "  Mix.  ", cook_instructions: "\nBake.\n", prep_minutes: nil, cook_minutes: "",
                             ingredients: [ { name: "  oil ", amount: " 2 tbsp " } ] })

      expect(response).to have_http_status(:ok)
      stored_recipe = Recipe.find(recipe.id)
      expect(stored_recipe.attributes.values_at("title", "prep_instructions", "cook_instructions", "prep_minutes", "cook_minutes"))
        .to eq([ "Loaf", "Mix.", "Bake.", nil, nil ])
      expect(stored.last).to eq([ [ "oil", "2 tbsp", 0 ] ])
    end

    it "treats a missing amount as empty" do
      patch_recipe(recipe: { ingredients: [ { name: "oil" } ] })

      expect(stored.last).to eq([ [ "oil", "", 0 ] ])
    end

    it "accepts the largest allowed values" do
      patch_recipe(recipe: { title: "t" * 100, prep_instructions: "p" * 10_000, cook_instructions: "c" * 10_000, prep_minutes: 99_999,
                             ingredients: Array.new(100) { |i| { name: "n" * 100, amount: "a" * 50 } } })

      expect(response).to have_http_status(:ok)
      expect(stored.last.size).to eq(100)
    end

    describe "validation" do
      it "answers 422 with field-keyed messages and writes nothing for a blank or over-long title" do
        before = stored

        patch_recipe(recipe: { title: "   " })
        expect_validation_failed("title")
        expect(response.parsed_body.dig("error", "fields", "title")).to eq([ "Title can't be blank." ])
        expect(response.parsed_body.dig("error", "message")).to eq("Title can't be blank.")

        patch_recipe(recipe: { title: "t" * 101 })
        expect_validation_failed("title")
        expect(response.parsed_body.dig("error", "fields", "title")).to eq([ "Title is too long (maximum is 100 characters)." ])
        expect(stored).to eq(before)
      end

      it "reports the index of an ingredient with a blank or over-long name or an over-long amount" do
        before = stored

        patch_recipe(recipe: { ingredients: [ { name: "ok" }, { name: "  ", amount: "1" } ] })
        expect_validation_failed("ingredients.1.name")
        expect(response.parsed_body.dig("error", "fields", "ingredients.1.name")).to eq([ "Name can't be blank." ])

        patch_recipe(recipe: { ingredients: [ { name: "n" * 101 } ] })
        expect_validation_failed("ingredients.0.name")

        patch_recipe(recipe: { ingredients: [ { name: "ok", amount: "a" * 51 } ] })
        expect_validation_failed("ingredients.0.amount")
        expect(response.parsed_body.dig("error", "fields", "ingredients.0.amount")).to eq([ "Amount is too long (maximum is 50 characters)." ])

        expect(stored).to eq(before)
      end

      it "rejects a row with only an amount on its name, without dropping it" do
        before = stored

        patch_recipe(recipe: { ingredients: [ { name: "", amount: "2 cups" } ] })

        expect_validation_failed("ingredients.0.name")
        expect(stored).to eq(before)
      end

      it "rejects minutes that are zero, negative, fractional or not a number" do
        before = stored

        [ 0, -1, 5.5, "abc", "5.5" ].each do |minutes|
          patch_recipe(recipe: { prep_minutes: minutes, cook_minutes: minutes })
          expect_validation_failed("prep_minutes", "cook_minutes")
        end
        expect(stored).to eq(before)
      end

      it "enforces the limits on ingredient count, instruction length and minutes" do
        before = stored

        patch_recipe(recipe: { ingredients: Array.new(101) { { name: "x" } } })
        expect_validation_failed("ingredients")
        expect(response.parsed_body.dig("error", "fields", "ingredients")).to eq([ "Ingredients has too many rows (maximum is 100)." ])

        patch_recipe(recipe: { prep_instructions: "p" * 10_001, cook_instructions: "c" * 10_001, prep_minutes: 100_000, cook_minutes: 100_000 })
        expect_validation_failed("prep_instructions", "cook_instructions", "prep_minutes", "cook_minutes")

        expect(stored).to eq(before)
      end

      it "answers 422, not 500, for minutes beyond the integer column" do
        before = stored

        patch_recipe('{"recipe":{"prep_minutes":99999999999999999999999,"cook_minutes":"99999999999999999999"}}')

        expect_validation_failed("prep_minutes", "cook_minutes")
        expect(stored).to eq(before)
      end

      it "saves nothing when one row is bad, not even the valid changes sent with it" do
        before = stored

        patch_recipe(recipe: { title: "Changed", prep_minutes: 1, ingredients: [ { name: "good" }, { name: "" }, { name: "also good" } ] })

        expect_validation_failed("ingredients.1.name")
        expect(stored).to eq(before)
      end

      it "reports every failing field in one answer, and joins the messages" do
        patch_recipe(recipe: { title: "", prep_minutes: 0, ingredients: [ { name: "" } ] })

        expect_validation_failed("title", "prep_minutes", "ingredients.0.name")
        expect(response.parsed_body.dig("error", "message")).to eq(response.parsed_body.dig("error", "fields").values.flatten.join(" "))
      end

      it "never echoes the submitted value in a 422" do
        patch_recipe(recipe: { title: "SENTINEL-recipe-echo-#{'x' * 100}", prep_minutes: "SENTINEL-recipe-echo-minutes",
                               ingredients: [ { name: "SENTINEL-recipe-echo-name-#{'y' * 100}", amount: "SENTINEL-recipe-echo-amount-#{'z' * 50}" } ] })

        expect_validation_failed("title", "prep_minutes", "ingredients.0.name", "ingredients.0.amount")
        expect(response.body).not_to include("SENTINEL-recipe-echo")
      end
    end

    describe "malformed requests" do
      it "answers 400 for malformed JSON, a missing recipe, an empty recipe and a recipe that is not a hash" do
        before = stored

        [ "{not json", "", "{}", '{"recipe":{}}', '{"recipe":"x"}', '{"recipe":[]}', '{"recipe":{"title":["a"]}}' ].each do |body|
          patch_recipe(body)
          expect_bad_request
        end
        expect(stored).to eq(before)
      end

      it "answers 400 when ingredients is not a list of hashes, and does not wipe the list" do
        before = stored

        [ '"flour"', "null", "5", '["flour"]', "[[]]", '[{"name":"a"},"b"]', '{"0":{"name":"a"}}', '{"name":"a"}' ].each do |ingredients|
          patch_recipe(%({"recipe":{"title":"Changed","ingredients":#{ingredients}}}))
          expect_bad_request
        end
        expect(stored).to eq(before)
      end

      it "answers 400 for a recipe holding only keys that are not allowed" do
        patch_recipe(recipe: { user_id: 1, id: 2, position: 3 })

        expect_bad_request
      end
    end

    describe "ownership" do
      it "answers another user's, a missing and a non-numeric id with the identical 404, byte for byte" do
        theirs = create(:recipe, user: create(:user), title: "Theirs")
        create(:recipe_ingredient, recipe: theirs, name: "secret")
        before = stored(theirs)
        token = token_for

        bodies = [ theirs.id.to_s, (theirs.id + 1000).to_s, "abc", "1.5", "-1", "99999999999999999999999999" ].map do |id|
          patch_recipe({ recipe: { title: "Hijacked", ingredients: [ { name: "evil" } ] } }, id: id, token: token)
          expect(response).to have_http_status(:not_found)
          expect(response.parsed_body).to eq("error" => { "code" => "not_found", "message" => "Not found." })
          [ response.status, response.body ]
        end

        expect(bodies.uniq.size).to eq(1)
        expect(stored(theirs)).to eq(before)
        get "/api/v1/recipes/#{theirs.id}", headers: bearer(token)
        expect(response).to have_http_status(:not_found)
      end

      it "ignores user_id, id, position, recipe_id and a nested recipe in the body and the query string" do
        other = create(:user)
        theirs = create(:recipe, user: other, title: "Theirs")
        before = stored(theirs)
        token = token_for

        patch_recipe({ id: theirs.id, user_id: other.id,
                       recipe: { title: "Mine now", user_id: other.id, id: theirs.id, recipe: { user_id: other.id, title: "Nested" },
                                 ingredients: [ { name: "oil", position: 9, recipe_id: theirs.id, id: 1, user_id: other.id } ] } },
                     token: token, query: "?id=#{theirs.id}&user_id=#{other.id}")

        expect(response).to have_http_status(:ok)
        mine = Recipe.find(recipe.id)
        expect(mine.user_id).to eq(user.id)
        expect(mine.title).to eq("Mine now")
        expect(response.parsed_body.dig("recipe", "id")).to eq(recipe.id)
        expect(stored(mine).last).to eq([ [ "oil", "", 0 ] ])
        expect(stored(theirs)).to eq(before)
        expect(RecipeIngredient.where(recipe_id: theirs.id)).to be_empty
      end

      it "ignores user_id and id in the query string, and answers 400 when the query holds only disallowed recipe keys" do
        other = create(:user)
        theirs = create(:recipe, user: other, title: "Theirs")
        before = stored(theirs)
        before_mine = stored

        patch_recipe({ recipe: { title: "Query" } }, query: "?user_id=#{other.id}&id=#{theirs.id}&recipe[user_id]=#{other.id}&recipe[id]=#{theirs.id}")

        expect_bad_request
        expect(stored(theirs)).to eq(before)
        expect(stored).to eq(before_mine)
      end
    end

    it "is not shared or public: Cache-Control contains private" do
      patch_recipe(recipe: { title: "Cache" })

      expect(response.headers["Cache-Control"]).to include("private")
    end

    describe "telemetry" do
      let(:sentinel) { "SENTINEL-recipe-patch-4d8a1b36-do-not-trace" }

      def expect_nothing_leaked(path_fragment)
        # Non-vacuous: the request was traced.
        expect(captured_spans).not_to be_empty
        dumped = dumped_telemetry
        expect(dumped).to include(path_fragment)
        expect(dumped).not_to include(sentinel)
        expect(response.body).not_to include(sentinel)
        expect(captured_sentry_events.map(&:to_h).inspect).not_to include(sentinel)
      end

      it "puts no recipe text in spans, Sentry events or the response on a 200" do
        token = token_for
        TelemetryHelpers.reset

        patch_recipe({ recipe: { title: "#{sentinel}-title", prep_instructions: "#{sentinel}-prep", cook_instructions: "#{sentinel}-cook",
                                 ingredients: [ { name: "#{sentinel}-name", amount: "#{sentinel}-amount" } ] } }, token: token)

        expect(response).to have_http_status(:ok)
        # The response legitimately carries the user's own text, so it is left out of the check on this path.
        expect(captured_spans).not_to be_empty
        expect(dumped_telemetry).to include("/api/v1/recipes")
        expect(dumped_telemetry).not_to include(sentinel)
        expect(captured_sentry_events.map(&:to_h).inspect).not_to include(sentinel)
      end

      it "puts no recipe text in spans, Sentry events or the response on a 422" do
        token = token_for
        TelemetryHelpers.reset

        patch_recipe({ recipe: { title: "#{sentinel}-#{'t' * 100}", prep_instructions: "#{sentinel}-prep", cook_instructions: "#{sentinel}-cook",
                                 ingredients: [ { name: "#{sentinel}-name-#{'n' * 100}", amount: "#{sentinel}-amount-#{'a' * 50}" } ] } }, token: token)

        expect(response).to have_http_status(:unprocessable_content)
        expect_nothing_leaked("/api/v1/recipes")
      end

      it "puts no body text in spans, Sentry events or the response on a malformed JSON 400" do
        token = token_for
        TelemetryHelpers.reset

        patch_recipe(%({"recipe":{"title":"#{sentinel}-title","ingredients":[{"name":"#{sentinel}-name"},]}}), token: token)

        expect_bad_request
        expect_nothing_leaked("/api/v1/recipes")
      end

      it "puts no body text in telemetry on a 400 for the wrong shape" do
        token = token_for
        TelemetryHelpers.reset

        patch_recipe({ recipe: { title: "#{sentinel}-title", ingredients: [ "#{sentinel}-row" ] } }, token: token)

        expect_bad_request
        expect_nothing_leaked("/api/v1/recipes")
      end
    end
  end
end
