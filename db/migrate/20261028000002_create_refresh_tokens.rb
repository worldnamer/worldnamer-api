class CreateRefreshTokens < ActiveRecord::Migration[8.1]
  def change
    create_table :refresh_tokens do |t|
      # on_delete: :cascade lets the database remove a user's tokens itself, even for a delete that skips callbacks.
      t.references :user, null: false, foreign_key: { on_delete: :cascade }
      # One family is one login on one browser. A native uuid column, filled in by the app (SecureRandom.uuid).
      t.uuid :family_id, null: false, index: true
      # SHA256 hex of the raw token. The raw token itself is never stored.
      t.string :token_digest, null: false, index: { unique: true }
      t.datetime :expires_at, null: false
      t.datetime :used_at

      t.timestamps
    end
  end
end
