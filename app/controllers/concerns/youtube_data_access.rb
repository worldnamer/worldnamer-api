# What the YouTube playlist controllers share: no caching of private titles, a Data API client built on an access
# token minted for this request only, and the one way a failure from Google is logged and answered.
#
# Every call here blocks the request's thread on Google: a token call, then one or two Data API calls.
module YouTubeDataAccess
  extend ActiveSupport::Concern

  included do
    # Playlist and video titles are private: no browser or proxy cache may keep them.
    before_action :youtube_no_store
  end

  private

  # The access token lives in this client for this request only. Raises GoogleCalendar::OauthClient::InvalidGrant when
  # Google no longer accepts the stored token; the caller decides what a lost connection means for its answer.
  def youtube_data_client(connection)
    YouTube::DataClient.new(access_token: connection.mint_access_token)
  end

  # The class and HTTP status only: the message could name Google's reason, and titles are never logged.
  def log_youtube_failure(error)
    status = error.respond_to?(:status) ? error.status : nil
    Rails.logger.warn("YouTube unavailable: #{error.class.name} status=#{status || "none"}")
  end

  def render_youtube_unavailable
    render_error "youtube_unavailable", "Couldn't reach YouTube.", :bad_gateway
  end

  def render_youtube_not_connected
    render_error "youtube_not_connected", "YouTube is not connected.", :conflict
  end

  def youtube_no_store
    response.cache_control.replace(no_store: true)
  end
end
