require "rails_helper"

RSpec.describe GoogleOauthState, type: :model do
  let(:connection) { ActiveRecord::Base.connection }
  let(:columns) { connection.columns(:google_oauth_states).index_by(&:name) }

  describe "table google_oauth_states" do
    it "requires user_id, state_digest and expires_at, and stores the verifier as text" do
      %w[user_id state_digest expires_at].each do |name|
        expect(columns[name].null).to be(false), "expected #{name} to be NOT NULL"
      end
      expect(columns["code_verifier"].sql_type).to eq("text")
    end

    it "has unique indexes on user_id and state_digest" do
      expect(connection.index_exists?(:google_oauth_states, :user_id, unique: true)).to be(true)
      expect(connection.index_exists?(:google_oauth_states, :state_digest, unique: true)).to be(true)
    end

    it "has a foreign key to users that cascades on delete" do
      foreign_key = connection.foreign_keys(:google_oauth_states).find { |fk| fk.to_table == "users" }
      expect(foreign_key.column).to eq("user_id")
      expect(foreign_key.on_delete).to eq(:cascade)
    end
  end

  describe ".start!" do
    let(:user) { create(:user) }

    it "returns a 32-byte URL-safe state and stores only its SHA256 digest" do
      raw_state, row = GoogleOauthState.start!(user)

      expect(raw_state).to match(/\A[A-Za-z0-9_-]{43}\z/)
      expect(row.state_digest).to eq(Digest::SHA256.hexdigest(raw_state))
      dump = connection.select_all("SELECT * FROM google_oauth_states").to_a.inspect
      expect(dump).not_to include(raw_state)
    end

    it "stores the code verifier as ciphertext and reads it back" do
      _raw_state, row = GoogleOauthState.start!(user)
      verifier = row.code_verifier

      expect(verifier).to match(/\A[A-Za-z0-9_-]{43,128}\z/)
      stored = connection.select_value("SELECT code_verifier FROM google_oauth_states WHERE id = #{Integer(row.id)}")
      expect(stored).not_to include(verifier)
      expect(GoogleOauthState.find(row.id).code_verifier).to eq(verifier)
    end

    it "expires in ten minutes" do
      _raw_state, row = GoogleOauthState.start!(user)

      expect(row.expires_at).to be_within(5.seconds).of(10.minutes.from_now)
      expect(row.expired?).to be(false)
    end

    it "replaces the user's pending sign-in, and leaves other users' alone" do
      other = create(:google_oauth_state)
      first_state, = GoogleOauthState.start!(user)
      second_state, row = GoogleOauthState.start!(user)

      expect(GoogleOauthState.where(user: user).count).to eq(1)
      expect(row.state_digest).to eq(GoogleOauthState.digest(second_state))
      expect(GoogleOauthState.find_by(state_digest: GoogleOauthState.digest(first_state))).to be_nil
      expect(GoogleOauthState.exists?(other.id)).to be(true)
    end
  end

  describe ".claim" do
    let(:user) { create(:user) }

    it "returns the row once and deletes it, so a second claim gets nothing" do
      raw_state, row = GoogleOauthState.start!(user)

      expect(GoogleOauthState.claim(raw_state)).to eq(row)
      expect(GoogleOauthState.exists?(row.id)).to be(false)
      expect(GoogleOauthState.claim(raw_state)).to be_nil
    end

    it "returns nil for a blank or unknown state" do
      GoogleOauthState.start!(user)

      expect(GoogleOauthState.claim(nil)).to be_nil
      expect(GoogleOauthState.claim("")).to be_nil
      expect(GoogleOauthState.claim("unknown")).to be_nil
      expect(GoogleOauthState.count).to eq(1)
    end

    it "deletes an expired row but returns nil for it" do
      row = create(:google_oauth_state, state: "old-state", expires_at: 1.second.ago)

      expect(GoogleOauthState.claim("old-state")).to be_nil
      expect(GoogleOauthState.exists?(row.id)).to be(false)
    end

    it "returns nil to the loser when another request deleted the row after it was found" do
      raw_state, row = GoogleOauthState.start!(user)
      allow(GoogleOauthState).to receive(:find_by).and_wrap_original do |original, *args|
        found = original.call(*args)
        GoogleOauthState.where(id: row.id).delete_all # the other request wins the race here
        found
      end

      expect(GoogleOauthState.claim(raw_state)).to be_nil
    end
  end

  describe "#code_challenge" do
    it "is the S256 challenge: unpadded base64url of the verifier's SHA-256" do
      # Expected value computed outside Ruby:
      # printf '%s' <verifier> | openssl dgst -sha256 -binary | openssl base64 | tr '+/' '-_' | tr -d '='
      row = build(:google_oauth_state, code_verifier: "dBjftJeZ4CVP-mJ92K9xMcV6Gzwi9ADmfQgVvtiJyAN")

      expect(row.code_challenge).to eq("1YOMGYA8k05sOI7KKpUcg0dWVI7oxoze3BeLuDQmkRw")
    end
  end

  describe "deleting the user" do
    it "deletes the pending sign-in, through has_one and in SQL" do
      first = create(:google_oauth_state)
      second = create(:google_oauth_state)

      expect { first.user.destroy! }.to change(GoogleOauthState, :count).by(-1)
      expect { User.where(id: second.user_id).delete_all }.to change(GoogleOauthState, :count).by(-1)
    end
  end
end
