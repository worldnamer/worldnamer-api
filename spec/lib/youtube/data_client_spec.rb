require "rails_helper"

RSpec.describe Youtube::DataClient, type: :youtube_client do
  let(:access_token) { "ya29.spec-youtube-access" }
  let(:client) { described_class.new(access_token: access_token) }
  let(:auth_header) { { "Authorization" => "Bearer #{access_token}" } }

  describe "public methods" do
    # The scope behind the token could manage the user's videos, comments and subscriptions. These four, three reads
    # and one playlist-item removal, are all the app may do with it.
    it "are exactly the three reads and the playlist-item removal" do
      expect(described_class.public_instance_methods(false))
        .to contain_exactly(:list_playlists, :list_playlist_items, :find_playlist_item, :delete_playlist_item)
    end
  end

  describe "#list_playlists" do
    it "asks for the user's own playlists, the first 50, with a fields filter and the token in a header" do
      stub = stub_request(:get, YoutubeDataHelpers::YOUTUBE_PLAYLISTS_ENDPOINT)
        .with(query: { "part" => "snippet", "mine" => "true", "maxResults" => "50", "fields" => "items(id,snippet/title)" },
          headers: auth_header)
        .to_return(youtube_json({ items: [ { id: "PLone", snippet: { title: "One" } }, { id: "PLtwo", snippet: { title: "Two" } } ] }))

      expect(client.list_playlists).to eq([ { id: "PLone", title: "One" }, { id: "PLtwo", title: "Two" } ])
      expect(stub).to have_been_requested.once
    end

    it "is empty when the user has no playlists" do
      stub_request(:get, YoutubeDataHelpers::YOUTUBE_PLAYLISTS_ENDPOINT).with(query: hash_including({}))
        .to_return(youtube_json({}))

      expect(client.list_playlists).to eq([])
    end

    it "never puts the token in the URL" do
      stub_youtube_playlists([])

      client.list_playlists

      expect(a_request(:get, /#{Regexp.escape(access_token)}/)).not_to have_been_made
    end
  end

  describe "#list_playlist_items" do
    it "asks for the first 10 items of the playlist, with a fields filter, and returns them in order with the total" do
      stub = stub_request(:get, YoutubeDataHelpers::YOUTUBE_PLAYLIST_ITEMS_ENDPOINT)
        .with(query: { "part" => "snippet", "playlistId" => "PLchosen", "maxResults" => "10",
          "fields" => "pageInfo/totalResults,items(id,snippet(title,position,resourceId/videoId))" }, headers: auth_header)
        .to_return(youtube_json({ pageInfo: { totalResults: 73 }, items: [
          youtube_item(id: "item0", title: "First", position: 0, video_id: "aaaaaaaaaaa"),
          youtube_item(id: "item1", title: "Second", position: 1, video_id: "bbbbbbbbbbb")
        ] }))

      expect(client.list_playlist_items("PLchosen")).to eq(
        total_count: 73,
        items: [
          { id: "item0", video_id: "aaaaaaaaaaa", title: "First", position: 0 },
          { id: "item1", video_id: "bbbbbbbbbbb", title: "Second", position: 1 }
        ]
      )
      expect(stub).to have_been_requested.once
    end

    it "drops a video id that is not a YouTube video id" do
      stub_youtube_playlist_items("PLchosen", [
        youtube_item(id: "item0", title: "Odd", position: 0, video_id: "javascript:alert(1)"),
        youtube_item(id: "item1", title: "Missing", position: 1, video_id: nil)
      ])

      items = client.list_playlist_items("PLchosen")[:items]

      expect(items.map { |item| item[:video_id] }).to eq([ nil, nil ])
    end

    it "encodes the playlist id as a query value" do
      stub = stub_request(:get, YoutubeDataHelpers::YOUTUBE_PLAYLIST_ITEMS_ENDPOINT)
        .with(query: hash_including("playlistId" => "PL&id=x")).to_return(youtube_json({ items: [] }))

      expect(client.list_playlist_items("PL&id=x")).to eq(total_count: 0, items: [])
      expect(stub).to have_been_requested.once
    end
  end

  describe "#find_playlist_item" do
    it "asks for the one item with a fields filter and returns its playlist" do
      stub = stub_request(:get, YoutubeDataHelpers::YOUTUBE_PLAYLIST_ITEMS_ENDPOINT)
        .with(query: { "part" => "snippet", "id" => "item0", "fields" => "items(id,snippet/playlistId)" }, headers: auth_header)
        .to_return(youtube_json({ items: [ { id: "item0", snippet: { playlistId: "PLchosen" } } ] }))

      expect(client.find_playlist_item("item0")).to eq(id: "item0", playlist_id: "PLchosen")
      expect(stub).to have_been_requested.once
    end

    it "is nil when YouTube knows no such item" do
      stub_youtube_find_item("gone", nil)

      expect(client.find_playlist_item("gone")).to be_nil
    end
  end

  describe "#delete_playlist_item" do
    it "sends DELETE /youtube/v3/playlistItems with only the item id, and the token in a header" do
      stub = stub_request(:delete, YoutubeDataHelpers::YOUTUBE_PLAYLIST_ITEMS_ENDPOINT)
        .with(query: { "id" => "item0" }, headers: auth_header).to_return(status: 204, body: "")

      expect(client.delete_playlist_item("item0")).to be(true)
      expect(stub).to have_been_requested.once
    end

    it "raises Error with the status and reason on a 404" do
      stub_youtube_delete_item("item0", status: 404, reason: "playlistItemNotFound")

      expect { client.delete_playlist_item("item0") }.to raise_error(described_class::Error) { |error|
        expect(error.status).to eq(404)
        expect(error.reason).to eq("playlistItemNotFound")
      }
    end
  end

  describe "the connection" do
    it "gives up after 2 seconds to connect and 3 to read, and never retries" do
      stub_youtube_playlists([])
      expect(Net::HTTP).to receive(:start)
        .with("www.googleapis.com", 443, hash_including(use_ssl: true, open_timeout: 2, read_timeout: 3, max_retries: 0))
        .and_call_original

      client.list_playlists
    end

    # WebMock answers before Net::HTTP's own retry logic runs, so this goes over a real socket to a local server that
    # never answers. Net::HTTP counts DELETE as idempotent and would otherwise send it again.
    it "sends the DELETE exactly once when YouTube does not answer in time" do
      stub_const("#{described_class}::READ_TIMEOUT", 0.2)

      with_local_http_server(->(_request) { nil }) do |base_url, requests|
        local = described_class.new(access_token: access_token, base_url: URI("#{base_url}/youtube/v3/"))

        expect { local.delete_playlist_item("item0") }
          .to raise_error(described_class::Error) { |error| expect(error.cause).to be_nil }
        sleep 0.3 # room for a retry to arrive, if one were sent
        expect(requests.size).to eq(1)
        expect(requests.pop).to start_with("DELETE /youtube/v3/playlistItems?id=item0 ")
      end
    end
  end

  describe "errors" do
    {
      401 => "authError",
      403 => "quotaExceeded",
      404 => "playlistNotFound",
      500 => "backendError"
    }.each do |status, reason|
      it "raise Error for a #{status}, with the status and Google's reason only" do
        stub_request(:get, YoutubeDataHelpers::YOUTUBE_PLAYLISTS_ENDPOINT).with(query: hash_including({}))
          .to_return(youtube_json(youtube_error_body(status, reason, message: "Leaky message Secret Title"), status: status))

        expect { client.list_playlists }.to raise_error(described_class::Error) { |error|
          expect(error.status).to eq(status)
          expect(error.reason).to eq(reason)
          expect(error.message).to include(status.to_s, reason)
          expect(error.message).not_to include("Leaky", "Secret Title", access_token)
        }
      end
    end

    it "drop a reason that is not a plain word" do
      stub_request(:get, YoutubeDataHelpers::YOUTUBE_PLAYLISTS_ENDPOINT).with(query: hash_including({}))
        .to_return(youtube_json(youtube_error_body(400, "Secret Title here"), status: 400))

      expect { client.list_playlists }.to raise_error(described_class::Error) { |error|
        expect(error.reason).to be_nil
        expect(error.message).not_to include("Secret Title")
      }
    end

    it "raise Error for a timeout, with no underlying exception attached" do
      stub_request(:get, YoutubeDataHelpers::YOUTUBE_PLAYLISTS_ENDPOINT).with(query: hash_including({})).to_timeout

      expect { client.list_playlists }.to raise_error(described_class::Error) { |error|
        expect(error.status).to be_nil
        expect(error.cause).to be_nil
      }
    end

    it "raise Error for a success with an unreadable body, quoting none of it" do
      stub_request(:get, YoutubeDataHelpers::YOUTUBE_PLAYLISTS_ENDPOINT).with(query: hash_including({}))
        .to_return(status: 200, body: "not json Secret Title")

      expect { client.list_playlists }.to raise_error(described_class::Error) { |error|
        expect(error.cause).to be_nil
        expect(error.message).not_to include("Secret Title")
      }
    end
  end
end
