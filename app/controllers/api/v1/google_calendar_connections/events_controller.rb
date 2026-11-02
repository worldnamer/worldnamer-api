module Api
  module V1
    module GoogleCalendarConnections
      # The Today card's events, with the connection status, so the card needs this one request on load.
      class EventsController < ApplicationController
        # Warden checks the Authorization: Bearer token. On failure Auth::FailureApp answers 401 "unauthenticated".
        # No only: list, so an action added later is protected by default.
        before_action :authenticate_user!
        # Event titles are private: no browser or proxy cache may keep them.
        before_action :no_store

        # How long a user's events are answered from the cache before Google is asked again.
        EVENTS_TTL = 60.seconds

        # GET /api/v1/google_calendar_connection/events. Any parameters are ignored.
        #
        # With no connection, or a lost one, the status comes with events: null and Google is not called. A connected
        # user's events are answered from the cache for a minute, so a revocation in Google can take that long to show
        # as lost. On a miss this makes two blocking calls to Google on the request's thread (a token, then Events:
        # list), normally well under a second but up to about 11 seconds if both time out. Every failure is a 502 that
        # changes nothing, except Google rejecting the stored token, which marks the connection lost.
        #
        # A stored token that cannot be decrypted (lost encryption keys) is not rescued: it is a 500, and the user
        # reconnects.
        def index
          connection = current_user.google_calendar_connection
          return render_status("not_connected") unless connection
          return render_status("lost") if connection.lost_at

          render json: { google_calendar_connection: { status: "connected" }, events: cached_events(connection) }
        rescue GoogleCalendar::OauthClient::InvalidGrant
          # If the user reconnected while this request was running, mark_lost! leaves the new connection alone, and
          # this request, made with the old token, has nothing to show.
          connection.mark_lost! ? render_status("lost") : render_google_unavailable
        rescue GoogleCalendar::OauthClient::Error, GoogleCalendar::EventsClient::Error => e
          # The class and HTTP status only: the message could name Google's reason, and nothing else is needed here.
          status = e.respond_to?(:status) ? e.status : nil
          Rails.logger.warn("Google Calendar events unavailable: #{e.class.name} status=#{status || "none"}")
          render_google_unavailable
        end

        private

        # Only the normalized events and fetched_at are cached: never a token, Google's own answer, a failure or "lost"
        # (a block that raises writes nothing). The key starts with the user's id, so one user can never be answered
        # from another's entry; connected_at drops the entry on a reconnect, which may be to another Google account;
        # the UTC date matches the window the events were fetched for.
        def cached_events(connection)
          utc_date = Time.now.utc.to_date
          key = [ "google_calendar_events", current_user.id, connection.connected_at.to_i, utc_date.iso8601 ]
          Rails.configuration.x.google_calendar.events_cache.fetch(key, expires_in: EVENTS_TTL) do
            fetch_events(connection, utc_date)
          end
        end

        # The access token lives in a local variable for this request only.
        def fetch_events(connection, utc_date)
          access_token = connection.mint_access_token
          items = GoogleCalendar::EventsClient.new.list(access_token: access_token, utc_date: utc_date)
          { fetched_at: Time.now.utc.iso8601, items: GoogleCalendar::EventNormalizer.call(items) }
        end

        def render_status(status)
          render json: { google_calendar_connection: { status: status }, events: nil }
        end

        def render_google_unavailable
          render_error "google_unavailable", "Couldn't reach Google Calendar.", :bad_gateway
        end

        def no_store
          # Rails 8 renders this as "Cache-Control: no-store".
          response.cache_control.replace(no_store: true)
        end
      end
    end
  end
end
