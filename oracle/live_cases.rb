# Oracle cases for ActionController::Live (Iteration 9).
#
# Run against the ORIGINAL gem:
#   ruby oracle/live_cases.rb > oracle/live_expected.yml
#
# Each line: "<case_id>\t<value>". Mirrored 1:1 in
# railties.cr/spec/live_spec.cr; the Crystal port must reproduce
# live_expected.yml exactly (captured from actionpack 8.1.4 + puma).
#
# Two groups:
#  - sse_* / buffer_*: in-process, deterministic wire bytes and
#    Live::Buffer semantics (SizedQueue(10) backpressure, abort,
#    ClientDisconnected, close) captured without any server.
#  - transport_*: a real HTTP server (Puma, thread mode) exercising
#    chunked framing, headers on first write, SSE over the wire,
#    send_stream, error-before-commit and client-disconnect
#    cancellation, driven by raw TCP sockets.

gem "actionpack", "= 8.1.4"
gem "activesupport", "= 8.1.4"
gem "rack", "~> 3.2"
require "action_controller"
require "stringio"
require "socket"
require "tmpdir"

def render(v)
  case v
  when String then v
  else v.inspect
  end
end

def case_run(id)
  puts "#{id}\t#{render(yield)}"
rescue StandardError => e
  puts "#{id}\traise:#{e.class.name}"
end

# ---------------------------------------------------------------------------
# Part A: SSE wire format (no server, StringIO stream)
# ---------------------------------------------------------------------------

class FakeStream
  attr_reader :chunks, :closed

  def initialize
    @chunks = []
    @closed = false
  end

  def write(str)
    @chunks << str
    str.bytesize
  end

  def close
    @closed = true
  end
end

def sse_bytes(object, ctor: {}, write: {})
  io = FakeStream.new
  sse = ActionController::Live::SSE.new(io, **ctor)
  sse.write(object, **write)
  io.chunks.join
end

case_run("sse_data") do
  sse_bytes("foo").inspect
end

case_run("sse_data_multiline") do
  sse_bytes("line1\nline2\n").inspect
end

case_run("sse_json_object") do
  sse_bytes({ "name" => "John" }).inspect
end

case_run("sse_json_nested") do
  sse_bytes({ "a" => [1, 2], "b" => nil }).inspect
end

case_run("sse_opts_order") do
  # PERMITTED_OPTIONS order: retry, event, id — regardless of kwarg order
  sse_bytes("x", write: { id: 10, event: "greet", retry: 500 }).inspect
end

case_run("sse_ctor_defaults") do
  sse_bytes("x", ctor: { retry: 300, event: "event-name" }).inspect
end

case_run("sse_write_overrides_ctor") do
  sse_bytes("x", ctor: { retry: 300, event: "a" }, write: { event: "b", retry: 500 }).inspect
end

case_run("sse_falsy_id_omitted") do
  # nil/absent options emit no line; id: 0 is falsy in Ruby -> omitted
  sse_bytes("x", write: { id: nil, event: nil, retry: nil }).inspect
end

case_run("sse_close_closes_stream") do
  io = FakeStream.new
  sse = ActionController::Live::SSE.new(io)
  sse.close
  io.closed.to_s
end

# ---------------------------------------------------------------------------
# Part A: Live::Buffer semantics (no server)
# ---------------------------------------------------------------------------

def live_buffer
  response = ActionDispatch::Response.new
  buffer = ActionController::Live::Buffer.new(response)
  [response, buffer]
end

case_run("buffer_queue_size_default") do
  ActionController::Live::Buffer.queue_size.to_s
end

case_run("buffer_write_headers") do
  response, buffer = live_buffer
  response.headers["content-length"] = "999"
  buffer.write("x")
  "#{response.headers["cache-control"]}|cl:#{response.headers["content-length"].inspect}|" \
    "committed:#{response.committed?.to_s}"
end

case_run("buffer_write_returns_bytesize") do
  _, buffer = live_buffer
  buffer.write("héllo").to_s # 6 bytes
end

case_run("buffer_writeln_appends") do
  _, buffer = live_buffer
  buffer.writeln("tick")
  buffer.close
  parts = []
  buffer.each { |p| parts << p }
  parts.join.inspect
end

case_run("buffer_writeln_keeps_trailing") do
  _, buffer = live_buffer
  buffer.writeln("tick\n")
  buffer.close
  parts = []
  buffer.each { |p| parts << p }
  parts.join.inspect
end

