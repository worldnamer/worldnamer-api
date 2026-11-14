module Api
  module V1
    class YoutubeConnectionsController < ApplicationController
      # Warden checks the Authorization: Bearer token. On failure Auth::FailureApp answers 401 "unauthenticated".
      # No only: list, so an action added later is protected by default.
      before_action :authenticate_user!

      # GET /api/v1/youtube_connection. The status ("not_connected", "connected" or "lost") and the chosen playlist,
      # or null when none is chosen. The playlist title is private, so no cache may keep the answer.
      #
      # With a stored token this calls Google on every request (see GoogleOauthConnection#check), holding a Puma
      # thread for up to a few seconds. A stored token that cannot be decrypted (lost encryption keys) is not rescued:
      # it is a 500, and the user reconnects.
      def show
        connection = current_user.youtube_connection
        status = connection ? connection.check : "not_connected"

        response.cache_control.replace(no_store: true)
        render json: { youtube_connection: { status: status, playlist: playlist_json(connection) } }
      end

      private

      def playlist_json(connection)
        return nil unless connection&.playlist_id

        { id: connection.playlist_id, title: connection.playlist_title }
      end
    end
  end
end
