class CreateSummaries < ActiveRecord::Migration[8.1]
  def change
    create_table :summaries do |t|
      # One summary row per video, created when a summary starts. on_delete: :cascade lets the database remove it with
      # its video, even for a delete that skips callbacks.
      t.references :video, null: false, foreign_key: { on_delete: :cascade }, index: { unique: true }
      # Null while a summary is in progress. Only outcomes are stored: waiting and working are derived from the row's
      # absence or from started_at against the lease, so a process that dies mid-call leaves nothing stuck.
      t.string :outcome
      # One of the client's allow-listed reason words, for a failed summary. Null otherwise.
      t.string :reason
      # The model's summary, kept only when the outcome is done. Untrusted text, stored as received.
      t.text :summary_text
      # The model name the service reported, kept only when the outcome is done.
      t.string :model
      # When the call that owns the row began: the lease's clock.
      t.datetime :started_at, null: false
      t.datetime :finished_at

      t.timestamps
    end

    add_check_constraint :summaries, "outcome IN ('done', 'nothing_to_summarise', 'failed')", name: "summaries_outcome_values"
  end
end
