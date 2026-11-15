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

  it "belongs to a video, which finds it" do
    transcript = create(:transcript)

    expect(transcript.video.transcript).to eq(transcript)
  end
end
