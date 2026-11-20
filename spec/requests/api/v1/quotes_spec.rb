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

  describe "POST /api/v1/quotes" do
    it "creates a quote for the caller and answers 201 with its id, text and author" do
      post "/api/v1/quotes",
           params: { quote: { text: "  Stay  ", author: "Me" } },
           headers: { "Authorization" => "Bearer #{token_for}" },
           as: :json

      expect(response).to have_http_status(:created)
      quote = user.quotes.find_by!(text: "Stay")
      expect(response.parsed_body).to eq("quote" => { "id" => quote.id, "text" => "Stay", "author" => "Me" })
    end

    it "takes the owner from the token, not from the body" do
      other = create(:user, username: "other")

      post "/api/v1/quotes",
           params: { quote: { text: "Mine", author: nil, user_id: other.id, id: 9999 } },
           headers: { "Authorization" => "Bearer #{token_for}" },
           as: :json

      expect(response).to have_http_status(:created)
      quote = user.quotes.find_by!(text: "Mine")
      expect(quote.id).not_to eq(9999)
      expect(response.parsed_body.fetch("quote").fetch("id")).to eq(quote.id)
      expect(other.quotes.find_by(text: "Mine")).to be_nil
    end

    it "answers 422 validation_failed with the message when the text is blank" do
      post "/api/v1/quotes",
           params: { quote: { text: "  ", author: "Me" } },
           headers: { "Authorization" => "Bearer #{token_for}" },
           as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to eq(
        "error" => { "code" => "validation_failed", "message" => "Text can't be blank." }
      )
    end

    it "answers 422 when the text or the author is too long" do
      post "/api/v1/quotes",
           params: { quote: { text: "a" * 501, author: "Me" } },
           headers: { "Authorization" => "Bearer #{token_for}" },
           as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to eq(
        "error" => { "code" => "validation_failed", "message" => "Text is too long (maximum is 500 characters)." }
      )

      post "/api/v1/quotes",
           params: { quote: { text: "Fine", author: "a" * 101 } },
           headers: { "Authorization" => "Bearer #{token_for}" },
           as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to eq(
        "error" => { "code" => "validation_failed", "message" => "Author is too long (maximum is 100 characters)." }
      )
    end

    it "answers 400 bad_request when the quote key is missing" do
      post "/api/v1/quotes",
           params: {},
           headers: { "Authorization" => "Bearer #{token_for}" },
           as: :json

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body.dig("error", "code")).to eq("bad_request")
    end
  end

  describe "DELETE /api/v1/quotes/:id" do
    it "deletes the caller's quote and answers 204" do
      quote = create(:quote, user: user, text: "Gone", author: nil)

      delete "/api/v1/quotes/#{quote.id}", headers: { "Authorization" => "Bearer #{token_for}" }

      expect(response).to have_http_status(:no_content)
      expect(Quote.exists?(quote.id)).to be false
    end

    it "answers the same 404 for someone else's quote and a missing one" do
      other = create(:user, username: "other")
      other_quote = create(:quote, user: other, text: "Not John's", author: nil)
      missing = create(:quote, user: user, text: "Already gone", author: nil)
      missing_id = missing.id
      missing.destroy!

      delete "/api/v1/quotes/#{other_quote.id}", headers: { "Authorization" => "Bearer #{token_for}" }
      expect_not_found
      expect(Quote.exists?(other_quote.id)).to be true

      delete "/api/v1/quotes/#{missing_id}", headers: { "Authorization" => "Bearer #{token_for}" }
      expect_not_found
    end
  end

  private

  def quote_json(quote)
    { "id" => quote.id, "text" => quote.text, "author" => quote.author }
  end
end
