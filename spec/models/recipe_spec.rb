require "rails_helper"

RSpec.describe Recipe, type: :model do
  let(:connection) { ActiveRecord::Base.connection }

  it "has a foreign key to users that cascades on delete" do
    foreign_key = connection.foreign_keys(:recipes).find { |fk| fk.to_table == "users" }
    expect(foreign_key.on_delete).to eq(:cascade)
  end

  it "is valid with a user and a title" do
    expect(build(:recipe)).to be_valid
  end

  it "strips the title and both instruction fields, and stores missing instructions as empty strings" do
    recipe = create(:recipe, title: "  Bread \n", prep_instructions: " Mix. ", cook_instructions: nil).reload

    expect(recipe.title).to eq("Bread")
    expect(recipe.prep_instructions).to eq("Mix.")
    expect(recipe.cook_instructions).to eq("")
  end

  it "requires a title and refuses a blank one" do
    [ nil, "", "   " ].each do |title|
      recipe = build(:recipe, title: title)
      expect(recipe).not_to be_valid
      expect(recipe.errors[:title]).to be_present
    end
  end

  it "accepts 100 characters and refuses 101" do
    expect(build(:recipe, title: "a" * 100)).to be_valid

    recipe = build(:recipe, title: "a" * 101)
    expect(recipe).not_to be_valid
    expect(recipe.errors.full_messages).to eq([ "Title is too long (maximum is 100 characters)" ])
  end

  it "accepts nil or a positive whole number of minutes, and refuses zero, negatives and fractions" do
    expect(build(:recipe, prep_minutes: nil, cook_minutes: nil)).to be_valid
    expect(build(:recipe, prep_minutes: 1, cook_minutes: 90)).to be_valid

    [ 0, -5, 1.5 ].each do |minutes|
      expect(build(:recipe, prep_minutes: minutes)).not_to be_valid
      expect(build(:recipe, cook_minutes: minutes)).not_to be_valid
    end
  end

  describe ".alphabetical" do
    it "orders case-insensitively and breaks ties by id" do
      bread = create(:recipe, title: "bread")
      apple = create(:recipe, title: "Apple pie")
      cake = create(:recipe, title: "Cake")
      cake_again = create(:recipe, title: "cake")

      expect(Recipe.alphabetical).to eq([ apple, bread, cake, cake_again ])
    end
  end

  describe "deleting" do
    it "removes its ingredients with destroy!" do
      recipe = create(:recipe)
      other = create(:recipe_ingredient)
      create_list(:recipe_ingredient, 2, recipe: recipe)

      recipe.destroy!

      expect(RecipeIngredient.all).to contain_exactly(other)
    end

    it "is removed with its ingredients when the user is destroyed" do
      user = create(:user)
      recipe = create(:recipe, user: user)
      create(:recipe_ingredient, recipe: recipe)

      user.destroy!

      expect(Recipe.count).to eq(0)
      expect(RecipeIngredient.count).to eq(0)
    end
  end
end
