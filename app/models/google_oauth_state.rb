require "digest"

# A Google sign-in in progress: one row per user, from POST /google_calendar_connection/authorization until Google
# redirects back to the callback (or ten minutes pass).
#
# The raw state (32 random bytes) goes to the browser twice, in a cookie and inside the consent URL, and Google sends
# it back on the callback. Only its SHA256 hex digest is stored: plain SHA-256 is enough for a value with 256 bits of
# entropy. The PKCE code verifier is stored encrypted and is sent to Google only when the code is exchanged; the
# consent URL carries just its hash, the code challenge.
class GoogleOauthState < ApplicationRecord
  LIFETIME = 10.minutes

  belongs_to :user

  encrypts :code_verifier

  class << self
    def digest(raw_state)
      Digest::SHA256.hexdigest(raw_state.to_s)
    end

    # Starts a sign-in for the user, replacing any pending one, and returns the raw state (the only moment it exists
    # on the server side) with the new row. One upsert on user_id, so two starts at once leave exactly one row.
    def start!(user)
      raw_state = SecureRandom.urlsafe_base64(32)
      # 32 random bytes give a 43-character verifier from the URL-safe alphabet PKCE allows.
      upsert(
        { user_id: user.id, state_digest: digest(raw_state), code_verifier: SecureRandom.urlsafe_base64(32),
          expires_at: LIFETIME.from_now },
        unique_by: :user_id
      )
      [ raw_state, find_by!(user_id: user.id) ]
    end

    # Uses up the sign-in for a raw state from the callback and returns its row, or nil if the state is blank,
    # unknown, already used or expired. The row is deleted in ONE statement, DELETE ... WHERE id = ?, and only the
    # request that deleted it gets the row back, so of two callbacks with the same state at most one succeeds.
    def claim(raw_state)
      return nil if raw_state.blank?

      row = find_by(state_digest: digest(raw_state))
      return nil unless row && where(id: row.id).delete_all == 1

      row.expired? ? nil : row
    end
  end

  # The PKCE S256 challenge: base64url of the verifier's SHA-256, without padding.
  def code_challenge
    Base64.urlsafe_encode64(Digest::SHA256.digest(code_verifier), padding: false)
  end

  def expired?
    expires_at <= Time.current
  end
end
