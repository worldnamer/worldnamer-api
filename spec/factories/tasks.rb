FactoryBot.define do
  factory :task do
    task_list
    sequence(:text) { |n| "Task #{n}" }
  end
end
