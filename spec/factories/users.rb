FactoryBot.define do
  factory :user do
    sequence(:username) { |n| "user#{n}" }
    password { "correct horse battery staple" }
  end
end
