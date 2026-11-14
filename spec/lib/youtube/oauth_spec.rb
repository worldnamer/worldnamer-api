require "rails_helper"

RSpec.describe YouTube::Oauth do
  it "asks for exactly the scope that manages the user's YouTube account" do
    expect(described_class::SCOPE).to eq("https://www.googleapis.com/auth/youtube")
  end

  it "builds a client that sends Google back to the YouTube callback" do
    url = described_class.client.authorization_url(state: "s", code_challenge: "c")
    query = URI.decode_www_form(URI(url).query).to_h

    expect(query["redirect_uri"]).to eq("http://www.example.com/api/v1/youtube_connection/callback")
    expect(query["scope"]).to eq(described_class::SCOPE)
  end
end
