# A user's link to their YouTube account, separate from the Calendar's: its own grant, token and lost state. The
# connection's state machine (connect, check, mint an access token, mark lost) is GoogleOauthConnection's, and its
# connect! writes only the token and time columns, so reconnecting keeps the chosen playlist.
#
# playlist_id and playlist_title are the user's chosen playlist; the title is a snapshot from when it was chosen.
class YoutubeConnection < ApplicationRecord
  include GoogleOauthConnection

  belongs_to :user

  # Non-deterministic Active Record encryption: the same token encrypts differently each time, so the column cannot be
  # searched, and nothing needs to search it.
  encrypts :refresh_token
end
