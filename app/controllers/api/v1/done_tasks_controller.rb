module Api
  module V1
    # DELETE /api/v1/task_lists/:task_list_id/done_tasks clears the done tasks of one list. It is idempotent and answers
    # 204 whether or not anything was done. The request body is never read: the list comes from the path (found through
    # the caller) and nothing else selects what is deleted.
    class DoneTasksController < ApplicationController
      # Warden checks the Authorization: Bearer token. No only: list, so an action added later is protected by default.
      before_action :authenticate_user!

      # Rails would copy the body into params[:done_task]. Nothing reads it, so do not build it.
      wrap_parameters false

      # The list is found through the caller, so a missing, foreign, non-numeric or out-of-range id all raise
      # RecordNotFound (404). The delete is built from that list's tasks, so it always carries the list id: one DELETE
      # statement, no callbacks (Task has none).
      def destroy
        @task_list = current_user.task_lists.find(params[:task_list_id])
        @task_list.tasks.where(done: true).delete_all
        head :no_content
      end
    end
  end
end
