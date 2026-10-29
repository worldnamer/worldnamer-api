require "digest"

# One row per refresh token. The raw token (SecureRandom.urlsafe_base64(32)) goes to the browser in a cookie and is
# never stored, logged or put in a span: the table holds only its SHA256 hex digest. Plain SHA-256 is enough because
# the token has 256 bits of entropy (bcrypt is for guessable passwords). See ../../../specs/login-plan.md, section 2.
class RefreshToken < ApplicationRecord
  # A refresh pushes expires_at out to this far from now (the "sliding" part).
  LIFETIME = 60.days
  # A used token presented again within this long after its rotation is a lost response or a second tab, not theft.
  GRACE_WINDOW = 30.seconds

  belongs_to :user

  class << self
    def digest(raw_token)
      Digest::SHA256.hexdigest(raw_token.to_s)
    end

    # The row for a raw token from a cookie, or nil if the token is blank or unknown.
    def find_by_raw(raw_token)
      return nil if raw_token.blank?

      find_by(token_digest: digest(raw_token))
    end

    # Inserts a new active token and returns the raw value (the only moment it exists on the server side).
    def issue!(user:, family_id: SecureRandom.uuid)
      raw_token = SecureRandom.urlsafe_base64(32)
      create!(user: user, family_id: family_id, token_digest: digest(raw_token), expires_at: LIFETIME.from_now)
      raw_token
    end

    def revoke_family!(family_id)
      where(family_id: family_id).delete_all
    end

    # Rotation in ONE atomic statement: UPDATE refresh_tokens SET used_at = ... WHERE id = ? AND used_at IS NULL.
    # Of two requests presenting the same token, the database lets exactly one change the row. Returns true for the
    # winner. (used_at comes from Ruby's clock, not SQL now(), so one clock rules rotation and the grace check.)
    def mark_used!(id)
      where(id: id, used_at: nil).update_all(used_at: Time.current) == 1
    end
  end

  def expired?
    expires_at <= Time.current
  end
end
