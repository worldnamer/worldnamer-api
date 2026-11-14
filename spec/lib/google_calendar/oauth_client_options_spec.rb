require "rails_helper"

# The scope and redirect URI a caller can pass in place of the Calendar's defaults.
RSpec.describe GoogleCalendar::OauthClient, "with a scope and redirect URI of its own" do
  let(:token_endpoint) { "https://oauth2.googleapis.com/token" }
  let(:other_scope) { "https://www.googleapis.com/auth/youtube" }
  let(:other_redirect_uri) { "http://www.example.com/api/v1/youtube_connection/callback" }
  let(:client) { described_class.new(scope: other_scope, redirect_uri: other_redirect_uri) }

  it "asks for the given scope only, and sends Google back to the given redirect URI" do
    url = client.authorization_url(state: "the-state", code_challenge: "the-challenge")
    query = URI.decode_www_form(URI(url).query).to_h

    expect(query["scope"].split).to eq([ other_scope ])
    expect(query["redirect_uri"]).to eq(other_redirect_uri)
  end

  it "exchanges the code with the given redirect URI" do
    stub = stub_request(:post, token_endpoint)
      .with(body: hash_including("grant_type" => "authorization_code", "redirect_uri" => other_redirect_uri))
      .to_return(status: 200, body: { access_token: "ya29.access", refresh_token: "1//refresh", scope: other_scope }.to_json)

    client.exchange_code(code: "the-code", code_verifier: "the-verifier")

    expect(stub).to have_been_requested.once
  end

  it "keeps the Calendar's scope and redirect URI when none are given" do
    query = URI.decode_www_form(URI(described_class.new.authorization_url(state: "s", code_challenge: "c")).query).to_h

    expect(query["scope"]).to eq(described_class::SCOPE)
    expect(query["redirect_uri"]).to eq(Rails.configuration.x.google_oauth.fetch(:redirect_uri))
  end
end
