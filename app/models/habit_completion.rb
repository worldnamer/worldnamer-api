# One row per (habit, day) that was done. A day with no row is a day not done.
class HabitCompletion < ApplicationRecord
  belongs_to :habit

  # No uniqueness validation: the unique index is the guarantee, and writes go through insert ... ON CONFLICT DO NOTHING.
  validates :date, presence: true
end
