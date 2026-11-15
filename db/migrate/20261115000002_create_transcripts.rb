class CreateTranscripts < ActiveRecord::Migration[8.1]
  def change
    create_table :transcripts do |t|
      # One transcript row per video, created when a fetch starts. on_delete: :cascade lets the database remove it with
      # its video, even for a delete that skips callbacks.
      t.references :video, null: false, foreign_key: { on_delete: :cascade }, index: { unique: true }
      # Null while a fetch is in progress. Only outcomes are stored: waiting and working are derived from the row's
      # absence or from started_at against the lease, so a process that dies mid-fetch leaves nothing stuck.
      t.string :outcome
      # The transcript service's reason word for a failed fetch (or one the client chose itself). Null otherwise.
      t.string :reason
      # The transcript as [{ "text": String, "start": Number }], kept only when the outcome is done.
      t.jsonb :lines
      # When the fetch that owns the row began: the lease's clock.
      t.datetime :started_at, null: false
      t.datetime :finished_at

      t.timestamps
    end

    add_check_constraint :transcripts, "outcome IN ('done', 'no_captions', 'failed')", name: "transcripts_outcome_values"
  end
end
