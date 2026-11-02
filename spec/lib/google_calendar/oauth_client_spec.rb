require "rails_helper"

RSpec.describe GoogleCalendar::OauthClient do
  let(:client) { described_class.new }
  let(:token_endpoint) { "https://oauth2.googleapis.com/token" }
  let(:client_id) { "spec-client-id.apps.googleusercontent.com" }
  let(:client_secret) { "SENTINEL-google-client-secret-5d1c-do-not-leak" }
  let(:redirect_uri) { "http://www.example.com/api/v1/google_calendar_connection/callback" }
  let(:scope) { "https://www.googleapis.com/auth/calendar.events.owned.readonly" }

  def json_response(status, body)
    { status: status, body: body.to_json, headers: { "Content-Type" => "application/json" } }
  end

  describe "SCOPE" do
    it "is exactly the read-only scope for events on calendars the user owns" do
      expect(described_class::SCOPE).to eq(scope)
    end
  end

  describe "#authorization_url" do
    let(:url) { URI(client.authorization_url(state: "the-state", code_challenge: "the-challenge")) }
    let(:query) { URI.decode_www_form(url.query).to_h }

    it "points at Google's consent endpoint" do
      expect("#{url.scheme}://#{url.host}#{url.path}").to eq("https://accounts.google.com/o/oauth2/v2/auth")
    end

    it "asks for exactly the one scope, offline access and a fresh consent, with an S256 PKCE challenge" do
      expect(query).to eq(
        "client_id" => client_id,
        "redirect_uri" => redirect_uri,
        "response_type" => "code",
        "scope" => scope,
        "state" => "the-state",
        "code_challenge" => "the-challenge",
        "code_challenge_method" => "S256",
        "access_type" => "offline",
        "prompt" => "consent"
      )
    end

    it "never carries the client secret, and asks for no other scopes" do
      expect(url.to_s).not_to include(client_secret)
      expect(query).not_to include("include_granted_scopes", "login_hint")
      expect(query["scope"].split).to eq([ scope ])
    end
  end

  describe "#exchange_code" do
    it "posts the code, verifier, client credentials and redirect URI, and returns the tokens and granted scopes" do
      stub = stub_request(:post, token_endpoint)
        .with(body: {
          "grant_type" => "authorization_code",
          "code" => "the-code",
          "code_verifier" => "the-verifier",
          "client_id" => client_id,
          "client_secret" => client_secret,
          "redirect_uri" => redirect_uri
        })
        .to_return(json_response(200, access_token: "ya29.access", refresh_token: "1//refresh", scope: scope, expires_in: 3599, token_type: "Bearer"))

      tokens = client.exchange_code(code: "the-code", code_verifier: "the-verifier")

      expect(stub).to have_been_requested.once
      expect(tokens.access_token).to eq("ya29.access")
      expect(tokens.refresh_token).to eq("1//refresh")
      expect(tokens.scopes).to eq([ scope ])
    end

    it "returns a nil refresh token and every granted scope when Google sends them that way" do
      stub_request(:post, token_endpoint)
        .to_return(json_response(200, access_token: "ya29.access", scope: "openid #{scope}"))

      tokens = client.exchange_code(code: "the-code", code_verifier: "the-verifier")

      expect(tokens.refresh_token).to be_nil
      expect(tokens.scopes).to eq([ "openid", scope ])
    end

    it "raises InvalidGrant for a code Google rejects" do
      stub_request(:post, token_endpoint).to_return(json_response(400, error: "invalid_grant", error_description: "Bad Request"))

      expect { client.exchange_code(code: "the-code", code_verifier: "the-verifier") }
        .to raise_error(GoogleCalendar::OauthClient::InvalidGrant)
    end
  end

  describe "#refresh_access_token" do
    it "posts the refresh token with the client credentials and returns the new access token" do
      stub = stub_request(:post, token_endpoint)
        .with(body: {
          "grant_type" => "refresh_token",
          "refresh_token" => "1//refresh",
          "client_id" => client_id,
          "client_secret" => client_secret
        })
        .to_return(json_response(200, access_token: "ya29.fresh", scope: scope, expires_in: 3599))

      tokens = client.refresh_access_token("1//refresh")

      expect(stub).to have_been_requested.once
      expect(tokens.access_token).to eq("ya29.fresh")
      expect(tokens.refresh_token).to be_nil
    end

    it "raises InvalidGrant when Google answers 400 invalid_grant (token revoked or expired)" do
      stub_request(:post, token_endpoint).to_return(json_response(400, error: "invalid_grant"))

      expect { client.refresh_access_token("1//refresh") }.to raise_error(GoogleCalendar::OauthClient::InvalidGrant)
    end

    it "raises a plain Error, not InvalidGrant, for invalid_client" do
      stub_request(:post, token_endpoint).to_return(json_response(401, error: "invalid_client"))

      expect { client.refresh_access_token("1//refresh") }.to raise_error(GoogleCalendar::OauthClient::Error) { |error|
        expect(error).not_to be_a(GoogleCalendar::OauthClient::InvalidGrant)
        expect(error.message).to include("401", "invalid_client")
      }
    end

    it "raises Error for a 5xx" do
      stub_request(:post, token_endpoint).to_return(status: 503, body: "<html>unavailable</html>")

      expect { client.refresh_access_token("1//refresh") }.to raise_error(GoogleCalendar::OauthClient::Error, /503/)
    end

    it "raises Error for a timeout, with no underlying exception attached" do
      stub_request(:post, token_endpoint).to_timeout

      expect { client.refresh_access_token("1//refresh") }.to raise_error(GoogleCalendar::OauthClient::Error) { |error|
        expect(error.cause).to be_nil
      }
    end

    it "raises Error for a success with an unreadable body, with no underlying exception attached" do
      stub_request(:post, token_endpoint).to_return(status: 200, body: "not json ya29.half-a-token")

      expect { client.refresh_access_token("1//refresh") }.to raise_error(GoogleCalendar::OauthClient::Error) { |error|
        expect(error.cause).to be_nil
        expect(error.message).not_to include("ya29")
      }
    end

    it "gives up after 3 seconds to connect and 3 seconds to read" do
      stub_request(:post, token_endpoint).to_return(json_response(200, access_token: "ya29.fresh"))
      expect(Net::HTTP).to receive(:start)
        .with("oauth2.googleapis.com", 443, hash_including(use_ssl: true, open_timeout: 3, read_timeout: 3))
        .and_call_original

      client.refresh_access_token("1//refresh")
    end
  end

  describe "errors" do
    it "carry only the status and Google's error code, never the response body or the tokens sent" do
      stub_request(:post, token_endpoint)
        .to_return(json_response(400, error: "invalid_request", error_description: "Leaky description 1//refresh"))

      expect { client.refresh_access_token("1//refresh") }.to raise_error(GoogleCalendar::OauthClient::Error) { |error|
        expect(error.message).to include("400", "invalid_request")
        expect(error.message).not_to include("Leaky", "1//refresh", client_secret)
      }
    end

    it "drop an error code that is not a plain snake_case word" do
      stub_request(:post, token_endpoint).to_return(json_response(400, error: "1//refresh sneaked in"))

      expect { client.refresh_access_token("1//refresh") }.to raise_error(GoogleCalendar::OauthClient::Error) { |error|
        expect(error.message).not_to include("1//refresh")
      }
    end
  end

  describe "the token response" do
    it "hides the tokens when inspected" do
      stub_request(:post, token_endpoint).to_return(json_response(200, access_token: "ya29.secret", refresh_token: "1//secret"))

      tokens = client.refresh_access_token("1//refresh")

      expect(tokens.inspect).not_to include("ya29.secret", "1//secret")
      expect(tokens.to_s).not_to include("ya29.secret", "1//secret")
    end
  end
end
