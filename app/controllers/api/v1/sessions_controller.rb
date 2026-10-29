module Api
  module V1
    class SessionsController < ApplicationController
      # API-only controllers have no cookie helpers by default. The middleware is added in config/application.rb.
      include ActionController::Cookies

      REFRESH_COOKIE = "wn_refresh".freeze
      REFRESH_COOKIE_PATH = "/api/v1/session".freeze

      # First, so a foreign or missing Origin gets 403 and nothing else happens (no rotation, no deletion, no cookie).
      before_action :require_allowed_origin
      # Responses carry an access token (or are about to), so no cache or proxy may keep them.
      before_action :no_store

      # A bcrypt digest of a throwaway string at the same cost as real passwords. Built on first use, then kept.
      def self.dummy_digest
        @dummy_digest ||= Devise::Encryptor.digest(User, SecureRandom.hex(16))
      end

      # POST /api/v1/session
      def create
        user = authenticate(params[:username], params[:password])
        return render_invalid_credentials unless user

        # Mint first: if it fails, nothing has been changed yet.
        body = access_token_body(user)
        raw_refresh_token = RefreshToken.transaction do
          # Logging in again from the same browser ends that browser's old session. Only this user's family is
          # deleted, so a cookie that belongs to someone else deletes nothing.
          old = RefreshToken.find_by_raw(cookies[REFRESH_COOKIE])
          RefreshToken.where(user_id: user.id, family_id: old.family_id).delete_all if old
          # Expired rows are purged here, once per login, not on every refresh.
          RefreshToken.where(user_id: user.id).where(expires_at: ..Time.current).delete_all
          RefreshToken.issue!(user: user)
        end

        set_refresh_cookie(raw_refresh_token)
        render json: body
      end

      # POST /api/v1/session/refresh. States and transitions: specs/login-plan.md, section 2.
      def refresh
        row = RefreshToken.find_by_raw(cookies[REFRESH_COOKIE])
        return render_unauthenticated unless row

        if row.expired?
          RefreshToken.revoke_family!(row.family_id)
          return render_unauthenticated
        end

        rotated = nil
        RefreshToken.transaction do
          # One atomic UPDATE ... WHERE used_at IS NULL. Exactly one of two racing requests wins it.
          rotated = RefreshToken.mark_used!(row.id)
          raw_refresh_token = RefreshToken.issue!(user: row.user, family_id: row.family_id) if rotated
          set_refresh_cookie(raw_refresh_token) if rotated
        end

        if rotated
          render json: access_token_body(row.user)
        else
          refresh_after_losing_the_race(row)
        end
      end

      # DELETE /api/v1/session. 204 whatever the cookie holds, and it needs no access token.
      def destroy
        row = RefreshToken.find_by_raw(cookies[REFRESH_COOKIE])
        RefreshToken.revoke_family!(row.family_id) if row
        clear_refresh_cookie
        head :no_content
      end

      private

      # The token was already used. Within the grace window that is a second tab or a lost response: hand out an access
      # token and leave the cookie alone (no new row, no Set-Cookie). Past it, it is reuse: delete the whole family.
      def refresh_after_losing_the_race(row)
        used_at = RefreshToken.where(id: row.id).pick(:used_at)
        if used_at && used_at > RefreshToken::GRACE_WINDOW.ago
          render json: access_token_body(row.user)
        else
          RefreshToken.revoke_family!(row.family_id)
          render_unauthenticated
        end
      end

      def require_allowed_origin
        return if Rails.configuration.x.allowed_origins.include?(request.headers["Origin"])

        render json: { error: { code: "forbidden_origin", message: "Origin not allowed." } }, status: :forbidden
      end

      def access_token_body(user)
        token, _payload = Warden::JWTAuth::UserEncoder.new.call(user, :user, nil)
        {
          access_token: token,
          token_type: "Bearer",
          expires_in: Warden::JWTAuth.config.expiration_time,
          user: { username: user.username }
        }
      end

      def refresh_cookie_options
        {
          httponly: true,
          same_site: :strict,
          path: REFRESH_COOKIE_PATH,
          # Secure only in production (plain http works on localhost). No domain: the cookie stays host-only.
          secure: Rails.env.production?
        }
      end

      # Reading goes through the cookie jar (ActionController::Cookies). Writing goes straight to the response with Rack's
      # set_cookie, because the jar skips a write when the value is unchanged (it would not clear an already-empty
      # cookie) and drops Secure cookies on a request it does not consider SSL.
      def set_refresh_cookie(raw_token)
        response.set_cookie(REFRESH_COOKIE, refresh_cookie_options.merge(value: raw_token, max_age: RefreshToken::LIFETIME.to_i))
      end

      # Same name and path, Max-Age=0.
      def clear_refresh_cookie
        response.set_cookie(REFRESH_COOKIE, refresh_cookie_options.merge(value: "", max_age: 0))
      end

      def render_unauthenticated
        clear_refresh_cookie
        render json: { error: { code: "unauthenticated", message: "Authentication required." } }, status: :unauthorized
      end

      def no_store
        # Rails 8 renders this as "Cache-Control: no-store".
        response.cache_control.replace(no_store: true)
      end

      # Returns the user when the username and password are right, otherwise nil. Every failure (missing field, wrong
      # type, unknown user, wrong password) ends the same way, so the response says nothing about which part was wrong.
      def authenticate(username, password)
        return nil unless username.is_a?(String) && password.is_a?(String)

        # find_for_authentication applies Devise's case_insensitive_keys and strip_whitespace_keys.
        user = User.find_for_authentication(username: username)
        return user if user&.valid_password?(password)

        # For an unknown username still spend one bcrypt comparison, so the response time does not reveal whether
        # the username exists. (A known user with a wrong password already paid for one in valid_password?.)
        Devise::Encryptor.compare(User, self.class.dummy_digest, password) unless user
        nil
      end

      def render_invalid_credentials
        render json: { error: { code: "invalid_credentials", message: "Invalid username or password." } },
          status: :unauthorized
      end
    end
  end
end
