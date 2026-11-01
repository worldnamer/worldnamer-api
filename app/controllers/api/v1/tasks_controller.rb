module Api
  module V1
    # Tasks nested under a list: /api/v1/task_lists/:task_list_id/tasks. A task is never looked up by its own id alone:
    # the list is found through the caller first, so a list or task that belongs to someone else cannot be reached.
    class TasksController < ApplicationController
      # Warden checks the Authorization: Bearer token. No only: list, so an action added later is protected by default.
      before_action :authenticate_user!
      # Runs after authentication, so an unauthenticated request gets 401 whatever the list id.
      before_action :set_task_list

      # Rails would copy a top-level text into params[:task]. The contract is { task: { ... } } only, so a body without
      # the task key must get 400.
      wrap_parameters false

      # GET /api/v1/task_lists/:task_list_id/tasks. Oldest first. Not paginated.
      def index
        render json: { tasks: @task_list.tasks.in_order.map { |task| task_json(task) } }
      end

      # POST /api/v1/task_lists/:task_list_id/tasks. The list comes from the path (found through the caller) and done
      # starts false: params.expect permits only text, so task_list_id, id and done in the body are dropped. A blank or
      # nil text is stored as "".
      def create
        task = @task_list.tasks.build(params.expect(task: [ :text ]))
        if task.save
          render json: { task: task_json(task) }, status: :created
        else
          render_error "validation_failed", "#{task.errors.full_messages.first}.", :unprocessable_content
        end
      rescue ActiveRecord::InvalidForeignKey
        # The list was deleted (another tab) between the lookup and the insert: the same 404 as a missing list.
        render_error "not_found", "Not found.", :not_found
      end

      private

      # Scoped to the caller's lists, so a missing, foreign, non-numeric or out-of-range id all raise RecordNotFound (404).
      def set_task_list
        @task_list = current_user.task_lists.find(params[:task_list_id])
      end

      # Only id, text and done leave the API: task_list_id and the timestamps stay inside.
      def task_json(task)
        { id: task.id, text: task.text, done: task.done }
      end
    end
  end
end
