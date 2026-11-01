class TaskList < ApplicationRecord
  belongs_to :user

  # Tasks have no callbacks, so one DELETE removes them. destroy! fires this, and the foreign key cascades in the
  # database as well for a delete that skips callbacks.
  has_many :tasks, dependent: :delete_all

  # Runs on assignment and in finders, so " Shopping " is stored as "Shopping" and nil as "". A blank name is allowed,
  # so there is no presence check.
  normalizes :name, with: ->(name) { name.to_s.strip }, apply_to_nil: true

  validates :name, length: { maximum: 100 }

  # A new list goes after the user's highest position. Deletes leave gaps, so this is the maximum, not the count.
  before_create :set_position, if: -> { position.nil? }

  # id breaks ties between lists that share a position.
  scope :in_order, -> { order(:position, :id) }

  private

  def set_position
    self.position = (user.task_lists.maximum(:position) || -1) + 1
  end
end
