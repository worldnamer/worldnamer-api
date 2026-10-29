require "rails_helper"
require Rails.root.join("config/allowed_origins")

RSpec.describe AllowedOrigins do
  def list(env, production: false)
    described_class.from(env, production: production)
  end

  it "defaults to the Vite dev server when the variable is unset" do
    expect(list({})).to eq([ "http://localhost:5173" ])
  end

  it "uses the variable as the whole list outside production" do
    expect(list({ "ALLOWED_ORIGINS" => "http://localhost:5301" })).to eq([ "http://localhost:5301" ])
  end

  it "accepts several comma-separated origins" do
    env = { "ALLOWED_ORIGINS" => "http://localhost:5301,http://localhost:5302" }
    expect(list(env)).to eq([ "http://localhost:5301", "http://localhost:5302" ])
  end

  it "strips whitespace and drops empty entries" do
    env = { "ALLOWED_ORIGINS" => " http://localhost:5301 , ,, http://localhost:5302,  " }
    expect(list(env)).to eq([ "http://localhost:5301", "http://localhost:5302" ])
  end

  it "falls back to the default when the variable yields no entries" do
    [ "", "   ", " , ,, " ].each do |value|
      expect(list({ "ALLOWED_ORIGINS" => value })).to eq([ "http://localhost:5173" ])
    end
  end

  it "ignores the variable in production" do
    env = { "ALLOWED_ORIGINS" => "http://localhost:5301,https://evil.example" }
    expect(list(env, production: true)).to eq([ "https://worldnamer.com" ])
  end

  describe "on the session endpoint", type: :request do
    let!(:user) { create(:user, username: "john") }

    def with_list(env)
      allow(Rails.configuration.x).to receive(:allowed_origins).and_return(list(env))
    end

    it "accepts only the configured origin when the variable is set" do
      with_list({ "ALLOWED_ORIGINS" => "http://localhost:5301" })

      login(origin: "http://localhost:5301")
      expect(response).to have_http_status(:ok)

      login(origin: "http://localhost:5173")
      expect_forbidden_origin
    end

    it "accepts 5173 and nothing else when the variable is unset" do
      with_list({})

      login(origin: "http://localhost:5173")
      expect(response).to have_http_status(:ok)

      login(origin: "http://localhost:5301")
      expect_forbidden_origin
    end
  end
end
