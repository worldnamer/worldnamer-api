class Habit < ApplicationRecord
  belongs_to :user

  # Runs on assignment and in finders, so " Stretch " is stored (and looked up) as "Stretch".
  normalizes :name, with: ->(name) { name.strip }

  # presence uses blank?, which treats Unicode whitespace as blank too.
  validates :name, presence: true, length: { maximum: 100 }
end
