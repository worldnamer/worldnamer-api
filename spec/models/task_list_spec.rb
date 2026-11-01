require "rails_helper"

RSpec.describe TaskList, type: :model do
  let(:connection) { ActiveRecord::Base.connection }
  let(:columns) { connection.columns(:task_lists).index_by(&:name) }

  describe "table task_lists" do
    it "has the expected columns" do
      expect(columns.keys).to include("user_id", "name", "position", "created_at", "updated_at")
    end

    it "requires user_id, name and position, and limits name to 100 characters with a blank default" do
      expect(columns["user_id"].null).to be(false)
      expect(columns["name"].null).to be(false)
      expect(columns["name"].default).to eq("")
      expect(columns["name"].limit).to eq(100)
      expect(columns["position"].null).to be(false)
      expect(columns["position"].type).to eq(:integer)
    end

    it "has one composite index on user_id and position, and none on user_id alone" do
      expect(connection.index_exists?(:task_lists, %i[user_id position])).to be(true)
      expect(connection.index_exists?(:task_lists, :user_id)).to be(false)
    end

    it "has a foreign key to users that cascades on delete" do
      foreign_key = connection.foreign_keys(:task_lists).find { |fk| fk.to_table == "users" }
      expect(foreign_key).to be_present
      expect(foreign_key.column).to eq("user_id")
      expect(foreign_key.on_delete).to eq(:cascade)
    end
  end

  describe "names" do
    it "is valid with a user and a name" do
      expect(build(:task_list)).to be_valid
    end

    it "stores an empty, whitespace-only or nil name as an empty string" do
      [ "", "   ", " \n ", nil ].each do |name|
        list = create(:task_list, name: name)
        expect(list.reload.name).to eq("")
      end
    end

    it "strips spaces at the start and end of the name" do
      expect(create(:task_list, name: "  Shopping List \n").reload.name).to eq("Shopping List")
    end

    it "accepts 100 characters and 100 multibyte characters, and refuses 101" do
      expect(build(:task_list, name: "a" * 100)).to be_valid
      expect(create(:task_list, name: "é" * 100)).to be_persisted

      list = build(:task_list, name: "a" * 101)
      expect(list).not_to be_valid
      expect(list.errors.full_messages).to eq([ "Name is too long (maximum is 100 characters)" ])
    end

    it "allows the same name twice" do
      user = create(:user)

      expect { 2.times { create(:task_list, user: user, name: "Errands") } }.to change(TaskList, :count).by(2)
    end

    it "needs a user" do
      expect(build(:task_list, user: nil)).not_to be_valid
    end
  end

  describe "position" do
    it "puts a new list after the user's highest position, leaving gaps alone" do
      user = create(:user)
      first = create(:task_list, user: user)
      second = create(:task_list, user: user)
      create(:task_list, user: user, position: 10)
      second.destroy!

      expect(first.position).to eq(0)
      expect(create(:task_list, user: user).position).to eq(11)
    end

    it "counts each user's lists separately" do
      create(:task_list, user: create(:user), position: 7)

      expect(create(:task_list, user: create(:user)).position).to eq(0)
    end

    it "keeps a position that is given" do
      expect(create(:task_list, position: 4).position).to eq(4)
    end

    it "orders by position, then id" do
      user = create(:user)
      later = create(:task_list, user: user, position: 5)
      first_tie = create(:task_list, user: user, position: 2)
      second_tie = create(:task_list, user: user, position: 2)

      expect(user.task_lists.in_order).to eq([ first_tie, second_tie, later ])
    end
  end

  describe "database guarantees" do
    it "refuses a list for a user that does not exist" do
      expect {
        TaskList.insert!({ user_id: 0, name: "Errands", position: 0 })
      }.to raise_error(ActiveRecord::InvalidForeignKey)
    end

    it "refuses a name over 100 characters, in the database" do
      user = create(:user)

      expect {
        TaskList.insert!({ user_id: user.id, name: "a" * 101, position: 0 })
      }.to raise_error(ActiveRecord::ValueTooLong)
    end
  end

  describe "deleting a user" do
    it "deletes their lists and no one else's" do
      user = create(:user)
      create_list(:task_list, 2, user: user)
      other = create(:task_list)

      expect { user.destroy! }.to change(TaskList, :count).by(-2)
      expect(TaskList.all).to contain_exactly(other)
    end

    it "deletes their lists when the user row is deleted in SQL (cascade, not just callbacks)" do
      list = create(:task_list)

      expect { User.where(id: list.user_id).delete_all }.to change(TaskList, :count).by(-1)
    end
  end
end
