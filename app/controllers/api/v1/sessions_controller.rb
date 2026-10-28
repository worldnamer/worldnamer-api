module Api
  module V1
    class SessionsController < ApplicationController
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

        token, _payload = Warden::JWTAuth::UserEncoder.new.call(user, :user, nil)
        render json: {
          access_token: token,
          token_type: "Bearer",
          expires_in: Warden::JWTAuth.config.expiration_time,
          user: { username: user.username }
        }
      end

      private

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
