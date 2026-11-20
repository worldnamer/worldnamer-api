require "rails_helper"

RSpec.describe "quotes table", type: :model do
  it "has a required, indexed user_id with a foreign key to users that cascades on delete" do
    connection = ActiveRecord::Base.connection
    columns = connection.columns(:quotes).index_by(&:name)

    expect(columns["user_id"].null).to be(false)
    expect(connection.index_exists?(:quotes, :user_id)).to be(true)

    foreign_key = connection.foreign_keys(:quotes).find { |fk| fk.to_table == "users" }
    expect(foreign_key).to be_present
    expect(foreign_key.column).to eq("user_id")
    expect(foreign_key.on_delete).to eq(:cascade)
  end

  it "requires text and limits it to 500 characters" do
    connection = ActiveRecord::Base.connection
    text_column = connection.columns(:quotes).index_by(&:name)["text"]

    expect(text_column).to be_present
    expect(text_column.null).to be(false)
    expect(text_column.limit).to eq(500)
  end

  it "limits author to 100 characters and defaults it to an empty string" do
    connection = ActiveRecord::Base.connection
    author_column = connection.columns(:quotes).index_by(&:name)["author"]

    expect(author_column).to be_present
    expect(author_column.null).to be(false)
    expect(author_column.limit).to eq(100)
    expect(author_column.default).to eq("")
  end
end
