#!/usr/bin/env ruby
# Plan-B device-side probe: connect to the OEM cloud at fzdbiology.com:502
# pretending to be Poolpump (using its real MAC so the cloud's auth/keying
# accepts us), then capture everything the cloud sends back.
#
# Why: passive sniffing reveals what the device *pushes*; this reveals what
# the cloud *sends* — welcome frames, ACK formats, and (the gold) any
# control commands the OEM Android app issues. Pair this run with the
# OEM app installed on a phone: app sends "set temp 28" → cloud routes it
# to us → we decode the wire format → we now know which register encodes
# setpoint and how the value is framed.
#
# Risk profile: low. Uses your own device's MAC against your own account.
# Cloud may briefly mark the device "online from new IP" — bumps
# last_seen_at, no other state affected. Real Poolpump is unaware (it's
# talking to our local sniffer, not the cloud).
#
# Usage:
#   ruby tools/cloud_replay.rb                      # default 60s, MAC from .env
#   ruby tools/cloud_replay.rb --duration 300       # 5 minutes
#   ruby tools/cloud_replay.rb --mac 001122334455   # explicit MAC
#   ruby tools/cloud_replay.rb --host 47.254.152.109 --port 502

require 'socket'
require 'optparse'
require 'time'

# Stdout is block-buffered when redirected to a file. With small frames
# (often <100 bytes) we'd lose visibility of cloud responses for minutes.
# Sync mode flushes every write — fine here, the volume is low.
$stdout.sync = true

# ──────────────────────────────────────────────────────────────────────────
# CLI args
# ──────────────────────────────────────────────────────────────────────────

options = {
  host: ENV.fetch('POOLPUMP_CLOUD_HOST', 'fzdbiology.com'),
  port: Integer(ENV.fetch('POOLPUMP_CLOUD_PORT', '502')),
  mac: ENV.fetch('POOLPUMP_MAC', '001122334455'),
  duration: 60.0,
  keepalive: 30.0,
}

OptionParser.new do |o|
  o.banner = 'usage: ruby tools/cloud_replay.rb [options]'
  o.on('--host HOST', 'cloud TCP host (default fzdbiology.com)') { |v| options[:host] = v }
  o.on('--port N', Integer, 'cloud TCP port (default 502)') { |v| options[:port] = v }
  o.on('--mac HEX', '12-hex-char device MAC (default Poolpump)') { |v| options[:mac] = v.downcase.delete(':') }
  o.on('--duration SEC', Float, 'how long to stay connected (default 60)') { |v| options[:duration] = v }
  o.on('--keepalive SEC', Float, 'gap between FC=0x41 heartbeats (default 30)') { |v| options[:keepalive] = v }
end.parse!

raise "MAC must be 12 hex chars, got #{options[:mac].inspect}" unless options[:mac] =~ /\A\h{12}\z/

# ──────────────────────────────────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────────────────────────────────

def log(msg)
  $stdout.puts "[#{Time.now.strftime('%H:%M:%S.%L')}] #{msg}"
  $stdout.flush
end

def hex_dump(bytes, prefix: '  ')
  bytes.bytes.each_slice(16).with_index.map { |row, i|
    addr = format('%04x', i * 16)
    hex = row.map { |b| format('%02x', b) }.join(' ').ljust(16 * 3 - 1)
    asc = row.map { |b| (32..126).cover?(b) ? b.chr : '.' }.join
    "#{prefix}#{addr}  #{hex}  |#{asc}|"
  }.join("\n")
end

# Build a FC=0x41 heartbeat frame mimicking Poolpump's exact format:
#   tid(2) pid(2) len=0x0011 uid=0x01 fc=0x41 + 9-byte vendor payload + 6-byte MAC
# The 9-byte vendor payload is what we observed Poolpump sending verbatim;
# meaning unknown but constant. Replaying it should satisfy the cloud's
# framing checks.
VENDOR_PAYLOAD = "\x00\x00\x00\x05\x0a\x00\x03\x00\x03".b
raise 'VENDOR_PAYLOAD must be 9 bytes' unless VENDOR_PAYLOAD.bytesize == 9

def build_fc41(tid, mac_hex)
  mac = [mac_hex].pack('H*')
  raise 'mac must be 6 bytes' unless mac.bytesize == 6

  pdu = "\x01\x41".b + VENDOR_PAYLOAD + mac # uid + fc + vendor + mac = 17 bytes
  [tid, 0, pdu.bytesize].pack('n n n') + pdu
end

# ──────────────────────────────────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────────────────────────────────

log "connecting #{options[:host]}:#{options[:port]} as MAC #{options[:mac]}"

begin
  sock = TCPSocket.new(options[:host], options[:port])
rescue => e
  log "CONNECT FAILED #{e.class}: #{e.message}"
  exit 1
end

log "CONNECTED  local=#{sock.addr[2]}:#{sock.addr[1]} peer=#{sock.peeraddr[2]}:#{sock.peeraddr[1]}"

stop_at = Process.clock_gettime(Process::CLOCK_MONOTONIC) + options[:duration]
next_keepalive = Process.clock_gettime(Process::CLOCK_MONOTONIC) # send one immediately
tid = 1
recv_buf = +''

trap('INT') { log 'SIGINT — disconnecting'; sock&.close; exit 0 }

begin
  loop do
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    break if now >= stop_at

    # Send keepalive if it's time
    if now >= next_keepalive
      frame = build_fc41(tid, options[:mac])
      sock.write(frame)
      log "SEND  fc=0x41 tid=#{format('%04x', tid)} (#{frame.bytesize}b)"
      puts hex_dump(frame)
      tid = (tid + 1) & 0xffff
      next_keepalive = now + options[:keepalive]
    end

    # Wait for data with a small timeout so we can re-check keepalive timing
    timeout = [next_keepalive - now, stop_at - now, 1.0].min
    ready, _, _ = IO.select([sock], nil, nil, [timeout, 0.1].max)
    next unless ready

    chunk = sock.read_nonblock(8192, exception: false)
    if chunk.nil? || chunk == ''
      log 'CLOSED  cloud closed the connection'
      break
    end
    next if chunk == :wait_readable

    log "RECV  #{chunk.bytesize}b"
    puts hex_dump(chunk)
    recv_buf << chunk
  end
ensure
  sock&.close
  log "DONE  total received: #{recv_buf.bytesize} bytes"
end
