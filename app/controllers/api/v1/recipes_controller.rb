module Api
  module V1
    class RecipesController < ApplicationController
      # Most ingredient rows one recipe may hold.
      MAX_INGREDIENTS = 100

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

      # PATCH /api/v1/recipes/:id. Changes only the keys present in recipe. An ingredients key replaces the whole list in
      # the order sent (an empty list removes them all). Everything is validated before anything is written, so a 422
      # changes nothing, and the write runs under a row lock so two saves of one recipe cannot collide on the unique
      # (recipe_id, position) index. The recipe is found through current_user.recipes, and only the allow-listed keys are
      # read, so the id, user_id and positions in a request are inert.
      def update
        recipe = current_user.recipes.find(params[:id])
        attributes = recipe_params
        submitted = attributes[:ingredients]
        rows = ingredient_rows(recipe, submitted) if submitted
        scalars = attributes.except(:ingredients)

        errors = validation_errors(recipe, scalars, rows, submitted)
        return render_validation_failed(errors) if errors.any?

        recipe.with_lock do
          recipe.update!(scalars)
          if rows
            recipe.recipe_ingredients.delete_all
            rows.each(&:save!)
          end
        end

        render json: { recipe: recipe_json(recipe.reload) }
      end

      # DELETE /api/v1/recipes/:id. Reads no params beyond the id. The recipe is found through current_user.recipes, so
      # someone else's recipe, a missing one and a non-numeric id all raise RecordNotFound and get the same 404. It is a
      # hard delete, and the ingredient rows go with it.
      def destroy
        current_user.recipes.find(params[:id]).destroy!
        head :no_content
      end

      private

      # params.expect answers 400 (ParameterMissing) when recipe is missing, empty or not a hash. It silently turns an
      # ingredients list holding non-hashes into an empty one, which would wipe the list, so the raw value is checked.
      def recipe_params
        permitted = params.expect(recipe: [ :title, :prep_instructions, :prep_minutes, :cook_instructions, :cook_minutes,
                                            { ingredients: [ [ :name, :amount ] ] } ])
        if params[:recipe].key?(:ingredients)
          sent = params[:recipe][:ingredients]
          raise ActionController::ParameterMissing, :ingredients unless sent.is_a?(Array) && sent.all?(ActionController::Parameters)
        end
        permitted
      end

      # Unsaved rows, positioned by their place in the request. Over the cap no rows are built, and the error is reported
      # instead.
      def ingredient_rows(recipe, submitted)
        return [] if submitted.size > MAX_INGREDIENTS

        submitted.each_with_index.map do |row, index|
          RecipeIngredient.new(recipe: recipe, name: row[:name], amount: row[:amount], position: index)
        end
      end

      # Field key => full messages. The recipe is checked on a copy, because locking reloads the record and refuses
      # one with unsaved changes. Messages are Rails attribute messages and never contain the submitted value.
      def validation_errors(recipe, scalars, rows, submitted)
        errors = Hash.new { |hash, key| hash[key] = [] }
        candidate = recipe.dup
        candidate.assign_attributes(scalars)
        candidate.validate
        candidate.errors.each { |error| errors[error.attribute.to_s] << "#{error.full_message}." }

        if submitted && submitted.size > MAX_INGREDIENTS
          errors["ingredients"] << "Ingredients has too many rows (maximum is #{MAX_INGREDIENTS})."
        end
        rows&.each_with_index do |row, index|
          row.validate
          row.errors.each { |error| errors["ingredients.#{index}.#{error.attribute}"] << "#{error.full_message}." }
        end
        errors
      end

      def render_validation_failed(errors)
        render json: { error: { code: "validation_failed", message: errors.values.flatten.join(" "), fields: errors } },
               status: :unprocessable_content
      end

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
