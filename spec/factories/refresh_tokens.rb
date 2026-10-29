FactoryBot.define do
  # The table stores only the SHA256 hex digest of the token. The raw token is a
  # transient attribute, so a spec can read it back: create(:refresh_token).token
  factory :refresh_token do
    transient do
      token { SecureRandom.urlsafe_base64(32) }
    end

    user
    family_id { SecureRandom.uuid }
    token_digest { Digest::SHA256.hexdigest(token) }
    expires_at { 60.days.from_now }
    used_at { nil }

    # Lets create(:refresh_token).token work: FactoryBot builds the object, then we expose the raw value.
    after(:build) do |record, evaluator|
      record.define_singleton_method(:token) { evaluator.token }
    end

    trait :used do
      used_at { 1.minute.ago }
    end

    trait :expired do
      expires_at { 1.day.ago }
    end
  end
end
