FactoryBot.define do
  factory :task_list do
    user
    sequence(:name) { |n| "List #{n}" }
  end
end
