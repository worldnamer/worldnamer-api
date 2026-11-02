# Stubs for Google Calendar's Events: list (GoogleCalendar::EventsClient). WebMock refuses every request that is not
# stubbed, so an example that never stubs the endpoint also proves the events were not fetched.
module GoogleCalendarEventsHelpers
  GOOGLE_EVENTS_ENDPOINT = "https://www.googleapis.com/calendar/v3/calendars/primary/events".freeze

  def google_events_endpoint
    GOOGLE_EVENTS_ENDPOINT
  end

  # Google answers with these items (Google's shape). Returns the WebMock stub, for have_been_requested.
  def stub_google_events(items = [], access_token: nil)
    stub = stub_request(:get, GOOGLE_EVENTS_ENDPOINT).with(query: hash_including({}))
    stub = stub.with(headers: { "Authorization" => "Bearer #{access_token}" }) if access_token
    stub.to_return(status: 200, body: { items: items }.to_json, headers: { "Content-Type" => "application/json" })
  end

  # Google answers with an API error, such as 403 rateLimitExceeded.
  def stub_google_events_error(status, reason)
    body = { error: { code: status, message: "Error", errors: [ { reason: reason } ] } }
    stub_request(:get, GOOGLE_EVENTS_ENDPOINT).with(query: hash_including({}))
      .to_return(status: status, body: body.to_json, headers: { "Content-Type" => "application/json" })
  end

  # An item as Google sends it for a timed event.
  def google_timed_event(id:, summary:, start:, finish:, **extra)
    { "id" => id, "status" => "confirmed", "summary" => summary, "eventType" => "default",
      "start" => { "dateTime" => start }, "end" => { "dateTime" => finish } }.merge(extra.transform_keys(&:to_s))
  end

  # An item as Google sends it for an all-day event.
  def google_all_day_event(id:, summary:, start:, finish:, **extra)
    { "id" => id, "status" => "confirmed", "summary" => summary, "eventType" => "default",
      "start" => { "date" => start }, "end" => { "date" => finish } }.merge(extra.transform_keys(&:to_s))
  end
end

RSpec.configure do |config|
  config.include GoogleCalendarEventsHelpers, type: :request
end
