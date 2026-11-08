class RecipeIngredient < ApplicationRecord
  belongs_to :recipe

  normalizes :name, with: ->(name) { name.to_s.strip }, apply_to_nil: true
  normalizes :amount, with: ->(amount) { amount.to_s.strip }, apply_to_nil: true

  # Capped so "amount name" is at most 100 characters (49 + a space + 50), which fits a task's text with no truncation.
  validates :name, presence: true, length: { maximum: 50 }
  validates :amount, length: { maximum: 49 }

  # A new ingredient goes after the recipe's highest position, so the console can create one without naming a place.
  # Two concurrent inserts could pick the same number; the unique index turns that into an error.
  before_create :set_position, if: -> { position.nil? }

  # id breaks ties between ingredients that share a position.
  scope :in_order, -> { order(:position, :id) }

  private

  def set_position
    self.position = (recipe.recipe_ingredients.maximum(:position) || -1) + 1
  end
end
