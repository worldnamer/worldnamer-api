require "webmock/rspec"

# No spec may reach the network. Calls to Google are stubbed with stub_request; any other outgoing HTTP request fails
# the example with WebMock::NetConnectNotAllowedError. webmock/rspec also clears stubs and recorded requests after
# every example.
WebMock.disable_net_connect!
