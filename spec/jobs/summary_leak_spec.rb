require "rails_helper"

# The summary service's bearer token, a transcript's text, the summary the service returns and a video's title must
# never reach the Rails log, OpenTelemetry spans or Sentry events while a summary is made. The transcript text and the
# summary text are stored in the database only. Every check first asserts that the summary really was logged and stored.
RSpec.describe "Leak checks on summarising a transcript", type: :job do
  let(:service_token) { "SENTINEL-summary-bearer-5e2a-do-not-leak" }
  let(:transcript_text) { "SENTINEL-transcript-text-71cd-do-not-leak #{Array.new(30) { |n| "filler#{n}" }.join(" ")}" }
  let(:summary_text) { "SENTINEL-summary-text-c40b-do-not-leak" }
  let(:video_title) { "SENTINEL-video-title-8f13-do-not-leak" }
  let(:secrets) { [ service_token, transcript_text, summary_text ] }
  let!(:connection) { create(:youtube_connection, :with_playlist) }
  let!(:video) { create(:video, user: connection.user, title: video_title) }
  let(:endpoint) { "http://transcripts.test:8080/summary" }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("TRANSCRIPTS_URL").and_return("http://transcripts.test:8080")
    allow(ENV).to receive(:[]).with("TRANSCRIPTS_TOKEN").and_return(service_token)
    create(:transcript, :done, video: video, lines: [ { "text" => transcript_text, "start" => 0 } ])
    TelemetryHelpers.reset
  end

  def stub_summary(answer)
    stub_request(:post, endpoint).with(headers: { "Authorization" => "Bearer #{service_token}" }).to_return(answer)
  end

  def ok_answer
    { status: 200, headers: { "Content-Type" => "application/json" },
      body: { outcome: "ok", summary: summary_text, model: "spec-model", tokens_in: 100, tokens_out: 20 }.to_json }
  end

  it "keeps the token and the texts out of the Rails log, including the statements that store the summary" do
    stub = stub_summary(ok_answer)

    log = request_logging { YouTubeSummariseJob.perform_now }

    expect(stub).to have_been_requested.once
    expect(log).to include("UPDATE \"summaries\"") # the finish's own statement was logged, with the text filtered
    expect(log).to match(/\["summary_text", "\[FILTERED\]"]/)
    expect(video.summary.reload.summary_text).to eq(summary_text)
    expect_none_of([ *secrets, video_title ], log)
  end

  it "keeps them out of the spans and Sentry" do
    stub_summary(ok_answer)

    YouTubeSummariseJob.perform_now

    expect(video.summary.reload.outcome).to eq("done")
    expect_none_of([ *secrets, video_title, video.youtube_id ], dump_spans)
    expect_none_of(secrets, dump_sentry_events)
  end

  it "keeps them out of the log, the spans and Sentry when the call raises an error quoting them" do
    stub_summary(ok_answer)
    allow_any_instance_of(Summaries::Client).to receive(:summarise).and_wrap_original do |original, *args|
      original.call(*args)
      raise "forced #{service_token} #{transcript_text} #{summary_text}"
    end

    # The job rescues the error and logs its class only, so the message reaches neither the log nor Sentry.
    log = request_logging { YouTubeSummariseJob.perform_now }

    expect(log).to include("summary failed (RuntimeError)")
    expect_none_of(secrets, log)
    expect_none_of(secrets, dump_sentry_events)
    expect_none_of(secrets, dump_spans)
  end

  it "keeps the token and the text out of every failure the client can store" do
    [
      { status: 502, body: { outcome: "failed", reason: service_token }.to_json },
      { status: 502, body: { outcome: "failed", reason: summary_text }.to_json },
      { status: 422, body: { outcome: "failed", reason: transcript_text }.to_json },
      { status: 401, body: { error: service_token }.to_json },
      { status: 500, body: "#{service_token} #{summary_text}" },
      { status: 200, body: "not json #{service_token} #{summary_text}" },
      { status: 200, body: { summary: summary_text, model: service_token, tokens_in: "x", tokens_out: 1 }.to_json }
    ].each do |answer|
      Summary.delete_all
      stub_summary(answer)

      log = request_logging { YouTubeSummariseJob.perform_now }

      row = video.reload.summary
      expect(row.outcome).to eq("failed")
      expect_none_of(secrets, [ row.reason, row.summary_text.inspect, row.model.inspect, log, dump_spans, dump_sentry_events ].join("\n"))
    end
  end
end
