# Builds the list of browser origins allowed to call the API (config.x.allowed_origins). Loaded by
# config/application.rb before the app boots, so it is plain Ruby and not autoloaded.
module AllowedOrigins
  PRODUCTION = [ "https://worldnamer.com" ].freeze
  DEFAULT = [ "http://localhost:5173" ].freeze

  # Outside production, ALLOWED_ORIGINS (comma-separated) replaces the default so a story's web dev server on
  # another port can log in. Production ignores it on purpose: a stray variable on App Platform must never
  # widen the live list. Entries are matched exactly later; nothing here expands or interprets them.
  def self.from(env, production:)
    return PRODUCTION if production

    entries = env.fetch("ALLOWED_ORIGINS", "").split(",").map(&:strip).reject(&:empty?)
    entries.empty? ? DEFAULT : entries
  end
end
