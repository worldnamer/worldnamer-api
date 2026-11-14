# A YouTube sign-in in progress, from POST /youtube_connection/authorization until Google redirects back to the
# callback. A table of its own, so a Calendar sign-in's state can never complete a YouTube sign-in. How the state and
# the PKCE verifier are made, stored and used up is GoogleOauthPendingSignIn's.
class YoutubeOauthState < ApplicationRecord
  include GoogleOauthPendingSignIn

  belongs_to :user

  encrypts :code_verifier
end
