FactoryBot.define do
  factory :google_oauth_state do
    user
    transient do
      # The raw state the row stands for. Only its digest is stored.
      state { SecureRandom.urlsafe_base64(32) }
    end
    state_digest { GoogleOauthState.digest(state) }
    code_verifier { SecureRandom.urlsafe_base64(32) }
    expires_at { GoogleOauthState::LIFETIME.from_now }
  end
end
