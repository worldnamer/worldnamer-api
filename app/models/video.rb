# A video seen in a user's chosen YouTube playlist, recorded the first time the playlist check meets it with the title
# it had then. Rows are never removed when the video leaves the playlist. Unique per user and YouTube id, so the check
# can insert with insert_all and skip what is already there (insert_all does not run these validations; the database
# constraints hold the same rules).
class Video < ApplicationRecord
  belongs_to :user

  # At most one. No callbacks on it; the foreign key cascades in the database as well.
  has_one :transcript, dependent: :delete

  validates :youtube_id, format: { with: YouTube::DataClient::VIDEO_ID }
end
