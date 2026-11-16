require "rails_helper"

RSpec.describe Summaries::Client, type: :lib do
  let(:token) { "spec-summary-bearer-token" }
  let(:base_url) { "http://transcripts.test:8080" }
  let(:endpoint) { "#{base_url}/summary" }
  let(:client) { described_class.new(base_url: base_url, token: token) }
  let(:text) { "some words to summarise" }

  def json_response(body, status: 200)
    { status: status, body: body.to_json, headers: { "Content-Type" => "application/json" } }
  end

  def stub_service(response)
    stub_request(:post, endpoint).to_return(response)
  end

  def failed(reason)
    described_class::Result.new(outcome: "failed", reason: reason, text: nil, model: nil, tokens_in: nil, tokens_out: nil)
  end

  def ok_body(**changes)
    { outcome: "ok", summary: "A short summary.", model: "some-model", tokens_in: 120, tokens_out: 30 }.merge(changes)
  end

  describe "the request" do
    it "posts the text as JSON with the token in the Authorization header only" do
      stub = stub_request(:post, endpoint)
        .with(body: { text: text }.to_json,
          headers: { "Authorization" => "Bearer #{token}", "Content-Type" => "application/json" })
        .to_return(json_response(ok_body))

      client.summarise(text)

      expect(stub).to have_been_requested.once
      expect(a_request(:any, /#{Regexp.escape(token)}/)).not_to have_been_made
    end

    it "does not retry, and waits up to 2 seconds to connect and 180 to read" do
      expect(described_class::OPEN_TIMEOUT).to eq(2)
      expect(described_class::READ_TIMEOUT).to eq(180)
      stub = stub_request(:post, endpoint).to_raise(Net::ReadTimeout)

      client.summarise(text)

      expect(stub).to have_been_requested.once
    end

    it "sends nothing for a text that is not a non-blank string" do
      [ nil, "", "  \n", 12, [ text ] ].each { |bad| expect(client.summarise(bad)).to eq(failed("bad_response")) }

      expect(a_request(:any, /./)).not_to have_been_made
    end

    it "keeps the token out of inspect output" do
      expect(client.inspect).not_to include(token)
    end
  end

  describe "what the service answers" do
    it "200 with a summary, a model and token counts is done, carrying them" do
      stub_service(json_response(ok_body))

      expect(client.summarise(text)).to eq(
        described_class::Result.new(outcome: "done", reason: nil, text: "A short summary.", model: "some-model",
                                    tokens_in: 120, tokens_out: 30)
      )
    end

    it "200 with a missing or wrongly typed field, an unreadable body or a body that is not an object is bad_response" do
      [
        ok_body(summary: ""), ok_body(summary: "  "), ok_body(summary: nil), ok_body(summary: 5),
        ok_body(model: nil), ok_body(model: 3), ok_body(tokens_in: "12"), ok_body(tokens_out: 1.5), ok_body(tokens_in: nil),
        {}, [ 1 ]
      ].each do |body|
        stub_service(json_response(body))
        expect(client.summarise(text)).to eq(failed("bad_response")), body.inspect
      end
      [ { status: 200, body: "<html>nope" }, { status: 200, body: "" } ].each do |response|
        stub_service(response)
        expect(client.summarise(text)).to eq(failed("bad_response"))
      end
    end

    it "502 keeps the service's reason when it is timed_out, rate_limited, service_error or empty_answer" do
      %w[timed_out rate_limited service_error empty_answer].each do |reason|
        stub_service(json_response({ outcome: "failed", reason: reason }, status: 502))
        expect(client.summarise(text)).to eq(failed(reason))
      end
    end

    it "502 unauthorized is model_unauthorized, to tell it from this app's own token being refused" do
      stub_service(json_response({ outcome: "failed", reason: "unauthorized" }, status: 502))

      expect(client.summarise(text)).to eq(failed("model_unauthorized"))
    end

    it "any other 502 is unknown, and only listed words are ever kept" do
      [
        { outcome: "failed", reason: "ip banned by ACME" }, { outcome: "failed", reason: token }, { outcome: "failed", reason: 7 },
        { outcome: "failed", reason: "too_long" }, { outcome: "failed" }, { error: "x" }
      ].each do |body|
        stub_service(json_response(body, status: 502))
        expect(client.summarise(text)).to eq(failed("unknown")), body.inspect
      end
      [ { status: 502, body: "Bad Gateway" }, { status: 502, body: "" } ].each do |response|
        stub_service(response)
        expect(client.summarise(text)).to eq(failed("unknown"))
      end
    end

    it "422 too_long is too_long" do
      stub_service(json_response({ outcome: "failed", reason: "too_long" }, status: 422))

      expect(client.summarise(text)).to eq(failed("too_long"))
    end

    it "any other 422 is bad_response" do
      [ json_response({ error: "invalid_text" }, status: 422), json_response({ reason: token }, status: 422),
        { status: 422, body: "no" } ].each do |response|
        stub_service(response)
        expect(client.summarise(text)).to eq(failed("bad_response"))
      end
    end

    it "429 is busy and 401 is unauthorized" do
      stub_service(json_response({ error: "busy" }, status: 429))
      expect(client.summarise(text)).to eq(failed("busy"))
      stub_service(json_response({ error: "unauthorized" }, status: 401))
      expect(client.summarise(text)).to eq(failed("unauthorized"))
    end

    it "any other status is bad_response" do
      [ 204, 301, 400, 404, 413, 500, 503 ].each do |status|
        stub_service({ status: status, body: "" })
        expect(client.summarise(text)).to eq(failed("bad_response")), "status #{status}"
      end
    end
  end

  describe "when the call itself fails" do
    it "a read timeout is timed_out" do
      stub_request(:post, endpoint).to_raise(Net::ReadTimeout)

      expect(client.summarise(text)).to eq(failed("timed_out"))
    end

    it "a connection that cannot be made is unreachable" do
      [ Net::OpenTimeout, Errno::ECONNREFUSED, Errno::ECONNRESET, SocketError, EOFError, OpenSSL::SSL::SSLError ].each do |error|
        stub_request(:post, endpoint).to_raise(error)
        expect(client.summarise(text)).to eq(failed("unreachable")), error.name
      end
    end

    it "an unexpected error is bad_response, and nothing is raised" do
      stub_request(:post, endpoint).to_raise(StandardError.new("quoted #{text} and #{token}"))

      expect(client.summarise(text)).to eq(failed("bad_response"))
    end
  end

  describe "the result" do
    it "never holds the token or the service's raw body" do
      stub_service(json_response({ outcome: "failed", reason: "secret sauce #{token}" }, status: 502))

      expect(client.summarise(text).inspect).not_to include(token)
    end
  end
end
