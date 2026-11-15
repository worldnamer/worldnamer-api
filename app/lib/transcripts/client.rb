require "net/http"

module Transcripts
  # The one call to the private transcript service: POST /transcript with a YouTube video id, answered with the
  # transcript's lines, "no captions", or a failure with a reason. Plain Net::HTTP, in the style of YouTube::DataClient.
  #
  # fetch never raises and never retries. Every way a fetch can end, including the service being unreachable or
  # answering something unexpected, comes back as a Result, so the caller stores it and moves on.
  #
  # The bearer token travels only in the Authorization header: it is not in the URL, in an error message or in the
  # inspect output, and the client logs nothing. The response body is read to take the outcome, the reason and the
  # lines from it and is never logged or kept: only a reason word on the allow-list is passed on, and only the text and
  # start of each line.
  class Client
    # outcome: "done", "no_captions" or "failed" (the values Transcript stores). reason: only for failed. lines: only
    # for done, a list of { "text" => String, "start" => Numeric }.
    Result = Data.define(:outcome, :reason, :lines)

    # Seconds. The service's own fetch through its proxy can take most of two minutes, and it serves one caller at a
    # time, so a second caller is answered 429 busy.
    OPEN_TIMEOUT = 2
    READ_TIMEOUT = 110

    # The reasons the service gives for a failed fetch. Any other word is stored as "unknown".
    SERVICE_REASONS = %w[blocked timed_out unavailable proxy_refused youtube_error unknown].freeze

    def initialize(base_url:, token:)
      @base_url = base_url
      @token = token
    end

    def inspect
      "#<#{self.class.name}>"
    end

    def fetch(video_id)
      # The id goes into the request body, so anything that is not a YouTube id is refused before it is sent.
      return failed("bad_response") unless video_id.is_a?(String) && video_id.match?(YouTube::DataClient::VIDEO_ID)

      read(post(video_id))
    rescue Net::ReadTimeout
      failed("timed_out")
    rescue Timeout::Error, SystemCallError, SocketError, IOError, OpenSSL::SSL::SSLError,
           Net::ProtocolError, Net::HTTPBadResponse
      failed("unreachable")
    rescue StandardError
      # Whatever else goes wrong is not worth more than a stored failure. The exception is dropped unlogged because
      # its message could quote part of the response.
      failed("bad_response")
    end

    private

    def post(video_id)
      uri = URI.join(@base_url, "/transcript")
      request = Net::HTTP::Post.new(
        uri.path,
        "Authorization" => "Bearer #{@token}", "Content-Type" => "application/json", "Accept" => "application/json"
      )
      request.body = { video_id: video_id }.to_json
      # max_retries = 0: Net::HTTP must never send the request a second time on its own, which would double the wait
      # and the proxy bandwidth spent on a fetch.
      Net::HTTP.start(
        uri.host, uri.port,
        use_ssl: uri.scheme == "https", open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT, max_retries: 0
      ) { |http| http.request(request) }
    end

    # The service answers failures with 502 and a body naming the reason, and 200 for a transcript or no captions.
    def read(response)
      case response.code.to_i
      when 200 then read_success(parse(response.body))
      when 502 then read_failure(parse(response.body))
      when 429 then failed("busy")
      when 401 then failed("unauthorized")
      else failed("bad_response")
      end
    end

    def read_success(body)
      case body&.fetch("outcome", nil)
      when "ok"
        lines = clean_lines(body["lines"])
        lines.empty? ? failed("bad_response") : Result.new(outcome: "done", reason: nil, lines: lines)
      when "no_captions" then Result.new(outcome: "no_captions", reason: nil, lines: nil)
      else failed("bad_response")
      end
    end

    def read_failure(body)
      return failed("bad_response") unless body&.fetch("outcome", nil) == "failed"

      reason = body["reason"]
      failed(SERVICE_REASONS.include?(reason) ? reason : "unknown")
    end

    # The parsed body if it is a JSON object, otherwise nil.
    def parse(text)
      body = JSON.parse(text.to_s)
      body.is_a?(Hash) ? body : nil
    rescue JSON::ParserError
      nil
    end

    # Only the text and start of each line are kept; an entry of any other shape is dropped.
    def clean_lines(lines)
      return [] unless lines.is_a?(Array)

      lines.filter_map do |line|
        next unless line.is_a?(Hash) && line["text"].is_a?(String) && line["start"].is_a?(Numeric)

        { "text" => line["text"], "start" => line["start"] }
      end
    end

    def failed(reason)
      Result.new(outcome: "failed", reason: reason, lines: nil)
    end
  end
end
