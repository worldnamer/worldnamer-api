FactoryBot.define do
  factory :habit_completion do
    habit
    # A different day each time, so two completions of one habit never collide on the unique index.
    sequence(:date) { |n| Date.new(2026, 1, 1) + n }
  end
end
