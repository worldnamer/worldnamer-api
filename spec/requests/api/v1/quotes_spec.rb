require "rails_helper"

RSpec.describe "/api/v1/quotes", type: :request do
  let!(:user) { create(:user, username: "john") }

  def token_for(account = user)
    login(username: account.username)
    response.parsed_body.fetch("access_token")
  end

  def expect_unauthenticated
    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body).to match(expected_unauthenticated_body)
  end

  def expect_not_found
    expect(response).to have_http_status(:not_found)
    expect(response.parsed_body).to eq("error" => { "code" => "not_found", "message" => "Not found." })
  end

  describe "GET /api/v1/quotes" do
    it "returns 401 unauthenticated with no token on GET quotes" do
      get "/api/v1/quotes"
      expect_unauthenticated
    end

    it "returns an empty list when there are no quotes" do
      get "/api/v1/quotes", headers: { "Authorization" => "Bearer #{token_for}" }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq("quotes" => [])
    end

    it "returns the caller's quotes oldest first, each with only id, text and author" do
      create(:quote, user: user, text: "Second", author: nil, created_at: 2.days.ago)
      create(:quote, user: user, text: "Third", author: nil, created_at: 1.day.ago)
      create(:quote, user: user, text: "First", author: "Ann", created_at: 3.days.ago)

      get "/api/v1/quotes", headers: { "Authorization" => "Bearer #{token_for}" }

      expected = user.quotes.order(:created_at, :id).map { |quote| quote_json(quote) }
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq("quotes" => expected)
      expect(expected.first).to eq("id" => expected.first["id"], "text" => "First", "author" => "Ann")
    end

    it "breaks a created_at tie by id" do
      same_time = 1.day.ago
      first = create(:quote, user: user, text: "A", author: nil, created_at: same_time)
      second = create(:quote, user: user, text: "B", author: nil, created_at: same_time)
      third = create(:quote, user: user, text: "C", author: nil, created_at: same_time)

      get "/api/v1/quotes", headers: { "Authorization" => "Bearer #{token_for}" }

      expect(response).to have_http_status(:ok)
      ids = response.parsed_body.fetch("quotes").pluck("id")
      expect(ids).to eq([ first.id, second.id, third.id ])
    end

    it "never includes another user's quotes" do
      other = create(:user, username: "other")
      create(:quote, user: other, text: "Not John's", author: nil)

      get "/api/v1/quotes", headers: { "Authorization" => "Bearer #{token_for}" }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("quotes").pluck("text")).not_to include("Not John's")
    end
  end

  private

  def quote_json(quote)
    { "id" => quote.id, "text" => quote.text, "author" => quote.author }
  end
end
