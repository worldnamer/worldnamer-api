# Helpers shared by request specs that talk to the login API.
module AuthHelpers
  TEST_PASSWORD = "correct horse battery staple".freeze
  # The one origin config.x.allowed_origins holds in the test environment.
  ALLOWED_ORIGIN = "http://localhost:5173".freeze
  REFRESH_COOKIE = "wn_refresh".freeze

  def jwt_secret
    ENV.fetch("DEVISE_JWT_SECRET_KEY")
  end

  # Session endpoints require an allowed Origin (api-2). It is sent by default;
  # pass origin: "https://evil.example" to send another, or origin: nil to send none.
  def origin_headers(origin = ALLOWED_ORIGIN)
    origin ? { "Origin" => origin } : {}
  end

  def json_post(path, body = {}, headers: {}, env: {}, origin: ALLOWED_ORIGIN)
    post path, params: body, as: :json, headers: origin_headers(origin).merge(headers), env: env
  end

  # Sets (or, with nil, removes) the refresh cookie in the test client's cookie jar,
  # replacing whatever an earlier response left there.
  def send_cookie(token)
    cookies.delete(REFRESH_COOKIE)
    cookies[REFRESH_COOKIE] = token if token
  end

  def refresh(token = :keep, origin: ALLOWED_ORIGIN, **options)
    send_cookie(token) unless token == :keep
    post "/api/v1/session/refresh", headers: origin_headers(origin), **options
  end

  def logout(token = :keep, origin: ALLOWED_ORIGIN, **options)
    send_cookie(token) unless token == :keep
    delete "/api/v1/session", headers: origin_headers(origin), **options
  end

  # All Set-Cookie lines of a response as one string (Rack 3 may give a String or an Array).
  def raw_set_cookie(res = response)
    Array(res.headers["Set-Cookie"]).join("\n")
  end

  # The raw refresh token a response set, or nil if it set none (or cleared it).
  def refresh_token_from(res = response)
    raw_set_cookie(res)[/#{REFRESH_COOKIE}=([^;\n]+)/, 1]
  end

  def digest_of(token)
    Digest::SHA256.hexdigest(token)
  end

  # Logs in and returns the raw refresh token from the response.
  def login_and_get_refresh_token(**options)
    login(**options)
    refresh_token_from
  end

  def row_for(token)
    RefreshToken.find_by(token_digest: digest_of(token))
  end

  def expect_cleared_cookie(res = response)
    line = raw_set_cookie(res).lines.find { |l| l.start_with?("#{REFRESH_COOKIE}=") }
    expect(line).to be_present
    expect(line).to match(/max-age=0/i)
    expect(line).to match(%r{path=/api/v1/session(;|\s|$)}i)
  end

  def expect_forbidden_origin(res = response)
    expect(res).to have_http_status(:forbidden)
    expect(res.parsed_body).to match("error" => { "code" => "forbidden_origin", "message" => a_kind_of(String) })
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
