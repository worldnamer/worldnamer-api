require "rails_helper"

RSpec.describe YouTubeOauthState, type: :model do
  let(:connection) { ActiveRecord::Base.connection }
  let(:columns) { connection.columns(:youtube_oauth_states).index_by(&:name) }
  let(:user) { create(:user) }

  describe "table youtube_oauth_states" do
    it "requires user_id, state_digest and expires_at, and stores the verifier as text" do
      %w[user_id state_digest expires_at].each do |name|
        expect(columns[name].null).to be(false), "expected #{name} to be NOT NULL"
      end
      expect(columns["code_verifier"].sql_type).to eq("text")
    end

    it "has unique indexes on user_id and state_digest" do
      expect(connection.index_exists?(:youtube_oauth_states, :user_id, unique: true)).to be(true)
      expect(connection.index_exists?(:youtube_oauth_states, :state_digest, unique: true)).to be(true)
    end

    it "has a foreign key to users that cascades on delete" do
      foreign_key = connection.foreign_keys(:youtube_oauth_states).find { |fk| fk.to_table == "users" }
      expect(foreign_key.column).to eq("user_id")
      expect(foreign_key.on_delete).to eq(:cascade)
    end
  end

  describe ".start!" do
    it "stores only the state's digest and the verifier as ciphertext, expiring in ten minutes" do
      raw_state, row = YouTubeOauthState.start!(user)

      expect(row.state_digest).to eq(Digest::SHA256.hexdigest(raw_state))
      dump = connection.select_all("SELECT * FROM youtube_oauth_states").to_a.inspect
      expect(dump).not_to include(raw_state)
      expect(dump).not_to include(row.code_verifier)
      expect(row.expires_at).to be_within(5.seconds).of(10.minutes.from_now)
    end

    it "replaces the user's pending sign-in" do
      YouTubeOauthState.start!(user)
      second_state, = YouTubeOauthState.start!(user)

      expect(YouTubeOauthState.where(user: user).pluck(:state_digest)).to eq([ YouTubeOauthState.digest(second_state) ])
    end
  end

  describe ".claim" do
    it "returns the row once and deletes it" do
      raw_state, row = YouTubeOauthState.start!(user)

      expect(YouTubeOauthState.claim(raw_state)).to eq(row)
      expect(YouTubeOauthState.claim(raw_state)).to be_nil
    end

    it "deletes an expired row but returns nil for it" do
      row = create(:youtube_oauth_state, state: "old-state", expires_at: 1.second.ago)

      expect(YouTubeOauthState.claim("old-state")).to be_nil
      expect(YouTubeOauthState.exists?(row.id)).to be(false)
    end
  end

  describe "independence from the Calendar sign-in" do
    it "cannot claim a Calendar sign-in's state, and leaves it pending" do
      calendar_state, = GoogleCalendarOauthState.start!(user)

      expect(YouTubeOauthState.claim(calendar_state)).to be_nil
      expect(GoogleCalendarOauthState.where(user: user).count).to eq(1)
    end

    it "starting one leaves the other's pending sign-in alone" do
      calendar_state, = GoogleCalendarOauthState.start!(user)
      youtube_state, = YouTubeOauthState.start!(user)

      expect(GoogleCalendarOauthState.find_by!(user: user).state_digest).to eq(GoogleCalendarOauthState.digest(calendar_state))
      expect(GoogleCalendarOauthState.claim(youtube_state)).to be_nil
    end
  end

  describe "deleting the user" do
    it "deletes the pending sign-in, through has_one and in SQL" do
      first = create(:youtube_oauth_state)
      second = create(:youtube_oauth_state)

      expect { first.user.destroy! }.to change(YouTubeOauthState, :count).by(-1)
      expect { User.where(id: second.user_id).delete_all }.to change(YouTubeOauthState, :count).by(-1)
    end
  end
end