case_run("buffer_backpressure_blocks") do
  _, buffer = live_buffer
  done = Queue.new
  t = Thread.new do
    (buffer.class.queue_size + 1).times { |i| buffer.write("c#{i}") }
    done << true
  end
  progressed = done.pop(true) rescue nil # non-blocking: must still be blocked
  t.join(0.3)
  blocked = t.alive?
  t.kill
  blocked.to_s
end

case_run("buffer_backpressure_unblocks") do
  _, buffer = live_buffer
  done = Queue.new
  t = Thread.new do
    (buffer.class.queue_size + 1).times { |i| buffer.write("c#{i}") }
    done << true
  end
  t.join(0.3) # now blocked on the (queue_size+1)th push
  popped = nil
  buffer.each { |p| popped = p; break } # pop exactly one chunk, free a slot
  finished = nil
  20.times do
    finished = done.pop(true) rescue nil
    break if finished
    sleep 0.1
  end
  "#{popped.inspect}|#{finished ? "unblocked" : "stuck"}"
end

case_run("buffer_write_after_abort") do
  _, buffer = live_buffer
  buffer.abort
  begin
    buffer.write("x")
    "no-raise"
  rescue ActionController::Live::ClientDisconnected
    "raise:ClientDisconnected"
  end
end

case_run("buffer_ignore_disconnect") do
  _, buffer = live_buffer
  buffer.ignore_disconnect = true
  buffer.abort
  buffer.write("x").to_s
end

case_run("buffer_connected_after_abort") do
  _, buffer = live_buffer
  "#{buffer.connected?}#{buffer.abort; buffer.connected?}"
end

case_run("buffer_closed_write") do
  _, buffer = live_buffer
  buffer.close
  begin
    buffer.write("x")
    "no-raise"
  rescue IOError
    "raise:closed"
  end
end

# ---------------------------------------------------------------------------
# Part B: transport (real Puma server, raw TCP clients)
# ---------------------------------------------------------------------------

gem "puma", "= 6.6.1"
require "puma"
require "puma/server"

class LiveTransportController < ActionController::Base
  include ActionController::Live

  def chunked
    response.headers["content-type"] = "text/plain"
    response.stream.write "hello "
    response.stream.write "world"
  ensure
    response.stream.close
  end

  def sse
    response.headers["content-type"] = "text/event-stream"
    sse = ActionController::Live::SSE.new(response.stream)
    sse.write "a"
    sse.write({ "name" => "John" }, event: "greet", id: 10, retry: 500)
  ensure
    sse.close
  end

  def csv
    send_stream(filename: "subscribers.csv", type: "text/csv") do |stream|
      stream.write "email\n"
      stream.write "a@b.c\n"
    end
  end

  def error_before_commit
    response.headers["content-type"] = "text/event-stream"
    raise "boom"
  end

  def error_after_commit
    response.headers["content-type"] = "text/event-stream"
    response.stream.write "partial"
    raise "boom-mid-stream"
  ensure
    response.stream.close
  end
end

DISCONNECT_STATE = Queue.new

class LiveDisconnectController < ActionController::Base
  include ActionController::Live

  def infinite
    response.headers["content-type"] = "text/event-stream"
    writes = 0
    10_000.times do |i|
      response.stream.writeln "tick #{i}"
      writes += 1
      sleep 0.02
    end
  rescue ActionController::Live::ClientDisconnected
    DISCONNECT_STATE << ["rescued:ClientDisconnected", writes]
  ensure
    response.stream.close
  end
end

ACTIONS = {
  "chunked" => LiveTransportController.action("chunked"),
  "sse" => LiveTransportController.action("sse"),
  "csv" => LiveTransportController.action("csv"),
  "error_before_commit" => LiveTransportController.action("error_before_commit"),
  "error_after_commit" => LiveTransportController.action("error_after_commit"),
  "infinite" => LiveDisconnectController.action("infinite"),
}

APP = ->(env) {
  action = ACTIONS[env["PATH_INFO"].sub(%r{\A/}, "")]
  action ? action.call(env) : [404, { "Content-Type" => "text/plain" }, ["not found"]]
}

def start_server
  events = Puma::Events.new
  server = Puma::Server.new(APP, events)
  server.add_tcp_listener("127.0.0.1", 0)
  port = server.connected_ports.first
  server.run
  sleep 0.5
  [server, port]
end

