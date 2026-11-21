require "rails_helper"

RSpec.describe "POST /api/v1/youtube_connection/videos/:youtube_id/requeue", type: :request do
  let!(:user) { create(:user, username: "john") }

  def token_for(account = user)
    login(username: account.username)
    response.parsed_body.fetch("access_token")
  end

  def path_for(youtube_id)
    "/api/v1/youtube_connection/videos/#{youtube_id}/requeue"
  end

  def requeue(youtube_id, headers = bearer(token_for))
    post path_for(youtube_id), headers: headers
  end

  def expect_not_found
    expect(response).to have_http_status(:not_found)
    expect(response.parsed_body).to eq("error" => { "code" => "not_found", "message" => "Not found." })
  end

  it "returns 401 unauthenticated on requeue without a valid token" do
    requeue("aaaaaaaaaaa", {})

    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body).to match(expected_unauthenticated_body)
  end

  it "is never cached and calls no outside service" do
    video = create(:video, user: user, youtube_id: "failedfail1")
    create(:transcript, :failed, video: video)

    requeue("failedfail1")

    expect(response.headers["Cache-Control"]).to eq("no-store")
    expect(a_request(:any, /./)).not_to have_been_made
  end

  it "resets a failed transcript, answers 202 with no body and queues only the playlist check" do
    video = create(:video, user: user, youtube_id: "failedfail1")
    create(:transcript, :failed, video: video)
    headers = bearer(token_for)

    expect { requeue("failedfail1", headers) }
      .to have_enqueued_job(YouTubePlaylistCheckJob).with(no_args).exactly(:once)
    expect(ActiveJob::Base.queue_adapter.enqueued_jobs.pluck(:job)).not_to include(YouTubeSummariseJob)
    expect(response).to have_http_status(:accepted)
    expect(response.body).to be_empty
    expect(Transcript.where(video: video)).to be_empty
  end

  it "answers 200 with no body and queues nothing for a video that is waiting or working" do
    create(:video, user: user, youtube_id: "waitingnone")
    working = create(:video, user: user, youtube_id: "workingnow1")
    create(:transcript, video: working)
    waiting_headers = bearer(token_for)
    working_headers = bearer(token_for)

    expect do
      requeue("waitingnone", waiting_headers)
      expect(response).to have_http_status(:ok)
      expect(response.body).to be_empty

      requeue("workingnow1", working_headers)
      expect(response).to have_http_status(:ok)
      expect(response.body).to be_empty
    end.not_to have_enqueued_job
  end

  it "resets a finished summary, keeps the transcript, answers 202 and queues only the summarise job" do
    video = create(:video, user: user, youtube_id: "sumdonedon1")
    create(:transcript, :done, video: video)
    create(:summary, :done, video: video)
    headers = bearer(token_for)

    expect { requeue("sumdonedon1", headers) }
      .to have_enqueued_job(YouTubeSummariseJob).with(no_args).exactly(:once)
    expect(ActiveJob::Base.queue_adapter.enqueued_jobs.pluck(:job)).not_to include(YouTubePlaylistCheckJob)
    expect(response).to have_http_status(:accepted)
    expect(response.body).to be_empty
    expect(Summary.where(video: video)).to be_empty
    expect(Transcript.where(video: video).pluck(:outcome)).to eq([ "done" ])
  end

  it "answers the same 404 for another user's video, an unknown id and a malformed id, and changes nothing" do
    other = create(:user, username: "other")
    video = create(:video, user: other, youtube_id: "notminenotm")
    create(:transcript, :failed, video: video)
    headers = bearer(token_for)

    expect do
      %w[notminenotm nosuchvideo short bad.id.here].each do |youtube_id|
        requeue(youtube_id, headers)
        expect_not_found
      end
    end.not_to have_enqueued_job

    expect(Transcript.where(video: video)).to exist
  end

  it "writes no transcript text, summary text or token to the log" do
    video = create(:video, user: user, youtube_id: "leakcheck11")
    create(:transcript, :done, video: video, lines: [ { "text" => "SENTINEL-transcript-text", "start" => 1 } ])
    create(:summary, :done, summary_text: "SENTINEL-summary-text", video: video)
    token = token_for

    logged = request_logging { requeue("leakcheck11", bearer(token)) }

    expect(logged).not_to be_empty
    expect_none_of([ "SENTINEL-transcript-text", "SENTINEL-summary-text", token ], logged)
  end
end
