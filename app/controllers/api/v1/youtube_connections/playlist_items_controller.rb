module Api
  module V1
    module YoutubeConnections
      # The videos in the caller's chosen playlist.
      class PlaylistItemsController < ApplicationController
        # Warden checks the Authorization: Bearer token. On failure Auth::FailureApp answers 401 "unauthenticated".
        # No only: list, so an action added later is protected by default.
        before_action :authenticate_user!
        include YoutubeDataAccess

        # GET /api/v1/youtube_connection/playlist/items. The first 10 videos of the chosen playlist in YouTube's order,
        # with the playlist's total count, the connection status and the chosen playlist.
        #
        # With no connection, a lost one, or no playlist chosen, playlist and videos are null as they apply and Google
        # is not called. A playlist YouTube no longer has, or no longer lets this user read, answers available: false
        # with videos null; the choice is kept, and the user chooses again. A rejected token marks the connection
        # lost; any other failure is a 502 that changes nothing.
        def index
          connection = current_user.youtube_connection
          return render_answer("not_connected") unless connection
          return render_answer("lost") if connection.lost_at
          return render_answer("connected") unless connection.playlist_id

          videos = fetch_videos(connection)
          render_answer("connected", playlist: playlist_json(connection, available: !videos.nil?), videos: videos)
        rescue GoogleCalendar::OauthClient::InvalidGrant
          # If the user reconnected while this request was running, mark_lost! leaves the new connection alone, and
          # this request, made with the old token, has nothing to show.
          connection.mark_lost! ? render_answer("lost") : render_youtube_unavailable
        rescue GoogleCalendar::OauthClient::Error, Youtube::DataClient::Error => e
          log_youtube_failure(e)
          render_youtube_unavailable
        end

        private

        # The videos, or nil when the playlist is gone or not readable. Other errors propagate.
        def fetch_videos(connection)
          youtube_data_client(connection).list_playlist_items(connection.playlist_id)
        rescue Youtube::DataClient::Error => e
          raise unless playlist_unavailable?(e)

          nil
        end

        # 404 means the playlist is gone; 403 playlistItemsNotAccessible means this user may no longer read it. Other
        # 403s (quota, permissions) say nothing about the playlist.
        def playlist_unavailable?(error)
          error.status == 404 || (error.status == 403 && error.reason == "playlistItemsNotAccessible")
        end

        def playlist_json(connection, available:)
          { id: connection.playlist_id, title: connection.playlist_title, available: available }
        end

        def render_answer(status, playlist: nil, videos: nil)
          render json: { youtube_connection: { status: status }, playlist: playlist, videos: videos }
        end
      end
    end
  end
end
