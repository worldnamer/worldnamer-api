require "rails_helper"

RSpec.describe "config/queue.yml" do
  let(:config) { YAML.safe_load(ERB.new(Rails.root.join("config/queue.yml").read).result, aliases: true) }

  it "polls no faster than every few seconds, to keep the database and Honeycomb quiet" do
    production = config.fetch("production")
    intervals = production.fetch("dispatchers").map { |d| d["polling_interval"] } +
                production.fetch("workers").map { |w| w["polling_interval"] }

    expect(intervals).to all(be >= 5)
  end
end
