require "rails_helper"

RSpec.describe Quote do
  it "is invalid when the text is blank" do
    quote = build(:quote, text: "  ")

    expect(quote).not_to be_valid
    expect(quote.errors).to have_key(:text)
  end

  it "is invalid when the text is longer than 500 characters" do
    expect(build(:quote, text: "a" * 500)).to be_valid
    expect(build(:quote, text: "a" * 501)).not_to be_valid
  end

  it "is invalid when the author is longer than 100 characters" do
    expect(build(:quote, author: "a" * 100)).to be_valid
    expect(build(:quote, author: "a" * 101)).not_to be_valid
  end

  it "strips whitespace from the text and the author" do
    quote = create(:quote, text: "  Stay  ", author: " Me ")

    expect(quote.text).to eq("Stay")
    expect(quote.author).to eq("Me")
  end

  it "stores an empty or blank author as an empty string" do
    expect(build(:quote, author: nil).author).to eq("")
    expect(build(:quote, author: "  ").author).to eq("")
  end

  it "deletes a user's quotes when the user is destroyed" do
    user = create(:user)
    create(:quote, user: user)

    user.destroy!

    expect(Quote.where(user_id: user.id)).to be_empty
  end
end
