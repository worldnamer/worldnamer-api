require "rails_helper"

RSpec.describe Transcript, type: :model do
  let(:connection) { ActiveRecord::Base.connection }
  let(:columns) { connection.columns(:transcripts).index_by(&:name) }

  describe "table transcripts" do
    it "requires video_id and started_at, and allows the outcome, reason, lines and finish time to be null" do
      %w[video_id started_at].each { |name| expect(columns[name].null).to be(false), "expected #{name} to be NOT NULL" }
      %w[outcome reason lines finished_at].each { |name| expect(columns[name].null).to be(true), "expected #{name} to allow NULL" }
      expect(columns["lines"].sql_type).to eq("jsonb")
    end

    it "has a unique index on video_id" do
      expect(connection.index_exists?(:transcripts, :video_id, unique: true)).to be(true)
    end

    it "has a foreign key to videos that cascades on delete" do
      foreign_key = connection.foreign_keys(:transcripts).find { |fk| fk.to_table == "videos" }
      expect(foreign_key).to be_present
      expect(foreign_key.on_delete).to eq(:cascade)
    end

    it "has a check constraint that allows only the three outcomes or null" do
      video = create(:video)
      expect {
        Transcript.transaction(requires_new: true) do
          Transcript.insert_all([ { video_id: video.id, outcome: "working", started_at: Time.current } ])
        end
      }.to raise_error(ActiveRecord::StatementInvalid, /transcripts_outcome_values/)
      expect { Transcript.insert_all([ { video_id: video.id, outcome: nil, started_at: Time.current } ]) }
        .to change(Transcript, :count).by(1)
    end

    it "is deleted with its video, and with its user" do
      transcript = create(:transcript)

      expect { transcript.video.user.destroy }.to change(Transcript, :count).by(-1)
    end

    it "allows one row per video" do
      transcript = create(:transcript)

      expect { create(:transcript, video: transcript.video) }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  describe "validations" do
    it "accepts each outcome and a missing one" do
      [ nil, "done", "no_captions", "failed" ].each { |outcome| expect(build(:transcript, outcome: outcome)).to be_valid }
    end

    it "refuses any other outcome" do
      expect(build(:transcript, outcome: "working")).not_to be_valid
    end

    it "requires started_at" do
      expect(build(:transcript, started_at: nil)).not_to be_valid
    end

    it "accepts lines of text and start only" do
      expect(build(:transcript, :done)).to be_valid
      expect(build(:transcript, lines: [ { "text" => "x", "start" => 3 } ])).to be_valid
    end

    it "refuses lines that hold anything else" do
      [
        "text",
        [ "text" ],
        [ { "text" => "x" } ],
        [ { "text" => "x", "start" => "0" } ],
        [ { "text" => 5, "start" => 0 } ],
        [ { "text" => "x", "start" => 0, "duration" => 2 } ]
      ].each { |lines| expect(build(:transcript, lines: lines)).not_to be_valid, "expected #{lines.inspect} to be refused" }
    end
  end

  describe "#state" do
    it "is the stored outcome once there is one" do
      expect(build(:transcript, :done).state).to eq("done")
      expect(build(:transcript, :no_captions).state).to eq("no_captions")
      expect(build(:transcript, :failed).state).to eq("failed")
    end

    it "is working while the fetch's lease is current and waiting once it has run out" do
      expect(build(:transcript, started_at: 1.minute.ago).state).to eq("working")
      expect(build(:transcript, started_at: (Transcript::LEASE + 1.second).ago).state).to eq("waiting")
    end

    it "keeps a stored outcome whatever the age of started_at" do
      expect(build(:transcript, :done, :expired).state).to eq("done")
    end
  end

  describe ".claim" do
    let(:video) { create(:video) }

    it "inserts a row with no outcome and a lease starting now when the video has none, and returns true" do
      expect(Transcript.claim(video.id)).to be(true)

      row = Transcript.find_by!(video_id: video.id)
      expect(row.outcome).to be_nil
      expect(row.started_at).to be_within(5.seconds).of(Time.current)
      expect(row.state).to eq("working")
    end

    it "refuses a second claim while the lease is current" do
      Transcript.claim(video.id)

      expect(Transcript.claim(video.id)).to be(false)
    end

    it "takes over an unfinished row whose lease has run out, starting a new lease" do
      create(:transcript, :expired, video: video)

      expect(Transcript.claim(video.id)).to be(true)
      expect(video.transcript.reload.state).to eq("working")
      expect(Transcript.claim(video.id)).to be(false)
    end

    it "never takes a row that has an outcome, however old" do
      %i[done no_captions failed].each do |outcome|
        transcript = create(:transcript, outcome, :expired)

        expect(Transcript.claim(transcript.video_id)).to be(false)
        expect(transcript.reload.outcome).to eq(outcome.to_s)
      end
    end

    it "leaves one row per video" do
      2.times { Transcript.claim(video.id) }

      expect(Transcript.where(video_id: video.id).count).to eq(1)
    end
  end

  describe ".finish" do
    let(:video) { create(:video) }
    let(:result_class) { Transcripts::Client::Result }

    before { Transcript.claim(video.id) }

    it "stores a done outcome with its lines and a finish time" do
      lines = [ { "text" => "Hello", "start" => 0.5 } ]

      Transcript.finish(video.id, result_class.new(outcome: "done", reason: nil, lines: lines))

      row = video.transcript.reload
      expect([ row.outcome, row.reason, row.lines ]).to eq([ "done", nil, lines ])
      expect(row.finished_at).to be_present
    end

    it "stores a failure's reason and no lines, and no captions with neither" do
      Transcript.finish(video.id, result_class.new(outcome: "failed", reason: "blocked", lines: [ { "text" => "x", "start" => 1 } ]))

      row = video.transcript.reload
      expect([ row.outcome, row.reason, row.lines ]).to eq([ "failed", "blocked", nil ])
    end

    it "does not overwrite a row that already has an outcome" do
      Transcript.finish(video.id, result_class.new(outcome: "no_captions", reason: nil, lines: nil))
      Transcript.finish(video.id, result_class.new(outcome: "failed", reason: "blocked", lines: nil))

      expect(video.transcript.reload.outcome).to eq("no_captions")
    end
  end

  it "belongs to a video, which finds it" do
    transcript = create(:transcript)

    expect(transcript.video.transcript).to eq(transcript)
  end
end
