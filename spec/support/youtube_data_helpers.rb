# Stubs for the YouTube Data API (YouTube::DataClient). WebMock refuses every request that is not stubbed, so an
# example that never stubs an endpoint also proves it was not called.
module YouTubeDataHelpers
  YOUTUBE_PLAYLISTS_ENDPOINT = "https://www.googleapis.com/youtube/v3/playlists".freeze
  YOUTUBE_PLAYLIST_ITEMS_ENDPOINT = "https://www.googleapis.com/youtube/v3/playlistItems".freeze

  def youtube_json(body, status: 200)
    { status: status, body: body.to_json, headers: { "Content-Type" => "application/json" } }
  end

  # Google's error shape, such as 404 playlistNotFound or 403 quotaExceeded.
  def youtube_error_body(status, reason, message: "Error")
    { error: { code: status, message: message, errors: [ { reason: reason, message: message } ] } }
  end

  # Playlists: list. playlists are [{ id:, title: }].
  def stub_youtube_playlists(playlists, access_token: nil)
    items = playlists.map { |p| { id: p[:id], snippet: { title: p[:title] } } }
    stub = stub_request(:get, YOUTUBE_PLAYLISTS_ENDPOINT).with(query: hash_including("mine" => "true"))
    stub = stub.with(headers: { "Authorization" => "Bearer #{access_token}" }) if access_token
    stub.to_return(youtube_json({ items: items }))
  end

  def stub_youtube_playlists_error(status, reason)
    stub_request(:get, YOUTUBE_PLAYLISTS_ENDPOINT).with(query: hash_including({}))
      .to_return(youtube_json(youtube_error_body(status, reason), status: status))
  end

  # A playlist item as Google sends it, after the fields filter.
  def youtube_item(id:, title:, position:, video_id: "dQw4w9WgXcQ")
    { id: id, snippet: { title: title, position: position, resourceId: { kind: "youtube#video", videoId: video_id } } }
  end

  # PlaylistItems: list for a playlist.
  def stub_youtube_playlist_items(playlist_id, items, total: items.size)
    stub_request(:get, YOUTUBE_PLAYLIST_ITEMS_ENDPOINT).with(query: hash_including("playlistId" => playlist_id))
      .to_return(youtube_json({ pageInfo: { totalResults: total }, items: items }))
  end

  def stub_youtube_playlist_items_error(status, reason)
    stub_request(:get, YOUTUBE_PLAYLIST_ITEMS_ENDPOINT).with(query: hash_including("playlistId" => anything))
      .to_return(youtube_json(youtube_error_body(status, reason), status: status))
  end

  # PlaylistItems: list for one item id. playlist_id nil answers with no items (YouTube knows no such item).
  def stub_youtube_find_item(item_id, playlist_id)
    items = playlist_id ? [ { id: item_id, snippet: { playlistId: playlist_id } } ] : []
    stub_request(:get, YOUTUBE_PLAYLIST_ITEMS_ENDPOINT).with(query: hash_including("id" => item_id))
      .to_return(youtube_json({ items: items }))
  end

  def stub_youtube_find_item_error(item_id, status, reason)
    stub_request(:get, YOUTUBE_PLAYLIST_ITEMS_ENDPOINT).with(query: hash_including("id" => item_id))
      .to_return(youtube_json(youtube_error_body(status, reason), status: status))
  end

  # PlaylistItems: delete. YouTube answers 204 with no body.
  def stub_youtube_delete_item(item_id, status: 204, reason: nil)
    stub = stub_request(:delete, YOUTUBE_PLAYLIST_ITEMS_ENDPOINT).with(query: { "id" => item_id })
    if reason
      stub.to_return(youtube_json(youtube_error_body(status, reason), status: status))
    else
      stub.to_return(status: status, body: "")
    end
  end
end

RSpec.configure do |config|
  config.include YouTubeDataHelpers, type: :request
  config.include YouTubeDataHelpers, type: :youtube_client
end
