require "rails_helper"

RSpec.describe Summaries::TranscriptText, type: :lib do
  def lines(*texts)
    texts.each_with_index.map { |text, index| { "text" => text, "start" => index.to_f } }
  end

  describe ".clean" do
    it "removes every square-bracket span, squeezes whitespace, drops empty lines and joins with one space" do
      text = described_class.clean(lines("[Music]", "Hello   there\nfriend", "  ", "so [Applause] it goes [laughter]", "", "end"))

      expect(text).to eq("Hello there friend so it goes end")
    end

    it "leaves parentheses and an unclosed bracket alone" do
      expect(described_class.clean(lines("(music) plays", "a [broken one"))).to eq("(music) plays a [broken one")
    end

    it "is empty when nothing is left" do
      expect(described_class.clean(lines("[Music]", "[Applause] [Music]"))).to eq("")
    end
  end

  describe ".word_count" do
    it "counts tokens with at least one letter or digit, in any script" do
      expect(described_class.word_count("one 2 - ... trois élan Привет — !")).to eq(5)
    end

    it "is zero for empty text" do
      expect(described_class.word_count("")).to eq(0)
    end
  end

  describe ".enough_words?" do
    it "needs 25 words: 24 is too few and 25 is enough" do
      expect(described_class.enough_words?(Array.new(24, "word").join(" "))).to be(false)
      expect(described_class.enough_words?(Array.new(25, "word").join(" "))).to be(true)
    end

    it "does not count punctuation-only tokens" do
      expect(described_class.enough_words?(Array.new(24, "word").join(" ") + " - -- ...")).to be(false)
    end

    it "does not count bracketed words once the text is cleaned" do
      cleaned = described_class.clean(lines(Array.new(30, "[music]").join(" "), "just five real words here"))

      expect(described_class.enough_words?(cleaned)).to be(false)
    end
  end
end