def raw_request(port, path, http_version: "1.1", read_seconds: 2.0, close_client_after: nil, linger_reset: false)
  sock = TCPSocket.new("127.0.0.1", port)
  if linger_reset
    sock.setsockopt(Socket::SOL_SOCKET, Socket::SO_LINGER, [1, 0].pack("i_i_"))
  end
  sock.write "GET #{path} HTTP/#{http_version}\r\nHost: localhost\r\n\r\n"
  if close_client_after
    got = +""
    while got.bytesize < close_client_after
      rs, = IO.select([sock], nil, nil, 3.0)
      break unless rs
      chunk = sock.read_nonblock(256, exception: false)
      got << chunk if chunk.is_a?(String)
    end
    sock.close
    return got
  end
  data = +""
  deadline = Time.now + read_seconds
  loop do
    remaining = deadline - Time.now
    break if remaining <= 0
    rs, = IO.select([sock], nil, nil, remaining)
    break unless rs
    chunk = sock.read_nonblock(65_536, exception: false)
    break if chunk.nil? # EOF
    next if chunk == :wait_readable
    data << chunk
  end
  sock.close
  data
end

# Parse a raw HTTP/1.1 response: [status, {hdr => val}, body_raw]
# (header names normalized to lowercase — Rack 3 servers emit them lowercased)
def parse_response(raw)
  head, body = raw.split("\r\n\r\n", 2)
  status = head[/\AHTTP\/\d\.\d (\d+)/, 1]
  headers = {}
  head.split("\r\n").drop(1).each do |line|
    k, v = line.split(":", 2)
    headers[k.strip.downcase] = v.strip
  end
  [status, headers, body.to_s]
end

# Decode chunked framing: list of chunk payloads (Symbol markers kept out)
def decode_chunks(body)
  chunks = []
  rest = body.dup
  loop do
    line, rest2 = rest.split("\r\n", 2)
    break if line.nil?
    size = line.to_i(16)
    break if size.zero? || rest2.nil? || rest2.bytesize < size
    chunks << rest2.byteslice(0, size)
    rest = rest2.byteslice(size + 2..) || ""
  end
  chunks
end

SERVER, PORT = start_server

begin
  case_run("transport_chunked_status_headers") do
    status, headers, = parse_response(raw_request(PORT, "/chunked"))
    "#{status}|cc:#{headers["cache-control"]}|cl:#{headers.key?("Content-Length")}|" \
      "te:#{headers["transfer-encoding"]}|ct:#{headers["content-type"]}"
  end

  case_run("transport_chunked_frames") do
    _, headers, body = parse_response(raw_request(PORT, "/chunked"))
    frames = headers["transfer-encoding"] ? decode_chunks(body) : [body]
    "#{frames.size}:#{frames.map(&:inspect).join("|")}"
  end

  case_run("transport_sse_wire") do
    _, headers, body = parse_response(raw_request(PORT, "/sse"))
    frames = headers["transfer-encoding"] ? decode_chunks(body) : [body]
    "#{headers["content-type"]}|cc:#{headers["cache-control"]}|" \
      "frames:#{frames.map(&:inspect).join("|")}"
  end

  case_run("transport_send_stream") do
    status, headers, body = parse_response(raw_request(PORT, "/csv"))
    "#{status}|ct:#{headers["content-type"]}|cd:#{headers["content-disposition"]}|" \
      "cc:#{headers["cache-control"]}|body:#{body.inspect}"
  end

  case_run("transport_error_before_commit_500") do
    status, = parse_response(raw_request(PORT, "/error_before_commit"))
    status
  end

  case_run("transport_error_after_commit_partial") do
    _, headers, body = parse_response(raw_request(PORT, "/error_after_commit"))
    frames = headers["transfer-encoding"] ? decode_chunks(body) : [body]
    "#{frames.map(&:inspect).join("|")}"
  end

  case_run("transport_http10_no_chunked") do
    _, headers, body = parse_response(raw_request(PORT, "/chunked", http_version: "1.0"))
    "te:#{headers.key?("Transfer-Encoding")}|body:#{body.inspect}"
  end

  case_run("transport_disconnect_cancels_action") do
    got = raw_request(PORT, "/infinite", close_client_after: 64, linger_reset: true)
    state, writes1 = DISCONNECT_STATE.pop(true) rescue nil
    # wait for the server to notice and cancel the action thread
    40.times do
      break if state
      state, writes1 = DISCONNECT_STATE.pop(true) rescue nil
      sleep 0.1
    end
    "got:#{got.bytesize > 0}|state:#{state ? state : "none"}"
  end
ensure
  SERVER.stop(true)
end
