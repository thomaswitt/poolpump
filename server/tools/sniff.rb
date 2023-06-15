#!/usr/bin/env ruby
# Active-ACK sniffer for the HF-LPB130's cloud-side TCP session.
#
# Listens on :502, parses MBAP framing, ACKs every device-initiated
# FC=0x10 (Write Multiple Registers) telemetry push so the module doesn't
# enter retry/backoff, and hex-dumps everything (RX + our TX) to stdout
# with timestamps.
#
# Optional Phase-1.5 control-model probe:
#   --probe-fc03 ADDR,QTY     send one master-side FC=0x03 read after first push
#
# Pure stdlib — `ruby tools/sniff.rb` is enough. macOS/Linux:
#   sudo ruby tools/sniff.rb           # :502 is privileged
#   PORT=5020 ruby tools/sniff.rb      # or just pick a high port and AT+NETP=...,5020

require 'socket'
require 'optparse'
require 'time'
require_relative '../lib/poolpump/mbap'

include Poolpump

# ──────────────────────────────────────────────────────────────────────────
# Output helpers
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

# ──────────────────────────────────────────────────────────────────────────
# CLI args
# ──────────────────────────────────────────────────────────────────────────

options = { probe: nil, probe_gap: 5.0, port: ENV.fetch('PORT', 502).to_i }
OptionParser.new do |o|
  o.banner = 'usage: ruby tools/sniff.rb [--probe-fc03 ADDR,QTY] [--probe-gap SEC]'
  o.on('--probe-fc03 ADDR,QTY', 'send a master-side FC=0x03 read after first telemetry push') do |v|
    addr_s, qty_s = v.split(',', 2)
    options[:probe] = [Integer(addr_s), Integer(qty_s || '1')]
  end
  o.on('--probe-gap SEC', Float, 'seconds to wait after first push before probing (default 5)') { |v| options[:probe_gap] = v }
  o.on('--port N', Integer, 'TCP port to listen on (default 502, env PORT)') { |v| options[:port] = v }
end.parse!

# ──────────────────────────────────────────────────────────────────────────
# Server loop
# ──────────────────────────────────────────────────────────────────────────

# H7 — set SO_REUSEADDR BEFORE bind. TCPServer.new binds atomically and
# applies sockopts after, which is a no-op for SO_REUSEADDR.
server = Socket.new(:INET, :STREAM)
server.setsockopt(:SOCKET, :REUSEADDR, true)
server.bind(Addrinfo.tcp('0.0.0.0', options[:port]))
server.listen(4)
log "sniffer listening on 0.0.0.0:#{options[:port]} (probe: #{options[:probe].inspect})"

CLIENT_IDLE_TIMEOUT = Float(ENV.fetch('POOLPUMP_CLIENT_IDLE_SEC', '90'))

