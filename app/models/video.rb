# A video seen in a user's chosen YouTube playlist, recorded the first time the playlist check meets it with the title
# it had then. Rows are never removed when the video leaves the playlist. Unique per user and YouTube id, so the check
# can insert with insert_all and skip what is already there (insert_all does not run these validations; the database
# constraints hold the same rules).
class Video < ApplicationRecord
  belongs_to :user

  # At most one. No callbacks on it; the foreign key cascades in the database as well.
  has_one :transcript, dependent: :delete
  has_one :summary, dependent: :delete

  validates :youtube_id, format: { with: YouTube::DataClient::VIDEO_ID }

  # The user's videos with each one's transcript state, newest first (by when the check first saw them), as
  # [youtube_id, title, state, reason] rows, in one query. The state is derived in SQL as Transcript#state does it: no
  # transcript row is waiting; a stored outcome is that outcome; an unfinished fetch is working while its lease is
  # current and waiting once it has run out. The reason is only ever set for a failed fetch. The transcript's lines are
  # never selected, so a long transcript is not read from the database. Call it on a scope such as user.videos.
  #
  # Each row ends with the summary's three values, from the same query: its state, text and reason. The state is nil
  # unless the transcript is done (there is nothing to summarise yet); otherwise it is derived as Summary#state does it,
  # with no summary row meaning waiting. The text is only set for a done summary and the reason only for a failed one.
  def self.with_states
    state = sanitize_sql_array([ <<~SQL.squish, Transcript.lease_cutoff ])
      CASE
        WHEN transcripts.id IS NULL THEN 'waiting'
        WHEN transcripts.outcome IS NOT NULL THEN transcripts.outcome
        WHEN transcripts.started_at >= ? THEN 'working'
        ELSE 'waiting'
      END
    SQL
    reason = "CASE WHEN transcripts.outcome = 'failed' THEN transcripts.reason END"
    summary_state = sanitize_sql_array([ <<~SQL.squish, Summary.lease_cutoff ])
      CASE
        WHEN transcripts.outcome IS DISTINCT FROM 'done' THEN NULL
        WHEN summaries.id IS NULL THEN 'waiting'
        WHEN summaries.outcome IS NOT NULL THEN summaries.outcome
        WHEN summaries.started_at >= ? THEN 'working'
        ELSE 'waiting'
      END
    SQL
    summary_text = "CASE WHEN summaries.outcome = 'done' THEN summaries.summary_text END"
    summary_reason = "CASE WHEN summaries.outcome = 'failed' THEN summaries.reason END"

    left_joins(:transcript, :summary)
      .order("videos.created_at DESC", "videos.id DESC")
      .pluck("videos.youtube_id", "videos.title", Arel.sql(state), Arel.sql(reason),
             Arel.sql(summary_state), Arel.sql(summary_text), Arel.sql(summary_reason))
  end

  # Requeues a finished video so its work runs again. A failed or no-captions transcript is deleted, and so is its
  # summary, which must not outlive it; the next run then fetches and summarises again. A done transcript is kept and
  # only a finished summary is deleted, so the next run summarises again. Returns :transcript, :summary, or nil when
  # there was nothing to requeue. The deletes are the state check, so no record is read first.
  def requeue!
    transaction do
      if Transcript.where(video_id: id, outcome: %w[failed no_captions]).delete_all.positive?
        Summary.where(video_id: id).delete_all
        next :transcript
      end

      if Transcript.exists?(video_id: id, outcome: "done") &&
         Summary.where(video_id: id).where.not(outcome: nil).delete_all.positive?
        next :summary
      end

      nil
    end
  end
end
