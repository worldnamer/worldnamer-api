module GoogleCalendar
  # Turns Google's event items (from EventsClient#list) into the rows the Today card shows. Each row has exactly these
  # keys, and nothing else from Google is passed on:
  #
  #   id, title (nil when the event has no summary), all_day,
  #   starts_on and ends_on (Dates, ends_on exclusive) for an all-day event, nil otherwise,
  #   starts_at and ends_at (ISO 8601 strings with the offset Google gave) for a timed event, nil otherwise.
  #
  # Left out: cancelled events, invitations the user declined, and working-location entries ("Home", "Office"), which
  # are a status rather than an event. An item whose id, start or end cannot be read is left out too, since the card
  # could not place it.
  #
  # The browser picks its own local day from the rows, so they are neither filtered to one day nor sorted here.
  module EventNormalizer
    # A full date and time with an explicit offset or Z. Time.iso8601 would read a value with no offset in the
    # server's own zone.
    DATE_TIME = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})\z/

    def self.call(items)
      items.filter_map { |item| normalize(item) if item.is_a?(Hash) && shown?(item) }
    end

    def self.shown?(item)
      return false if item["status"] == "cancelled"
      return false if item["eventType"] == "workingLocation"

      own = Array(item["attendees"]).find { |attendee| attendee.is_a?(Hash) && attendee["self"] == true }
      !(own && own["responseStatus"] == "declined")
    end
    private_class_method :shown?

    def self.normalize(item)
      id = item["id"]
      return nil unless id.is_a?(String) && id.present?

      start = item["start"].is_a?(Hash) ? item["start"] : {}
      finish = item["end"].is_a?(Hash) ? item["end"] : {}
      summary = item["summary"]
      row = { id: id, title: summary.is_a?(String) && summary.present? ? summary : nil }

      if start.key?("dateTime")
        starts_at = time_value(start["dateTime"])
        ends_at = time_value(finish["dateTime"])
        return nil unless starts_at && ends_at

        row.merge(all_day: false, starts_on: nil, ends_on: nil, starts_at: starts_at, ends_at: ends_at)
      else
        starts_on = IsoDate.parse(start["date"])
        ends_on = IsoDate.parse(finish["date"])
        return nil unless starts_on && ends_on

        row.merge(all_day: true, starts_on: starts_on, ends_on: ends_on, starts_at: nil, ends_at: nil)
      end
    end
    private_class_method :normalize

    # The value re-written by Ruby, which keeps Google's offset and drops fractional seconds, or nil if unreadable.
    def self.time_value(value)
      return nil unless value.is_a?(String) && value.match?(DATE_TIME)

      Time.iso8601(value).iso8601
    rescue ArgumentError
      nil
    end
    private_class_method :time_value
  end
end
