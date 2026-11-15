# The recurring check of every user's chosen YouTube playlist. It takes no arguments: everything it works on comes from
# the database, so nothing a caller passes in can steer it.
#
# For each live connection with a chosen playlist it lists the whole playlist and records each video it has not seen,
# with the title it has now. Recording is one INSERT ... ON CONFLICT DO NOTHING per user, so a second run inserts
# nothing and the first title seen is kept. A video that leaves the playlist keeps its row.
class YouTubePlaylistCheckJob < ApplicationJob
  # One run at a time. The semaphore lasts at most 30 minutes, which covers a run that is killed without releasing it.
  limits_concurrency to: 1, key: "youtube_playlist_check", duration: 30.minutes

  def perform
    YouTubeConnection.where.not(playlist_id: nil).where(lost_at: nil).find_each do |connection|
      record_new_videos(connection)
    end
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
end
