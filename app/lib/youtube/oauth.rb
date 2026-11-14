module Youtube
  # The YouTube connection's settings for Google's OAuth flow: the same Google client as the Calendar, with its own
  # scope and callback, so the user approves YouTube on a consent screen of its own.
  module Oauth
    # "Manage your YouTube account". The narrowest scope that allows removing an item from a playlist; it is broader
    # than that, so the site only ever calls the playlist endpoints (Youtube::DataClient).
    SCOPE = "https://www.googleapis.com/auth/youtube".freeze

    def self.client
      GoogleCalendar::OauthClient.new(
        scope: SCOPE,
        redirect_uri: Rails.configuration.x.google_oauth.fetch(:youtube_redirect_uri)
      )
    end
  end
end
