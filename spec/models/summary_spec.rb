require "rails_helper"

RSpec.describe Summary, type: :model do
  let(:connection) { ActiveRecord::Base.connection }
  let(:columns) { connection.columns(:summaries).index_by(&:name) }

  describe "table summaries" do
    it "requires video_id and started_at, and allows the outcome, reason, text, model and finish time to be null" do
      %w[video_id started_at].each { |name| expect(columns[name].null).to be(false), "expected #{name} to be NOT NULL" }
      %w[outcome reason summary_text model finished_at].each { |name| expect(columns[name].null).to be(true), "expected #{name} to allow NULL" }
    end

    it "has a unique index on video_id" do
      expect(connection.index_exists?(:summaries, :video_id, unique: true)).to be(true)
    end

    it "has a foreign key to videos that cascades on delete" do
      foreign_key = connection.foreign_keys(:summaries).find { |fk| fk.to_table == "videos" }
      expect(foreign_key).to be_present
      expect(foreign_key.on_delete).to eq(:cascade)
    end

    it "has a check constraint that allows only the three outcomes or null" do
      video = create(:video)
      expect {
        Summary.transaction(requires_new: true) do
          Summary.insert_all([ { video_id: video.id, outcome: "working", started_at: Time.current } ])
        end
      }.to raise_error(ActiveRecord::StatementInvalid, /summaries_outcome_values/)
      expect { Summary.insert_all([ { video_id: video.id, outcome: nil, started_at: Time.current } ]) }
        .to change(Summary, :count).by(1)
    end

    it "is deleted with its video, and with its user" do
      summary = create(:summary)

      expect { summary.video.user.destroy }.to change(Summary, :count).by(-1)
    end

    it "allows one row per video" do
      summary = create(:summary)

      expect { create(:summary, video: summary.video) }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  describe "validations" do
    it "accepts each outcome and a missing one" do
      [ nil, "done", "nothing_to_summarise", "failed" ].each { |outcome| expect(build(:summary, outcome: outcome)).to be_valid }
    end

    it "refuses any other outcome" do
      expect(build(:summary, outcome: "working")).not_to be_valid
    end

    it "requires started_at" do
      expect(build(:summary, started_at: nil)).not_to be_valid
    end
  end

  describe "#state" do
    it "is the stored outcome once there is one" do
      expect(build(:summary, :done).state).to eq("done")
      expect(build(:summary, :nothing_to_summarise).state).to eq("nothing_to_summarise")
      expect(build(:summary, :failed).state).to eq("failed")
    end

    it "is working while the lease is current and waiting once it has run out" do
      expect(build(:summary, started_at: 1.minute.ago).state).to eq("working")
      expect(build(:summary, started_at: (Summary::LEASE + 1.second).ago).state).to eq("waiting")
    end

    it "keeps a stored outcome whatever the age of started_at" do
      expect(build(:summary, :done, :expired).state).to eq("done")
    end
  end

  describe ".claim" do
    let(:video) { create(:video) }

    it "inserts a row with no outcome and a lease starting now when the video has none, and returns true" do
      expect(Summary.claim(video.id)).to be(true)

      row = Summary.find_by!(video_id: video.id)
      expect(row.outcome).to be_nil
      expect(row.started_at).to be_within(5.seconds).of(Time.current)
      expect(row.state).to eq("working")
    end

    it "refuses a second claim while the lease is current" do
      Summary.claim(video.id)

      expect(Summary.claim(video.id)).to be(false)
    end

    it "takes over an unfinished row whose lease has run out, starting a new lease" do
      create(:summary, :expired, video: video)

      expect(Summary.claim(video.id)).to be(true)
      expect(video.summary.reload.state).to eq("working")
      expect(Summary.claim(video.id)).to be(false)
    end

    it "never takes a row that has an outcome, however old" do
      %i[done nothing_to_summarise failed].each do |outcome|
        summary = create(:summary, outcome, :expired)

        expect(Summary.claim(summary.video_id)).to be(false)
        expect(summary.reload.outcome).to eq(outcome.to_s)
      end
    end

    it "leaves one row per video" do
      2.times { Summary.claim(video.id) }

      expect(Summary.where(video_id: video.id).count).to eq(1)
    end
  end

  describe ".finish" do
    let(:video) { create(:video) }
    # Stands in for Summaries::Client::Result: finish reads only these four values.
    let(:result_class) { Struct.new(:outcome, :reason, :text, :model) }

    before { Summary.claim(video.id) }

    it "stores a done outcome with its text, model and a finish time" do
      Summary.finish(video.id, result_class.new("done", nil, "The summary.", "some-model"))

      row = video.summary.reload
      expect([ row.outcome, row.reason, row.summary_text, row.model ]).to eq([ "done", nil, "The summary.", "some-model" ])
      expect(row.finished_at).to be_present
    end

    it "stores a failure's reason and no text or model, and nothing to summarise with neither" do
      Summary.finish(video.id, result_class.new("failed", "busy", "stray text", "stray-model"))

      row = video.summary.reload
      expect([ row.outcome, row.reason, row.summary_text, row.model ]).to eq([ "failed", "busy", nil, nil ])
    end

    it "does not overwrite a row that already has an outcome, so a second finish changes nothing" do
      Summary.finish(video.id, result_class.new("nothing_to_summarise", nil, nil, nil))
      Summary.finish(video.id, result_class.new("failed", "busy", nil, nil))

      expect(video.summary.reload.outcome).to eq("nothing_to_summarise")
    end
  end

  it "belongs to a video, which finds it" do
    summary = create(:summary)

    expect(summary.video.summary).to eq(summary)
  end
end
