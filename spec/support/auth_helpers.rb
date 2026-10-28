# Helpers shared by request specs that talk to the login API.
module AuthHelpers
  TEST_PASSWORD = "correct horse battery staple".freeze

  def jwt_secret
    ENV.fetch("DEVISE_JWT_SECRET_KEY")
  end

  def json_post(path, body = {}, headers: {}, env: {})
    post path, params: body, as: :json, headers: headers, env: env
  end

  def login(username: "john", password: TEST_PASSWORD, **options)
    json_post "/api/v1/session", { username: username, password: password }, **options
  end

  def decode_jwt(token, key: jwt_secret)
    JWT.decode(token, key, true, algorithm: "HS256").first
  end

  def bearer(token)
    { "Authorization" => "Bearer #{token}" }
  end

  def expected_unauthenticated_body
    { "error" => { "code" => "unauthenticated", "message" => a_kind_of(String) } }
  end
end

RSpec.configure do |config|
  config.include AuthHelpers, type: :request
  config.include AuthHelpers, type: :task
end
