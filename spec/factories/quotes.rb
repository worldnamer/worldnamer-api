FactoryBot.define do
  factory :quote do
    user
    sequence(:text) { |n| "Quote #{n}" }
    author { "" }
  end
end
