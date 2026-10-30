module Api
  module V1
    class TaskListsController < ApplicationController
      # Warden checks the Authorization: Bearer token. On failure Auth::FailureApp answers 401 "unauthenticated".
      # No only: list, so an action added later is protected by default.
      before_action :authenticate_user!

      # Rails would copy a top-level name into params[:task_list] for JSON bodies. The contract is { task_list: { name } }
      # only, so a body without the task_list key must get 400.
      wrap_parameters false

      # GET /api/v1/task_lists. Every query starts from current_user.task_lists, never TaskList.find, so a list that
      # belongs to someone else cannot be reached. Not paginated.
      def index
        render json: { task_lists: current_user.task_lists.in_order.map { |list| task_list_json(list) } }
      end

      private

      # Only id and name leave the API: user_id and position stay inside.
      def task_list_json(list)
        { id: list.id, name: list.name }
      end
    end
  end
end
