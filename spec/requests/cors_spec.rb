require "rails_helper"

RSpec.describe "CORS", type: :request do
  let(:allowed_origin) { "http://localhost:5173" }

  it "allows the configured origin to read responses, with credentials" do
    get "/api/v1/health", headers: { "Origin" => allowed_origin }

    expect(response.headers["Access-Control-Allow-Origin"]).to eq(allowed_origin)
    expect(response.headers["Access-Control-Allow-Credentials"]).to eq("true")
  end

  it "answers a preflight request that asks for the traceparent header" do
    process :options, "/api/v1/health", headers: {
      "Origin" => allowed_origin,
      "Access-Control-Request-Method" => "GET",
      "Access-Control-Request-Headers" => "authorization,traceparent"
    }

    expect(response).to have_http_status(:ok)
    expect(response.headers["Access-Control-Allow-Origin"]).to eq(allowed_origin)
    expect(response.headers["Access-Control-Allow-Headers"].downcase).to include("traceparent")
  end

  it "answers a preflight for PUT to a completions path from the allowed origin, with PUT allowed" do
    process :options, "/api/v1/habits/1/completions/2026-10-28", headers: {
      "Origin" => allowed_origin,
      "Access-Control-Request-Method" => "PUT",
      "Access-Control-Request-Headers" => "authorization"
    }

    expect(response).to have_http_status(:ok)
    expect(response.headers["Access-Control-Allow-Origin"]).to eq(allowed_origin)
    expect(response.headers["Access-Control-Allow-Methods"].split(/,\s*/)).to include("PUT")
    expect(response.headers["Access-Control-Allow-Headers"].downcase).to include("authorization")
  end

  it "sends no CORS headers to other origins, but still serves the request" do
    get "/api/v1/health", headers: { "Origin" => "https://evil.example" }

    expect(response.headers).not_to have_key("Access-Control-Allow-Origin")
    expect(response).to have_http_status(:ok)
  end
end
