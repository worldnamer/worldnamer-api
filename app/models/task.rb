class Task < ApplicationRecord
  belongs_to :task_list

  # Runs on assignment and in finders, so " Milk " is stored as "Milk" and nil as "". A blank text is allowed, so there
  # is no presence check.
  normalizes :text, with: ->(text) { text.to_s.strip }, apply_to_nil: true

  validates :text, length: { maximum: 100 }

  # Backstop: the controller only lets true or false through, and the column is not null.
  validates :done, inclusion: { in: [ true, false ] }

  # Oldest first. A new task gets the next id, so it lands last, and checking a task never moves it.
  scope :in_order, -> { order(:id) }
end
