# Devise is used for bcrypt hashing and for Warden's JWT strategy only. The controllers are our own thin ones
# (Api::V1::SessionsController, Api::V1::MeController) and devise_for in routes.rb adds no routes.
require "devise/orm/active_record"

Devise.setup do |config|
  # The user logs in with a username. There is no email column.
  config.authentication_keys = [ :username ]
  config.case_insensitive_keys = [ :username ]
  config.strip_whitespace_keys = [ :username ]

  # API only: no sessions, no redirects, no flash. Failures are JSON (Auth::FailureApp).
  config.navigational_formats = []
  config.skip_session_storage = [ :http_auth, :params_auth ]

  # bcrypt cost. 12 is about 250 ms of CPU, which is why POST /session is throttled (config/initializers/rack_attack.rb).
  # Specs use cost 1 so the suite stays fast.
  config.stretches = Rails.env.test? ? 1 : 12

  # Signs and verifies the access token (devise-jwt). HS256 is devise-jwt's default.
  # Production fails loudly if the key is missing (ENV.fetch). Development and test use the env var if set, otherwise
  # a fixed throwaway key, so local work needs no setup. The throwaway key must never reach production.
  config.jwt do |jwt|
    jwt.secret =
      if Rails.env.production?
        ENV.fetch("DEVISE_JWT_SECRET_KEY")
      else
        ENV.fetch("DEVISE_JWT_SECRET_KEY", "development-and-test-only-throwaway-jwt-key")
      end
    jwt.expiration_time = 900 # 15 minutes
  end
end
