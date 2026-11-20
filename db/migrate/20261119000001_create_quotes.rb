class CreateQuotes < ActiveRecord::Migration[8.1]
  def change
    create_table :quotes do |t|
      # on_delete: :cascade lets the database remove a user's quotes itself, even for a delete that skips callbacks.
      t.references :user, null: false, foreign_key: { on_delete: :cascade }
      t.string :text, null: false, limit: 500
      t.string :author, null: false, limit: 100, default: ""

      t.timestamps
    end
  end
end
