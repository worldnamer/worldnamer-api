module Api
  module V1
    class QuotesController < ApplicationController
      # Warden checks the Authorization: Bearer token. On failure Auth::FailureApp answers 401 "unauthenticated".
      # No only: list, so an action added later is protected by default.
      before_action :authenticate_user!

      # Rails would copy a top-level name into params[:quote] for JSON bodies. Keep request bodies explicit.
      wrap_parameters false

      # GET /api/v1/quotes. Lists the caller's own quotes only, through current_user.
      # Oldest first, with a stable order for quotes created at the same time.
      def index
        quotes = current_user.quotes.order(:created_at, :id).map { |quote| quote_json(quote) }
        render json: { quotes: quotes }
      end

      private

      # Only the fields the client shows. Other columns stay out of the response.
      def quote_json(quote)
        { id: quote.id, text: quote.text, author: quote.author }
      end
    end
  end
end
