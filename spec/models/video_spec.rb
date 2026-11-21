require "rails_helper"

RSpec.describe Video, type: :model do
  let(:connection) { ActiveRecord::Base.connection }
  let(:columns) { connection.columns(:videos).index_by(&:name) }

  describe "table videos" do
    it "requires user_id, youtube_id and title, and gives title an empty default" do
      %w[user_id youtube_id title].each do |name|
        expect(columns[name].null).to be(false), "expected #{name} to be NOT NULL"
      end
      expect(columns["title"].default).to eq("")
    end

    it "has a unique index on user and YouTube id" do
      expect(connection.index_exists?(:videos, %i[user_id youtube_id], unique: true)).to be(true)
    end

    it "has a foreign key to users that cascades on delete" do
      foreign_key = connection.foreign_keys(:videos).find { |fk| fk.to_table == "users" }
      expect(foreign_key).to be_present
      expect(foreign_key.column).to eq("user_id")
      expect(foreign_key.on_delete).to eq(:cascade)
    end

    it "has a check constraint that refuses a YouTube id that is not 11 characters of letters, digits, _ and -" do
      user = create(:user)
      [ "short", "twelve_chars", "has space  x", "bad.chars.xx", "newline\nxxxx", "aaaaaaaaaa\n" ].each do |bad|
        # A savepoint, so a refused insert does not abort the example's transaction.
        expect {
          Video.transaction(requires_new: true) { Video.insert_all([ { user_id: user.id, youtube_id: bad } ]) }
        }.to raise_error(ActiveRecord::StatementInvalid, /videos_youtube_id_format/)
      end
      expect { Video.insert_all([ { user_id: user.id, youtube_id: "a-Z_09abcde" } ]) }.to change(Video, :count).by(1)
    end

    it "lets insert_all skip a video the user already has, keeping the first title" do
      user = create(:user)
      Video.insert_all([ { user_id: user.id, youtube_id: "aaaaaaaaaaa", title: "First" } ], unique_by: %i[user_id youtube_id])
      Video.insert_all([ { user_id: user.id, youtube_id: "aaaaaaaaaaa", title: "Second" } ], unique_by: %i[user_id youtube_id])

      expect(Video.pluck(:title)).to eq([ "First" ])
    end
  end

  describe "validations" do
    it "is valid with a user and a YouTube id" do
      expect(build(:video)).to be_valid
    end

    it "refuses a YouTube id that is missing or malformed" do
      [ nil, "", "short", "twelve_chars", "bad chars xx", "aaaaaaaaaaa\n" ].each do |bad|
        expect(build(:video, youtube_id: bad)).not_to be_valid
      end
    end

    it "refuses a second video with the same YouTube id for one user, but not for another user" do
      video = create(:video)

      expect { create(:video, user: video.user, youtube_id: video.youtube_id) }.to raise_error(ActiveRecord::RecordNotUnique)
      expect(build(:video, youtube_id: video.youtube_id)).to be_valid
    end
  end

  describe "#requeue!" do
    it "deletes a failed transcript and returns :transcript" do
      video = create(:video)
      create(:transcript, :failed, video: video)

      expect(video.requeue!).to eq(:transcript)
      expect(Transcript.exists?(video_id: video.id)).to be(false)
    end

    it "deletes a no_captions transcript and any summary row with it" do
      video = create(:video)
      create(:transcript, :no_captions, video: video)
      create(:summary, :done, video: video)

      expect(video.requeue!).to eq(:transcript)
      expect(Transcript.exists?(video_id: video.id)).to be(false)
      expect(Summary.exists?(video_id: video.id)).to be(false)
    end

    it "keeps a done transcript, deletes its finished summary and returns :summary" do
      %i[done nothing_to_summarise failed].each do |trait|
        video = create(:video)
        create(:transcript, :done, video: video)
        create(:summary, trait, video: video)

        expect(video.requeue!).to eq(:summary)
        expect(Summary.exists?(video_id: video.id)).to be(false)
        expect(Transcript.where(video_id: video.id).pluck(:outcome)).to eq([ "done" ])
      end
    end

    it "changes nothing and returns nil while the transcript or the summary is waiting or working" do
      %i[none working_transcript expired_transcript done_transcript working_summary expired_summary].each do |setup|
        video = create(:video)
        case setup
        when :working_transcript then create(:transcript, video: video)
        when :expired_transcript then create(:transcript, :expired, video: video)
        when :done_transcript then create(:transcript, :done, video: video)
        when :working_summary
          create(:transcript, :done, video: video)
          create(:summary, video: video)
        when :expired_summary
          create(:transcript, :done, video: video)
          create(:summary, :expired, video: video)
        end

        transcripts = Transcript.count
        summaries = Summary.count

        expect(video.requeue!).to be_nil
        expect(Transcript.count).to eq(transcripts)
        expect(Summary.count).to eq(summaries)
      end
    end

    it "touches only its own video's records" do
      first = create(:video)
      second = create(:video)
      third = create(:video)
      create(:transcript, :failed, video: first)
      create(:transcript, :failed, video: second)
      create(:transcript, :done, video: third)
      create(:summary, :done, video: third)

      expect(first.requeue!).to eq(:transcript)
      expect(Transcript.exists?(video_id: first.id)).to be(false)
      expect(Transcript.exists?(video_id: second.id, outcome: "failed")).to be(true)
      expect(Transcript.exists?(video_id: third.id, outcome: "done")).to be(true)
      expect(Summary.exists?(video_id: third.id, outcome: "done")).to be(true)
    end
  end

  describe "user" do
    it "is deleted with its user, and one user's videos never include another's" do
      video = create(:video)
      other = create(:video)

      expect(video.user.videos).to contain_exactly(video)
      expect { video.user.destroy }.to change(Video, :count).by(-1)
      expect(Video.all).to contain_exactly(other)
    end
  end
end
