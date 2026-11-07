module Api
  module V1
    class RecipesController < ApplicationController
      # Warden checks the Authorization: Bearer token. On failure Auth::FailureApp answers 401 "unauthenticated".
      # No only: list, so an action added later is protected by default.
      before_action :authenticate_user!

      # GET /api/v1/recipes. Every query starts from current_user.recipes, never Recipe.find or an unscoped where, so a
      # recipe that belongs to someone else cannot be reached. Only id and title are selected, so the list stays small
      # and touches no ingredients. Not paginated.
      def index
        recipes = current_user.recipes.select(:id, :title).alphabetical
        render json: { recipes: recipes.map { |recipe| { id: recipe.id, title: recipe.title } } }
      end

      # GET /api/v1/recipes/:id. Someone else's recipe, a missing one and a non-numeric id all raise RecordNotFound from
      # the scoped find and get the same 404, so existence is not revealed.
      def show
        recipe = current_user.recipes.find(params[:id])
        render json: { recipe: recipe_json(recipe) }
      end

      # POST /api/v1/recipes. Reads no params at all: the owner comes from the token through current_user.recipes, and the
      # fields are the defaults, so nothing in the request (body or query) can set an owner or a field. There is no rescue:
      # the default title cannot fail validation, so a failure here is a real surprise and should be a 500 that Sentry sees.
      def create
        recipe = current_user.recipes.create!(title: Recipe::DEFAULT_TITLE)
        render json: { recipe: recipe_json(recipe) }, status: :created
      end

      private

      # An explicit allow-list: user_id, position, timestamps and ingredient ids stay inside. Ingredients are loaded in
      # position order with one query.
      def recipe_json(recipe)
        {
          id: recipe.id,
          title: recipe.title,
          ingredients: recipe.recipe_ingredients.in_order.map { |ingredient| { name: ingredient.name, amount: ingredient.amount } },
          prep_instructions: recipe.prep_instructions,
          prep_minutes: recipe.prep_minutes,
          cook_instructions: recipe.cook_instructions,
          cook_minutes: recipe.cook_minutes
        }
      end
    end
  end
end
