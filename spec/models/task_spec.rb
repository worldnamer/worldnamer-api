require "rails_helper"

RSpec.describe Task, type: :model do
  let(:connection) { ActiveRecord::Base.connection }
  let(:columns) { connection.columns(:tasks).index_by(&:name) }

  describe "table tasks" do
    it "has the expected columns" do
      expect(columns.keys).to include("task_list_id", "text", "done", "created_at", "updated_at")
    end

    it "requires task_list_id, text and done, limits text to 100 characters and defaults done to false" do
      expect(columns["task_list_id"].null).to be(false)
      expect(columns["text"].null).to be(false)
      expect(columns["text"].default).to eq("")
      expect(columns["text"].limit).to eq(100)
      expect(columns["done"].null).to be(false)
      expect(columns["done"].type).to eq(:boolean)
      expect(columns["done"].default).to eq("false")
      expect(Task.new.done).to be(false)
    end

    it "has an index on task_list_id" do
      expect(connection.index_exists?(:tasks, :task_list_id)).to be(true)
    end

    it "has a foreign key to task_lists that cascades on delete" do
      foreign_key = connection.foreign_keys(:tasks).find { |fk| fk.to_table == "task_lists" }
      expect(foreign_key).to be_present
      expect(foreign_key.column).to eq("task_list_id")
      expect(foreign_key.on_delete).to eq(:cascade)
    end
  end

  describe "text" do
    it "is valid with a list and text" do
      expect(build(:task)).to be_valid
    end

    it "stores an empty, whitespace-only or nil text as an empty string" do
      [ "", "   ", " \n ", nil ].each do |text|
        expect(create(:task, text: text).reload.text).to eq("")
      end
    end

    it "strips spaces at the start and end of the text" do
      expect(create(:task, text: "  Buy milk \n").reload.text).to eq("Buy milk")
    end

    it "accepts 100 characters and 100 multibyte characters, and refuses 101" do
      expect(build(:task, text: "a" * 100)).to be_valid
      expect(create(:task, text: "é" * 100)).to be_persisted

      task = build(:task, text: "a" * 101)
      expect(task).not_to be_valid
      expect(task.errors.full_messages).to eq([ "Text is too long (maximum is 100 characters)" ])
    end

    it "allows the same text twice in one list" do
      list = create(:task_list)

      expect { 2.times { create(:task, task_list: list, text: "Milk") } }.to change(Task, :count).by(2)
    end
  end

  describe "done" do
    it "is false for a new task" do
      expect(create(:task).reload.done).to be(false)
    end

    it "is invalid when null" do
      task = build(:task, done: nil)

      expect(task).not_to be_valid
      expect(task.errors[:done]).to be_present
    end

    it "is refused as null by the database" do
      list = create(:task_list)

      expect {
        Task.insert!({ task_list_id: list.id, text: "x", done: nil })
      }.to raise_error(ActiveRecord::NotNullViolation)
    end
  end

  describe "in_order" do
    it "orders by id, whatever the done flags" do
      list = create(:task_list)
      first = create(:task, task_list: list, done: true)
      second = create(:task, task_list: list)
      third = create(:task, task_list: list, done: true)

      expect(list.tasks.in_order).to eq([ first, second, third ])
    end
  end

  describe "database guarantees" do
    it "needs a list" do
      expect(build(:task, task_list: nil)).not_to be_valid
    end

    it "refuses a task for a list that does not exist" do
      expect {
        Task.insert!({ task_list_id: 0, text: "x" })
      }.to raise_error(ActiveRecord::InvalidForeignKey)
    end

    it "refuses a text over 100 characters, in the database" do
      list = create(:task_list)

      expect {
        Task.insert!({ task_list_id: list.id, text: "a" * 101 })
      }.to raise_error(ActiveRecord::ValueTooLong)
    end
  end

  describe "deleting a list" do
    it "destroy! fires dependent: and deletes its tasks and no other list's" do
      list = create(:task_list)
      create_list(:task, 2, task_list: list)
      other = create(:task)

      expect { list.destroy! }.to change(Task, :count).by(-2)
      expect(Task.all).to contain_exactly(other)
    end

    it "deletes its tasks when the list row is deleted in SQL (cascade, not just callbacks)" do
      task = create(:task)
      other = create(:task)

      expect { TaskList.where(id: task.task_list_id).delete_all }.to change(Task, :count).by(-1)
      expect(Task.all).to contain_exactly(other)
    end
  end

  describe "deleting a user" do
    it "deletes their tasks and no one else's, with destroy and with SQL" do
      user = create(:user)
      create_list(:task, 2, task_list: create(:task_list, user: user))
      create(:task, task_list: create(:task_list, user: user))
      other = create(:task)

      expect { user.destroy! }.to change(Task, :count).by(-3)
      expect(Task.all).to contain_exactly(other)

      expect { User.where(id: other.task_list.user_id).delete_all }.to change(Task, :count).by(-1)
    end
  end
end
