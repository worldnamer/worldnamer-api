FactoryBot.define do
  factory :recipe do
    user
    sequence(:title) { |n| "Recipe #{n}" }
  end
end
