class CreateGoogleOauthStates < ActiveRecord::Migration[8.1]
  def change
    create_table :google_oauth_states do |t|
      # One pending Google sign-in per user: starting again replaces it. on_delete: :cascade lets the database remove
      # it with the user.
      t.references :user, null: false, foreign_key: { on_delete: :cascade }, index: { unique: true }
      # SHA256 hex of the raw state. The raw state lives only in the browser's cookie and Google's redirect.
      t.string :state_digest, null: false, index: { unique: true }
      # The PKCE code verifier, encrypted by Active Record (the column holds ciphertext).
      t.text :code_verifier
      t.datetime :expires_at, null: false

      t.timestamps
    end
  end
end
