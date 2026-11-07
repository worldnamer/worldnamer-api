FactoryBot.define do
  factory :recipe_ingredient do
    recipe
    sequence(:name) { |n| "Ingredient #{n}" }
  end
end
