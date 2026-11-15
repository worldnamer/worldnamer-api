# The recurring check of every user's chosen YouTube playlist. It takes no arguments: everything it works on comes from
# the database, so nothing a caller passes in can steer it.
#
# For each live connection with a chosen playlist it lists the whole playlist and records each video it has not seen,
# with the title it has now. Recording is one INSERT ... ON CONFLICT DO NOTHING per user, so a second run inserts
# nothing and the first title seen is kept. A video that leaves the playlist keeps its row.
#
# It then fetches transcripts for the videos still waiting, the newest ten at most per run and strictly one at a time
# (the transcript service answers a second caller with "busy"). The listing and the fetching are separate phases: a
# failed listing does not stop the fetching.
class YouTubePlaylistCheckJob < ApplicationJob
  # One run at a time. The semaphore lasts at most 30 minutes, which covers a run that is killed without releasing it.
  limits_concurrency to: 1, key: "youtube_playlist_check", duration: 30.minutes

  # The most transcripts fetched in one run. Each fetch can take up to two minutes and spends proxy bandwidth.
  FETCHES_PER_RUN = 10

  def perform
    YouTubeConnection.where.not(playlist_id: nil).where(lost_at: nil).find_each do |connection|
      record_new_videos(connection)
    end
    fetch_waiting_transcripts
  end

  private

  # A rejected token marks the connection lost and skips this user. Any other Google failure is logged by class and
  # status only (a message could quote a body) and skips this user's listing for this run.
  def record_new_videos(connection)
    access_token = connection.mint_access_token
    listed = YouTube::DataClient.new(access_token: access_token).list_all_playlist_items(connection.playlist_id)
    rows = listed.map { |video| { user_id: connection.user_id, youtube_id: video[:video_id], title: video[:title] } }
    Video.insert_all(rows, unique_by: %i[user_id youtube_id]) if rows.any?
  rescue GoogleCalendar::OauthClient::InvalidGrant
    # If the user reconnected while this ran, mark_lost! leaves the new connection alone.
    connection.mark_lost!
  rescue GoogleCalendar::OauthClient::Error, YouTube::DataClient::Error => e
    status = e.respond_to?(:status) ? e.status : nil
    Rails.logger.warn("YouTube playlist check: #{e.class.name} status=#{status || "none"}")
  end

  # Waiting is no transcript row, or a row with no outcome whose lease has run out. Only users with a live connection
  # count, so a lost or disconnected account's videos wait. Newest first, by when the check first saw them. Only the ids
  # needed are read.
  def waiting_videos
    Video.where(user_id: YouTubeConnection.where(lost_at: nil).select(:user_id))
      .where("NOT EXISTS (SELECT 1 FROM transcripts WHERE transcripts.video_id = videos.id " \
             "AND (transcripts.outcome IS NOT NULL OR transcripts.started_at >= ?))", Transcript.lease_cutoff)
      .order(created_at: :desc, id: :desc).limit(FETCHES_PER_RUN).pluck(:id, :youtube_id)
  end

  # The service's address and token are read when the job runs, never at boot, so a missing value skips the fetching
  # with a log line instead of failing a deploy.
  def fetch_waiting_transcripts
    url = ENV["TRANSCRIPTS_URL"]
    token = ENV["TRANSCRIPTS_TOKEN"]
    if url.blank? || token.blank?
      Rails.logger.warn("YouTube playlist check: transcript service is not configured, skipping fetches")
      return
    end

    client = Transcripts::Client.new(base_url: url, token: token)
    waiting_videos.each { |id, youtube_id| fetch_transcript(client, id, youtube_id) }
  end

  # Claims the video first (so a second run cannot take it), then makes the slow call holding no transaction and no
  # lock, then stores the outcome. One video's trouble never stops the others; only the exception's class is logged,
  # because its message could quote a response. A claim that is never finished runs out its lease and the video waits
  # again.
  def fetch_transcript(client, video_id, youtube_id)
    return unless Transcript.claim(video_id)

    Transcript.finish(video_id, client.fetch(youtube_id))
  rescue StandardError => e
    Rails.logger.warn("YouTube playlist check: transcript fetch failed (#{e.class.name})")
  end
end
