# Each user's normalized Google Calendar events, kept for a minute so reloads and open tabs do not each cost two calls
# to Google (Api::V1::GoogleCalendarConnections::EventsController).
#
# A store of its own in process memory, not Rails.cache: Rails.cache is Solid Cache in production, which would write
# private event titles to Postgres in plaintext and add a database write on every miss, and it is a null store in
# test, where the cache could not be checked. Being in memory, it is per Puma process and empties on every deploy,
# which is harmless for a minute's worth of data. The size cap bounds its memory; the oldest entries go first.
Rails.application.config.x.google_calendar.events_cache = ActiveSupport::Cache::MemoryStore.new(size: 4.megabytes)
