require "rails_helper"

# The transcript service's bearer token, a transcript's text and a video's title must never reach the Rails log,
# OpenTelemetry spans or Sentry events while the playlist check fetches a transcript, and the transcript's text is
# stored in the database only. Every check first asserts that the fetch really was logged, traced and stored.
RSpec.describe "Leak checks on fetching a transcript", type: :job do
  let(:service_token) { "SENTINEL-transcripts-bearer-7c1e-do-not-leak" }
  let(:line_text) { "SENTINEL-transcript-line-text-92ab-do-not-leak" }
  let(:video_title) { "SENTINEL-video-title-4d08-do-not-leak" }
  let(:google_access_token) { "ya29.SENTINEL-transcripts-access-31fa-do-not-leak" }
  let(:secrets) { [ service_token, line_text ] }
  let!(:connection) { create(:youtube_connection, :with_playlist, refresh_token: "1//SENTINEL-transcripts-refresh-6b52") }
  let!(:video) { create(:video, user: connection.user, title: video_title) }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("TRANSCRIPTS_URL").and_return("http://transcripts.test:8080")
    allow(ENV).to receive(:[]).with("TRANSCRIPTS_TOKEN").and_return(service_token)
    stub_google_tokens(access_token: google_access_token)
    stub_request(:get, YouTubeDataHelpers::YOUTUBE_PLAYLIST_ITEMS_ENDPOINT).with(query: hash_including({}))
      .to_return(youtube_json({ items: [] }))
    TelemetryHelpers.reset
  end

  def stub_transcript(answer)
    stub_request(:post, "http://transcripts.test:8080/transcript")
      .with(headers: { "Authorization" => "Bearer #{service_token}" }).to_return(answer)
  end

  def ok_answer
    { status: 200, body: { outcome: "ok", lines: [ { text: line_text, start: 0.5 } ] }.to_json,
      headers: { "Content-Type" => "application/json" } }
  end

  it "keeps the token and the transcript text out of the Rails log" do
    stub = stub_transcript(ok_answer)

    log = request_logging { YouTubePlaylistCheckJob.perform_now }

    expect(stub).to have_been_requested.once
    expect(log).to include("transcripts") # the fetch's own database statements were logged
    expect(video.transcript.reload.lines).to eq([ { "text" => line_text, "start" => 0.5 } ])
    expect_none_of(secrets, log)
  end

  it "keeps them out of the spans" do
    stub_transcript(ok_answer)

    YouTubePlaylistCheckJob.perform_now

    dump = dump_spans
    expect(dump).to include("transcripts.fetch")
    expect_none_of([ *secrets, video_title, video.youtube_id ], dump)
  end

  it "keeps them out of the log, the spans and Sentry when the fetch raises an error quoting them" do
    stub_transcript(ok_answer)
    allow_any_instance_of(Transcripts::Client).to receive(:fetch).and_wrap_original do |original, *args|
      original.call(*args)
      raise "forced #{service_token} #{line_text}"
    end

    # The job rescues the error and logs its class only, so the message reaches neither the log nor Sentry.
    log = request_logging { YouTubePlaylistCheckJob.perform_now }

    expect(log).to include("transcript fetch failed (RuntimeError)")
    expect_none_of(secrets, log)
    expect_none_of(secrets, dump_sentry_events)
    expect_none_of(secrets, dump_spans)
  end

  it "keeps the token out of every failure the client can store" do
    [
      { status: 502, body: { outcome: "failed", reason: service_token }.to_json },
      { status: 401, body: { error: service_token }.to_json },
      { status: 500, body: "#{service_token} #{line_text}" },
      { status: 200, body: "not json #{service_token}" }
    ].each do |answer|
      Transcript.delete_all
      stub_transcript(answer)

      log = request_logging { YouTubePlaylistCheckJob.perform_now }

      row = video.transcript
      expect(row.outcome).to eq("failed")
      expect_none_of(secrets, [ row.reason, row.lines.inspect, log, dump_spans, dump_sentry_events ].join("\n"))
    end
  end
end
