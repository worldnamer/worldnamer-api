require "rails_helper"

RSpec.describe "Unknown paths", type: :request do
  it "returns 404 for the root path" do
    get "/"

    expect(response).to have_http_status(:not_found)
  end

  it "returns 404 for any other unknown path" do
    get "/nope"

    expect(response).to have_http_status(:not_found)
  end
end
