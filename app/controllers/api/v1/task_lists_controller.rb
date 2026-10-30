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

      # POST /api/v1/task_lists. The owner comes from the token and the position from the model (the end of the list):
      # params.expect permits only name, so user_id, id and position in the body are dropped. A blank or nil name is
      # stored as "".
      def create
        list = current_user.task_lists.build(params.expect(task_list: [ :name ]))
        if list.save
          render json: { task_list: task_list_json(list) }, status: :created
        else
          render_error "validation_failed", "#{list.errors.full_messages.first}.", :unprocessable_content
        end
      end

      # PATCH /api/v1/task_lists/:id renames a list. Someone else's list and a missing one get the same 404, so existence
      # is not revealed. Only name is permitted: position changes only through the order endpoint.
      def update
        list = current_user.task_lists.find(params[:id])
        if list.update(params.expect(task_list: [ :name ]))
          render json: { task_list: task_list_json(list) }
        else
          render_error "validation_failed", "#{list.errors.full_messages.first}.", :unprocessable_content
        end
      end

      # DELETE /api/v1/task_lists/:id. Someone else's list and a missing one get the same 404, so existence is not
      # revealed, and a second delete of the same id is a 404 too. The remaining lists keep their positions, leaving a gap.
      def destroy
        current_user.task_lists.find(params[:id]).destroy!
        head :no_content
      end

      private

      # Only id and name leave the API: user_id and position stay inside.
      def task_list_json(list)
        { id: list.id, name: list.name }
      end
    end
  end
end
