require "rails_helper"

RSpec.describe YoutubeConnection, type: :model do
  let(:connection) { ActiveRecord::Base.connection }
  let(:columns) { connection.columns(:youtube_connections).index_by(&:name) }
  let(:client) { GoogleCalendar::OauthClient.new }

  # The column as stored in Postgres, bypassing Active Record's decryption.
  def stored_refresh_token(record)
    connection.select_value("SELECT refresh_token FROM youtube_connections WHERE id = #{Integer(record.id)}")
  end

  describe "table youtube_connections" do
    it "requires user_id and connected_at, and allows the token, lost_at and the playlist to be null" do
      %w[user_id connected_at].each do |name|
        expect(columns[name].null).to be(false), "expected #{name} to be NOT NULL"
      end
      %w[refresh_token lost_at playlist_id playlist_title].each do |name|
        expect(columns[name].null).to be(true), "expected #{name} to allow NULL"
      end
      expect(columns["refresh_token"].sql_type).to eq("text")
    end

    it "has a unique index on user_id" do
      expect(connection.index_exists?(:youtube_connections, :user_id, unique: true)).to be(true)
    end

    it "has a foreign key to users that cascades on delete" do
      foreign_key = connection.foreign_keys(:youtube_connections).find { |fk| fk.to_table == "users" }
      expect(foreign_key).to be_present
      expect(foreign_key.column).to eq("user_id")
      expect(foreign_key.on_delete).to eq(:cascade)
    end
  end

  describe "encryption" do
    it "stores ciphertext, never the refresh token, and reads the token back" do
      record = create(:youtube_connection, refresh_token: "1//plaintext-youtube-token")

      stored = stored_refresh_token(record)
      expect(stored).to be_present
      expect(stored).not_to include("plaintext-youtube-token")
      expect(YoutubeConnection.find(record.id).refresh_token).to eq("1//plaintext-youtube-token")
    end

    it "encrypts the same token differently each time (non-deterministic)" do
      first = create(:youtube_connection, refresh_token: "1//same-token")
      second = create(:youtube_connection, refresh_token: "1//same-token")

      expect(stored_refresh_token(first)).not_to eq(stored_refresh_token(second))
    end

    it "stores a rotated token as ciphertext too" do
      record = create(:youtube_connection, refresh_token: "1//stored")
      stub_google_tokens(refresh_token: "1//rotated-youtube")

      record.mint_access_token(client: client)

      expect(YoutubeConnection.find(record.id).refresh_token).to eq("1//rotated-youtube")
      expect(stored_refresh_token(record)).not_to include("rotated-youtube")
    end
  end

  describe "one connection per user" do
    it "refuses a second row for the same user, in the database" do
      first = create(:youtube_connection)

      expect {
        YoutubeConnection.insert!({ user_id: first.user_id, connected_at: Time.current })
      }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "is reached through the user" do
      record = create(:youtube_connection)

      expect(record.user.youtube_connection).to eq(record)
    end

    it "connect! keeps one row per user" do
      user = create(:user)

      YoutubeConnection.connect!(user_id: user.id, refresh_token: "1//first")
      YoutubeConnection.connect!(user_id: user.id, refresh_token: "1//second")

      expect(YoutubeConnection.where(user: user).count).to eq(1)
      expect(user.reload.youtube_connection.refresh_token).to eq("1//second")
    end
  end

  describe "deleting the user" do
    it "deletes the user's connection when the user is destroyed" do
      record = create(:youtube_connection)
      other = create(:youtube_connection)

      expect { record.user.destroy! }.to change(YoutubeConnection, :count).by(-1)
      expect(YoutubeConnection.all).to contain_exactly(other)
    end

    it "deletes the connection when the user row is deleted in SQL (cascade, not just callbacks)" do
      record = create(:youtube_connection)

      expect { User.where(id: record.user_id).delete_all }.to change(YoutubeConnection, :count).by(-1)
    end
  end

  describe "reconnecting" do
    it "replaces the token and clears lost_at, and keeps the chosen playlist" do
      record = create(:youtube_connection, :lost, playlist_id: "PLkept123", playlist_title: "Kept", connected_at: 1.day.ago)

      YoutubeConnection.connect!(user_id: record.user_id, refresh_token: "1//reconnected")

      stored = YoutubeConnection.find(record.id)
      expect(stored.refresh_token).to eq("1//reconnected")
      expect(stored.lost_at).to be_nil
      expect(stored.connected_at).to be > 1.minute.ago
      expect(stored.playlist_id).to eq("PLkept123")
      expect(stored.playlist_title).to eq("Kept")
    end
  end

  describe "independence from the Calendar connection" do
    it "connecting YouTube leaves the Calendar connection alone, and the other way round" do
      user = create(:user)
      calendar = create(:google_calendar_connection, user: user, refresh_token: "1//calendar")

      expect { YoutubeConnection.connect!(user_id: user.id, refresh_token: "1//youtube") }
        .not_to change { GoogleCalendarConnection.find(calendar.id).attributes }

      youtube = user.reload.youtube_connection
      expect { GoogleCalendarConnection.connect!(user_id: user.id, refresh_token: "1//calendar-again") }
        .not_to change { YoutubeConnection.find(youtube.id).attributes }
    end

    it "marking YouTube lost leaves the Calendar connection connected" do
      user = create(:user)
      calendar = create(:google_calendar_connection, user: user)
      youtube = create(:youtube_connection, user: user)

      expect(youtube.mark_lost!).to be(true)

      expect(GoogleCalendarConnection.find(calendar.id).status).to eq("connected")
      expect(GoogleCalendarConnection.find(calendar.id).refresh_token).to be_present
    end
  end

  describe "#status" do
    it "is connected without lost_at and lost with it" do
      expect(build(:youtube_connection).status).to eq("connected")
      expect(build(:youtube_connection, :lost).status).to eq("lost")
    end
  end

  describe "#mark_lost!" do
    it "clears the token and sets lost_at, and keeps the playlist" do
      record = create(:youtube_connection, :with_playlist)

      expect(record.mark_lost!).to be(true)
      stored = YoutubeConnection.find(record.id)
      expect(stored.refresh_token).to be_nil
      expect(stored.lost_at).to be_within(5.seconds).of(Time.current)
      expect(stored.playlist_id).to eq(record.playlist_id)
    end

    it "leaves alone a connection that was reconnected after this copy was loaded" do
      record = create(:youtube_connection, connected_at: 1.hour.ago)
      stale_copy = YoutubeConnection.find(record.id)
      YoutubeConnection.connect!(user_id: record.user_id, refresh_token: "1//after-reconnect")

      expect(stale_copy.mark_lost!).to be(false)
      stored = YoutubeConnection.find(record.id)
      expect(stored.refresh_token).to eq("1//after-reconnect")
      expect(stored.lost_at).to be_nil
    end
  end

  describe "#check" do
    it "marks the connection lost on invalid_grant" do
      record = create(:youtube_connection)
      stub_google_token_error("invalid_grant")

      expect(record.check(client: client)).to eq("lost")
      expect(YoutubeConnection.find(record.id).lost_at).to be_present
    end

    it "does not call Google for a lost connection" do
      record = create(:youtube_connection, :lost)

      expect(record.check(client: client)).to eq("lost")
      expect(a_request(:any, google_token_endpoint)).not_to have_been_made
    end
  end
end
