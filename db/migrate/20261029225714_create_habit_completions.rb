class CreateHabitCompletions < ActiveRecord::Migration[8.1]
  def change
    create_table :habit_completions do |t|
      # on_delete: :cascade lets the database remove a habit's completions itself, even for a delete that skips
      # callbacks (and a user's habits are deleted that way). The composite index below leads with habit_id, so a
      # separate habit_id index would be redundant.
      t.references :habit, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.date :date, null: false

      t.timestamps
    end

    # One completion per habit per day, enforced by the database whatever the code does.
    add_index :habit_completions, %i[habit_id date], unique: true
  end
end
