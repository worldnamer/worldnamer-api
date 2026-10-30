module Api
  module V1
    # PUT and DELETE /api/v1/habits/:habit_id/completions/:date. Both are idempotent and answer 204 whether or not the
    # day was already in that state. Neither reads the request body: the habit and the date come from the path and the
    # owner from the token.
    #
    # Checks run in a fixed order: 401, then 404 for the habit, then 400 for the date. A habit that is not yours gets the
    # same 404 as a missing one whatever the date, so nothing about it is revealed.
    class CompletionsController < ApplicationController
      # Warden checks the Authorization: Bearer token. No only: list, so an action added later is protected by default.
      before_action :authenticate_user!
      before_action :set_habit
      before_action :set_date

      # Rails would copy the body into params[:completion]. Nothing reads it, so do not build it.
      wrap_parameters false

      # PUT (and PATCH) marks the day as done. One INSERT ... ON CONFLICT DO NOTHING, so a repeat or two requests at
      # once leave a single row and never raise.
      def update
        HabitCompletion.insert({ habit_id: @habit.id, date: @date }, unique_by: %i[habit_id date])
        head :no_content
      rescue ActiveRecord::InvalidForeignKey
        # The habit was deleted (another tab) between the lookup above and the insert: the same 404 as a missing habit.
        render_error "not_found", "Habit not found.", :not_found
      end

      # DELETE marks the day as not done. Scoped to the habit that was already found, and a day that was never done is
      # not an error.
      def destroy
        @habit.habit_completions.where(date: @date).delete_all
        head :no_content
      end

      private

      # Scoped to the caller's habits, so a habit that belongs to someone else raises RecordNotFound (404).
      def set_habit
        @habit = current_user.habits.find(params[:habit_id])
      end

      def set_date
        @date = IsoDate.parse(params[:date])
        render_error "bad_request", "Date must be a real date in the form YYYY-MM-DD.", :bad_request unless @date
      end
    end
  end
end
