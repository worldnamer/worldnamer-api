module Api
  module V1
    class HabitsController < ApplicationController
      # Warden checks the Authorization: Bearer token. On failure Auth::FailureApp answers 401 "unauthenticated".
      # No only: list, so an action added later is protected by default.
      before_action :authenticate_user!

      # GET /api/v1/habits. Every query starts from current_user.habits, never Habit.find, so a habit that belongs to
      # someone else cannot be reached. id breaks ties between habits created in the same instant.
      def index
        habits = current_user.habits.order(:created_at, :id)
        render json: { habits: habits.map { |habit| habit_json(habit) } }
      end

      private

      def habit_json(habit)
        { id: habit.id, name: habit.name }
      end
    end
  end
end
