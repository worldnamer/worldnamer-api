class CreateTaskLists < ActiveRecord::Migration[8.1]
  def change
    create_table :task_lists do |t|
      # on_delete: :cascade lets the database remove a user's lists itself, even for a delete that skips callbacks.
      # index: false because the composite index below already serves lookups by user_id.
      t.references :user, null: false, foreign_key: { on_delete: :cascade }, index: false
      # varchar(100) counts characters, like Ruby does. A blank name is allowed and stored as "".
      t.string :name, null: false, default: "", limit: 100
      t.integer :position, null: false

      t.timestamps
    end

    # Serves "this user's lists in order". Not unique: ties are broken by id, and deletes leave gaps.
    add_index :task_lists, %i[user_id position]
  end
end
