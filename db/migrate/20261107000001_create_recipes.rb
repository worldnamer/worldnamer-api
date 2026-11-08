class CreateRecipes < ActiveRecord::Migration[8.1]
  def change
    create_table :recipes do |t|
      # on_delete: :cascade lets the database remove a user's recipes itself, even for a delete that skips callbacks.
      # The default index on user_id serves "this user's recipes".
      t.references :user, null: false, foreign_key: { on_delete: :cascade }
      t.string :title, null: false, limit: 100
      t.text :prep_instructions, null: false, default: ""
      t.text :cook_instructions, null: false, default: ""
      # Nil means "not given". A given value is a positive whole number (checked in the model).
      t.integer :prep_minutes
      t.integer :cook_minutes

      t.timestamps
    end

    create_table :recipe_ingredients do |t|
      t.references :recipe, null: false, foreign_key: { on_delete: :cascade }
      t.integer :position, null: false
      t.string :name, null: false, limit: 100
      # Free text such as "500 g" or "a pinch"; blank when the ingredient has no amount.
      t.string :amount, null: false, default: "", limit: 50

      t.timestamps
    end

    # Also serves "this recipe's ingredients in order", and stops two ingredients taking the same place.
    add_index :recipe_ingredients, %i[recipe_id position], unique: true
  end
end
