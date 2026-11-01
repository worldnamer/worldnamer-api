require "net/http"

module GoogleCalendar
  # Google's OAuth 2.0 authorization code flow, on plain Net::HTTP: the consent URL, swapping the code for tokens, and
  # minting an access token from the stored refresh token.
  #
  # Errors never carry a response body, a token or the client secret: only the HTTP status and Google's error code
  # (such as "invalid_client"). They are also raised without the underlying exception attached, because that exception's
  # message could quote the body, and Sentry reports the whole chain.
  class OauthClient
    AUTHORIZATION_ENDPOINT = "https://accounts.google.com/o/oauth2/v2/auth".freeze
    TOKEN_ENDPOINT = URI("https://oauth2.googleapis.com/token").freeze

    # The only scope ever requested: read events on calendars the user owns.
    SCOPE = "https://www.googleapis.com/auth/calendar.events.owned.readonly".freeze

    # Seconds. A status check waits on Google while the browser waits on us, so give up well before the browser does.
    OPEN_TIMEOUT = 3
    READ_TIMEOUT = 3

    # Network failure, timeout, an unexpected status, or a body that cannot be read.
    class Error < StandardError; end
    # Google rejected the code or refresh token (revoked, expired, already used). Retrying will not help.
    class InvalidGrant < Error; end

    # What a successful token request returns. scopes is the list Google actually granted. refresh_token is nil when
    # Google sends none (a refresh usually does not).
    TokenResponse = Data.define(:access_token, :refresh_token, :scopes) do
      # Keeps the tokens out of anything that inspects or prints this object (a log line, an error report).
      def inspect
        "#<#{self.class.name} scopes=#{scopes.inspect}>"
      end
      alias_method :to_s, :inspect
    end

    def initialize(config = Rails.configuration.x.google_oauth)
      @client_id = config.fetch(:client_id)
      @client_secret = config.fetch(:client_secret)
      @redirect_uri = config.fetch(:redirect_uri)
    end

    # The Google consent page to send the browser to. It holds the client id, the state and the PKCE challenge, never
    # the secret. access_type=offline asks for a refresh token; prompt=consent asks for one again on every connect.
    def authorization_url(state:, code_challenge:)
      query = {
        client_id: @client_id,
        redirect_uri: @redirect_uri,
        response_type: "code",
        scope: SCOPE,
        state: state,
        code_challenge: code_challenge,
        code_challenge_method: "S256",
        access_type: "offline",
        prompt: "consent"
      }
      "#{AUTHORIZATION_ENDPOINT}?#{URI.encode_www_form(query)}"
    end

    # Swaps the one-time code from the callback for tokens. Returns a TokenResponse.
    def exchange_code(code:, code_verifier:)
      request_tokens(
        grant_type: "authorization_code",
        code: code,
        code_verifier: code_verifier,
        redirect_uri: @redirect_uri
      )
    end

    # Mints a new access token from a stored refresh token. Returns a TokenResponse. Raises InvalidGrant when Google
    # no longer accepts the refresh token.
    def refresh_access_token(refresh_token)
      request_tokens(grant_type: "refresh_token", refresh_token: refresh_token)
    end

    private

    def request_tokens(form)
      response = post_form(form.merge(client_id: @client_id, client_secret: @client_secret))
      raise_for(response) unless response.is_a?(Net::HTTPSuccess)

      body = parse_json(response.body)
      access_token = body["access_token"] if body.is_a?(Hash)
      raise Error, "Google token endpoint answered #{response.code} without an access token" unless access_token.is_a?(String)

      TokenResponse.new(
        access_token: access_token,
        refresh_token: body["refresh_token"].presence,
        scopes: body["scope"].to_s.split
      )
    end

    def post_form(form)
      Net::HTTP.start(
        TOKEN_ENDPOINT.host, TOKEN_ENDPOINT.port,
        use_ssl: true, open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT
      ) do |http|
        http.post(TOKEN_ENDPOINT.path, URI.encode_www_form(form), "Content-Type" => "application/x-www-form-urlencoded")
      end
    rescue Timeout::Error, SystemCallError, SocketError, IOError, OpenSSL::SSL::SSLError,
           Net::ProtocolError, Net::HTTPBadResponse => e
      raise Error, "Google token endpoint unreachable (#{e.class.name})", cause: nil
    end

    def raise_for(response)
      body = parse_json(response.body, strict: false)
      code = body["error"] if body.is_a?(Hash)
      # Only a plain snake_case word is kept, so nothing else from the body can reach the message.
      code = nil unless code.is_a?(String) && code.match?(/\A[a-z_]{1,64}\z/)

      if response.code == "400" && code == "invalid_grant"
        raise InvalidGrant, "Google token endpoint answered 400 (invalid_grant)"
      end
      raise Error, "Google token endpoint answered #{response.code} (#{code || "no error code"})"
    end

    # With strict: false an unreadable body is nil (an error status says enough on its own).
    def parse_json(text, strict: true)
      JSON.parse(text.to_s)
    rescue JSON::ParserError
      raise Error, "Google token endpoint sent a body that is not JSON", cause: nil if strict

      nil
    end
  end
end
