class Recipe < ApplicationRecord
  belongs_to :user

  # Ingredients have no callbacks, so one DELETE removes them. The foreign key cascades in the database as well.
  has_many :recipe_ingredients, dependent: :delete_all

  # Runs on assignment and in finders, so " Bread " is stored as "Bread". Instructions may be blank, stored as "".
  normalizes :title, with: ->(title) { title.to_s.strip }, apply_to_nil: true
  normalizes :prep_instructions, :cook_instructions, with: ->(text) { text.to_s.strip }, apply_to_nil: true

  validates :title, presence: true, length: { maximum: 100 }
  validates :prep_minutes, :cook_minutes, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true

  # Case-insensitive alphabetical; id breaks ties. LOWER(title) cannot use an index, which is fine for one user's rows.
  scope :alphabetical, -> { order(Arel.sql("LOWER(title)"), :id) }
end
