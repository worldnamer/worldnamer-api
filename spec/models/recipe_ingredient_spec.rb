require "rails_helper"

RSpec.describe RecipeIngredient, type: :model do
  let(:connection) { ActiveRecord::Base.connection }
  let(:columns) { connection.columns(:recipe_ingredients).index_by(&:name) }

  describe "table recipe_ingredients" do
    it "limits name to 100 and amount to 50 characters, with a blank amount default" do
      expect(columns["name"].limit).to eq(100)
      expect(columns["amount"].limit).to eq(50)
      expect(columns["amount"].default).to eq("")
      expect(columns["position"].null).to be(false)
    end

    it "has a unique index on recipe_id and position" do
      expect(connection.index_exists?(:recipe_ingredients, %i[recipe_id position], unique: true)).to be(true)
    end

    it "has a foreign key to recipes that cascades on delete" do
      foreign_key = connection.foreign_keys(:recipe_ingredients).find { |fk| fk.to_table == "recipes" }
      expect(foreign_key.on_delete).to eq(:cascade)
    end
  end

  it "is valid with a recipe and a name" do
    expect(build(:recipe_ingredient)).to be_valid
  end

  it "strips name and amount, and stores a nil amount as an empty string" do
    ingredient = create(:recipe_ingredient, name: "  flour ", amount: " 500 g ").reload
    expect(ingredient.name).to eq("flour")
    expect(ingredient.amount).to eq("500 g")

    expect(create(:recipe_ingredient, amount: nil).reload.amount).to eq("")
  end

  it "requires a name" do
    [ nil, "", "  " ].each do |name|
      expect(build(:recipe_ingredient, name: name)).not_to be_valid
    end
  end

  it "accepts 50 characters of name and refuses 51" do
    expect(build(:recipe_ingredient, name: "a" * 50)).to be_valid
    expect(build(:recipe_ingredient, name: "a" * 51)).not_to be_valid
  end

  it "accepts 49 characters of amount and refuses 50" do
    expect(build(:recipe_ingredient, amount: "a" * 49)).to be_valid
    expect(build(:recipe_ingredient, amount: "a" * 50)).not_to be_valid
  end

  it "keeps the longest amount and name joined by a space within a task's 100 characters" do
    ingredient = build(:recipe_ingredient, name: "n" * 50, amount: "a" * 49)

    expect(ingredient).to be_valid
    expect("#{ingredient.amount} #{ingredient.name}".length).to eq(100)
  end

  describe "position" do
    it "is the recipe's highest plus one, starting at zero, per recipe" do
      recipe = create(:recipe)
      first = create(:recipe_ingredient, recipe: recipe)
      second = create(:recipe_ingredient, recipe: recipe)
      elsewhere = create(:recipe_ingredient)

      expect([ first.position, second.position, elsewhere.position ]).to eq([ 0, 1, 0 ])
    end

    it "goes after the highest even when earlier ones were deleted" do
      recipe = create(:recipe)
      create(:recipe_ingredient, recipe: recipe, position: 4)

      expect(create(:recipe_ingredient, recipe: recipe).position).to eq(5)
    end

    it "keeps an explicit position and refuses a duplicate within a recipe" do
      recipe = create(:recipe)
      create(:recipe_ingredient, recipe: recipe, position: 2)

      expect { create(:recipe_ingredient, recipe: recipe, position: 2) }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  describe ".in_order" do
    it "orders by position, then id" do
      recipe = create(:recipe)
      last = create(:recipe_ingredient, recipe: recipe, position: 9)
      first = create(:recipe_ingredient, recipe: recipe, position: 1)

      expect(recipe.recipe_ingredients.in_order).to eq([ first, last ])
    end
  end
end
