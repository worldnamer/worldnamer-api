FactoryBot.define do
  factory :video do
    user
    # Eleven characters, the shape of a YouTube id.
    sequence(:youtube_id) { |n| "vid#{n.to_s.rjust(8, "0")}" }
    sequence(:title) { |n| "Video #{n}" }
  end
end
