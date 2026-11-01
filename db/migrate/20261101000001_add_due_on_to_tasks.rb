class AddDueOnToTasks < ActiveRecord::Migration[8.1]
  def change
    # A calendar day with no time zone, so it cannot shift between storage, API and browser. Nullable with no default:
    # most tasks have no due date. No index until something queries by date.
    add_column :tasks, :due_on, :date
  end
end
