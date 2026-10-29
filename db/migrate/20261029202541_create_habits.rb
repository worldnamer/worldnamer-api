class CreateHabits < ActiveRecord::Migration[8.1]
  def change
    create_table :habits do |t|
      # on_delete: :cascade lets the database remove a user's habits itself, even for a delete that skips callbacks.
      t.references :user, null: false, foreign_key: { on_delete: :cascade }
      # varchar(100) counts characters, like Ruby does. It backs up the model's length validation.
      t.string :name, null: false, limit: 100

      t.timestamps
    end
  end
end