loop do
  client, addrinfo = server.accept
  peer = "#{addrinfo.ip_address}:#{addrinfo.ip_port}"
  log "ACCEPT  #{peer}"
  Thread.new(client, peer) do |client_t, peer_t|
    Thread.current.name = peer_t
    Thread.current.report_on_exception = true
    buf = String.new(encoding: Encoding::BINARY)
    tid_counter = 0
    probe_at = nil
    control_outcome = nil
    # P3 — track probe lifecycle so the inferred-B verdict is grounded in what
    # actually happened, not just "no A or C was seen". Both flags must be true
    # before we can claim Outcome B; otherwise the run is inconclusive.
    probe_fired = false
    telemetry_after_probe = false
    last_rx_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    begin
      loop do
        idle_deadline = last_rx_at + CLIENT_IDLE_TIMEOUT
        idle_remaining = [idle_deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC), 0].max
        if idle_remaining <= 0
          log "IDLE    #{peer_t} silent for >#{CLIENT_IDLE_TIMEOUT}s — closing to free accept slot"
          break
        end
        probe_remaining = probe_at ? [probe_at - Process.clock_gettime(Process::CLOCK_MONOTONIC), 0].max : nil
        timeout = [idle_remaining, probe_remaining].compact.min
        ready, _, _ = IO.select([client_t], nil, nil, timeout)
        client = client_t # alias so the rest of the body keeps reading like before

      # Time to fire the FC=0x03 probe?
      if probe_at && Process.clock_gettime(Process::CLOCK_MONOTONIC) >= probe_at
        tid_counter += 1
        addr, qty = options[:probe]
        req = MBAP.fc03_request(tid: tid_counter, start_addr: addr, qty: qty)
        client.write(req)
        log "PROBE   FC=0x03 read addr=#{addr} qty=#{qty} tid=#{format('%04x', tid_counter)} (#{req.bytesize}b)"
        puts hex_dump(req)
        probe_at = nil
        probe_fired = true
      end

      next unless ready

      chunk = client.read_nonblock(8192, exception: false)
      raise EOFError if chunk.nil? || chunk == ''
      next if chunk == :wait_readable

      last_rx_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      buf << chunk

      while (frame = MBAP.take_frame(buf))
        log "RECV    tid=#{format('%04x', frame.tid)} pid=#{frame.pid} len=#{frame.length} uid=#{frame.uid} fc=0x#{frame.fc.to_s(16).rjust(2, '0')} bytes=#{frame.bytes.bytesize}"
        puts hex_dump(frame.bytes)

        case frame.fc
        when 0x10 # device-initiated Write Multiple Registers (telemetry push)
          ack = MBAP.fc16_ack(frame)
          client.write(ack)
          log "SEND    ack tid=#{format('%04x', frame.tid)} (#{ack.bytesize}b)"
          puts hex_dump(ack)
          # Pushes that arrive AFTER probe_fired count as evidence the device
          # is still talking — that's the precondition for a real Outcome-B
          # verdict (it ignored our probe but kept its own telemetry going).
          telemetry_after_probe = true if probe_fired
          # Schedule the FC=0x03 probe relative to the first push we ACK.
          if options[:probe] && probe_at.nil? && !probe_fired && control_outcome.nil?
            probe_at = Process.clock_gettime(Process::CLOCK_MONOTONIC) + options[:probe_gap]
            log "STAGED  FC=0x03 probe will fire in #{options[:probe_gap]}s"
          end
        when 0x03 # OUTCOME A — device replied to our master-side read
          control_outcome = :A
          values = MBAP.decode_read_response(frame)
          log "CONTROL-MODEL OUTCOME A: device answered FC=0x03 → #{values.inspect}. Master polling works."
        when 0x83 # OUTCOME C — exception in response to our FC=0x03
          control_outcome = :C
          ex_code = frame.bytes.getbyte(8)
          log "CONTROL-MODEL OUTCOME C: device returned exception 0x#{ex_code.to_s(16)} — refuses unsolicited reads."
        when 0x41 # vendor-defined registration heartbeat (DOTELS-SWP firmware)
          # Device sends this every 2s with its MAC in the body. We need
          # to figure out the correct ACK to transition it into FC=0x10
          # telemetry mode. Empirical only — no docs. Strategy is selected
          # via env var so we can iterate without code edits:
          #   POOLPUMP_FC41=none      (default) — log only, no reply
          #   POOLPUMP_FC41=cx        — FC|0x80=0xC1 + status 0x00 (Modbus ACK convention)
          #   POOLPUMP_FC41=echo      — echo the device's frame back unchanged
          #   POOLPUMP_FC41=ok        — send literal text "+ok"
          #   POOLPUMP_FC41=read      — send a master-side FC=0x03 read of HR 0..1
          #   POOLPUMP_FC41=read10    — send FC=0x04 read of input regs 0..15
          ack = case ENV.fetch('POOLPUMP_FC41', 'none')
          when 'none'   then nil
          when 'cx'     then [frame.tid, 0, 3, frame.uid, 0xC1, 0x00].pack('n n n C C C')
          when 'echo'   then frame.bytes
          when 'ok'     then '+ok'.b
          when 'read'   then MBAP.fc03_request(tid: frame.tid, start_addr: 0, qty: 1, uid: frame.uid)
          when 'read10' then MBAP.fc04_request(tid: frame.tid, start_addr: 0, qty: 16, uid: frame.uid)
          else
                  log "UNKNOWN POOLPUMP_FC41 strategy #{ENV['POOLPUMP_FC41'].inspect}; not replying"
                  nil
          end
          if ack
            client.write(ack)
            log "SEND    fc=0x41 ACK strategy=#{ENV.fetch('POOLPUMP_FC41', 'none')} (#{ack.bytesize}b)"
            puts hex_dump(ack)
          end
        else
          log "UNHANDLED FC=0x#{frame.fc.to_s(16)} — logged only, no response sent."
        end
      end
    end
    rescue EOFError, Errno::ECONNRESET
      log "CLOSED  #{peer_t} by peer"
    rescue => e
      log "ERROR   #{peer_t} #{e.class}: #{e.message}"
      log e.backtrace.first(5).join("\n  ")
    ensure
      client_t.close
      # Only claim Outcome B if (a) probe was actually sent on the wire and
      # (b) at least one telemetry push arrived after it. Otherwise the
      # connection ended too early to form an opinion — say so.
      if options[:probe] && control_outcome.nil?
        if probe_fired && telemetry_after_probe
          log "CONTROL-MODEL OUTCOME B (inferred) [#{peer_t}]: probe fired, no reply, telemetry continued — derive state from pushes."
        elsif probe_fired
          log "CONTROL-MODEL INCONCLUSIVE [#{peer_t}]: probe fired, no FC=0x03 reply, but no telemetry observed afterward either. Try again with a longer --probe-gap and/or a longer session before disconnecting."
        else
          log "CONTROL-MODEL INCONCLUSIVE [#{peer_t}]: connection ended before probe fired (no telemetry arrived to schedule it, or you Ctrl-C'd too soon). Try a longer session."
        end
      end
      log "DONE    #{peer_t}; accept loop unblocked."
    end
  end
end
