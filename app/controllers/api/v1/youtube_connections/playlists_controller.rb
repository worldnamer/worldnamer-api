module Api
  module V1
    module YouTubeConnections
      # The caller's own YouTube playlists, for choosing one.
      class PlaylistsController < ApplicationController
        # Warden checks the Authorization: Bearer token. On failure Auth::FailureApp answers 401 "unauthenticated".
        # No only: list, so an action added later is protected by default.
        before_action :authenticate_user!
        include YouTubeDataAccess

        # GET /api/v1/youtube_connection/playlists. The first 50 playlists the user owns (mine=true), with the
        # connection status. With no connection, or a lost one, playlists is null and Google is not called. Google
        # rejecting the stored token marks the connection lost; any other failure is a 502 that changes nothing.
        def index
          connection = current_user.youtube_connection
          return render_status("not_connected") unless connection
          return render_status("lost") if connection.lost_at

          playlists = youtube_data_client(connection).list_playlists
          render json: { youtube_connection: { status: "connected" }, playlists: playlists }
        rescue GoogleCalendar::OauthClient::InvalidGrant
          # If the user reconnected while this request was running, mark_lost! leaves the new connection alone, and
          # this request, made with the old token, has nothing to show.
          connection.mark_lost! ? render_status("lost") : render_youtube_unavailable
        rescue GoogleCalendar::OauthClient::Error, YouTube::DataClient::Error => e
          log_youtube_failure(e)
          render_youtube_unavailable
        end

        private

        def render_status(status)
          render json: { youtube_connection: { status: status }, playlists: nil }
        end
      end
    end
  end
end
