class Quote < ApplicationRecord
  belongs_to :user

  # Runs on assignment, so "  Stay  " is stored as "Stay" and " Me " as "Me".
  normalizes :text, with: ->(value) { value.strip }

  # The author column does not allow null, so a missing author is stored as "".
  normalizes :author, with: ->(author) { author.to_s.strip }, apply_to_nil: true

  # presence uses blank?, which treats Unicode whitespace as blank too.
  validates :text, presence: true, length: { maximum: 500 }
  validates :author, length: { maximum: 100 }
end
