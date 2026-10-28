module Api
  module V1
    class MeController < ApplicationController
      # Warden checks the Authorization: Bearer token. On failure Auth::FailureApp answers 401 "unauthenticated".
      before_action :authenticate_user!

      # GET /api/v1/me
      def show
        render json: { user: { username: current_user.username } }
      end
    end
  end
end
