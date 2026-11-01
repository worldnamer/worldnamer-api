# The Google OAuth client this app uses to link a user's Google Calendar (GoogleCalendar::OauthClient).
#
# Production fails at boot if any value is missing (ENV.fetch), including in the db:migrate pre-deploy job.
# Development and test use the env var if set (locally from .env.development.local), otherwise placeholders that
# Google would reject, so local work boots with no setup. GOOGLE_CLIENT_SECRET is a secret; the other two are not.
Rails.application.config.x.google_oauth =
  if Rails.env.production?
    {
      client_id: ENV.fetch("GOOGLE_CLIENT_ID"),
      client_secret: ENV.fetch("GOOGLE_CLIENT_SECRET"),
      redirect_uri: ENV.fetch("GOOGLE_REDIRECT_URI")
    }
  else
    {
      client_id: ENV.fetch("GOOGLE_CLIENT_ID", "placeholder-client-id.apps.googleusercontent.com"),
      client_secret: ENV.fetch("GOOGLE_CLIENT_SECRET", "placeholder-client-secret"),
      redirect_uri: ENV.fetch("GOOGLE_REDIRECT_URI", "http://localhost:3000/api/v1/google_calendar_connection/callback")
    }
  end.freeze
