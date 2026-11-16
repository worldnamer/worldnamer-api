require "rails_helper"

RSpec.describe YouTubePlaylistCheckJob, type: :job do
  let(:user) { create(:user) }
  let!(:connection) { create(:youtube_connection, :with_playlist, user: user, refresh_token: "1//stored") }
  let(:playlist_id) { connection.playlist_id }

  def listed_page(videos)
    youtube_json({ items: videos.map { |id, title| { snippet: { title: title, resourceId: { videoId: id } } } } })
  end

  def configure_service(url: "http://transcripts.test:8080", token: "spec-transcripts-token")
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("TRANSCRIPTS_URL").and_return(url)
    allow(ENV).to receive(:[]).with("TRANSCRIPTS_TOKEN").and_return(token)
  end

  def transcript_endpoint
    "http://transcripts.test:8080/transcript"
  end

  def service_answer(body = { outcome: "no_captions" }, status: 200)
    { status: status, body: body.to_json, headers: { "Content-Type" => "application/json" } }
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

  describe "queueing the summaries" do
    before do
      stub_google_tokens
      stub_listing([])
    end

    it "queues the summarise job on every run, with no arguments" do
      configure_service

      expect { described_class.perform_now }.to have_enqueued_job(YouTubeSummariseJob).with(no_args).exactly(:once)
      expect { 2.times { described_class.perform_now } }.to have_enqueued_job(YouTubeSummariseJob).exactly(:twice)
    end

    it "queues it as the last thing a run does, after the fetching" do
      configure_service
      create(:video, user: user)
      stub_request(:post, transcript_endpoint).to_return(service_answer)
      order = []
      allow(YouTubeSummariseJob).to receive(:perform_later) { order << :queued }
      allow(Transcript).to receive(:finish).and_wrap_original { |original, *args| order << :fetched; original.call(*args) }

      described_class.perform_now

      expect(order).to eq(%i[fetched queued])
    end

    it "queues it when the listing failed, when there is no connection and when the transcript service is not configured" do
      configure_service(url: nil)
      stub_youtube_playlist_items_error(500, "backendError")

      expect { described_class.perform_now }.to have_enqueued_job(YouTubeSummariseJob).once

      connection.destroy
      expect { described_class.perform_now }.to have_enqueued_job(YouTubeSummariseJob).once
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

  describe "fetching transcripts" do
    before do
      configure_service
      stub_google_tokens
      stub_listing([])
    end

    it "fetches each recorded video and stores the outcome: done with its lines, no captions, or failed with the reason" do
      stub_listing([ [ "aaaaaaaaaaa", "Has captions" ], [ "bbbbbbbbbbb", "None" ], [ "ccccccccccc", "Broken" ] ])
      outcomes = {
        "aaaaaaaaaaa" => service_answer({ outcome: "ok", lines: [ { text: "Hi", start: 0 } ] }),
        "bbbbbbbbbbb" => service_answer({ outcome: "no_captions" }),
        "ccccccccccc" => service_answer({ outcome: "failed", reason: "blocked" }, status: 502)
      }
      outcomes.each do |id, answer|
        stub_request(:post, transcript_endpoint).with(body: { video_id: id }.to_json).to_return(answer)
      end

      described_class.perform_now

      rows = Transcript.joins(:video).order("videos.youtube_id").pluck("videos.youtube_id", :outcome, :reason, :lines)
      expect(rows).to eq([
        [ "aaaaaaaaaaa", "done", nil, [ { "text" => "Hi", "start" => 0 } ] ],
        [ "bbbbbbbbbbb", "no_captions", nil, nil ],
        [ "ccccccccccc", "failed", "blocked", nil ]
      ])
      expect(Transcript.pluck(:finished_at)).to all(be_present)
    end

    it "sends the token in the Authorization header" do
      stub_listing([ [ "aaaaaaaaaaa", "One" ] ])
      stub = stub_request(:post, transcript_endpoint).with(headers: { "Authorization" => "Bearer spec-transcripts-token" })
        .to_return(service_answer)

      described_class.perform_now

      expect(stub).to have_been_requested.once
    end

    it "fetches only the ten newest waiting videos, newest first, one after another, leaving the rest waiting" do
      12.times do |n|
        create(:video, user: user, youtube_id: "video#{n.to_s.rjust(6, "0")}", created_at: (12 - n).hours.ago)
      end
      baseline = ActiveRecord::Base.connection.open_transactions
      seen = []
      stub_request(:post, transcript_endpoint).to_return do |request|
        id = JSON.parse(request.body).fetch("video_id")
        row = Transcript.joins(:video).find_by(videos: { youtube_id: id })
        # Claimed before the call, and no transaction of the job's own is open during the slow call.
        seen << [ id, row&.outcome, ActiveRecord::Base.connection.open_transactions - baseline ]
        service_answer
      end

      described_class.perform_now

      expect(seen.map(&:first)).to eq((2..11).to_a.reverse.map { |n| "video#{n.to_s.rjust(6, "0")}" })
      expect(seen.map { |_id, outcome, transactions| [ outcome, transactions ] }.uniq).to eq([ [ nil, 0 ] ])
      expect(Transcript.count).to eq(10)
      expect(Video.where.missing(:transcript).pluck(:youtube_id)).to contain_exactly("video000000", "video000001")
    end

    it "picks the rest up on the next run, and fetches no video twice" do
      12.times { |n| create(:video, user: user, youtube_id: "video#{n.to_s.rjust(6, "0")}", created_at: (12 - n).hours.ago) }
      stub = stub_request(:post, transcript_endpoint).to_return(service_answer)

      described_class.perform_now
      described_class.perform_now
      described_class.perform_now

      expect(stub).to have_been_requested.times(12)
      expect(Transcript.pluck(:outcome)).to all(eq("no_captions"))
    end

    it "never fetches a done, no captions or failed video again, however old" do
      %i[done no_captions failed].each { |outcome| create(:transcript, outcome, :expired) }
      stub = stub_request(:post, transcript_endpoint).to_return(service_answer)

      described_class.perform_now

      expect(stub).not_to have_been_requested
    end

    it "skips a video whose fetch is in progress, and takes over one whose lease has run out" do
      working = create(:transcript, video: create(:video, user: user, youtube_id: "workingxxxx"))
      stale = create(:transcript, :expired, video: create(:video, user: user, youtube_id: "stalexxxxxx"))
      stub = stub_request(:post, transcript_endpoint).to_return(service_answer)

      described_class.perform_now

      expect(stub).to have_been_requested.once
      expect(a_request(:post, transcript_endpoint).with(body: { video_id: "stalexxxxxx" }.to_json)).to have_been_made.once
      expect(stale.reload.outcome).to eq("no_captions")
      expect(working.reload.outcome).to be_nil
    end

    it "skips a video that another run claimed after this one chose it" do
      create(:video, user: user)
      allow(Transcript).to receive(:claim).and_return(false)
      stub = stub_request(:post, transcript_endpoint).to_return(service_answer)

      described_class.perform_now

      expect(stub).not_to have_been_requested
    end

    it "leaves the videos of a user with a lost connection or none waiting" do
      lost = create(:youtube_connection, :lost, :with_playlist)
      create(:video, user: lost.user)
      create(:video, user: create(:user))
      stub = stub_request(:post, transcript_endpoint).to_return(service_answer)

      described_class.perform_now

      expect(stub).not_to have_been_requested
    end

    it "still fetches when the listing failed" do
      create(:video, user: user)
      stub_youtube_playlist_items_error(500, "backendError")
      stub = stub_request(:post, transcript_endpoint).to_return(service_answer)

      described_class.perform_now

      expect(stub).to have_been_requested.once
    end

    it "does not fetch a video of a user whose token was just rejected" do
      create(:video, user: user)
      stub_request(:post, google_token_endpoint).to_return(status: 400, body: { error: "invalid_grant" }.to_json)
      stub = stub_request(:post, transcript_endpoint).to_return(service_answer)

      described_class.perform_now

      expect(stub).not_to have_been_requested
    end

    it "stores a failure the client reports, such as an unreachable service, and goes on to the next video" do
      create(:video, user: user, youtube_id: "aaaaaaaaaaa", created_at: 2.hours.ago)
      create(:video, user: user, youtube_id: "bbbbbbbbbbb", created_at: 1.hour.ago)
      stub_request(:post, transcript_endpoint).to_raise(Errno::ECONNREFUSED).then.to_return(service_answer)

      described_class.perform_now

      expect(Transcript.joins(:video).order("videos.youtube_id").pluck("videos.youtube_id", :outcome, :reason))
        .to eq([ [ "aaaaaaaaaaa", "no_captions", nil ], [ "bbbbbbbbbbb", "failed", "unreachable" ] ])
    end

    it "goes on to the next video when one raises, logging only the class" do
      create(:video, user: user, youtube_id: "aaaaaaaaaaa", created_at: 2.hours.ago)
      create(:video, user: user, youtube_id: "bbbbbbbbbbb", created_at: 1.hour.ago)
      calls = 0
      allow_any_instance_of(Transcripts::Client).to receive(:fetch) do
        calls += 1
        raise "secret body text" if calls == 1

        Transcripts::Client::Result.new(outcome: "no_captions", reason: nil, lines: nil)
      end

      logged = request_logging { expect { described_class.perform_now }.not_to raise_error }

      expect(calls).to eq(2)
      expect(logged).to include("transcript fetch failed (RuntimeError)")
      expect(logged).not_to include("secret body text")
      # The newest video is fetched first, and is the one that raised.
      expect(Transcript.find_by(video: Video.find_by(youtube_id: "bbbbbbbbbbb")).outcome).to be_nil
      expect(Transcript.find_by(video: Video.find_by(youtube_id: "aaaaaaaaaaa")).outcome).to eq("no_captions")
    end

    it "skips the fetching with one log line when the service's address or token is missing" do
      create(:video, user: user)
      stub = stub_request(:post, /transcripts/).to_return(service_answer)

      [ { url: nil }, { url: "" }, { token: nil }, { token: "" } ].each do |missing|
        configure_service(**missing)
        logged = request_logging { described_class.perform_now }

        expect(logged.scan("transcript service is not configured").size).to eq(1)
      end
      expect(stub).not_to have_been_requested
      expect(Transcript.count).to eq(0)
    end
  end
end
