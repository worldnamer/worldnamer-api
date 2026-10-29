require "rails_helper"

RSpec.describe IsoDate do
  describe ".parse" do
    it "returns a Date for a real YYYY-MM-DD date" do
      expect(IsoDate.parse("2026-10-26")).to eq(Date.new(2026, 10, 26))
      expect(IsoDate.parse("2028-02-29")).to eq(Date.new(2028, 2, 29))
    end

    it "accepts the first and last supported days" do
      expect(IsoDate.parse("1900-01-01")).to eq(Date.new(1900, 1, 1))
      expect(IsoDate.parse("9999-12-31")).to eq(Date.new(9999, 12, 31))
    end

    it "returns a plain Date, not a time" do
      expect(IsoDate.parse("2026-10-26")).to be_a(Date).and(satisfy { |date| !date.is_a?(DateTime) })
    end

    it "returns nil for dates that do not exist or are out of range" do
      %w[2026-02-29 2026-13-01 2026-00-10 2026-10-00 2026-04-31 1899-12-31 0000-01-03 99999-01-01].each do |value|
        expect(IsoDate.parse(value)).to be_nil, "expected #{value.inspect} to be refused"
      end
    end

    it "returns nil for other formats" do
      %w[2026-10-5 26-10-2026 20261026 2026-W44-1 2026-10-26T00:00:00 +2026-10-26 2026/10/26 2026-300].each do |value|
        expect(IsoDate.parse(value)).to be_nil, "expected #{value.inspect} to be refused"
      end
    end

    it "returns nil for whitespace, padding and the empty string" do
      [ "2026-10-26\n", " 2026-10-26", "2026-10-26 ", "\n2026-10-26", "2026-10-26\n2026-10-27", "", " " ].each do |value|
        expect(IsoDate.parse(value)).to be_nil, "expected #{value.inspect} to be refused"
      end
    end

    it "returns nil for a non-ASCII digit" do
      expect(IsoDate.parse("２０２６-10-26")).to be_nil
    end

    it "returns nil, and does not raise, for nil, an Array and a Hash" do
      expect(IsoDate.parse(nil)).to be_nil
      expect(IsoDate.parse([ "2026-10-26" ])).to be_nil
      expect(IsoDate.parse({ "a" => "2026-10-26" })).to be_nil
      expect(IsoDate.parse(20_261_026)).to be_nil
    end
  end
end
