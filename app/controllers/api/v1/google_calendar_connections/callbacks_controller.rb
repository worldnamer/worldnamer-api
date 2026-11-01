module Api
  module V1
    module GoogleCalendarConnections
      # Where Google sends the browser back after the consent screen. It is a top-level navigation from Google, so there
      # is no bearer token: the user comes from the pending sign-in that the state belongs to, and the wn_google_oauth
      # cookie proves this browser started it. This is the only unauthenticated action of the feature, which is why it
      # has a controller of its own.
      #
      # The query string carries Google's one-time code and the state. They are kept out of the Rails log by
      # filter_parameter_logging, and out of traces because this path is an untraced endpoint of the Rack
      # instrumentation (config/initializers/opentelemetry.rb).
      class CallbacksController < ApplicationController
        include GoogleOauthCookie

        # The only values the web app is ever told. It reads the real state from GET /google_calendar_connection.
        CONNECTED = "connected".freeze
        CANCELLED = "cancelled".freeze
        FAILED = "failed".freeze

        # GET /api/v1/google_calendar_connection/callback?code=...&state=... (or ?error=...&state=...).
        # Always 303 to the web app's home with ?google_calendar=connected|cancelled|failed, and the cookie cleared.
        def show
          outcome = complete_sign_in

          clear_google_oauth_cookie
          response.cache_control.replace(no_store: true)
          # The page this lands on must not send the callback URL, with its code and state, as a Referer.
          response.set_header("Referrer-Policy", "no-referrer")
          # The target is built only from configuration and the fixed outcomes above, never from the request, so
          # allow_other_host cannot turn this into an open redirect.
          redirect_to "#{Rails.configuration.x.allowed_origins.first}/?google_calendar=#{outcome}",
            allow_other_host: true, status: :see_other
        end

        private

        # Every failure path stores nothing. Google is called only once the state has been matched and used up.
        def complete_sign_in
          oauth_state = claim_state
          return FAILED unless oauth_state

          # The user denied access on the consent screen, or Google reported another problem.
          if params[:error].present?
            return params[:error] == "access_denied" ? CANCELLED : FAILED
          end

          code = params[:code]
          return FAILED unless code.is_a?(String) && code.present?

          tokens = GoogleCalendar::OauthClient.new.exchange_code(code: code, code_verifier: oauth_state.code_verifier)
          # Without a refresh token the calendar cannot be read later, and without the scope it cannot be read at all
          # (the user may untick it on the consent screen).
          return FAILED unless tokens.refresh_token && tokens.scopes.include?(GoogleCalendar::OauthClient::SCOPE)

          GoogleCalendarConnection.connect!(user_id: oauth_state.user_id, refresh_token: tokens.refresh_token)
          CONNECTED
        rescue GoogleCalendar::OauthClient::Error
          FAILED
        end

        # The state parameter must equal this browser's cookie (compared in constant time) and then claim a pending
        # sign-in, which deletes it. A mismatch claims nothing, so it cannot use up another browser's sign-in.
        def claim_state
          state = params[:state]
          cookie = google_oauth_cookie
          return nil unless state.is_a?(String) && cookie.is_a?(String) && state.present?
          return nil unless ActiveSupport::SecurityUtils.secure_compare(state, cookie)

          GoogleOauthState.claim(state)
        end
      end
    end
  end
end
