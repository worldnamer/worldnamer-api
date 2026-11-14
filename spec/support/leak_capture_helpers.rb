# Captures for the YouTube leak specs: what reached the Rails log, the OpenTelemetry spans and Sentry, as text a spec
# can search for sentinel values. Each leak check first asserts that something real was captured, so an empty capture
# cannot pass.
module LeakCaptureHelpers
  # The Rails log written while the block runs.
  def request_logging
    io = StringIO.new
    capture_logger = ActiveSupport::Logger.new(io)
    Rails.logger.broadcast_to(capture_logger)
    yield
    io.string
  ensure
    Rails.logger.stop_broadcasting_to(capture_logger)
  end

  # Names, attributes and events of the spans, as one string.
  def dump_spans(spans = captured_spans)
    spans.map do |span|
      {
        name: span.name,
        attributes: span.attributes,
        events: Array(span.events).map { |event| { name: event.name, attributes: event.attributes } }
      }
    end.inspect
  end

  # Every captured Sentry event, as one string.
  def dump_sentry_events
    captured_sentry_events.map(&:to_h).inspect
  end

  def expect_none_of(values, text)
    values.each { |value| expect(text).not_to include(value), "#{value.inspect} leaked" }
  end
end

RSpec.configure do |config|
  config.include LeakCaptureHelpers, type: :request
end
