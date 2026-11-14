# The wn_youtube_oauth cookie binds a YouTube sign-in to the browser that started it. POST
# /youtube_connection/authorization sets it to the raw state; the callback requires Google's state parameter to equal
# it, so a callback link from someone else's sign-in fails in this browser. Its name and path differ from the
# Calendar's cookie, so the two sign-ins never see each other's state.
#
# SameSite=Lax, not Strict: the callback is a top-level navigation started by Google, a different site, and Lax cookies
# are sent on those. Path limits the cookie to the callback; there is no Domain, so it stays host-only. Ten minutes,
# like the server-side row.
module YouTubeOauthCookie
  extend ActiveSupport::Concern

  # API-only controllers have no cookie helpers by default. The middleware is added in config/application.rb.
  include ActionController::Cookies

  COOKIE_NAME = "wn_youtube_oauth".freeze
  COOKIE_PATH = "/api/v1/youtube_connection/callback".freeze

  private

  def youtube_oauth_cookie_options
    {
      httponly: true,
      same_site: :lax,
      path: COOKIE_PATH,
      # Secure only in production (plain http works on localhost).
      secure: Rails.env.production?
    }
  end

  # Written with Rack's set_cookie rather than the cookie jar, which drops Secure cookies on a request it does not
  # consider SSL and skips writes it thinks change nothing.
  def set_youtube_oauth_cookie(raw_state)
    response.set_cookie(COOKIE_NAME, youtube_oauth_cookie_options.merge(value: raw_state, max_age: YouTubeOauthState::LIFETIME.to_i))
  end

  def clear_youtube_oauth_cookie
    response.set_cookie(COOKIE_NAME, youtube_oauth_cookie_options.merge(value: "", max_age: 0))
  end

  def youtube_oauth_cookie
    cookies[COOKIE_NAME]
  end
end
