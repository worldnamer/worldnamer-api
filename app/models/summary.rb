# The result of summarising one video's transcript, one row per video. Only outcomes are stored. A row is created when a
# summary starts, with outcome null and started_at set, and that start time is a lease: while it is younger than LEASE
# the video is "working", and once it is older (the process died or never finished) the video is "waiting" again and the
# next run may claim it. A video with no row is "waiting" too. A finished row is "done", "nothing_to_summarise" or
# "failed".
class Summary < ApplicationRecord
  OUTCOMES = %w[done nothing_to_summarise failed].freeze
  STATES = (%w[waiting working] + OUTCOMES).freeze

  # How long a summary may hold a video before another run may take it over. The client's read timeout is 180 seconds.
  LEASE = 5.minutes

  belongs_to :video

  validates :outcome, inclusion: { in: OUTCOMES }, allow_nil: true
  validates :started_at, presence: true

  # Rows whose lease is over compare older than this.
  def self.lease_cutoff
    LEASE.ago
  end

  # Takes the right to summarise this video, in one statement each way, so two runs can never both hold it. No row yet:
  # inserts one, with its lease starting now. A row whose summary never finished and whose lease has run out (outcome
  # null, started_at older than the cutoff): starts a new lease on it. Anything else (a summary in progress, or a stored
  # outcome of any kind) is left alone. Returns true when the caller now holds the video and false when not.
  def self.claim(video_id)
    now = Time.current
    inserted = insert_all([ { video_id: video_id, started_at: now } ], unique_by: :video_id)
    return true if inserted.rows.any?

    where(video_id: video_id, outcome: nil).where(started_at: ...lease_cutoff)
      .update_all(started_at: now, reason: nil, summary_text: nil, model: nil, finished_at: nil, updated_at: now) == 1
  end

  # Stores a Summaries::Client::Result on the video's unfinished row. The text and model of a done result are the only
  # ones kept. A row that already has an outcome is never overwritten.
  def self.finish(video_id, result)
    now = Time.current
    done = result.outcome == "done"
    where(video_id: video_id, outcome: nil).update_all(
      outcome: result.outcome, reason: result.reason, summary_text: (done ? result.text : nil), model: (done ? result.model : nil),
      finished_at: now, updated_at: now
    )
  end

  def state
    return outcome if outcome
    started_at > self.class.lease_cutoff ? "working" : "waiting"
  end
end
