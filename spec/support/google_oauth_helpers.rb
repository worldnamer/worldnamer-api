# Stubs for Google's token endpoint (GoogleCalendar::OauthClient). WebMock refuses every request that is not stubbed,
# so an example that never stubs the endpoint also proves Google was not called.
module GoogleOauthHelpers
  GOOGLE_TOKEN_ENDPOINT = "https://oauth2.googleapis.com/token".freeze
  GOOGLE_SCOPE = "https://www.googleapis.com/auth/calendar.events.owned.readonly".freeze

  # Google accepts the request. Returns the WebMock stub, for have_been_requested.
  def stub_google_tokens(access_token: "ya29.spec-access-token", refresh_token: nil, scope: GOOGLE_SCOPE, grant_type: nil)
    body = { access_token: access_token, expires_in: 3599, token_type: "Bearer", scope: scope }
    body[:refresh_token] = refresh_token if refresh_token
    stub = stub_request(:post, GOOGLE_TOKEN_ENDPOINT)
    stub = stub.with(body: hash_including("grant_type" => grant_type)) if grant_type
    stub.to_return(status: 200, body: body.to_json, headers: { "Content-Type" => "application/json" })
  end

  # Google answers with an OAuth error, such as "invalid_grant" (400) or "invalid_client" (401).
  def stub_google_token_error(error, status: 400)
    stub_request(:post, GOOGLE_TOKEN_ENDPOINT)
      .to_return(status: status, body: { error: error }.to_json, headers: { "Content-Type" => "application/json" })
  end

  def stub_google_token_server_error
    stub_request(:post, GOOGLE_TOKEN_ENDPOINT).to_return(status: 503, body: "Service Unavailable")
  end

  def stub_google_token_timeout
    stub_request(:post, GOOGLE_TOKEN_ENDPOINT).to_timeout
  end

  def google_token_endpoint
    GOOGLE_TOKEN_ENDPOINT
  end

  # The refresh_token column as stored, bypassing decryption.
  def stored_refresh_token_ciphertext(connection)
    ActiveRecord::Base.connection.select_value(
      "SELECT refresh_token FROM google_calendar_connections WHERE id = #{Integer(connection.id)}"
    )
  end
end

RSpec.configure do |config|
  config.include GoogleOauthHelpers, type: :request
  config.include GoogleOauthHelpers, type: :model
end
