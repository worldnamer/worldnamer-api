require "rails_helper"

RSpec.describe YouTubeSummariseJob, type: :job do
  let(:user) { create(:user) }
  let!(:connection) { create(:youtube_connection, :with_playlist, user: user) }
  let(:endpoint) { "http://transcripts.test:8080/summary" }
  let(:wordy) { Array.new(30) { |n| "word#{n}" }.join(" ") }

  def configure_service(url: "http://transcripts.test:8080", token: "spec-transcripts-token")
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("TRANSCRIPTS_URL").and_return(url)
    allow(ENV).to receive(:[]).with("TRANSCRIPTS_TOKEN").and_return(token)
  end

  def service_answer(body = nil, status: 200)
    body ||= { outcome: "ok", summary: "A summary.", model: "spec-model", tokens_in: 10, tokens_out: 5 }
    { status: status, body: body.to_json, headers: { "Content-Type" => "application/json" } }
  end

  # A video of the user's with a done transcript holding the given text as one line.
  def video_with_transcript(youtube_id: nil, text: wordy, created_at: Time.current, owner: user)
    attributes = { user: owner, created_at: created_at }
    attributes[:youtube_id] = youtube_id if youtube_id
    video = create(:video, **attributes)
    create(:transcript, :done, video: video, lines: [ { "text" => text, "start" => 0 } ])
    video
  end

  before { configure_service }

  describe "concurrency" do
    it "lets one run at a time under its own key, with a semaphore that expires after 40 minutes, and discards a second" do
      expect(described_class.concurrency_limit).to eq(1)
      expect(described_class.concurrency_duration).to eq(40.minutes)
      expect(described_class.concurrency_key).to eq("youtube_summarise")
      expect(described_class.concurrency_on_conflict).to eq(:discard)
    end

    it "takes no arguments and is not a recurring task, because the check job queues it" do
      tasks = YAML.safe_load(ERB.new(Rails.root.join("config/recurring.yml").read).result, aliases: true)
      expect(tasks.values.flat_map(&:values).map { |task| task["class"] }).not_to include("YouTubeSummariseJob")
      expect(described_class.instance_method(:perform).arity).to eq(0)
    end
  end

  describe "summarising" do
    it "stores a done summary with its text and model, and sends the bracket-stripped text with the token in the header" do
      video = video_with_transcript(text: "[Music] #{wordy} [Applause]")
      stub = stub_request(:post, endpoint)
        .with(body: { text: wordy }.to_json, headers: { "Authorization" => "Bearer spec-transcripts-token" })
        .to_return(service_answer)

      described_class.perform_now

      expect(stub).to have_been_requested.once
      row = video.summary
      expect([ row.outcome, row.reason, row.summary_text, row.model ]).to eq([ "done", nil, "A summary.", "spec-model" ])
      expect(row.finished_at).to be_present
    end

    it "stores a failure with the client's reason" do
      video = video_with_transcript
      stub_request(:post, endpoint).to_return(service_answer({ outcome: "failed", reason: "timed_out" }, status: 502))

      described_class.perform_now

      expect(video.summary.slice(:outcome, :reason, :summary_text)).to eq("outcome" => "failed", "reason" => "timed_out", "summary_text" => nil)
    end

    it "marks a transcript of too few words nothing to summarise, with no call" do
      video = video_with_transcript(text: "[Music] [Music] only four words here")
      stub = stub_request(:post, endpoint).to_return(service_answer)

      described_class.perform_now

      expect(stub).not_to have_been_requested
      expect(captured_spans.map(&:name)).not_to include("summaries.generate")
      expect(video.summary.reload.outcome).to eq("nothing_to_summarise")
      expect(video.summary.finished_at).to be_present
    end

    it "claims the video before the call, and holds no transaction of its own during it" do
      video = video_with_transcript
      baseline = ActiveRecord::Base.connection.open_transactions
      seen = nil
      stub_request(:post, endpoint).to_return do
        row = Summary.find_by(video_id: video.id)
        seen = [ row&.outcome, row&.state, ActiveRecord::Base.connection.open_transactions - baseline ]
        service_answer
      end

      described_class.perform_now

      expect(seen).to eq([ nil, "working", 0 ])
    end
  end

  describe "which videos it takes" do
    it "takes only the ten newest waiting videos, newest first, one after another, leaving the rest" do
      12.times { |n| video_with_transcript(youtube_id: "video#{n.to_s.rjust(6, "0")}", created_at: (12 - n).hours.ago) }
      calls = 0
      stub_request(:post, endpoint).to_return { calls += 1; service_answer }

      described_class.perform_now

      expect(calls).to eq(10)
      expect(Summary.count).to eq(10)
      expect(Video.where.missing(:summary).pluck(:youtube_id)).to contain_exactly("video000000", "video000001")
    end

    it "orders by creation time, then by id, newest first" do
      tie = 2.hours.ago.change(usec: 0)
      first = video_with_transcript(created_at: tie)
      second = video_with_transcript(created_at: tie)
      newest = video_with_transcript(created_at: 1.hour.ago)
      oldest = video_with_transcript(created_at: 5.hours.ago)
      stub_request(:post, endpoint).to_return(service_answer)

      described_class.perform_now

      expect(Summary.order(:id).pluck(:video_id)).to eq([ newest, second, first, oldest ].map(&:id))
    end

    it "picks the rest up on the next run, and summarises no video twice" do
      12.times { |n| video_with_transcript(youtube_id: "video#{n.to_s.rjust(6, "0")}", created_at: (12 - n).hours.ago) }
      stub = stub_request(:post, endpoint).to_return(service_answer)

      3.times { described_class.perform_now }

      expect(stub).to have_been_requested.times(12)
    end

    it "never takes a video that is done, nothing to summarise or failed, however old" do
      %i[done nothing_to_summarise failed].each { |outcome| create(:summary, outcome, :expired, video: video_with_transcript) }
      stub = stub_request(:post, endpoint).to_return(service_answer)

      described_class.perform_now

      expect(stub).not_to have_been_requested
    end

    it "skips a video whose summary lease is current, and takes over one whose lease has run out" do
      create(:summary, video: video_with_transcript)
      stale = create(:summary, :expired, video: video_with_transcript)
      stub = stub_request(:post, endpoint).to_return(service_answer)

      described_class.perform_now

      expect(stub).to have_been_requested.once
      expect(stale.reload.outcome).to eq("done")
    end

    it "skips a video that another run claimed after this one chose it" do
      video_with_transcript
      allow(Summary).to receive(:claim).and_return(false)
      stub = stub_request(:post, endpoint).to_return(service_answer)

      described_class.perform_now

      expect(stub).not_to have_been_requested
    end

    it "takes only videos whose transcript is done" do
      create(:transcript, :no_captions, video: create(:video, user: user))
      create(:transcript, :failed, video: create(:video, user: user))
      create(:transcript, video: create(:video, user: user))
      create(:video, user: user)
      stub = stub_request(:post, endpoint).to_return(service_answer)

      described_class.perform_now

      expect(stub).not_to have_been_requested
      expect(Summary.count).to eq(0)
    end

    it "leaves the videos of a user whose connection is lost or gone" do
      lost = create(:youtube_connection, :lost, :with_playlist)
      video_with_transcript(owner: lost.user)
      video_with_transcript(owner: create(:user))
      stub = stub_request(:post, endpoint).to_return(service_answer)

      described_class.perform_now

      expect(stub).not_to have_been_requested
    end

    it "reads only the ids of the waiting videos, and loads each video's transcript lines separately" do
      3.times { video_with_transcript }
      stub_request(:post, endpoint).to_return(service_answer)
      line_reads = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        line_reads << payload[:sql] if payload[:sql].match?(/SELECT "transcripts"."lines"/)
      end

      described_class.perform_now
      ActiveSupport::Notifications.unsubscribe(subscriber)

      expect(line_reads.size).to eq(3)
    end
  end

  describe "when a call fails" do
    it "stores a failure the client reports, such as an unreachable service, and goes on to the next video" do
      older = video_with_transcript(created_at: 2.hours.ago)
      newer = video_with_transcript(created_at: 1.hour.ago)
      stub_request(:post, endpoint).to_raise(Errno::ECONNREFUSED).then.to_return(service_answer)

      described_class.perform_now

      expect(newer.summary.slice(:outcome, :reason)).to eq("outcome" => "failed", "reason" => "unreachable")
      expect(older.summary.outcome).to eq("done")
    end

    it "goes on to the next video when one raises, logging only the class" do
      older = video_with_transcript(created_at: 2.hours.ago)
      newer = video_with_transcript(created_at: 1.hour.ago)
      calls = 0
      allow_any_instance_of(Summaries::Client).to receive(:summarise) do
        calls += 1
        raise "secret body text" if calls == 1

        Summaries::Client::Result.new(outcome: "done", reason: nil, text: "ok", model: "m", tokens_in: 1, tokens_out: 1)
      end

      logged = request_logging { expect { described_class.perform_now }.not_to raise_error }

      expect(calls).to eq(2)
      expect(logged).to include("summary failed (RuntimeError)")
      expect(logged).not_to include("secret body text")
      # The newest video is first, and is the one that raised: it keeps its claim and waits out the lease.
      expect(newer.summary.outcome).to be_nil
      expect(older.summary.outcome).to eq("done")
    end
  end

  describe "when the service is not configured" do
    it "logs one line and does nothing, whichever value is missing" do
      video_with_transcript
      stub = stub_request(:post, /transcripts/).to_return(service_answer)

      [ { url: nil }, { url: "" }, { token: nil }, { token: "" } ].each do |missing|
        configure_service(**missing)
        logged = request_logging { described_class.perform_now }

        expect(logged.scan("summary service is not configured").size).to eq(1)
      end
      expect(stub).not_to have_been_requested
      expect(Summary.count).to eq(0)
    end
  end
end
