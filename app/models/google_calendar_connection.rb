# A user's link to their Google account, for reading their calendar. The connection's state machine (connect, check,
# mint an access token, mark lost) is GoogleOauthConnection's.
class GoogleCalendarConnection < ApplicationRecord
  include GoogleOauthConnection

  belongs_to :user

  # Non-deterministic Active Record encryption: the same token encrypts differently each time, so the column cannot be
  # searched, and nothing needs to search it.
  encrypts :refresh_token
end
