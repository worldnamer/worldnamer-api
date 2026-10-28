require "rails_helper"

# Plan section 6, scenarios 14, 15 and 16 (the refresh-token parts arrive with api-2).
#
# TEST-SUPPORT INTERFACE THIS SPEC ASSUMES (the implementer provides it, e.g. in
# spec/support/telemetry_helpers.rb, included for type: :request):
#
#   captured_spans
#     Returns an Array of every OpenTelemetry span that FINISHED during the
#     current example, and only that example (the store is reset before or after
#     each example). Spans must be readable synchronously, straight after the
#     request returns: an in-memory exporter behind a simple (non-batching)
#     processor, no waiting or flushing in the spec. Each element responds like
#     OpenTelemetry::SDK::Trace::SpanData:
#       #name        String
#       #attributes  Hash of String => value, or nil when there are none
#       #events      Array (or nil); each event responds to #name and #attributes
#                    (Hash or nil), like OpenTelemetry::SDK::Trace::Event
#     It must reflect the real production configuration (same instrumentation
#     and options), not a spec-only copy.
#
#   captured_sentry_events
#     Returns an Array of every Sentry::Event captured during the current example
#     (Sentry's test transport, reset between examples). Each responds to #to_h
#     with the full event payload. Real production Sentry configuration
#     (data_collection settings), sending nothing over the network.
#
# Log capture needs no helper: this spec attaches its own logger to Rails.logger.
RSpec.describe "Password leak checks on POST /api/v1/session", type: :request do
  SENTINEL = "SENTINEL-pw-7f3a9c1e-do-not-leak".freeze

  let!(:user) { create(:user, username: "john", password: SENTINEL) }

  def dump(object)
    object.inspect
  end

  def dump_spans(spans)
    spans.map do |span|
      {
        name: span.name,
        attributes: span.attributes,
        events: Array(span.events).map { |event| { name: event.name, attributes: event.attributes } }
      }
    end.inspect
  end

  def request_logging
    io = StringIO.new
    capture_logger = ActiveSupport::Logger.new(io)
    Rails.logger.broadcast_to(capture_logger)
    yield
    io.string
  ensure
    Rails.logger.stop_broadcasting_to(capture_logger)
  end

  describe "scenario 14: Rails log" do
    it "logs the parameters with the password filtered, never the sentinel (successful login)" do
      log = request_logging { login(password: SENTINEL) }

      expect(response).to have_http_status(:ok)
      expect(log).to include("Parameters:")        # the request really was logged
      expect(log).to include("[FILTERED]")         # and the password param was filtered
      expect(log).to include("/api/v1/session")
      expect(log).not_to include(SENTINEL)
    end

    it "never logs the sentinel on a failed login either" do
      log = request_logging { login(username: "john", password: "#{SENTINEL}-wrong") }

      expect(response).to have_http_status(:unauthorized)
      expect(log).to include("[FILTERED]")
      expect(log).not_to include(SENTINEL)
    end
  end

  describe "scenario 15: OpenTelemetry spans" do
    it "records spans for the login request but no attribute or event holds the sentinel" do
      login(password: SENTINEL)

      spans = captured_spans
      expect(response).to have_http_status(:ok)
      # Non-vacuous: the login request was traced.
      expect(spans).not_to be_empty
      expect(dump_spans(spans)).to include("/api/v1/session")

      expect(dump_spans(spans)).not_to include(SENTINEL)
    end

    it "does the same for a failed login" do
      login(password: "#{SENTINEL}-wrong")

      spans = captured_spans
      expect(response).to have_http_status(:unauthorized)
      expect(spans).not_to be_empty
      expect(dump_spans(spans)).to include("/api/v1/session")
      expect(dump_spans(spans)).not_to include(SENTINEL)
    end

    it "holds no sentinel in database spans (statements are obfuscated)" do
      login(password: SENTINEL)

      db_spans = captured_spans.select { |span| span.attributes&.key?("db.system") || span.attributes&.key?("db.system.name") }
      expect(db_spans).not_to be_empty # non-vacuous: the user lookup was traced
      expect(dump_spans(db_spans)).not_to include(SENTINEL)
    end
  end

  describe "scenario 16: Sentry" do
    it "captures an event for an error forced during login, holding no sentinel" do
      allow_any_instance_of(User).to receive(:valid_password?).and_raise(RuntimeError, "forced login failure")

      begin
        login(password: SENTINEL)
      rescue RuntimeError
        # In the test environment Rails re-raises unrescued errors; Sentry's
        # middleware has already captured it by then.
      end

      events = captured_sentry_events
      expect(events).not_to be_empty
      # Non-vacuous: it is our forced error, with real content in it.
      expect(dump(events.map(&:to_h))).to include("forced login failure")

      expect(dump(events.map(&:to_h))).not_to include(SENTINEL)
    end
  end
end
