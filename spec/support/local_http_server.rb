require "socket"

# A tiny plain-HTTP server on 127.0.0.1 for the few specs that need a request to really go through Net::HTTP: WebMock
# answers stubbed requests before Net::HTTP sends anything, so it can neither show Net::HTTP's own retries nor let the
# OpenTelemetry Net::HTTP instrumentation record its span.
#
#   with_local_http_server(->(request_text) { "HTTP/1.1 200 OK\r\n..." }) do |base_url, requests|
#     ...
#   end
#
# The responder gets the raw request (request line and headers) and returns the raw response, or nil to answer
# nothing and leave the client waiting. requests collects every raw request received. Only connections to the
# server's own address are let past WebMock, and only inside the block.
module LocalHttpServer
  def with_local_http_server(responder)
    server = TCPServer.new("127.0.0.1", 0)
    requests = Queue.new
    held = []
    thread = Thread.new do
      loop do
        socket = server.accept
        request = +""
        while (line = socket.gets)
          request << line
          break if line == "\r\n"
        end
        requests << request
        answer = responder.call(request)
        if answer
          socket.write(answer)
          socket.close
        else
          held << socket
        end
      end
    rescue IOError, Errno::EBADF
      # The server was closed at the end of the block.
    end

    WebMock.disable_net_connect!(allow: "127.0.0.1:#{server.addr[1]}")
    yield "http://127.0.0.1:#{server.addr[1]}", requests
  ensure
    WebMock.disable_net_connect!
    server&.close
    thread&.kill
    thread&.join
    held&.each(&:close)
  end

  # A complete HTTP/1.1 response with a JSON body.
  def local_json_response(body, status: "200 OK")
    json = body.to_json
    "HTTP/1.1 #{status}\r\nContent-Type: application/json\r\nContent-Length: #{json.bytesize}\r\nConnection: close\r\n\r\n#{json}"
  end
end

RSpec.configure do |config|
  config.include LocalHttpServer
end
