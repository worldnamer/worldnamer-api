module Api
  module V1
    module YouTubeConnections
      # The caller's chosen playlist. Singular: each user has at most one.
      class PlaylistController < ApplicationController
        # Warden checks the Authorization: Bearer token. On failure Auth::FailureApp answers 401 "unauthenticated".
        # No only: list, so an action added later is protected by default.
        before_action :authenticate_user!
        include YouTubeDataAccess

        # The body must hold { playlist: { id } } itself. Rails would otherwise wrap a bare { id } under "playlist",
        # named after this controller, and accept it.
        wrap_parameters false

        # A YouTube playlist id. Checked before anything is sent to Google.
        PLAYLIST_ID = /\A[A-Za-z0-9_-]{2,64}\z/

        # PUT /api/v1/youtube_connection/playlist with { playlist: { id } }. Chooses one of the caller's own playlists,
        # replacing any earlier choice, and answers like GET /youtube_connection.
        #
        # The id must be among the first 50 playlists the user owns on YouTube (the same list the picker shows), so a
        # playlist of someone else's can never be chosen. The title is taken from YouTube's answer, never from the
        # request, and kept as a snapshot. Every failure leaves the earlier choice as it was.
        def update
          id = params.expect(playlist: [ :id ])[:id]
          connection = current_user.youtube_connection
          return render_youtube_not_connected if connection.nil? || connection.lost_at
          return render_invalid_playlist unless id.is_a?(String) && id.match?(PLAYLIST_ID)

          playlist = youtube_data_client(connection).list_playlists.find { |p| p[:id] == id }
          return render_invalid_playlist unless playlist

          connection.update!(playlist_id: playlist[:id], playlist_title: playlist[:title])
          render json: { youtube_connection: { status: "connected", playlist: playlist } }
        rescue GoogleCalendar::OauthClient::InvalidGrant
          # If the user reconnected while this request was running, mark_lost! leaves the new connection alone.
          connection.mark_lost! ? render_youtube_not_connected : render_youtube_unavailable
        rescue GoogleCalendar::OauthClient::Error, YouTube::DataClient::Error => e
          log_youtube_failure(e)
          render_youtube_unavailable
        end

        private

        def render_invalid_playlist
          render_error "invalid_playlist", "That is not one of your playlists.", :unprocessable_content
        end
      end
    end
  end
end
