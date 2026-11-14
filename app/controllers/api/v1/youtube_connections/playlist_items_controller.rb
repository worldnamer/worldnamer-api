module Api
  module V1
    module YouTubeConnections
      # The videos in the caller's chosen playlist, and removing one of them from it.
      class PlaylistItemsController < ApplicationController
        # Warden checks the Authorization: Bearer token. On failure Auth::FailureApp answers 401 "unauthenticated".
        # No only: list, so an action added later is protected by default.
        before_action :authenticate_user!
        include YouTubeDataAccess

        # A YouTube playlist item id. Checked before anything is sent to Google.
        ITEM_ID = /\A[A-Za-z0-9_=-]{1,128}\z/

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
        rescue GoogleCalendar::OauthClient::Error, YouTube::DataClient::Error => e
          log_youtube_failure(e)
          render_youtube_unavailable
        end

        # DELETE /api/v1/youtube_connection/playlist/items/:id. Removes one item from the chosen playlist on YouTube;
        # the video itself is never touched. 204 on success.
        #
        # YouTube would remove an item from any playlist the user owns, so the item is first looked up and must
        # belong to the chosen playlist; otherwise the answer is 404 and no DELETE is sent. That is three calls to
        # Google (a token, the lookup, the delete), 52 quota units of the shared daily 10,000.
        def destroy
          item_id = params[:id]
          connection = current_user.youtube_connection
          return render_youtube_not_connected if connection.nil? || connection.lost_at
          return render_not_found unless connection.playlist_id && item_id.is_a?(String) && item_id.match?(ITEM_ID)

          client = youtube_data_client(connection)
          item = client.find_playlist_item(item_id)
          return render_not_found unless item && item[:playlist_id] == connection.playlist_id

          client.delete_playlist_item(item_id)
          head :no_content
        rescue GoogleCalendar::OauthClient::InvalidGrant
          # If the user reconnected while this request was running, mark_lost! leaves the new connection alone.
          connection.mark_lost! ? render_youtube_not_connected : render_youtube_unavailable
        rescue YouTube::DataClient::Error => e
          # The item or the playlist is gone, or no longer the user's to read: nothing to remove.
          return render_not_found if playlist_unavailable?(e)

          log_youtube_failure(e)
          render_youtube_unavailable
        rescue GoogleCalendar::OauthClient::Error => e
          log_youtube_failure(e)
          render_youtube_unavailable
        end

        private

        def render_not_found
          render_error "not_found", "Not found.", :not_found
        end

        # The videos, or nil when the playlist is gone or not readable. Other errors propagate.
        def fetch_videos(connection)
          youtube_data_client(connection).list_playlist_items(connection.playlist_id)
        rescue YouTube::DataClient::Error => e
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
