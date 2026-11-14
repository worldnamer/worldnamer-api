FactoryBot.define do
  factory :youtube_connection do
    user
    sequence(:refresh_token) { |n| "1//youtube-refresh-token-#{n}" }
    connected_at { Time.current }

    trait :lost do
      refresh_token { nil }
      lost_at { Time.current }
    end

    trait :with_playlist do
      sequence(:playlist_id) { |n| "PLchosen#{n.to_s.rjust(6, "0")}" }
      playlist_title { "Watch later, really" }
    end
  end
end
