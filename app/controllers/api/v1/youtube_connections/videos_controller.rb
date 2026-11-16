module Api
  module V1
    module YouTubeConnections
      # The caller's recorded videos, each with the state of its transcript and of its summary. It reads only this app's
      # database and never calls Google or the transcript service.
      class VideosController < ApplicationController
        # Warden checks the Authorization: Bearer token. On failure Auth::FailureApp answers 401 "unauthenticated".
        # No only: list, so an action added later is protected by default.
        before_action :authenticate_user!
        # Video titles are private: no browser or proxy cache may keep them.
        before_action { response.cache_control.replace(no_store: true) }

        # GET /api/v1/youtube_connection/videos. Every video recorded for the caller (current_user.videos, so never
        # another user's), newest first: { videos: [{ youtube_id, title, state, reason }] }. state is waiting, working,
        # done, no_captions or failed; reason is null unless the state is failed. summary is null unless the transcript
        # is done, otherwise { state } with state waiting, working, done, nothing_to_summarise or failed, plus text only
        # when done and reason only when failed. The summary text is model output: it is sent as stored and is only ever
        # shown as text. The transcript text and the model's name are never included. The list is not capped.
        def index
          videos = current_user.videos.with_states.map do |youtube_id, title, state, reason, *summary|
            { youtube_id: youtube_id, title: title, state: state, reason: reason, summary: summary_json(*summary) }
          end
          render json: { videos: videos }
        end

        private

        def summary_json(state, text, reason)
          return nil if state.nil?

          { state: state }.merge(text ? { text: text } : {}).merge(reason ? { reason: reason } : {})
        end
      end
    end
  end
end
