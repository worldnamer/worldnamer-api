# A Google Calendar sign-in in progress, from POST /google_calendar_connection/authorization until Google redirects
# back to the callback. How the state and the PKCE verifier are made, stored and used up is GoogleOauthPendingSignIn's.
class GoogleOauthState < ApplicationRecord
  include GoogleOauthPendingSignIn

  belongs_to :user

  encrypts :code_verifier
end
