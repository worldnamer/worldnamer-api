require "rails_helper"

# Plan section 2, "Refresh token": the table and its database-level guarantees.
# Named by string so this file loads (and fails per example) before the model exists.
RSpec.describe "RefreshToken", type: :model do
  let(:connection) { ActiveRecord::Base.connection }
  let(:columns) { connection.columns(:refresh_tokens).index_by(&:name) }

  describe "table refresh_tokens" do
    it "has the planned columns" do
      expect(columns.keys).to include("user_id", "family_id", "token_digest", "expires_at", "used_at", "created_at", "updated_at")
    end

    it "stores family_id as a uuid" do
      expect(columns["family_id"].sql_type).to eq("uuid")
    end

    it "allows used_at to be null and requires the other planned values" do
      expect(columns["used_at"].null).to be(true)
      %w[user_id family_id token_digest expires_at].each do |name|
        expect(columns[name].null).to be(false), "expected #{name} to be NOT NULL"
      end
    end

    it "indexes family_id" do
      expect(connection.index_exists?(:refresh_tokens, :family_id)).to be(true)
    end

    it "has a unique index on token_digest" do
      expect(connection.index_exists?(:refresh_tokens, :token_digest, unique: true)).to be(true)
    end

    it "has a foreign key to users that cascades on delete" do
      foreign_key = connection.foreign_keys(:refresh_tokens).find { |fk| fk.to_table == "users" }
      expect(foreign_key).to be_present
      expect(foreign_key.column).to eq("user_id")
      expect(foreign_key.on_delete).to eq(:cascade)
    end
  end

  describe "the factory" do
    it "stores the SHA256 hex digest of the raw token, not the token" do
      record = create(:refresh_token)

      expect(record.token_digest).to eq(Digest::SHA256.hexdigest(record.token))
      expect(record.token_digest).not_to eq(record.token)
      expect(record.token_digest).to match(/\A\h{64}\z/)
    end

    it "gives each record a different token" do
      expect(create(:refresh_token).token_digest).not_to eq(create(:refresh_token).token_digest)
    end
  end

  describe "database guarantees" do
    it "refuses a second row with the same token_digest, in the database" do
      first = create(:refresh_token)

      expect {
        RefreshToken.insert!({ user_id: first.user_id, family_id: SecureRandom.uuid, token_digest: first.token_digest, expires_at: 1.day.from_now })
      }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "deletes a user's tokens when the user is destroyed" do
      user = create(:user)
      create_list(:refresh_token, 2, user: user)
      other = create(:refresh_token)

      expect { user.destroy! }.to change(RefreshToken, :count).by(-2)
      expect(RefreshToken.all).to contain_exactly(other)
    end

    it "deletes a user's tokens when the user row is deleted in SQL (cascade, not just callbacks)" do
      token = create(:refresh_token)

      expect { User.where(id: token.user_id).delete_all }.to change(RefreshToken, :count).by(-1)
    end

    it "refuses a token for a user that does not exist" do
      expect {
        RefreshToken.insert!({ user_id: 0, family_id: SecureRandom.uuid, token_digest: "a" * 64, expires_at: 1.day.from_now })
      }.to raise_error(ActiveRecord::InvalidForeignKey)
    end
  end
end
