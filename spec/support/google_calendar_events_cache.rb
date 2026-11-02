# The events cache (config/initializers/google_calendar.rb) lives for the whole process, so one example's cached
# events would answer the next example's request. Give every example a fresh, empty store instead.
module GoogleCalendarEventsCache
  def google_calendar_events_cache
    Rails.configuration.x.google_calendar.events_cache
  end
end

RSpec.configure do |config|
  config.include GoogleCalendarEventsCache, type: :request

  config.before(:each) do
    Rails.configuration.x.google_calendar.events_cache = ActiveSupport::Cache::MemoryStore.new(size: 4.megabytes)
  end
end
