require "rails_helper"

# The table's database-level guarantees, and what deleting a habit or a user does to its completions.
RSpec.describe HabitCompletion, type: :model do
  let(:connection) { ActiveRecord::Base.connection }
  let(:columns) { connection.columns(:habit_completions).index_by(&:name) }

  describe "table habit_completions" do
    it "has the planned columns" do
      expect(columns.keys).to include("habit_id", "date", "created_at", "updated_at")
      expect(columns["date"].type).to eq(:date)
    end

    it "requires habit_id and date" do
      expect(columns["habit_id"].null).to be(false)
      expect(columns["date"].null).to be(false)
    end

    it "has a unique index on habit_id and date, and no separate habit_id index" do
      indexes = connection.indexes(:habit_completions)

      expect(indexes.map { |index| [ index.columns, index.unique ] }).to eq([ [ %w[habit_id date], true ] ])
    end

    it "has a foreign key to habits that cascades on delete" do
      foreign_key = connection.foreign_keys(:habit_completions).find { |fk| fk.to_table == "habits" }
      expect(foreign_key).to be_present
      expect(foreign_key.column).to eq("habit_id")
      expect(foreign_key.on_delete).to eq(:cascade)
    end
  end

  describe "validations" do
    it "is valid with a habit and a date" do
      expect(build(:habit_completion)).to be_valid
    end

    it "needs a habit" do
      expect(build(:habit_completion, habit: nil)).not_to be_valid
    end

    it "needs a date" do
      expect(build(:habit_completion, date: nil)).not_to be_valid
    end
  end

  describe "database guarantees" do
    it "refuses the same habit and date twice" do
      habit = create(:habit)
      HabitCompletion.insert!({ habit_id: habit.id, date: Date.new(2026, 10, 26) })

      expect {
        HabitCompletion.insert!({ habit_id: habit.id, date: Date.new(2026, 10, 26) })
      }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "allows the same date for two habits and two dates for one habit" do
      habit = create(:habit)
      other = create(:habit)

      expect {
        HabitCompletion.insert_all!([
          { habit_id: habit.id, date: Date.new(2026, 10, 26) },
          { habit_id: other.id, date: Date.new(2026, 10, 26) },
          { habit_id: habit.id, date: Date.new(2026, 10, 27) }
        ])
      }.to change(HabitCompletion, :count).by(3)
    end

    it "refuses a completion for a habit that does not exist" do
      expect {
        HabitCompletion.insert!({ habit_id: 0, date: Date.new(2026, 10, 26) })
      }.to raise_error(ActiveRecord::InvalidForeignKey)
    end
  end

  describe "deleting a habit" do
    it "deletes its completions and no other habit's" do
      habit = create(:habit)
      other = create(:habit)
      create_list(:habit_completion, 2, habit: habit)
      kept = create(:habit_completion, habit: other)

      expect { habit.destroy! }.to change(HabitCompletion, :count).by(-2)
      expect(HabitCompletion.all).to contain_exactly(kept)
    end

    it "deletes its completions when the habit row is deleted in SQL (cascade, not just callbacks)" do
      habit = create(:habit)
      create_list(:habit_completion, 2, habit: habit)

      expect { Habit.where(id: habit.id).delete_all }.to change(HabitCompletion, :count).by(-2)
    end
  end

  describe "deleting a user" do
    it "deletes that user's completions and no one else's" do
      user = create(:user)
      create_list(:habit_completion, 2, habit: create(:habit, user: user))
      kept = create(:habit_completion)

      expect { user.destroy! }.to change(HabitCompletion, :count).by(-2)
      expect(HabitCompletion.all).to contain_exactly(kept)
    end

    it "deletes that user's completions when the user row is deleted in SQL" do
      habit = create(:habit)
      create_list(:habit_completion, 2, habit: habit)

      expect { User.where(id: habit.user_id).delete_all }.to change(HabitCompletion, :count).by(-2)
    end
  end
end
