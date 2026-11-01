require "rails_helper"

RSpec.describe GoogleCalendarConnection, type: :model do
  let(:connection) { ActiveRecord::Base.connection }
  let(:columns) { connection.columns(:google_calendar_connections).index_by(&:name) }

  # The column as stored in Postgres, bypassing Active Record's decryption.
  def stored_refresh_token(record)
    connection.select_value(
      "SELECT refresh_token FROM google_calendar_connections WHERE id = #{Integer(record.id)}"
    )
  end

  describe "table google_calendar_connections" do
    it "requires user_id and connected_at, and allows refresh_token and lost_at to be null" do
      %w[user_id connected_at].each do |name|
        expect(columns[name].null).to be(false), "expected #{name} to be NOT NULL"
      end
      %w[refresh_token lost_at].each do |name|
        expect(columns[name].null).to be(true), "expected #{name} to allow NULL"
      end
      expect(columns["refresh_token"].sql_type).to eq("text")
    end

    it "has a unique index on user_id" do
      expect(connection.index_exists?(:google_calendar_connections, :user_id, unique: true)).to be(true)
    end

    it "has a foreign key to users that cascades on delete" do
      foreign_key = connection.foreign_keys(:google_calendar_connections).find { |fk| fk.to_table == "users" }
      expect(foreign_key).to be_present
      expect(foreign_key.column).to eq("user_id")
      expect(foreign_key.on_delete).to eq(:cascade)
    end
  end

  describe "encryption" do
    it "stores ciphertext, never the refresh token, and reads the token back" do
      record = create(:google_calendar_connection, refresh_token: "1//plaintext-refresh-token")

      stored = stored_refresh_token(record)
      expect(stored).to be_present
      expect(stored).not_to include("plaintext-refresh-token")
      expect(GoogleCalendarConnection.find(record.id).refresh_token).to eq("1//plaintext-refresh-token")
    end

    it "encrypts the same token differently each time (non-deterministic)" do
      first = create(:google_calendar_connection, refresh_token: "1//same-token")
      second = create(:google_calendar_connection, refresh_token: "1//same-token")

      expect(stored_refresh_token(first)).not_to eq(stored_refresh_token(second))
    end
  end

  describe "one connection per user" do
    it "refuses a second row for the same user, in the database" do
      first = create(:google_calendar_connection)

      expect {
        GoogleCalendarConnection.insert!({ user_id: first.user_id, connected_at: Time.current })
      }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "is reached through the user" do
      record = create(:google_calendar_connection)

      expect(record.user.google_calendar_connection).to eq(record)
    end
  end

  describe "deleting the user" do
    it "deletes the user's connection when the user is destroyed" do
      record = create(:google_calendar_connection)
      other = create(:google_calendar_connection)

      expect { record.user.destroy! }.to change(GoogleCalendarConnection, :count).by(-1)
      expect(GoogleCalendarConnection.all).to contain_exactly(other)
    end

    it "deletes the connection when the user row is deleted in SQL (cascade, not just callbacks)" do
      record = create(:google_calendar_connection)

      expect { User.where(id: record.user_id).delete_all }.to change(GoogleCalendarConnection, :count).by(-1)
    end
  end

  describe "#status" do
    it "is connected without lost_at and lost with it" do
      expect(build(:google_calendar_connection).status).to eq("connected")
      expect(build(:google_calendar_connection, :lost).status).to eq("lost")
    end
  end

  describe "#mark_lost!" do
    it "clears the token and sets lost_at" do
      record = create(:google_calendar_connection)

      expect(record.mark_lost!).to be(true)
      stored = GoogleCalendarConnection.find(record.id)
      expect(stored.refresh_token).to be_nil
      expect(stored.lost_at).to be_within(5.seconds).of(Time.current)
      expect(stored.status).to eq("lost")
    end

    it "leaves alone a connection that was reconnected after this copy was loaded" do
      record = create(:google_calendar_connection, connected_at: 1.hour.ago)
      stale_copy = GoogleCalendarConnection.find(record.id)
      # A reconnect in another request: new token, new connected_at.
      record.update!(refresh_token: "1//after-reconnect", connected_at: Time.current, lost_at: nil)

      expect(stale_copy.mark_lost!).to be(false)
      stored = GoogleCalendarConnection.find(record.id)
      expect(stored.refresh_token).to eq("1//after-reconnect")
      expect(stored.lost_at).to be_nil
    end
  end

  describe "#check" do
    let(:client) { GoogleCalendar::OauthClient.new }

    it "is connected when Google accepts the token, and changes nothing" do
      record = create(:google_calendar_connection, refresh_token: "1//stored")
      stub_google_tokens(grant_type: "refresh_token")

      expect { expect(record.check(client: client)).to eq("connected") }
        .not_to change { GoogleCalendarConnection.find(record.id).attributes }
    end

    it "stores a new refresh token when Google sends one, encrypted" do
      record = create(:google_calendar_connection, refresh_token: "1//stored")
      stub_google_tokens(refresh_token: "1//rotated")

      expect(record.check(client: client)).to eq("connected")
      expect(GoogleCalendarConnection.find(record.id).refresh_token).to eq("1//rotated")
      expect(stored_refresh_token_ciphertext(record)).not_to include("1//rotated")
    end

    it "does not let a rotated token overwrite a connection reconnected during the check" do
      record = create(:google_calendar_connection, refresh_token: "1//stored", connected_at: 1.hour.ago)
      stub_request(:post, google_token_endpoint).to_return do
        GoogleCalendarConnection.where(id: record.id).update_all(refresh_token: nil, connected_at: Time.current)
        GoogleCalendarConnection.find(record.id).update!(refresh_token: "1//after-reconnect")
        { status: 200, body: { access_token: "ya29.x", refresh_token: "1//old-grant" }.to_json }
      end

      record.check(client: client)

      expect(GoogleCalendarConnection.find(record.id).refresh_token).to eq("1//after-reconnect")
    end

    it "marks the connection lost on invalid_grant" do
      record = create(:google_calendar_connection)
      stub_google_token_error("invalid_grant")

      expect(record.check(client: client)).to eq("lost")
      expect(GoogleCalendarConnection.find(record.id).lost_at).to be_present
    end

    it "is connected, and the new connection kept, when the user reconnects while invalid_grant is on its way" do
      record = create(:google_calendar_connection, connected_at: 1.hour.ago)
      stub_request(:post, google_token_endpoint).to_return do
        GoogleCalendarConnection.find(record.id).update!(refresh_token: "1//after-reconnect", connected_at: Time.current)
        { status: 400, body: { error: "invalid_grant" }.to_json }
      end

      expect(record.check(client: client)).to eq("connected")
      stored = GoogleCalendarConnection.find(record.id)
      expect(stored.refresh_token).to eq("1//after-reconnect")
      expect(stored.lost_at).to be_nil
    end

    it "does not call Google for a lost connection" do
      record = create(:google_calendar_connection, :lost)

      expect(record.check(client: client)).to eq("lost")
      expect(a_request(:any, google_token_endpoint)).not_to have_been_made
    end
  end
end
