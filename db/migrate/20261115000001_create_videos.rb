class CreateVideos < ActiveRecord::Migration[8.1]
  def change
    create_table :videos do |t|
      # on_delete: :cascade lets the database remove a user's videos itself, even for a delete that skips callbacks.
      t.references :user, null: false, foreign_key: { on_delete: :cascade }, index: false
      # YouTube's 11-character video id. The database refuses anything else, as the Ruby side does.
      t.string :youtube_id, null: false
      # The title as it was when the video was first seen.
      t.string :title, null: false, default: ""

      t.timestamps
    end

    add_index :videos, %i[user_id youtube_id], unique: true
    add_check_constraint :videos, "youtube_id ~ '^[A-Za-z0-9_-]{11}$'", name: "videos_youtube_id_format"
  end
end
