module Api
  module V1
    module GoogleCalendarConnections
      class AuthorizationsController < ApplicationController
        include GoogleOauthCookie

        # Warden checks the Authorization: Bearer token. On failure Auth::FailureApp answers 401 "unauthenticated".
        # The bearer token lives in the web app's memory, which a cross-site form or link cannot send, so this is also
        # what stops another site from starting a sign-in for the user. No only: list.
        before_action :authenticate_user!

        # POST /api/v1/google_calendar_connection/authorization. Starts linking Google Calendar: replaces any pending
        # sign-in, sets the wn_google_oauth cookie, and returns Google's consent URL for the web app to navigate to.
        # Allowed while connected; a successful reconnect replaces the stored token.
        def create
          raw_state, oauth_state = GoogleOauthState.start!(current_user)
          url = GoogleCalendar::OauthClient.new.authorization_url(state: raw_state, code_challenge: oauth_state.code_challenge)

          set_google_oauth_cookie(raw_state)
          # The URL holds the state, so no cache or proxy may keep the response. Rails renders "Cache-Control: no-store".
          response.cache_control.replace(no_store: true)
          render json: { authorization_url: url }, status: :created
        end
      end
    end
  end
end
