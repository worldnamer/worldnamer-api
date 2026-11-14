class DropGoogleOauthStates < ActiveRecord::Migration[8.1]
  def change
    # Replaced by google_calendar_oauth_states and unused since that release. Rows lived only minutes, so none are kept.
    drop_table :google_oauth_states do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }, index: { unique: true }
      t.string :state_digest, null: false, index: { unique: true }
      t.text :code_verifier
      t.datetime :expires_at, null: false

      t.timestamps
    end
  end
end
