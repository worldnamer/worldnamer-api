# Strict YYYY-MM-DD parsing for dates that arrive in a URL or query string.
module IsoDate
  FORMAT = /\A\d{4}-\d{2}-\d{2}\z/
  # Ruby's Date reads days before 15 October 1582 in the Julian calendar, while Postgres and browsers use the Gregorian
  # one for every year, so the three would disagree about older dates. Nothing here needs them.
  RANGE = Date.new(1900, 1, 1)..Date.new(9999, 12, 31)

  # Returns a Date, or nil for anything else. Never raises, so bad input becomes a 400 and not a 500.
  # Date.parse and Date.iso8601 are not used: they accept far more than YYYY-MM-DD (20261026, 2026-W44-1, "Oct 5").
  # \A and \z anchor the whole string; ^ and $ would let "2026-10-26\n" through.
  def self.parse(value)
    return nil unless value.is_a?(String) && value.match?(FORMAT)

    date = Date.strptime(value, "%Y-%m-%d")
    RANGE.cover?(date) ? date : nil
  rescue Date::Error
    nil
  end
end
