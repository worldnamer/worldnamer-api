FactoryBot.define do
  factory :google_calendar_connection do
    user
    sequence(:refresh_token) { |n| "1//refresh-token-#{n}" }
    connected_at { Time.current }

    trait :lost do
      refresh_token { nil }
      lost_at { Time.current }
    end
  end
end
