require "rails_helper"

RSpec.describe "User", type: :model do
  it "has a username and no email column" do
    expect(User.column_names).to include("username")
    expect(User.column_names).not_to include("email")
  end

  it "stores a bcrypt digest, never the password" do
    user = create(:user, password: AuthHelpers::TEST_PASSWORD)

    expect(user.encrypted_password).to start_with("$2")
    expect(user.encrypted_password).not_to include(AuthHelpers::TEST_PASSWORD)
    expect(user.valid_password?(AuthHelpers::TEST_PASSWORD)).to be(true)
    expect(user.valid_password?("wrong")).to be(false)
  end

  it "downcases and strips the username" do
    user = create(:user, username: "  JoHn ")

    expect(user.reload.username).to eq("john")
  end

  it "requires a username" do
    expect(build(:user, username: "")).not_to be_valid
    expect(build(:user, username: nil)).not_to be_valid
  end

  it "requires a unique username, ignoring case and whitespace" do
    create(:user, username: "john")

    expect(build(:user, username: "john")).not_to be_valid
    expect(build(:user, username: "JOHN")).not_to be_valid
    expect(build(:user, username: " john ")).not_to be_valid
  end

  it "enforces uniqueness in the database too" do
    create(:user, username: "john")
    other = build(:user, username: "john")

    expect { other.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
  end
end
