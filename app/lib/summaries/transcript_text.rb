module Summaries
  # Turns a transcript's lines into the text that is sent for summarising, and decides whether it holds enough words to
  # be worth a call. Automatic captions mark non-speech with bracketed lines such as "[Music]", so every [...] span is
  # removed first (square brackets only; parentheses are left alone), whitespace is squeezed, empty lines are dropped and
  # the rest is joined with single spaces.
  #
  # A word is a run of non-space characters holding at least one letter or digit, so a lone "-" or "..." is not one.
  # Known limit: Chinese, Japanese and similar text has no spaces between words, so it counts as very few words and may
  # be judged too short.
  module TranscriptText
    MIN_WORDS = 25

    # [text, "["..."]"] spans, without crossing into another "[" so an unclosed bracket is left as it is.
    BRACKETED = /\[[^\[\]]*\]/
    WORD = /[\p{L}\p{N}]/

    # lines: the stored transcript, a list of { "text" => String, "start" => Numeric }.
    def self.clean(lines)
      lines.filter_map do |line|
        text = line["text"].to_s.gsub(BRACKETED, " ").squish
        text unless text.empty?
      end.join(" ")
    end

    def self.word_count(text)
      text.split.count { |token| token.match?(WORD) }
    end

    def self.enough_words?(text)
      word_count(text) >= MIN_WORDS
    end
  end
end
