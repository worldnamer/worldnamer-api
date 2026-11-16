require "net/http"

module Summaries
  # The one call to the private summary service: POST /summary with a text, answered with a short summary, or a failure
  # with a reason. Plain Net::HTTP, in the style of Transcripts::Client, which it mirrors.
  #
  # summarise never raises and never retries. Every way a call can end, including the service being unreachable or
  # answering something unexpected, comes back as a Result, so the caller stores it and moves on.
  #
  # The bearer token travels only in the Authorization header: it is not in the URL, in an error message or in the
  # inspect output, and the client logs nothing. The response body is read to take the summary, the model and the token
  # counts from it and is never logged or kept: only a reason word on a fixed list is passed on.
  class Client
    # outcome: "done" or "failed" (the values Summary stores). reason: only for failed. text, model, tokens_in and
    # tokens_out: only for done. The text is model output and must be treated as untrusted wherever it is shown.
    Result = Data.define(:outcome, :reason, :text, :model, :tokens_in, :tokens_out)

    # Seconds. A summary can take a couple of minutes, and the service serves one caller at a time, so a second caller
    # is answered 429 busy.
    OPEN_TIMEOUT = 2
    READ_TIMEOUT = 180

    # The reasons the service gives with a 502, kept as they are. Its "unauthorized" means the service's own key for
    # its model was refused, so it is stored as "model_unauthorized" to tell it from this app's own token being refused
    # ("unauthorized"). Any other 502 reason is stored as "unknown".
    SERVICE_REASONS = %w[timed_out rate_limited service_error empty_answer].freeze

    def initialize(base_url:, token:)
      @base_url = base_url
      @token = token
    end

    def inspect
      "#<#{self.class.name}>"
    end

    # Each call that is sent leaves one span, "summaries.generate", with the outcome, the reason (only for a failure),
    # the model and the token counts (only for a summary) and how long it took in milliseconds. The span carries no
    # video id, title, token or text, so it cannot leak any of them, and its status is left unset: a failed call is an
    # expected result, not an error in this code. A text that is not a non-blank string is refused before anything is
    # sent, and leaves no span.
    def summarise(text)
      return failed("bad_response") unless text.is_a?(String) && text.present?

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      WorldnamerTelemetry.tracer.in_span("summaries.generate", kind: :client) do |span|
        result = call(text)
        span.set_attribute("summaries.outcome", result.outcome)
        span.set_attribute("summaries.reason", result.reason) if result.reason
        span.set_attribute("summaries.model", result.model) if result.model
        span.set_attribute("summaries.tokens_in", result.tokens_in) if result.tokens_in
        span.set_attribute("summaries.tokens_out", result.tokens_out) if result.tokens_out
        span.set_attribute("summaries.duration_ms", ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round)
        result
      end
    end

    private

    # Sends the request and turns whatever happens into a Result. Nothing escapes.
    def call(text)
      read(post(text))
    rescue Net::ReadTimeout
      failed("timed_out")
    rescue Timeout::Error, SystemCallError, SocketError, IOError, OpenSSL::SSL::SSLError,
           Net::ProtocolError, Net::HTTPBadResponse
      failed("unreachable")
    rescue StandardError
      # Whatever else goes wrong is not worth more than a stored failure. The exception is dropped unlogged because
      # its message could quote part of the text or the response.
      failed("bad_response")
    end

    def post(text)
      uri = URI.join(@base_url, "/summary")
      request = Net::HTTP::Post.new(
        uri.path,
        "Authorization" => "Bearer #{@token}", "Content-Type" => "application/json", "Accept" => "application/json"
      )
      request.body = { text: text }.to_json
      # max_retries = 0: Net::HTTP must never send the request a second time on its own, which would double the wait
      # and the spend on a call.
      Net::HTTP.start(
        uri.host, uri.port,
        use_ssl: uri.scheme == "https", open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT, max_retries: 0
      ) { |http| http.request(request) }
    end

    def read(response)
      case response.code.to_i
      when 200 then read_success(parse(response.body))
      when 502 then read_bad_gateway(parse(response.body))
      when 422 then read_unprocessable(parse(response.body))
      when 429 then failed("busy")
      when 401 then failed("unauthorized")
      else failed("bad_response")
      end
    end

    def read_success(body)
      return failed("bad_response") unless body

      summary, model, tokens_in, tokens_out = body.values_at("summary", "model", "tokens_in", "tokens_out")
      valid = summary.is_a?(String) && summary.present? && model.is_a?(String) &&
              tokens_in.is_a?(Integer) && tokens_out.is_a?(Integer)
      return failed("bad_response") unless valid

      Result.new(outcome: "done", reason: nil, text: summary, model: model, tokens_in: tokens_in, tokens_out: tokens_out)
    end

    def read_bad_gateway(body)
      reason = body&.fetch("reason", nil)
      return failed("model_unauthorized") if reason == "unauthorized"

      failed(SERVICE_REASONS.include?(reason) ? reason : "unknown")
    end

    def read_unprocessable(body)
      failed(body&.fetch("reason", nil) == "too_long" ? "too_long" : "bad_response")
    end

    # The parsed body if it is a JSON object, otherwise nil.
    def parse(text)
      body = JSON.parse(text.to_s)
      body.is_a?(Hash) ? body : nil
    rescue JSON::ParserError
      nil
    end

    def failed(reason)
      Result.new(outcome: "failed", reason: reason, text: nil, model: nil, tokens_in: nil, tokens_out: nil)
    end
  end
end
