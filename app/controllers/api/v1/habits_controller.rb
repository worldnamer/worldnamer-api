module Api
  module V1
    class HabitsController < ApplicationController
      # Warden checks the Authorization: Bearer token. On failure Auth::FailureApp answers 401 "unauthenticated".
      # No only: list, so an action added later is protected by default.
      before_action :authenticate_user!

      # Rails would copy a top-level name into params[:habit] for JSON bodies. The contract is { habit: { name } } only,
      # so a body without the habit key must get 400.
      wrap_parameters false

      # GET /api/v1/habits. Every query starts from current_user.habits, never Habit.find, so a habit that belongs to
      # someone else cannot be reached. id breaks ties between habits created in the same instant.
      def index
        habits = current_user.habits.order(:created_at, :id)
        render json: { habits: habits.map { |habit| habit_json(habit) } }
      end

      # POST /api/v1/habits. The owner comes from the token, never from the body: params.expect permits only name, so
      # user_id and id in the body are dropped.
      def create
        habit = current_user.habits.build(params.expect(habit: [ :name ]))
        if habit.save
          render json: { habit: habit_json(habit) }, status: :created
        else
          render_error "validation_failed", "#{habit.errors.full_messages.first}.", :unprocessable_content
        end
      end

      private

      def habit_json(habit)
        { id: habit.id, name: habit.name }
      end
    end
  end
end
