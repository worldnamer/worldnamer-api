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
end
