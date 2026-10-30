require "rails_helper"

# Plan section 6, API scenarios 6, 8 and 15, plus the table's database-level guarantees.
RSpec.describe Habit, type: :model do
  let(:connection) { ActiveRecord::Base.connection }
  let(:columns) { connection.columns(:habits).index_by(&:name) }

  describe "table habits" do
    it "has the planned columns" do
      expect(columns.keys).to include("user_id", "name", "created_at", "updated_at")
    end

    it "requires user_id and name, and limits name to 100 characters" do
      expect(columns["user_id"].null).to be(false)
      expect(columns["name"].null).to be(false)
      expect(columns["name"].limit).to eq(100)
    end

    it "indexes user_id" do
      expect(connection.index_exists?(:habits, :user_id)).to be(true)
    end

    it "has a foreign key to users that cascades on delete" do
      foreign_key = connection.foreign_keys(:habits).find { |fk| fk.to_table == "users" }
      expect(foreign_key).to be_present
      expect(foreign_key.column).to eq("user_id")
      expect(foreign_key.on_delete).to eq(:cascade)
    end
  end

  describe "validations" do
    it "is valid with a user and a name" do
      expect(build(:habit)).to be_valid
    end

    it "strips spaces at the start and end of the name" do
      expect(build(:habit, name: "  Stretch \n").name).to eq("Stretch")
    end

    it "refuses an empty, whitespace-only or missing name" do
      [ "", "   ", " 　", nil ].each do |name|
        habit = build(:habit, name: name)
        expect(habit).not_to be_valid
        expect(habit.errors.full_messages).to eq([ "Name can't be blank" ])
      end
    end

    it "accepts 100 characters and refuses 101" do
      expect(build(:habit, name: "a" * 100)).to be_valid

      habit = build(:habit, name: "a" * 101)
      expect(habit).not_to be_valid
      expect(habit.errors.full_messages).to eq([ "Name is too long (maximum is 100 characters)" ])
    end

    it "accepts 100 multibyte characters" do
      expect(create(:habit, name: "é" * 100)).to be_persisted
    end

    it "allows the same name twice" do
      user = create(:user)

      expect { 2.times { create(:habit, user: user, name: "Stretch") } }.to change(Habit, :count).by(2)
    end

    it "needs a user" do
      expect(build(:habit, user: nil)).not_to be_valid
    end
  end

  describe "database guarantees" do
    it "refuses a habit for a user that does not exist" do
      expect {
        Habit.insert!({ user_id: 0, name: "Stretch" })
      }.to raise_error(ActiveRecord::InvalidForeignKey)
    end

    it "refuses a name over 100 characters, in the database" do
      user = create(:user)

      expect {
        Habit.insert!({ user_id: user.id, name: "a" * 101 })
      }.to raise_error(ActiveRecord::ValueTooLong)
    end
  end

  describe "deleting a user" do
    it "deletes their habits and no one else's" do
      user = create(:user)
      create_list(:habit, 2, user: user)
      other = create(:habit)

      expect { user.destroy! }.to change(Habit, :count).by(-2)
      expect(Habit.all).to contain_exactly(other)
    end

    it "deletes their habits when the user row is deleted in SQL (cascade, not just callbacks)" do
      habit = create(:habit)

      expect { User.where(id: habit.user_id).delete_all }.to change(Habit, :count).by(-1)
    end
  end

  describe "deleting a habit" do
    let(:habit) { create(:habit) }
    let(:monday) { Date.new(2026, 10, 26) }

    before { (0..2).each { |offset| create(:habit_completion, habit: habit, date: monday + offset) } }

    it "deletes its completions and no one else's" do
      other = create(:habit_completion)

      expect { habit.destroy! }.to change(HabitCompletion, :count).by(-3)
      expect(HabitCompletion.all).to contain_exactly(other)
    end

    it "deletes its completions in one statement, however many there are" do
      statements = []
      callback = lambda do |*, payload|
        statements << payload[:sql] if payload[:sql].include?('DELETE FROM "habit_completions"')
      end
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { habit.destroy! }

      expect(statements.size).to eq(1)
    end
  end

  describe ".completed_dates_in_week" do
    let(:monday) { Date.new(2026, 10, 26) }
    let(:user) { create(:user) }
    let(:stretch) { create(:habit, user: user) }
    let(:read) { create(:habit, user: user) }

    def complete(habit, *dates)
      dates.each { |date| create(:habit_completion, habit: habit, date: date) }
    end

    it "maps each habit id to its dates in the week as ISO strings, ascending" do
      complete(stretch, monday + 2, monday)
      complete(read, monday + 6)

      expect(user.habits.completed_dates_in_week(monday)).to eq(
        stretch.id => [ "2026-10-26", "2026-10-28" ],
        read.id => [ "2026-11-01" ]
      )
    end

    it "includes the Monday and the Sunday and leaves out the days either side" do
      complete(stretch, monday - 1, monday, monday + 6, monday + 7)

      expect(user.habits.completed_dates_in_week(monday)[stretch.id]).to eq([ "2026-10-26", "2026-11-01" ])
    end

    it "leaves out habits with no completions that week" do
      complete(stretch, monday - 7)
      read

      expect(user.habits.completed_dates_in_week(monday)).to eq({})
    end

    it "only reads completions of the habits in the relation it is called on" do
      other = create(:habit)
      complete(other, monday)
      complete(stretch, monday)

      expect(user.habits.completed_dates_in_week(monday).keys).to eq([ stretch.id ])
    end

    it "runs one query, however many habits there are" do
      complete(stretch, monday)
      complete(read, monday)

      statements = []
      callback = lambda do |*, payload|
        statements << payload[:sql] unless payload[:name] == "SCHEMA" || payload[:cached]
      end
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
        user.habits.order(:created_at, :id).completed_dates_in_week(monday)
      end

      expect(statements.size).to eq(1)
    end
  end
end
