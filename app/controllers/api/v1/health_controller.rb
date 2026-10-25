module Api
  module V1
    class HealthController < ApplicationController
      def show
        ActiveRecord::Base.connection.select_value("SELECT 1")
        render json: { status: "ok", db: "ok" }
      rescue ActiveRecord::ActiveRecordError
        render json: { status: "error", db: "unreachable" }, status: :service_unavailable
      end
    end
  end
end
