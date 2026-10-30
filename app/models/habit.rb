class Habit < ApplicationRecord
  belongs_to :user

  # One DELETE for all of a habit's completions, since a daily habit gathers a row a day and HabitCompletion has no
  # callbacks to run; the foreign key also cascades in the database for deletes that skip the model.
  has_many :habit_completions, dependent: :delete_all

  # Runs on assignment and in finders, so " Stretch " is stored (and looked up) as "Stretch".
  normalizes :name, with: ->(name) { name.strip }

  # presence uses blank?, which treats Unicode whitespace as blank too.
  validates :name, presence: true, length: { maximum: 100 }

  # The dates each habit was completed in the week starting on week_start (a Date), as { habit_id => ["2026-10-26", ...] }
  # with the dates ascending. Habits with none that week are left out. Call it on a relation, as in
  # current_user.habits.completed_dates_in_week(monday): only the completions of those habits are read, in a single
  # query however many habits there are (a query per habit would be an N+1).
  def self.completed_dates_in_week(week_start)
    HabitCompletion.where(habit_id: unscope(:order).select(:id), date: week_start..(week_start + 6))
                   .order(:date)
                   .pluck(:habit_id, :date)
                   .group_by(&:first)
                   .transform_values { |rows| rows.map { |_habit_id, date| date.iso8601 } }
  end
end
