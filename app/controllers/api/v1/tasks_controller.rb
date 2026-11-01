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

      # PATCH /api/v1/task_lists/:task_list_id/tasks/:id edits a task's text, its done flag, or both. Unsent fields are
      # left alone. The task is found through the list that was found through the caller, so a task in someone else's
      # list, or in another of the caller's lists, gets the same 404 as a missing one. That lookup runs before the body
      # is read, so a bad body sent to a task that is not yours is a 404, not a 400. Only text and done are permitted:
      # task_list_id and id in the body are dropped, so a task cannot be moved.
      def update
        task = @task_list.tasks.find(params[:id])
        return render_error("bad_request", "done must be true or false.", :bad_request) unless done_valid?

        changes = params.expect(task: [ :text, :done ])
        if task.update(changes)
          render json: { task: task_json(task) }
        else
          render_error "validation_failed", "#{task.errors.full_messages.first}.", :unprocessable_content
        end
      end

      private

      # Scoped to the caller's lists, so a missing, foreign, non-numeric or out-of-range id all raise RecordNotFound (404).
      def set_task_list
        @task_list = current_user.task_lists.find(params[:task_list_id])
      end

      # done must be a JSON boolean when it is sent. Left to Rails it would cast "yes" or 1 to true and let null reach the
      # database, so anything else, including null, is refused. The raw value is checked, because params.expect would
      # silently drop a hash or array done. A task that is not a hash is left for params.expect to refuse as malformed.
      def done_valid?
        raw = params[:task]
        !raw.respond_to?(:key?) || !raw.key?(:done) || [ true, false ].include?(raw[:done])
      end

      # Only id, text and done leave the API: task_list_id and the timestamps stay inside.
      def task_json(task)
        { id: task.id, text: task.text, done: task.done }
      end
    end
  end
end
