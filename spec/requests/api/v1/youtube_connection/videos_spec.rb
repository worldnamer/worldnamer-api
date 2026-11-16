require "rails_helper"

RSpec.describe "GET /api/v1/youtube_connection/videos", type: :request do
  let!(:user) { create(:user, username: "john") }
  let(:path) { "/api/v1/youtube_connection/videos" }

  def token_for(account = user)
    login(username: account.username)
    response.parsed_body.fetch("access_token")
  end

  def list(account = user)
    get path, headers: bearer(token_for(account))
  end

  def videos
    response.parsed_body.fetch("videos")
  end

  it "returns 401 unauthenticated without a valid token" do
    get path
    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body).to match(expected_unauthenticated_body)
  end

  it "is an empty list when the user has no videos, whether or not they have a YouTube connection" do
    list

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq("videos" => [])
  end

  it "is never cached, and calls neither Google nor the transcript service" do
    create(:youtube_connection, :with_playlist, user: user)
    create(:video, user: user)

    list

    expect(response.headers["Cache-Control"]).to eq("no-store")
    expect(a_request(:any, /./)).not_to have_been_made
  end

  it "gives each video's id, title, state, reason and summary" do
    create(:video, user: user, youtube_id: "aaaaaaaaaaa", title: "Plain")

    list

    expect(videos).to eq([ { "youtube_id" => "aaaaaaaaaaa", "title" => "Plain", "state" => "waiting", "reason" => nil, "summary" => nil } ])
  end

  describe "state" do
    def state_of(youtube_id)
      videos.find { |video| video["youtube_id"] == youtube_id }.slice("state", "reason")
    end

    before do
      create(:video, user: user, youtube_id: "waitingnone")
      create(:transcript, :expired, video: create(:video, user: user, youtube_id: "waitingold1"))
      create(:transcript, video: create(:video, user: user, youtube_id: "workingnow1"))
      create(:transcript, :done, video: create(:video, user: user, youtube_id: "donedonedo1"))
      create(:transcript, :no_captions, video: create(:video, user: user, youtube_id: "nocaptions1"))
      create(:transcript, :failed, reason: "proxy_refused", video: create(:video, user: user, youtube_id: "failedfail1"))
      create(:transcript, :done, :expired, video: create(:video, user: user, youtube_id: "doneolddon1"))
    end

    it "is waiting with no transcript row, or an unfinished one whose lease has run out; working while the lease is current" do
      list

      expect(state_of("waitingnone")).to eq("state" => "waiting", "reason" => nil)
      expect(state_of("waitingold1")).to eq("state" => "waiting", "reason" => nil)
      expect(state_of("workingnow1")).to eq("state" => "working", "reason" => nil)
    end

    it "is the stored outcome once there is one, however old, with a reason only for a failure" do
      list

      expect(state_of("donedonedo1")).to eq("state" => "done", "reason" => nil)
      expect(state_of("doneolddon1")).to eq("state" => "done", "reason" => nil)
      expect(state_of("nocaptions1")).to eq("state" => "no_captions", "reason" => nil)
      expect(state_of("failedfail1")).to eq("state" => "failed", "reason" => "proxy_refused")
    end

    it "agrees with Transcript#state for every video" do
      list

      Video.includes(:transcript).where(user: user).each do |video|
        expect(state_of(video.youtube_id)["state"]).to eq(video.transcript&.state || "waiting")
      end
    end
  end

  describe "summary" do
    def summary_of(youtube_id)
      videos.find { |video| video["youtube_id"] == youtube_id }["summary"]
    end

    def video_with(transcript_trait, youtube_id)
      video = create(:video, user: user, youtube_id: youtube_id)
      create(:transcript, transcript_trait, video: video)
      video
    end

    it "is null unless the transcript is done" do
      create(:video, user: user, youtube_id: "notranscrip")
      create(:transcript, video: create(:video, user: user, youtube_id: "tworking111"))
      create(:transcript, :no_captions, video: create(:video, user: user, youtube_id: "nocaptions1"))
      create(:transcript, :failed, video: create(:video, user: user, youtube_id: "failedtran1"))
      # Even a stray summary row does not show before the transcript is done.
      create(:summary, :done, video: Video.find_by!(youtube_id: "nocaptions1"))

      list

      %w[notranscrip tworking111 nocaptions1 failedtran1].each { |id| expect(summary_of(id)).to be_nil, id }
    end

    it "is waiting for a done transcript with no summary row, or one whose lease has run out, and working while it is current" do
      video_with(:done, "sumnorow111")
      create(:summary, :expired, video: video_with(:done, "sumexpired1"))
      create(:summary, video: video_with(:done, "sumworking1"))

      list

      expect(summary_of("sumnorow111")).to eq("state" => "waiting")
      expect(summary_of("sumexpired1")).to eq("state" => "waiting")
      expect(summary_of("sumworking1")).to eq("state" => "working")
    end

    it "is the stored outcome, with the text only when done and the reason only when failed, and never the model" do
      create(:summary, :done, summary_text: "The <b>summary</b>.", model: "SENTINEL-model", video: video_with(:done, "sumdonedon1"))
      create(:summary, :nothing_to_summarise, video: video_with(:done, "sumnothing1"))
      create(:summary, :failed, reason: "busy", video: video_with(:done, "sumfailed11"))

      list

      expect(summary_of("sumdonedon1")).to eq("state" => "done", "text" => "The <b>summary</b>.")
      expect(summary_of("sumnothing1")).to eq("state" => "nothing_to_summarise")
      expect(summary_of("sumfailed11")).to eq("state" => "failed", "reason" => "busy")
      expect(response.body).not_to include("SENTINEL-model")
    end

    it "gives only the signed-in user's summaries" do
      create(:summary, :done, summary_text: "Mine.", video: video_with(:done, "mineminemin"))
      other = create(:video, user: create(:user), youtube_id: "notminenotm")
      create(:transcript, :done, video: other)
      create(:summary, :done, summary_text: "SENTINEL-theirs", video: other)

      list

      expect(videos.pluck("youtube_id")).to eq([ "mineminemin" ])
      expect(response.body).not_to include("SENTINEL-theirs")
    end

    it "reads every video's transcript and summary in one query" do
      3.times { |n| create(:summary, :done, video: video_with(:done, "manyvideo#{n}1")) }
      bearer_headers = bearer(token_for)
      statements = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        statements << payload[:sql] if payload[:sql].match?(/FROM "videos"|FROM "summaries"/)
      end

      get path, headers: bearer_headers
      ActiveSupport::Notifications.unsubscribe(subscriber)

      expect(statements.size).to eq(1)
      expect(statements.first).to match(/LEFT OUTER JOIN "summaries"/)
    end
  end

  it "lists the newest first, by when the video was first recorded, with the later id first on a tie" do
    create(:video, user: user, youtube_id: "oldestvideo", created_at: 30.days.ago)
    tie = 10.days.ago.change(usec: 0)
    create(:video, user: user, youtube_id: "tiefirstone", created_at: tie)
    create(:video, user: user, youtube_id: "tiesecondon", created_at: tie)
    create(:video, user: user, youtube_id: "newestvideo", created_at: 1.hour.ago)

    list

    expect(videos.pluck("youtube_id")).to eq(%w[newestvideo tiesecondon tiefirstone oldestvideo])
  end

  it "lists only the caller's own videos" do
    create(:video, user: user, youtube_id: "mineminemin")
    create(:video, user: create(:user), youtube_id: "notminenotm")

    list

    expect(videos.pluck("youtube_id")).to eq([ "mineminemin" ])
  end

  it "reads in one query that never selects the transcript text, and never sends the text" do
    video = create(:video, user: user)
    create(:transcript, :done, video: video, lines: [ { "text" => "SENTINEL-transcript-text", "start" => 1 } ])
    bearer_headers = bearer(token_for)
    statements = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      statements << payload[:sql] if payload[:sql].match?(/FROM "videos"/)
    end

    get path, headers: bearer_headers
    ActiveSupport::Notifications.unsubscribe(subscriber)

    expect(statements.size).to eq(1)
    expect(statements.first).to match(/LEFT OUTER JOIN "transcripts"/)
    expect(statements.first).not_to include("lines")
    expect(response.body).not_to include("SENTINEL-transcript-text")
    expect(videos.first.keys).to contain_exactly("youtube_id", "title", "state", "reason", "summary")
  end

  it "renders a title as text, whatever it holds" do
    create(:video, user: user, title: "<script>alert(1)</script> \"quoted\"")

    list

    expect(videos.first["title"]).to eq("<script>alert(1)</script> \"quoted\"")
    expect(response.media_type).to eq("application/json")
  end
end
