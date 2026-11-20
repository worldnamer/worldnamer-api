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

      # POST /api/v1/quotes. The owner comes from the token, never from the body: params.expect permits only text and
      # author, so user_id and id in the body are dropped.
      def create
        quote = current_user.quotes.build(params.expect(quote: [ :text, :author ]))
        if quote.save
          render json: { quote: quote_json(quote) }, status: :created
        else
          render_error "validation_failed", "#{quote.errors.full_messages.first}.", :unprocessable_content
        end
      end

      # DELETE /api/v1/quotes/:id. Someone else's quote and a missing one get the same 404, so existence is not revealed.
      # destroy! (not delete) so the model's callbacks run.
      def destroy
        current_user.quotes.find(params[:id]).destroy!
        head :no_content
      end

      private

      # Only the fields the client shows. Other columns stay out of the response.
      def quote_json(quote)
        { id: quote.id, text: quote.text, author: quote.author }
      end
    end
  end
end
