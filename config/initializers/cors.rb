# Be sure to restart your server when you modify this file.

# CORS lets a browser running the React app (a different origin from this API) read our responses.
# It is enforced by the browser, not the server: it does not stop curl or other non-browser clients.
# Read more: https://github.com/cyu/rack-cors

allowed_origins = Rails.env.production? ? [ "https://worldnamer.com" ] : [ "http://localhost:5173" ]

Rails.application.config.middleware.insert_before 0, Rack::Cors do
  allow do
    origins(*allowed_origins)

    resource "*",
      # traceparent/tracestate carry the browser's trace into the API for Honeycomb.
      headers: %w[ Authorization Content-Type traceparent tracestate ],
      methods: %i[ get post put patch delete options head ],
      # Needed so the browser sends the httpOnly refresh-token cookie cross-origin (see ../CLAUDE.md, Auth).
      credentials: true,
      max_age: 86_400
  end
end
