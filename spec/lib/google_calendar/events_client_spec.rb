require "rails_helper"

RSpec.describe GoogleCalendar::EventsClient do
  let(:client) { described_class.new }
  let(:endpoint) { "https://www.googleapis.com/calendar/v3/calendars/primary/events" }
  let(:access_token) { "ya29.SENTINEL-events-access-token" }
  let(:utc_date) { Date.new(2026, 11, 1) }
  let(:expected_query) do
    {
      "timeMin" => "2026-10-30T10:00:00Z",
      "timeMax" => "2026-11-03T12:00:00Z",
      "singleEvents" => "true",
      "orderBy" => "startTime",
      "showDeleted" => "false",
      "maxResults" => "250",
      "fields" => "nextPageToken,items(id,status,summary,start,end,eventType,attendees(self,responseStatus))"
    }
  end

  def json_response(status, body)
    { status: status, body: body.to_json, headers: { "Content-Type" => "application/json" } }
  end

  def stub_events(status: 200, body: { items: [] })
    stub_request(:get, endpoint).with(query: hash_including({})).to_return(json_response(status, body))
  end

  def list
    client.list(access_token: access_token, utc_date: utc_date)
  end

  describe ".window" do
    it "runs from 38 hours before to 60 hours after 00:00 UTC of the date" do
      time_min, time_max = described_class.window(utc_date)

      expect(time_min).to eq(Time.utc(2026, 10, 30, 10))
      expect(time_max).to eq(Time.utc(2026, 11, 3, 12))
    end

    it "holds the local yesterday, today and tomorrow of every zone from UTC-12 to UTC+14" do
      time_min, time_max = described_class.window(utc_date)

      # At any instant of UTC date D, a UTC+14 clock can still read D, and its yesterday starts at D-1 00:00 +14:00.
      expect(time_min).to be <= Time.new(2026, 10, 31, 0, 0, 0, "+14:00")
      # A UTC-12 clock can read D at the end of D UTC, and its tomorrow ends at D+2 00:00 -12:00.
      expect(time_max).to be >= Time.new(2026, 11, 3, 0, 0, 0, "-12:00")
    end
  end

  describe "#list" do
    it "calls Events: list on the primary calendar once, with the exact parameters and the token in a bearer header" do
      stub = stub_request(:get, endpoint)
        .with(query: expected_query, headers: { "Authorization" => "Bearer #{access_token}" })
        .to_return(json_response(200, items: []))

      list

      expect(stub).to have_been_requested.once
    end

    it "never puts the access token in the URL" do
      stub_events
      list

      expect(a_request(:get, /#{Regexp.escape(access_token)}/)).not_to have_been_made
    end

    it "returns Google's items as they came" do
      items = [ { "id" => "abc", "status" => "confirmed", "summary" => "Dentist", "start" => { "date" => "2026-11-01" } } ]
      stub_events(body: { items: items })

      expect(list).to eq(items)
    end

    it "returns no items when Google leaves the list out (an empty calendar)" do
      stub_events(body: {})

      expect(list).to eq([])
    end

    it "logs that there was a second page, never the page token" do
      stub_events(body: { items: [], nextPageToken: "SENTINEL-page-token" })
      io = StringIO.new
      capture_logger = ActiveSupport::Logger.new(io)
      Rails.logger.broadcast_to(capture_logger)

      list

      expect(io.string).to include("more than one page")
      expect(io.string).not_to include("SENTINEL-page-token")
    ensure
      Rails.logger.stop_broadcasting_to(capture_logger)
    end

    it "gives up after 2 seconds to connect and 3 to read, and never retries" do
      stub_events
      expect(Net::HTTP).to receive(:start)
        .with("www.googleapis.com", 443, hash_including(use_ssl: true, open_timeout: 2, read_timeout: 3, max_retries: 0))
        .and_call_original

      list
    end

    # WebMock answers before Net::HTTP's own retry logic runs, so this goes over a real socket to a local server that
    # never answers.
    it "sends the GET exactly once when Google does not answer in time" do
      stub_const("#{described_class}::READ_TIMEOUT", 0.2)

      with_local_http_server(->(_request) { nil }) do |base_url, requests|
        local = described_class.new(endpoint: URI("#{base_url}/calendar/v3/calendars/primary/events"))

        expect { local.list(access_token: access_token, utc_date: utc_date) }
          .to raise_error(described_class::Error) { |error| expect(error.cause).to be_nil }
        sleep 0.3 # room for a retry to arrive, if one were sent
        expect(requests.size).to eq(1)
      end
    end
  end

  describe "errors" do
    {
      401 => "authError",
      403 => "rateLimitExceeded",
      429 => "rateLimitExceeded",
      500 => "backendError"
    }.each do |status, reason|
      it "raises Error for a #{status}, with the status and Google's reason only" do
        stub_events(status: status, body: {
          error: { code: status, message: "Leaky message Dentist", errors: [ { reason: reason, message: "Leaky detail" } ] }
        })

        expect { list }.to raise_error(described_class::Error) { |error|
          expect(error.status).to eq(status)
          expect(error.message).to include(status.to_s, reason)
          expect(error.message).not_to include("Leaky", "Dentist", access_token)
        }
      end
    end

    it "drops a reason that is not a plain word" do
      stub_events(status: 403, body: { error: { errors: [ { reason: "Dentist at 9, room 4" } ] } })

      expect { list }.to raise_error(described_class::Error) { |error|
        expect(error.message).not_to include("Dentist")
      }
    end

    it "raises Error for a 5xx that is not JSON" do
      stub_request(:get, endpoint).with(query: hash_including({})).to_return(status: 503, body: "<html>Dentist</html>")

      expect { list }.to raise_error(described_class::Error) { |error|
        expect(error.status).to eq(503)
        expect(error.message).not_to include("Dentist")
      }
    end

    it "raises Error for a timeout, with no status and no underlying exception attached" do
      stub_request(:get, endpoint).with(query: hash_including({})).to_timeout

      expect { list }.to raise_error(described_class::Error) { |error|
        expect(error.status).to be_nil
        expect(error.cause).to be_nil
      }
    end

    it "raises Error for a success with an unreadable body, without quoting it" do
      stub_request(:get, endpoint).with(query: hash_including({})).to_return(status: 200, body: "{\"items\": [{\"summary\": \"Dentist")

      expect { list }.to raise_error(described_class::Error) { |error|
        expect(error.cause).to be_nil
        expect(error.message).not_to include("Dentist")
      }
    end

    it "raises Error for a success whose items are not a list" do
      stub_events(body: { items: "Dentist" })

      expect { list }.to raise_error(described_class::Error) { |error|
        expect(error.message).not_to include("Dentist")
      }
    end
  end
end
