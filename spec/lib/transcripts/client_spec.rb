require "rails_helper"

RSpec.describe Transcripts::Client, type: :lib do
  let(:token) { "spec-transcripts-bearer-token" }
  let(:base_url) { "http://transcripts.test:8080" }
  let(:endpoint) { "#{base_url}/transcript" }
  let(:client) { described_class.new(base_url: base_url, token: token) }
  let(:video_id) { "dQw4w9WgXcQ" }

  def json_response(body, status: 200)
    { status: status, body: body.to_json, headers: { "Content-Type" => "application/json" } }
  end

  def stub_service(response)
    stub_request(:post, endpoint).to_return(response)
  end

  def result(outcome, reason: nil, lines: nil)
    described_class::Result.new(outcome: outcome, reason: reason, lines: lines)
  end

  def failed(reason)
    result("failed", reason: reason)
  end

  describe "the request" do
    it "posts the video id as JSON with the token in the Authorization header only" do
      stub = stub_request(:post, endpoint)
        .with(body: { video_id: video_id }.to_json,
          headers: { "Authorization" => "Bearer #{token}", "Content-Type" => "application/json" })
        .to_return(json_response({ outcome: "no_captions" }))

      client.fetch(video_id)

      expect(stub).to have_been_requested.once
      expect(a_request(:any, /#{Regexp.escape(token)}/)).not_to have_been_made
    end

    it "does not retry, and waits up to 2 seconds to connect and 110 to read" do
      expect(described_class::OPEN_TIMEOUT).to eq(2)
      expect(described_class::READ_TIMEOUT).to eq(110)
      stub = stub_request(:post, endpoint).to_raise(Net::ReadTimeout)

      client.fetch(video_id)

      expect(stub).to have_been_requested.once
    end

    it "sends nothing for an id that is not 11 characters of letters, digits, _ and -" do
      [ "short", "twelve_chars", "abc def ghij", "a;b/c?d=e&f", "aaaaaaaaaaa\n", nil, 12_345_678_901, [ video_id ] ].each do |bad|
        expect(client.fetch(bad)).to eq(failed("bad_response"))
      end

      expect(a_request(:any, /./)).not_to have_been_made
    end

    it "keeps the token out of inspect output" do
      expect(client.inspect).not_to include(token)
    end
  end

  describe "what the service answers" do
    it "200 ok is done, with the lines' text and start only" do
      stub_service(json_response({ outcome: "ok", lines: [
        { text: "Hello", start: 0.0, duration: 2.1, extra: "x" }, { text: "World", start: 3 }
      ] }))

      expect(client.fetch(video_id)).to eq(result("done", lines: [
        { "text" => "Hello", "start" => 0.0 }, { "text" => "World", "start" => 3 }
      ]))
    end

    it "drops line entries of the wrong shape" do
      stub_service(json_response({ outcome: "ok", lines: [ { text: "Kept", start: 1 }, { text: 5, start: 1 }, { text: "x" }, "y" ] }))

      expect(client.fetch(video_id).lines).to eq([ { "text" => "Kept", "start" => 1 } ])
    end

    it "200 ok with no usable lines is bad_response, never done" do
      [ { outcome: "ok", lines: [] }, { outcome: "ok" }, { outcome: "ok", lines: "text" }, { outcome: "ok", lines: [ { text: 1 } ] } ].each do |body|
        stub_service(json_response(body))
        expect(client.fetch(video_id)).to eq(failed("bad_response"))
      end
    end

    it "200 no_captions is no_captions" do
      stub_service(json_response({ outcome: "no_captions" }))

      expect(client.fetch(video_id)).to eq(result("no_captions"))
    end

    it "200 with any other outcome, an unreadable body or a body that is not an object is bad_response" do
      [ json_response({ outcome: "failed", reason: "blocked" }), json_response({}), json_response([ 1 ]),
        { status: 200, body: "<html>nope" }, { status: 200, body: "" } ].each do |response|
        stub_service(response)
        expect(client.fetch(video_id)).to eq(failed("bad_response"))
      end
    end

    it "502 failed carries the service's reason when it is on the list" do
      %w[blocked timed_out unavailable proxy_refused youtube_error unknown].each do |reason|
        stub_service(json_response({ outcome: "failed", reason: reason }, status: 502))
        expect(client.fetch(video_id)).to eq(failed(reason))
      end
    end

    it "502 failed with a reason that is not on the list, or none, is stored as unknown" do
      [ { outcome: "failed", reason: "ip banned by ACME proxy" }, { outcome: "failed", reason: 7 }, { outcome: "failed" } ].each do |body|
        stub_service(json_response(body, status: 502))
        expect(client.fetch(video_id)).to eq(failed("unknown"))
      end
    end

    it "502 with a body that is not a failed outcome is bad_response" do
      [ json_response({ error: "x" }, status: 502), { status: 502, body: "Bad Gateway" }, { status: 502, body: "" } ].each do |response|
        stub_service(response)
        expect(client.fetch(video_id)).to eq(failed("bad_response"))
      end
    end

    it "429 is busy, 401 is unauthorized and 422 is bad_response" do
      stub_service(json_response({ error: "busy" }, status: 429))
      expect(client.fetch(video_id)).to eq(failed("busy"))
      stub_service(json_response({ error: "unauthorized" }, status: 401))
      expect(client.fetch(video_id)).to eq(failed("unauthorized"))
      stub_service(json_response({ error: "invalid_video_id" }, status: 422))
      expect(client.fetch(video_id)).to eq(failed("bad_response"))
    end

    it "any other status is bad_response" do
      [ 204, 301, 400, 404, 500, 503 ].each do |status|
        stub_service({ status: status, body: "" })
        expect(client.fetch(video_id)).to eq(failed("bad_response")), "status #{status}"
      end
    end
  end

  describe "when the call itself fails" do
    it "a read timeout is timed_out" do
      stub_request(:post, endpoint).to_raise(Net::ReadTimeout)

      expect(client.fetch(video_id)).to eq(failed("timed_out"))
    end

    it "a connection that cannot be made is unreachable" do
      [ Net::OpenTimeout, Errno::ECONNREFUSED, Errno::ECONNRESET, SocketError, EOFError, OpenSSL::SSL::SSLError ].each do |error|
        stub_request(:post, endpoint).to_raise(error)
        expect(client.fetch(video_id)).to eq(failed("unreachable")), error.name
      end
    end

    it "an unexpected error is bad_response, and nothing is raised" do
      stub_request(:post, endpoint).to_raise(StandardError.new("quoted body and #{token}"))

      expect(client.fetch(video_id)).to eq(failed("bad_response"))
    end
  end

  describe "the result" do
    it "never holds the token or the service's raw body" do
      stub_service(json_response({ outcome: "failed", reason: "secret sauce #{token}" }, status: 502))

      expect(client.fetch(video_id).inspect).not_to include(token)
    end
  end

  describe "the telemetry span" do
    def fetch_spans
      captured_spans.select { |span| span.name == "transcripts.fetch" }
    end

    it "leaves one client span per fetch with the outcome and a whole-number duration in milliseconds" do
      stub_service(json_response({ outcome: "ok", lines: [ { text: "Hi", start: 0 } ] }))

      client.fetch(video_id)

      expect(fetch_spans.size).to eq(1)
      span = fetch_spans.first
      expect(span.kind).to eq(:client)
      expect(span.attributes).to match(
        "transcripts.outcome" => "done", "transcripts.duration_ms" => a_kind_of(Integer)
      )
      expect(span.attributes["transcripts.duration_ms"]).to be >= 0
    end

    it "adds the reason only when the fetch failed" do
      stub_service(json_response({ outcome: "failed", reason: "blocked" }, status: 502))

      client.fetch(video_id)

      expect(fetch_spans.first.attributes).to include("transcripts.outcome" => "failed", "transcripts.reason" => "blocked")
    end

    it "records no reason for no captions" do
      stub_service(json_response({ outcome: "no_captions" }))

      client.fetch(video_id)

      expect(fetch_spans.first.attributes).to match(
        "transcripts.outcome" => "no_captions", "transcripts.duration_ms" => a_kind_of(Integer)
      )
    end

    it "leaves the span's status unset, even for a failure, and for a call that could not be made" do
      stub_request(:post, endpoint).to_raise(Errno::ECONNREFUSED)

      client.fetch(video_id)

      expect(fetch_spans.first.status.code).to eq(OpenTelemetry::Trace::Status::UNSET)
      expect(fetch_spans.first.attributes).to include("transcripts.reason" => "unreachable")
    end

    it "leaves no span for an id that is refused without a call" do
      client.fetch("not an id")

      expect(fetch_spans).to be_empty
    end

    it "holds nothing but the three attributes: no video id, title, token or text" do
      stub_service(json_response({ outcome: "ok", lines: [ { text: "SENTINEL-line-text", start: 0 } ] }))

      client.fetch(video_id)

      dump = dump_spans(fetch_spans)
      expect(dump).to include("transcripts.fetch")
      expect_none_of([ video_id, token, "SENTINEL-line-text" ], dump)
      expect(fetch_spans.first.attributes.keys)
        .to contain_exactly("transcripts.outcome", "transcripts.duration_ms")
    end
  end
end
