# Summarises the transcripts the playlist check has fetched. The check job queues it at the end of every run. It takes
# no arguments: everything it works on comes from the database, so nothing a caller passes in can steer it.
#
# It has a queue and a limit of its own, so a slow summary never holds up the listing and fetching of the check job.
# A run starts only when none is running (a run queued meanwhile is discarded, not held: the next check queues another),
# and the semaphore lasts at most 40 minutes, which covers a run that is killed without releasing it. Ten summaries at
# the client's three-minute limit are thirty minutes at worst.
#
# It takes the newest ten videos that have a done transcript and no summary that is finished or in progress, one at a
# time (the summary service answers a second caller with "busy"). A video that ends done, nothing to summarise or
# failed is never summarised again by the schedule.
class YouTubeSummariseJob < ApplicationJob
  limits_concurrency to: 1, key: "youtube_summarise", duration: 40.minutes, on_conflict: :discard

  # The most summaries made in one run. Each is a paid call that can take up to three minutes.
  SUMMARIES_PER_RUN = 10

  def perform
    # The service's address and token are read when the job runs, never at boot, so a missing value skips the run with
    # a log line instead of failing a deploy. They are the same as the transcript client's: one private service.
    url = ENV["TRANSCRIPTS_URL"]
    token = ENV["TRANSCRIPTS_TOKEN"]
    if url.blank? || token.blank?
      Rails.logger.warn("YouTube summarise: summary service is not configured, skipping summaries")
      return
    end

    client = Summaries::Client.new(base_url: url, token: token)
    waiting_video_ids.each { |video_id| summarise(client, video_id) }
  end

  private

  # Done transcript, and no summary row that has an outcome or whose lease is current. Only users with a live
  # connection count, so a lost or disconnected account's videos wait. Newest first, by when the check first saw them.
  # Only the ids are read: a transcript's lines are loaded one video at a time, when its turn comes.
  def waiting_video_ids
    Video.where(user_id: YouTubeConnection.where(lost_at: nil).select(:user_id))
      .where("EXISTS (SELECT 1 FROM transcripts WHERE transcripts.video_id = videos.id AND transcripts.outcome = 'done')")
      .where("NOT EXISTS (SELECT 1 FROM summaries WHERE summaries.video_id = videos.id " \
             "AND (summaries.outcome IS NOT NULL OR summaries.started_at >= ?))", Summary.lease_cutoff)
      .order(created_at: :desc, id: :desc).limit(SUMMARIES_PER_RUN).pluck(:id)
  end

  # Claims the video first (so a second run cannot take it), then makes the slow call holding no transaction and no
  # lock, then stores the outcome. One video's trouble never stops the others; only the exception's class is logged,
  # because its message could quote the text or a response. A claim that is never finished runs out its lease and the
  # video waits again.
  def summarise(client, video_id)
    return unless Summary.claim(video_id)

    Summary.finish(video_id, summary_for(client, video_id))
  rescue StandardError => e
    Rails.logger.warn("YouTube summarise: summary failed (#{e.class.name})")
  end

  # A text with too few words is nothing to summarise: no call is made and no span is left.
  def summary_for(client, video_id)
    lines = Transcript.where(video_id: video_id, outcome: "done").pick(:lines)
    text = Summaries::TranscriptText.clean(lines || [])
    return client.summarise(text) if Summaries::TranscriptText.enough_words?(text)

    Summaries::Client::Result.new(outcome: "nothing_to_summarise", reason: nil, text: nil, model: nil, tokens_in: nil, tokens_out: nil)
  end
end
