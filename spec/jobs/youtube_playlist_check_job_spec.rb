require "rails_helper"

RSpec.describe YouTubePlaylistCheckJob, type: :job do
  let(:user) { create(:user) }
  let!(:connection) { create(:youtube_connection, :with_playlist, user: user, refresh_token: "1//stored") }
  let(:playlist_id) { connection.playlist_id }

  def listed_page(videos)
    youtube_json({ items: videos.map { |id, title| { snippet: { title: title, resourceId: { videoId: id } } } } })
  end

  def stub_listing(videos, playlist: playlist_id)
    stub_request(:get, YouTubeDataHelpers::YOUTUBE_PLAYLIST_ITEMS_ENDPOINT)
      .with(query: hash_including("playlistId" => playlist)).to_return(listed_page(videos))
  end

  describe "schedule and overlap" do
    it "is a recurring task every 15 minutes in production, and takes no arguments" do
      tasks = YAML.safe_load(ERB.new(Rails.root.join("config/recurring.yml").read).result, aliases: true)
      expect(tasks.fetch("production").fetch("youtube_playlist_check"))
        .to eq("class" => "YouTubePlaylistCheckJob", "schedule" => "every 15 minutes")
      expect(described_class.instance_method(:perform).arity).to eq(0)
    end

    it "lets one run at a time, with a semaphore that expires after 30 minutes" do
      expect(described_class.concurrency_limit).to eq(1)
      expect(described_class.concurrency_duration).to eq(30.minutes)
      expect(described_class.concurrency_key).to eq("youtube_playlist_check")
    end
  end

  describe "recording videos" do
    before { stub_google_tokens(access_token: "ya29.job-access") }

    it "records each video in the chosen playlist for its user with the title it has now" do
      stub = stub_listing([ [ "aaaaaaaaaaa", "First" ], [ "bbbbbbbbbbb", "Second" ] ])

      described_class.perform_now

      expect(user.videos.order(:id).pluck(:youtube_id, :title)).to eq([ [ "aaaaaaaaaaa", "First" ], [ "bbbbbbbbbbb", "Second" ] ])
      expect(stub).to have_been_requested.once
    end

    it "lists with the token minted from the stored refresh token, in a header" do
      stub = stub_request(:get, YouTubeDataHelpers::YOUTUBE_PLAYLIST_ITEMS_ENDPOINT)
        .with(query: hash_including({}), headers: { "Authorization" => "Bearer ya29.job-access" })
        .to_return(listed_page([ [ "aaaaaaaaaaa", "First" ] ]))

      described_class.perform_now

      expect(stub).to have_been_requested.once
    end

    it "records nothing new on a second run, and keeps the first title it saw" do
      stub_listing([ [ "aaaaaaaaaaa", "First" ] ])
      described_class.perform_now
      stub_listing([ [ "aaaaaaaaaaa", "Renamed" ], [ "bbbbbbbbbbb", "New" ] ])

      expect { described_class.perform_now }.to change(Video, :count).by(1)

      expect(user.videos.order(:id).pluck(:youtube_id, :title)).to eq([ [ "aaaaaaaaaaa", "First" ], [ "bbbbbbbbbbb", "New" ] ])
    end

    it "keeps the row of a video that has left the playlist" do
      stub_listing([ [ "aaaaaaaaaaa", "First" ] ])
      described_class.perform_now
      stub_listing([])

      expect { described_class.perform_now }.not_to change(Video, :count)
    end

    it "records a video listed twice once" do
      stub_listing([ [ "aaaaaaaaaaa", "First" ], [ "aaaaaaaaaaa", "First again" ] ])

      expect { described_class.perform_now }.to change(Video, :count).by(1)
    end

    it "records for each user from their own playlist" do
      other = create(:youtube_connection, :with_playlist, user: create(:user))
      stub_listing([ [ "aaaaaaaaaaa", "Mine" ] ], playlist: playlist_id)
      stub_listing([ [ "bbbbbbbbbbb", "Theirs" ] ], playlist: other.playlist_id)

      described_class.perform_now

      expect(user.videos.pluck(:youtube_id)).to eq([ "aaaaaaaaaaa" ])
      expect(other.user.videos.pluck(:youtube_id)).to eq([ "bbbbbbbbbbb" ])
    end
  end

  describe "when there is nothing to check" do
    it "does nothing, calls neither Google endpoint and does not fail without a connection, with a lost one, or with no playlist" do
      connection.destroy
      create(:youtube_connection, :lost, :with_playlist)
      create(:youtube_connection)

      expect { described_class.perform_now }.not_to raise_error

      expect(a_request(:any, /google/)).not_to have_been_made
      expect(Video.count).to eq(0)
    end
  end

  describe "when Google fails" do
    it "marks the connection lost on a rejected token and skips that user, while others are still checked" do
      other = create(:youtube_connection, :with_playlist, user: create(:user), refresh_token: "1//other")
      stub_request(:post, google_token_endpoint).with(body: hash_including("refresh_token" => "1//stored"))
        .to_return(status: 400, body: { error: "invalid_grant" }.to_json)
      stub_request(:post, google_token_endpoint).with(body: hash_including("refresh_token" => "1//other"))
        .to_return(status: 200, body: { access_token: "ya29.other" }.to_json)
      stub_listing([ [ "bbbbbbbbbbb", "Theirs" ] ], playlist: other.playlist_id)

      described_class.perform_now

      expect(connection.reload.lost_at).to be_present
      expect(connection.refresh_token).to be_nil
      expect(user.videos.count).to eq(0)
      expect(other.user.videos.pluck(:youtube_id)).to eq([ "bbbbbbbbbbb" ])
    end

    it "logs the error class and status only, records nothing and does not fail when YouTube answers an error" do
      stub_google_tokens
      stub_youtube_playlist_items_error(403, "quotaExceeded")

      logged = request_logging { expect { described_class.perform_now }.not_to raise_error }

      expect(Video.count).to eq(0)
      expect(logged).to include("YouTube playlist check: YouTube::DataClient::Error status=403")
      expect(logged).not_to include("quotaExceeded")
      expect(connection.reload.lost_at).to be_nil
    end

    it "skips the user and does not fail when Google's token endpoint is down" do
      stub_google_token_server_error

      expect { described_class.perform_now }.not_to raise_error

      expect(Video.count).to eq(0)
      expect(connection.reload.lost_at).to be_nil
    end
  end
end
