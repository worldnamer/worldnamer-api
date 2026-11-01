require "net/http"

module GoogleCalendar
  # Lists events on the user's primary Google calendar (Calendar API v3, Events: list) on plain Net::HTTP.
  #
  # The access token travels in the Authorization header, never in the URL, so it cannot reach a log line or a trace
  # span that records the request target. The fields filter asks Google for the few fields the Today card shows, so an
  # event's description, location, attendee emails and meeting links never reach this server at all.
  #
  # Errors never carry a response body: only the HTTP status and Google's reason code (such as "rateLimitExceeded").
  # They are also raised without the underlying exception attached, because that exception's message could quote the
  # body, and Sentry reports the whole chain.
  class EventsClient
    ENDPOINT = URI("https://www.googleapis.com/calendar/v3/calendars/primary/events").freeze

    # Seconds. The browser gives up on the whole request after 5, and a token call comes first.
    OPEN_TIMEOUT = 2
    READ_TIMEOUT = 3

    # The window around the server's UTC date D: from D 00:00 UTC minus 38 hours to D 00:00 UTC plus 60 hours. Any
    # time zone from UTC-12 to UTC+14 then has its own local yesterday, today and tomorrow inside it, so the browser
    # can pick its local day from the list.
    WINDOW_BEFORE = 38.hours
    WINDOW_AFTER = 60.hours

    FIELDS = "nextPageToken,items(id,status,summary,start,end,eventType,attendees(self,responseStatus))".freeze

    # Network failure, timeout, an unexpected status, or a body that cannot be read. status is the HTTP status as an
    # Integer, or nil when Google never answered.
    class Error < StandardError
      attr_reader :status

      def initialize(message, status: nil)
        super(message)
        @status = status
      end
    end

    # [time_min, time_max] for the given UTC date, as Time objects in UTC.
    def self.window(utc_date)
      midnight = utc_date.in_time_zone("UTC")
      [ midnight - WINDOW_BEFORE, midnight + WINDOW_AFTER ]
    end

    def initialize(endpoint: ENDPOINT)
      @endpoint = endpoint
    end

    # Returns Google's event items (an Array of Hashes, still in Google's shape) for the window around utc_date. Only
    # the first page is read; it holds up to 250 events, far more than four days need.
    def list(access_token:, utc_date:)
      time_min, time_max = self.class.window(utc_date)
      query = {
        timeMin: time_min.utc.iso8601,
        timeMax: time_max.utc.iso8601,
        singleEvents: "true",
        orderBy: "startTime",
        showDeleted: "false",
        maxResults: "250",
        fields: FIELDS
      }

      response = get("#{@endpoint.path}?#{URI.encode_www_form(query)}", access_token)
      raise_for(response) unless response.is_a?(Net::HTTPSuccess)

      body = parse_json(response.body)
      items = body["items"] || [] if body.is_a?(Hash)
      raise Error.new("Google Calendar answered #{response.code} without a list of events", status: response.code.to_i) unless items.is_a?(Array)

      # A fact, never content: the token itself is an opaque cursor, so it is not logged either.
      Rails.logger.warn("Google Calendar events: more than one page in the window; only the first was read") if body["nextPageToken"]
      items
    end

    private

    def get(target, access_token)
      # max_retries = 0: by default Net::HTTP quietly sends an idempotent GET a second time after a read timeout,
      # which would double the time a Puma thread waits on Google.
      Net::HTTP.start(
        @endpoint.host, @endpoint.port,
        use_ssl: @endpoint.scheme == "https", open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT, max_retries: 0
      ) do |http|
        http.get(target, "Authorization" => "Bearer #{access_token}", "Accept" => "application/json")
      end
    rescue Timeout::Error, SystemCallError, SocketError, IOError, OpenSSL::SSL::SSLError,
           Net::ProtocolError, Net::HTTPBadResponse => e
      raise Error, "Google Calendar unreachable (#{e.class.name})", cause: nil
    end

    # Google's error body looks like { "error": { "code": 403, "errors": [ { "reason": "rateLimitExceeded" } ] } }.
    def raise_for(response)
      body = parse_json(response.body, strict: false)
      error = body["error"] if body.is_a?(Hash)
      first = error["errors"].first if error.is_a?(Hash) && error["errors"].is_a?(Array)
      reason = first["reason"] if first.is_a?(Hash)
      # Only a plain word is kept, so nothing else from the body can reach the message.
      reason = nil unless reason.is_a?(String) && reason.match?(/\A[A-Za-z_]{1,64}\z/)

      raise Error.new("Google Calendar answered #{response.code} (#{reason || "no reason"})", status: response.code.to_i)
    end

    # With strict: false an unreadable body is nil (an error status says enough on its own).
    def parse_json(text, strict: true)
      JSON.parse(text.to_s)
    rescue JSON::ParserError
      raise Error, "Google Calendar sent a body that is not JSON", cause: nil if strict

      nil
    end
  end
end
