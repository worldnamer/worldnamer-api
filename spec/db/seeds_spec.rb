require "rails_helper"

# db/seeds.rb creates the known development user (john) and does nothing in production.
RSpec.describe "db/seeds.rb", type: :request do
  let(:seed_password) { "correct horse battery" }

  def run_seed
    load Rails.root.join("db/seeds.rb")
  end

  def login_as(username, password)
    json_post "/api/v1/session", { username: username, password: password }
  end

  def stub_env(name)
    allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new(name))
  end

  context "in development" do
    before { stub_env("development") }

  it "creates john, who can log in with the seed password" do
    expect { run_seed }.to change(User, :count).by(1)

    login_as("john", seed_password)

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["user"]).to eq("username" => "john")
  end

  it "changes nothing the second time" do
    run_seed
    record = User.find_by!(username: "john")

    expect { run_seed }.not_to change(User, :count)
    expect(record.reload.attributes).to eq(User.find_by!(username: "john").attributes)
  end

  it "leaves an existing john and his password alone" do
    create(:user, username: "john", password: AuthHelpers::TEST_PASSWORD)
    digest = User.find_by!(username: "john").encrypted_password

    expect { run_seed }.not_to change(User, :count)
    expect(User.find_by!(username: "john").encrypted_password).to eq(digest)

    login_as("john", AuthHelpers::TEST_PASSWORD)
    expect(response).to have_http_status(:ok)
    login_as("john", seed_password)
    expect(response).to have_http_status(:unauthorized)
  end

  it "gives john the seed habits" do
    run_seed

    expect(User.find_by!(username: "john").habits.order(:id).pluck(:name)).to eq([ "Drink water", "Read 20 pages", "Stretch" ])
  end

  it "adds no habits the second time" do
    run_seed

    expect { run_seed }.not_to change(Habit, :count)
  end

  it "gives the seed habits to an existing john who has none" do
    john = create(:user, username: "john")

    expect { run_seed }.to change { john.habits.count }.from(0).to(3)
  end

  it "adds no habits to a john who already has some" do
    john = create(:user, username: "john")
    create(:habit, user: john, name: "Mine")

    expect { run_seed }.not_to change(Habit, :count)
    expect(john.habits.pluck(:name)).to eq([ "Mine" ])
  end
  end

  %w[production staging].each do |name|
    it "creates nothing in #{name} and never touches User" do
      stub_env(name)
      expect(User).not_to receive(:find_by)
      expect(User).not_to receive(:create!)
      expect(User).not_to receive(:new)
      expect(Habit).not_to receive(:create!)

      expect { run_seed }.to output(/skipp/i).to_stdout
    end
  end

  it "creates nothing in the real test environment and never touches User" do
    expect(Rails.env).to be_test
    expect(User).not_to receive(:find_by)
    expect(User).not_to receive(:create!)
    expect(Habit).not_to receive(:create!)

    expect { run_seed }.to output(/skipp/i).to_stdout
    expect(User.count).to eq(0)
    expect(Habit.count).to eq(0)
  end
end
