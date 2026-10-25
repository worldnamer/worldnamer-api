require "rails_helper"

# Deliberately failing, to prove CI turns red. Delete this file; never merge it.
RSpec.describe "CI red test" do
  it "fails on purpose" do
    expect(1).to eq(2)
  end
end
