# The result of fetching one video's transcript, one row per video. Only outcomes are stored. A row is created when a
# fetch starts, with outcome null and started_at set, and that start time is a lease: while it is younger than LEASE the
# video is "working", and once it is older (the process died or never finished) the video is "waiting" again and the
# next run may claim it. A video with no row is "waiting" too. A finished row is "done", "no_captions" or "failed".
class Transcript < ApplicationRecord
  OUTCOMES = %w[done no_captions failed].freeze
  STATES = (%w[waiting working] + OUTCOMES).freeze

  # How long a fetch may hold a video before another run may take it over. The client's read timeout is 110 seconds.
  LEASE = 5.minutes

  belongs_to :video

  validates :outcome, inclusion: { in: OUTCOMES }, allow_nil: true
  validates :started_at, presence: true
  validate :lines_hold_only_text_and_start

  # Rows whose lease is over compare older than this.
  def self.lease_cutoff
    LEASE.ago
  end

  # Takes the right to fetch this video's transcript, in one statement each way, so two runs can never both hold it.
  # No row yet: inserts one, with its lease starting now. A row whose fetch never finished and whose lease has run out
  # (outcome null, started_at older than the cutoff): starts a new lease on it. Anything else (a fetch in progress, or
  # a stored outcome of any kind) is left alone. Returns true when the caller now holds the video and false when not.
  def self.claim(video_id)
    now = Time.current
    inserted = insert_all([ { video_id: video_id, started_at: now } ], unique_by: :video_id)
    return true if inserted.rows.any?

    where(video_id: video_id, outcome: nil).where(started_at: ...lease_cutoff)
      .update_all(started_at: now, reason: nil, lines: nil, finished_at: nil, updated_at: now) == 1
  end

  # Stores a Transcripts::Client::Result on the video's unfinished row. Only the lines of a done result are kept. A
  # row that already has an outcome is never overwritten.
  def self.finish(video_id, result)
    now = Time.current
    where(video_id: video_id, outcome: nil).update_all(
      outcome: result.outcome, reason: result.reason, lines: (result.outcome == "done" ? result.lines : nil),
      finished_at: now, updated_at: now
    )
  end

  def state
    return outcome if outcome
    started_at > self.class.lease_cutoff ? "working" : "waiting"
  end

  private

  # The transcript text is third-party content, so only the two fields the app uses are ever kept.
  def lines_hold_only_text_and_start
    return if lines.nil?

    valid = lines.is_a?(Array) && lines.all? do |line|
      line.is_a?(Hash) && line.keys.sort == %w[start text] && line["text"].is_a?(String) && line["start"].is_a?(Numeric)
    end
    errors.add(:lines, "must be a list of text and start") unless valid
  end
end
