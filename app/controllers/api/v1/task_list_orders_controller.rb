module Api
  module V1
    # PUT /api/v1/task_list_order takes the full ordered list of the caller's list ids, { "ids": [3, 1, 2] }.
    class TaskListOrdersController < ApplicationController
      # Warden checks the Authorization: Bearer token. No only: list, so an action added later is protected by default.
      before_action :authenticate_user!

      # Nothing should be built from the body but ids, so Rails does not wrap it.
      wrap_parameters false

      # The ids must be exactly the caller's lists, each once. Anything else (a missing, extra, repeated, nonexistent or
      # someone else's id) is the same 409, so a foreign id is not told apart from a nonexistent one, and a tab that
      # missed a create or delete learns it is out of date. The same set in a different order is accepted: the last
      # write wins.
      def update
        ids = params[:ids]
        unless ids.is_a?(Array) && ids.any? && ids.all?(Integer)
          return render_error "bad_request", "ids must be a non-empty array of integers.", :bad_request
        end

        lists = reorder(ids)
        if lists
          render json: { task_lists: lists.map { |list| { id: list.id, name: list.name } } }
        else
          render_error "conflict", "The lists have changed. Reload and try again.", :conflict
        end
      end

      private

      # Returns the lists in the new order, or nil when ids are not a permutation of the caller's lists. The rows are
      # locked (SELECT ... FOR UPDATE, in position order so two requests cannot deadlock), so two reorders at once run
      # one after the other, and the check and the writes see the same rows. Only rows whose position changes are
      # written, so a swap is two UPDATEs and a repeat of the same order writes nothing.
      def reorder(ids)
        TaskList.transaction do
          by_id = current_user.task_lists.in_order.lock.index_by(&:id)
          next unless ids.sort == by_id.keys.sort

          ids.each_with_index.map do |id, index|
            list = by_id.fetch(id)
            list.update!(position: index) unless list.position == index
            list
          end
        end
      end
    end
  end
end
