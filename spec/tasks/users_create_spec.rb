require "rails_helper"
require "rake"

# Plan section 6, scenario 17, and the behavior in plan section 2 ("Seeding the
# single user in production").
#
# Assumptions about the task's input handling, from the plan: it checks
# $stdin.tty?, reads the username with $stdin.gets, and reads each password with
# $stdin.noecho (require "io/console"), asked twice. The spec stubs those calls
# on $stdin.
RSpec.describe "users:create", type: :task do
  let(:password) { "a sentinel password 4f8e2b91" }
  let(:task) { Rake::Task["users:create"] }

  before do
    Rails.application.load_tasks unless Rake::Task.task_defined?("users:create")
    task.reenable
  end

  # answers: what $stdin.gets returns, in order (username, password, confirmation)
  def feed(*answers, tty: true)
    allow($stdin).to receive(:tty?).and_return(tty)
    allow($stdin).to receive(:noecho).and_yield($stdin)
    allow($stdin).to receive(:gets).and_return(*answers.map { |a| "#{a}\n" })
  end

  def run_task
    stdout = StringIO.new
    stderr = StringIO.new
    original = [ $stdout, $stderr ]
    $stdout, $stderr = stdout, stderr
    begin
      task.invoke
    rescue SystemExit => e
      exit_status = e.status
    ensure
      $stdout, $stderr = original
    end
    { out: stdout.string, err: stderr.string, exit_status: exit_status }
  end

  context "without a TTY" do
    it "refuses, creates nothing, reads no input and prints no password" do
      feed("john", password, password, tty: false)

      result = run_task

      expect(result[:exit_status]).to be_present.and(satisfy { |status| status != 0 })
      expect(User.count).to eq(0)
      expect($stdin).not_to have_received(:gets)
      expect(result[:out] + result[:err]).not_to include(password)
      expect(result[:err]).to be_present # says why
    end
  end

  context "with a TTY and a new username" do
    it "creates the user with a working password and prints only the confirmation" do
      feed("  John ", password, password)

      result = run_task

      expect(result[:exit_status]).to be_nil
      expect(User.count).to eq(1)
      user = User.find_by!(username: "john")
      expect(user.valid_password?(password)).to be(true)
      expect(result[:out]).to include("User john created")
      expect(result[:out] + result[:err]).not_to include(password)
    end

    it "reads the password without echo, both times" do
      feed("john", password, password)

      run_task

      expect($stdin).to have_received(:noecho).twice
    end
  end

  context "with a TTY and an existing username" do
    it "updates the password and says updated" do
      existing = create(:user, username: "john", password: "the old password 123")
      feed("john", password, password)

      result = run_task

      expect(User.count).to eq(1)
      expect(existing.reload.valid_password?(password)).to be(true)
      expect(existing.valid_password?("the old password 123")).to be(false)
      expect(result[:out]).to include("User john updated")
      expect(result[:out] + result[:err]).not_to include(password)
    end
  end

  context "with bad passwords" do
    it "aborts when the two entries differ, creating nothing and printing neither" do
      feed("john", password, "#{password}-different")

      result = run_task

      expect(result[:exit_status]).to be_present
      expect(User.count).to eq(0)
      expect(result[:out] + result[:err]).not_to include(password)
    end

    it "aborts when the password is shorter than 12 bytes" do
      short = "x" * 11
      feed("john", short, short)

      result = run_task

      expect(result[:exit_status]).to be_present
      expect(User.count).to eq(0)
      expect(result[:out] + result[:err]).not_to include(short)
    end

    it "accepts exactly 12 bytes" do
      twelve = "x" * 12
      feed("john", twelve, twelve)

      run_task

      expect(User.find_by(username: "john")&.valid_password?(twelve)).to be(true)
    end

    it "accepts exactly 72 bytes" do
      seventy_two = "y" * 72
      feed("john", seventy_two, seventy_two)

      run_task

      expect(User.find_by(username: "john")&.valid_password?(seventy_two)).to be(true)
    end

    it "aborts when the password is longer than 72 bytes (bcrypt ignores the rest)" do
      long = "z" * 73
      feed("john", long, long)

      result = run_task

      expect(result[:exit_status]).to be_present
      expect(User.count).to eq(0)
      expect(result[:out] + result[:err]).not_to include(long)
    end

    it "counts bytes, not characters" do
      # 37 two-byte characters = 37 chars but 74 bytes
      wide = "é" * 37
      feed("john", wide, wide)

      result = run_task

      expect(result[:exit_status]).to be_present
      expect(User.count).to eq(0)
    end

    it "leaves an existing user's password unchanged when the new one is rejected" do
      existing = create(:user, username: "john", password: "the old password 123")
      feed("john", "short", "short")

      run_task

      expect(existing.reload.valid_password?("the old password 123")).to be(true)
    end
  end
end
