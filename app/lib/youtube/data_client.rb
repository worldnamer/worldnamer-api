require "net/http"

module Youtube
  # The few YouTube Data API v3 calls the playlist page needs, on plain Net::HTTP, made with one user's access token.
  #
  # The OAuth scope behind the token can also manage the user's videos, comments and subscriptions, so this class is
  # deliberately the only way the app talks to YouTube, and it has exactly four public methods: three reads and the
  # removal of one playlist item. There is no method for videos, channels or any other write, and a spec pins the list.
  # Quota cost per call, out of a shared 10,000 units a day: each read 1 unit, a delete 50.
  #
  # The access token travels in the Authorization header, never in the URL, so it cannot reach a log line or a span
  # that records the request target. Each read asks Google, through fields=, for only the fields it uses.
  #
  # Errors never carry a response body: only the HTTP status and Google's reason code (such as "playlistNotFound").
  # They are also raised without the underlying exception attached, because that exception's message could quote the
  # body, and Sentry reports the whole chain.
  class DataClient
    BASE_URL = URI("https://www.googleapis.com/youtube/v3/").freeze

    # Seconds. The browser gives up on the whole request after 5, and a token call comes first.
    OPEN_TIMEOUT = 2
    READ_TIMEOUT = 3

    # The first page of the user's playlists, and the first videos of a playlist.
    PLAYLISTS_PAGE_SIZE = 50
    ITEMS_PAGE_SIZE = 10

    PLAYLISTS_FIELDS = "items(id,snippet/title)".freeze
    ITEMS_FIELDS = "pageInfo/totalResults,items(id,snippet(title,position,resourceId/videoId))".freeze
    ITEM_FIELDS = "items(id,snippet/playlistId)".freeze

    # A YouTube video id. Anything else from Google is dropped rather than turned into a link.
    VIDEO_ID = /\A[A-Za-z0-9_-]{11}\z/

    # Network failure, timeout, an unexpected status, or a body that cannot be read. status is the HTTP status as an
    # Integer, or nil when Google never answered; reason is Google's reason code when it sent a plain one.
    class Error < StandardError
      attr_reader :status, :reason

      def initialize(message, status: nil, reason: nil)
        super(message)
        @status = status
        @reason = reason
      end
    end

    def initialize(access_token:, base_url: BASE_URL)
      @access_token = access_token
      @base_url = base_url
    end

    # Playlists: list with mine=true, the first page. Returns [{ id:, title: }] in YouTube's order.
    def list_playlists
      body = get_json("playlists", part: "snippet", mine: "true", maxResults: PLAYLISTS_PAGE_SIZE, fields: PLAYLISTS_FIELDS)
      items(body).map { |item| { id: item["id"].to_s, title: item.dig("snippet", "title").to_s } }
    end

    # PlaylistItems: list for one playlist, the first page in playlist order. Returns
    # { total_count:, items: [{ id:, video_id:, title:, position: }] }; video_id is nil unless it is a valid video id.
    def list_playlist_items(playlist_id)
      body = get_json("playlistItems", part: "snippet", playlistId: playlist_id, maxResults: ITEMS_PAGE_SIZE, fields: ITEMS_FIELDS)
      list = items(body).map do |item|
        snippet = item["snippet"].is_a?(Hash) ? item["snippet"] : {}
        video_id = snippet.dig("resourceId", "videoId")
        {
          id: item["id"].to_s,
          video_id: video_id.is_a?(String) && video_id.match?(VIDEO_ID) ? video_id : nil,
          title: snippet["title"].to_s,
          position: snippet["position"].is_a?(Integer) ? snippet["position"] : nil
        }
      end
      total = body.dig("pageInfo", "totalResults")
      { total_count: total.is_a?(Integer) ? total : list.size, items: list }
    end

    # PlaylistItems: list for one item id. Returns { id:, playlist_id: }, or nil when YouTube knows no such item.
    def find_playlist_item(id)
      body = get_json("playlistItems", part: "snippet", id: id, fields: ITEM_FIELDS)
      item = items(body).first
      item && { id: item["id"].to_s, playlist_id: item.dig("snippet", "playlistId").to_s }
    end

    # PlaylistItems: delete. Removes the item from its playlist; the video itself is untouched. Returns true.
    def delete_playlist_item(id)
      response = request(Net::HTTP::Delete, "playlistItems", id: id)
      raise_for(response) unless response.is_a?(Net::HTTPSuccess)

      true
    end

    private

    def get_json(resource, query)
      response = request(Net::HTTP::Get, resource, query)
      raise_for(response) unless response.is_a?(Net::HTTPSuccess)

      body = parse_json(response.body)
      raise Error.new("YouTube answered #{response.code} without an object", status: response.code.to_i) unless body.is_a?(Hash)

      body
    end

    def items(body)
      list = body["items"] || []
      raise Error, "YouTube answered without a list of items" unless list.is_a?(Array)

      list.select { |item| item.is_a?(Hash) }
    end

    def request(method_class, resource, query)
      uri = URI.join(@base_url, resource)
      target = "#{uri.path}?#{URI.encode_www_form(query)}"
      # max_retries = 0: by default Net::HTTP quietly sends an idempotent request again after a read timeout. That
      # would double the wait on Google, and for DELETE it would remove the item a second time and spend its quota
      # twice.
      Net::HTTP.start(
        uri.host, uri.port,
        use_ssl: uri.scheme == "https", open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT, max_retries: 0
      ) do |http|
        http.request(method_class.new(target, "Authorization" => "Bearer #{@access_token}", "Accept" => "application/json"))
      end
    rescue Timeout::Error, SystemCallError, SocketError, IOError, OpenSSL::SSL::SSLError,
           Net::ProtocolError, Net::HTTPBadResponse => e
      raise Error, "YouTube unreachable (#{e.class.name})", cause: nil
    end

    # Google's error body looks like { "error": { "code": 404, "errors": [ { "reason": "playlistNotFound" } ] } }.
    def raise_for(response)
      body = parse_json(response.body, strict: false)
      error = body["error"] if body.is_a?(Hash)
      first = error["errors"].first if error.is_a?(Hash) && error["errors"].is_a?(Array)
      reason = first["reason"] if first.is_a?(Hash)
      # Only a plain word is kept, so nothing else from the body can reach the message.
      reason = nil unless reason.is_a?(String) && reason.match?(/\A[A-Za-z_]{1,64}\z/)

      raise Error.new("YouTube answered #{response.code} (#{reason || "no reason"})", status: response.code.to_i, reason: reason)
    end

    # With strict: false an unreadable body is nil (an error status says enough on its own).
    def parse_json(text, strict: true)
      JSON.parse(text.to_s)
    rescue JSON::ParserError
      raise Error, "YouTube sent a body that is not JSON", cause: nil if strict

      nil
    end
  end
end
