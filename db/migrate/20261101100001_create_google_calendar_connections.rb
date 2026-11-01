class CreateGoogleCalendarConnections < ActiveRecord::Migration[8.1]
  def change
    create_table :google_calendar_connections do |t|
      # One connection per user. on_delete: :cascade lets the database remove it itself, even for a delete that skips
      # callbacks.
      t.references :user, null: false, foreign_key: { on_delete: :cascade }, index: { unique: true }
      # Google's refresh token, encrypted by Active Record (the column holds ciphertext). Null only once the connection
      # is lost: the row stays behind as a tombstone so the user is told, until they connect again.
      t.text :refresh_token
      t.datetime :connected_at, null: false
      t.datetime :lost_at

      t.timestamps
    end
  end
end
