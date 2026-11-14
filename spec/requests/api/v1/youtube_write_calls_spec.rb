require "rails_helper"

# The YouTube scope could delete the user's videos and change much else on their account. The site may write exactly
# one thing: removing an item from the chosen playlist. This drives every YouTube endpoint against WebMock and reads
# every request the app sent, so a new call anywhere would show up here.
RSpec.describe "Outgoing calls of the YouTube endpoints", type: :request do
  let!(:user) { create(:user, username: "john") }
  let(:token_uri) { URI(google_token_endpoint) }

  def bearer_token
    login(username: "john")
    response.parsed_body.fetch("access_token")
  end

  def outgoing
    WebMock::RequestRegistry.instance.requested_signatures.hash.keys
  end

  def youtube_calls
    outgoing.reject { |signature| signature.uri.host == token_uri.host && signature.uri.path == token_uri.path }
  end

  before do
    stub_google_tokens(refresh_token: "1//yt", scope: YouTube::Oauth::SCOPE)
    stub_youtube_playlists([ { id: "PLchosen01", title: "Chosen" } ])
    stub_youtube_playlist_items("PLchosen01", [ youtube_item(id: "item0", title: "A video", position: 0) ])
    stub_youtube_find_item("item0", "PLchosen01")
    stub_youtube_find_item("itemElsewhere", "PLanother1")
    stub_youtube_delete_item("item0")
  end

  it "makes one DELETE of a playlist item, by id only, and never touches videos" do
    token = bearer_token

    post "/api/v1/youtube_connection/authorization", headers: bearer(token)
    state = URI.decode_www_form(URI(response.parsed_body.fetch("authorization_url")).query).to_h.fetch("state")
    get "/api/v1/youtube_connection/callback", params: { code: "the-code", state: state }
    expect(response.headers["Location"]).to end_with("youtube=connected")

    get "/api/v1/youtube_connection", headers: bearer(token)
    get "/api/v1/youtube_connection/playlists", headers: bearer(token)
    put "/api/v1/youtube_connection/playlist", params: { playlist: { id: "PLchosen01" } }, as: :json, headers: bearer(token)
    get "/api/v1/youtube_connection/playlist/items", headers: bearer(token)
    delete "/api/v1/youtube_connection/playlist/items/item0", headers: bearer(token)
    expect(response).to have_http_status(:no_content)

    # Non-vacuous: every read really happened.
    paths = youtube_calls.map { |signature| [ signature.method, signature.uri.path ] }
    expect(paths).to include([ :get, "/youtube/v3/playlists" ], [ :get, "/youtube/v3/playlistItems" ])

    writes = youtube_calls.reject { |signature| signature.method == :get }
    expect(writes.size).to eq(1)
    expect(writes.first.method).to eq(:delete)
    expect(writes.first.uri.host).to eq("www.googleapis.com")
    expect(writes.first.uri.path).to eq("/youtube/v3/playlistItems")
    expect(writes.first.uri.query).to eq("id=item0")
    expect(WebMock::RequestRegistry.instance.requested_signatures.get(writes.first)).to eq(1) # sent once

    expect(outgoing.map { |signature| signature.uri.path }).not_to include(a_string_including("/youtube/v3/videos"))
    # The only POST is to Google's token endpoint.
    expect(outgoing.select { |s| s.method == :post }.map { |s| s.uri.host }.uniq).to eq([ token_uri.host ])
  end

  it "makes no DELETE for an item in another playlist" do
    create(:youtube_connection, user: user, playlist_id: "PLchosen01", playlist_title: "Chosen")

    delete "/api/v1/youtube_connection/playlist/items/itemElsewhere", headers: bearer(bearer_token)

    expect(response).to have_http_status(:not_found)
    expect(youtube_calls.map(&:method)).to eq([ :get ]) # non-vacuous: the lookup happened
    expect(outgoing.map(&:method)).not_to include(:delete, :put, :patch)
  end
end
