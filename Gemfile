source "https://rubygems.org"

# Hard-coded (not read from .ruby-version) because DigitalOcean App Platform reads this line.
# Keep in sync with .ruby-version.
ruby "3.4.9"

# Bundle edge Rails instead: gem "rails", github: "rails/rails", branch: "main"
gem "rails", "~> 8.1.4"
# Use postgresql as the database for Active Record
gem "pg", "~> 1.1"
# Use the Puma web server [https://github.com/puma/puma]
gem "puma", ">= 5.0"
# Build JSON APIs with ease [https://github.com/rails/jbuilder]
# gem "jbuilder"

# Use Active Model has_secure_password [https://guides.rubyonrails.org/active_model_basics.html#securepassword]
# gem "bcrypt", "~> 3.1.7"

# Windows does not include zoneinfo files, so bundle the tzinfo-data gem
gem "tzinfo-data", platforms: %i[ windows jruby ]

# Use the database-backed adapters for Rails.cache, Active Job, and Action Cable
gem "solid_cache"
gem "solid_queue"
gem "solid_cable"

# Reduces boot times through caching; required in config/boot.rb
gem "bootsnap", require: false

# Use Active Storage variants [https://guides.rubyonrails.org/active_storage_overview.html#transforming-images]
gem "image_processing", "~> 1.2"

# Use Rack CORS for handling Cross-Origin Resource Sharing (CORS), making cross-origin Ajax possible
gem "rack-cors"

group :development, :test do
  # See https://guides.rubyonrails.org/debugging_rails_applications.html#debugging-with-the-debug-gem
  gem "debug", platforms: %i[ mri windows ], require: "debug/prelude"

  # Audits gems for known security defects (use config/bundler-audit.yml to ignore issues)
  gem "bundler-audit", require: false

  # Static analysis for security vulnerabilities [https://brakemanscanner.org/]
  gem "brakeman", require: false

  # Omakase Ruby styling [https://github.com/rails/rubocop-rails-omakase/]
  gem "rubocop-rails-omakase", require: false

  # Testing: RSpec with FactoryBot for test data
  gem "rspec-rails"
  gem "factory_bot_rails"
  gem "dotenv-rails", "~> 3.2" # loads .env.development.local (gitignored) for local-only keys
end

# Traces to Honeycomb over OpenTelemetry (see config/initializers/opentelemetry.rb)
gem "opentelemetry-sdk", "~> 1.13"
gem "opentelemetry-exporter-otlp", "~> 0.37.0"
gem "opentelemetry-instrumentation-all", "~> 0.99.0"

# Exception reporting to Sentry (see config/initializers/sentry.rb)
gem "sentry-ruby", "~> 7.1"
gem "sentry-rails", "~> 7.1"

# Login: Devise for bcrypt and Warden, devise-jwt for the access token (bcrypt and jwt arrive with them)
gem "devise", "~> 5.0"
gem "devise-jwt", "~> 0.13.0"

# Throttles POST /api/v1/session (see config/initializers/rack_attack.rb)
gem "rack-attack", "~> 6.8"
