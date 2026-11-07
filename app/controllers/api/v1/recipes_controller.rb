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
    end
  end
end
