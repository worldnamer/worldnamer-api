require "rails_helper"

RSpec.describe "GET /api/v1/health", type: :request do
  it "returns 200 with status ok when the database is reachable" do
    get "/api/v1/health"

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq("status" => "ok", "db" => "ok")
  end

  it "serves the same response at /up" do
    get "/up"

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq("status" => "ok", "db" => "ok")
  end

  it "returns 503 when the database is unreachable" do
    allow(ActiveRecord::Base.connection).to receive(:select_value).and_raise(ActiveRecord::ConnectionNotEstablished)

    get "/api/v1/health"

    expect(response).to have_http_status(:service_unavailable)
    expect(response.parsed_body).to eq("status" => "error", "db" => "unreachable")
  end
end
