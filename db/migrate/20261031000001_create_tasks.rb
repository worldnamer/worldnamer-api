class CreateTasks < ActiveRecord::Migration[8.1]
  def change
    create_table :tasks do |t|
      # on_delete: :cascade lets the database remove a list's tasks itself, even for a delete that skips callbacks
      # (deleting a user deletes their lists in SQL). The default index on task_list_id serves "this list's tasks".
      t.references :task_list, null: false, foreign_key: { on_delete: :cascade }
      # varchar(100) counts characters, like Ruby does. A blank text is allowed and stored as "".
      t.string :text, null: false, default: "", limit: 100
      t.boolean :done, null: false, default: false

      t.timestamps
    end
  end
end
