# Ingredient names are now capped at 50 characters and amounts at 49, so "amount name" always fits a task's 100. The
# columns keep their wider limits; only the model enforces the new caps, so older rows must be cut to match.
class ShortenRecipeIngredientLimits < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL.squish
      UPDATE recipe_ingredients
      SET name = LEFT(name, 50), amount = LEFT(amount, 49)
      WHERE CHAR_LENGTH(name) > 50 OR CHAR_LENGTH(amount) > 49
    SQL
  end

  # The cut text is gone, so there is nothing to restore.
  def down
    raise ActiveRecord::IrreversibleMigration, "The cut ingredient text cannot be recovered."
  end
end
