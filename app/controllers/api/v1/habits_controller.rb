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
      #
      # With week_start (a Monday, YYYY-MM-DD) each habit lists the dates it was completed that week. Without the key
      # the lists are empty and no completions are read. A present but empty or non-string value is a 400.
      def index
        week_start = nil
        if params.key?(:week_start)
          week_start = IsoDate.parse(params[:week_start])
          unless week_start&.monday?
            return render_error "bad_request", "week_start must be a Monday in the form YYYY-MM-DD.", :bad_request
          end
        end

        habits = current_user.habits.order(:created_at, :id).to_a
        dates_by_habit = week_start ? completed_dates_by_habit(habits, week_start) : {}
        render json: { habits: habits.map { |habit| habit_json(habit, dates_by_habit.fetch(habit.id, [])) } }
      end

      # POST /api/v1/habits. The owner comes from the token, never from the body: params.expect permits only name, so
      # user_id and id in the body are dropped.
      def create
        habit = current_user.habits.build(params.expect(habit: [ :name ]))
        if habit.save
          render json: { habit: { id: habit.id, name: habit.name } }, status: :created
        else
          render_error "validation_failed", "#{habit.errors.full_messages.first}.", :unprocessable_content
        end
      end

      # DELETE /api/v1/habits/:id. Someone else's habit and a missing one get the same 404, so existence is not revealed.
      # destroy! (not delete) so the callbacks that delete a habit's completions run.
      def destroy
        current_user.habits.find(params[:id]).destroy!
        head :no_content
      end

      private

      def habit_json(habit, completed_dates)
        { id: habit.id, name: habit.name, completed_dates: completed_dates }
      end

      # One query for the whole week, however many habits there are (a query per habit would be an N+1). The ids come
      # from the caller's own habits, so another user's completions cannot be read.
      def completed_dates_by_habit(habits, week_start)
        HabitCompletion.where(habit_id: habits.map(&:id), date: week_start..(week_start + 6))
                       .order(:date)
                       .pluck(:habit_id, :date)
                       .group_by(&:first)
                       .transform_values { |rows| rows.map { |_habit_id, date| date.iso8601 } }
      end
    end
  end
end
