module Api
  module V1
    # POST /api/v1/recipes/:recipe_id/task_list makes a new task list from one of the caller's recipes: the list is named
    # for the recipe and holds one task per ingredient, in order. The request body is never read: the recipe comes from
    # the path (found through the caller) and nothing else decides what is made. There is no de-duplication, so a second
    # request makes a second list.
    class RecipeTaskListsController < ApplicationController
      # Warden checks the Authorization: Bearer token. No only: list, so an action added later is protected by default.
      before_action :authenticate_user!

      # Rails would copy the body into params[:task_list]. Nothing reads it, so do not build it.
      wrap_parameters false

      # The recipe is found through the caller, so a missing, foreign, non-numeric or out-of-range id all raise
      # RecordNotFound (404). The list and its tasks are made in one transaction, so a failure leaves nothing behind. The
      # ingredient caps keep "amount name" within a task's 100 characters, and a recipe title within a list name's, so
      # nothing is truncated. A recipe without ingredients gives an empty list.
      def create
        recipe = current_user.recipes.find(params[:recipe_id])
        list = TaskList.transaction do
          current_user.task_lists.create!(name: recipe.title).tap do |new_list|
            recipe.recipe_ingredients.in_order.each do |ingredient|
              new_list.tasks.create!(text: [ ingredient.amount, ingredient.name ].reject(&:blank?).join(" "))
            end
          end
        end
        render json: { task_list: { id: list.id, name: list.name } }, status: :created
      end
    end
  end
end
