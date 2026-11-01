module Api
  module V1
    class GoogleCalendarConnectionsController < ApplicationController
      # Warden checks the Authorization: Bearer token. On failure Auth::FailureApp answers 401 "unauthenticated".
      # No only: list, so an action added later is protected by default.
      before_action :authenticate_user!

      # GET /api/v1/google_calendar_connection. "not_connected", "connected" or "lost".
      #
      # With a stored token this calls Google on every request (see GoogleCalendarConnection#check), holding a Puma
      # thread for up to a few seconds. The web asks on page load only, not on tab focus. A stored token that cannot be
      # decrypted (lost encryption keys) is not rescued: it is a 500, and the user reconnects.
      def show
        connection = current_user.google_calendar_connection
        status = connection ? connection.check : "not_connected"
        render json: { google_calendar_connection: { status: status } }
      end
    end
  end
end
