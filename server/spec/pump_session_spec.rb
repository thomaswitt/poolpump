# spec/pump_session_spec.rb

require 'spec_helper'
require 'async'
require 'poolpump/pump_session'
require 'poolpump/command_translator'

# A drop-in fake for Socket that lets the test choreograph chunk delivery.
# `push_chunk` enqueues bytes for the next `read` to return; without one,
# `read` blocks the calling fiber until a chunk arrives.
class FakeSocket
  attr_reader :writes

  def initialize(scripted_chunks: [])
    @queue = Async::Queue.new
    @writes = []
    @closed = false
    scripted_chunks.each { |c| @queue.enqueue(c) }
  end

  def push_chunk(bytes); @queue.enqueue(bytes) end

  # Match real Socket semantics: read/readpartial/write all raise once close
  # has been called. Without this, a "closed" FakeSocket would still happily
  # serve queued chunks, and bugs like the P1 stale-reconnect close would go
  # undetected because the test path keeps "working" past the close.
  def read(_max)
    raise IOError, 'closed stream' if @closed

    @queue.dequeue
  end

  def readpartial(_max)
    raise IOError, 'closed stream' if @closed

    @queue.dequeue
  end

  def write(bytes)
    raise IOError, 'closed stream' if @closed

    @writes << bytes
    bytes.bytesize
  end

  def close; @closed = true end
  def closed?; @closed end
  def remote_address; nil end
end

# Helper: build the bytes of an FC=0x10 telemetry push at TELEMETRY_BLOCK_START
# (the 7-register control block at addr 2000) with the supplied register values.
def telemetry_push(values, tid: 0x0001, uid: 0x01, start_addr: nil)
  start_addr ||= Poolpump::RegisterMap::TELEMETRY_BLOCK_START
  qty = values.length
  bc = qty * 2
  pdu = ([0x10, start_addr, qty, bc] + values).pack("C n n C n#{qty}")
  mbap_len = pdu.bytesize + 1 # +UID
  header = [tid, 0, mbap_len, uid].pack('n n n C')
  header + pdu
end

# Helper: build a Poolpump-format FC=0x41 heartbeat frame (23 bytes, with MAC).
def fc41_heartbeat(tid: 0x0aec, uid: 0x01, mac_hex: '001122334455')
  mac = [mac_hex].pack('H*')
  vendor = "\x00\x00\x00\x05\x0a\x00\x03\x00\x03".b
  pdu = "\x01\x41".b + vendor + mac # uid byte will be overridden by MBAP encoder
  pdu = ([uid, 0x41].pack('C C') + vendor + mac)
  ([tid, 0, pdu.bytesize].pack('n n n') + pdu).b
end

# Captured 7-register control block ("at rest") for use as a baseline.
# Mode=heat (0x04), switch=on (0x01), function=smart (0x0000), setpoint=29.
def control_block_values(model: 0x04, switch: 0x01, function: 0x0000,
                         r2003: 0, r2004: 0, r2005: 0, settemp: 29)
  [model, switch, function, r2003, r2004, r2005, settemp]
end

RSpec.describe Poolpump::PumpSession do
  let(:session) { described_class.new(queue_limit: 8) }

  it 'starts disconnected with empty snapshot' do
    expect(session.connected?).to be(false)
    expect(session.snapshot).to eq({})
    expect(session.healthz[:queue_depth]).to eq(0)
  end

  it 'rejects enqueue while no socket is attached' do
    cmd = Poolpump::CommandTranslator.parse('on')
    expect { session.enqueue(cmd) }.to raise_error(Poolpump::PumpSession::SessionStale)
  end

  describe '#serve (integration)' do
    it 'ACKs an inbound FC=0x10 telemetry push and updates the snapshot' do
      sock = FakeSocket.new(scripted_chunks: [telemetry_push(control_block_values)])

      Sync do |task|
        run = task.async { session.serve(sock) }
        sleep 0.4
        run.stop
      end

      expect(sock.writes.length).to be >= 1
      ack = sock.writes.first
      expect(ack.bytesize).to eq(12)              # standard 12-byte FC=0x10 ack
      expect(ack.unpack('n n n C C').last).to eq(0x10)
      snap = session.snapshot
      expect(snap[:switch]).to eq(1)
      expect(snap[:model]).to eq(2)               # raw 0x04 → semantic 2 (heat)
      expect(snap[:settemp]).to eq(29)
    end

    it 'ACKs an inbound FC=0x41 heartbeat with the cloud-format 12-byte reply' do
      sock = FakeSocket.new(scripted_chunks: [fc41_heartbeat(tid: 0x0aec)])

      Sync do |task|
        run = task.async { session.serve(sock) }
        sleep 0.4
        run.stop
      end

      expect(sock.writes.length).to be >= 1
      ack = sock.writes.first
      expect(ack.bytesize).to eq(12)
      tid, _pid, _len, _uid, fc = ack.unpack('n n n C C')
      expect(tid).to eq(0x0aec)
      expect(fc).to eq(0x41)
      expect(ack.byteslice(8, 4)).to eq("\x00\x00\x00\x05".b) # cloud-format payload
    end

    it 'fires queued FC=0x06 writes with uid=0x81 and resolves their futures on the FC=0x06 echo (fast path, ~150ms)' do
      sock = FakeSocket.new
      result = nil
      Sync do |task|
        run = task.async { session.serve(sock) }
        # Establish session with one telemetry push so connected? returns true.
        sock.push_chunk(telemetry_push(control_block_values(switch: 0)))
        sleep 0.3
        future = session.enqueue(Poolpump::CommandTranslator.parse('on'), deadline: 2.0)
        sleep 0.3 # let dispatcher fire FC=0x06

        # Inspect the dispatched frame to grab the TID we sent, then echo it
        # back with the same TID — that's how the real device responds.
        fc06_writes = sock.writes.select { |b| b.bytesize == 12 && b.getbyte(7) == 0x06 }
        expect(fc06_writes.length).to be >= 1
        sent_tid = fc06_writes.first.unpack1('n')
        echo = [sent_tid, 0, 6, 0x81, 0x06, 0x07d1, 1].pack('n n n C C n n')
        sock.push_chunk(echo)
        result = future.wait
        run.stop
      end

      expect(result[:ok]).to be(true)
      fc06_writes = sock.writes.select { |b| b.bytesize == 12 && b.getbyte(7) == 0x06 }
      _tid, _pid, _len, uid, _fc, addr, raw = fc06_writes.first.unpack('n n n C C n n')
      expect(uid).to eq(0x81)                    # CONFIRMED cloud convention
      expect(addr).to eq(0x07d1)                 # :switch write_address
      expect(raw).to eq(1)
    end

    it 'falls back to telemetry-based confirmation if FC=0x06 echo never arrives' do
      sock = FakeSocket.new
      result = nil
      Sync do |task|
        run = task.async { session.serve(sock) }
        sock.push_chunk(telemetry_push(control_block_values(switch: 0)))
        sleep 0.3
        future = session.enqueue(Poolpump::CommandTranslator.parse('on'), deadline: 3.0)
        sleep 0.3
        # No FC=0x06 echo. Telemetry push showing the new state arrives instead.
        sock.push_chunk(telemetry_push(control_block_values(switch: 1), tid: 0x0002))
        result = future.wait
        run.stop
      end

      expect(result[:ok]).to be(true)
    end

    it 'merges register values across multiple block pushes (control block + raw blocks)' do
      # First block: control block at addr 2000 (model=heat, on, settemp=29).
      ctl = telemetry_push(control_block_values, start_addr: 0x07d0, tid: 0x01)
      # Second block: arbitrary other addresses preserved as raw_*.
      misc = telemetry_push([0x1234, 0x5678], start_addr: 0x9000, tid: 0x02)

      sock = FakeSocket.new
      Sync do |task|
        run = task.async { session.serve(sock) }
        sock.push_chunk(ctl)
        sleep 0.2
        sock.push_chunk(misc)
        sleep 0.2
        run.stop
      end

      snap = session.snapshot
      expect(snap[:settemp]).to eq(29)
      expect(snap[:raw_9000]).to eq(0x1234)
      expect(snap[:raw_9001]).to eq(0x5678)
    end

    it 'resolves with echo-timeout when telemetry never confirms the write' do
      sock = FakeSocket.new(scripted_chunks: [telemetry_push(control_block_values(switch: 0))])

      result = nil
      Sync do |task|
        run = task.async { session.serve(sock) }
        sleep 0.3
        cmd = Poolpump::CommandTranslator.parse('on')
        future = session.enqueue(cmd, deadline: 0.5)
        result = future.wait
        run.stop
      end

      expect(result[:ok]).to be(false)
      expect(result[:reason]).to eq('echo-timeout')
    end

    it 'P1 — resets last_seen_at when a new socket attaches so reconnects survive past the stale threshold' do
      tiny_stale = described_class.new(
        stale_before_handshake_sec: 0.3,
        stale_after_handshake_sec:  0.5,
        queue_limit: 4,
      )
      sock1 = FakeSocket.new
      sock2 = FakeSocket.new

      Sync do |task|
        run1 = task.async { tiny_stale.serve(sock1) }
        sock1.push_chunk(telemetry_push(control_block_values(switch: 0)))
        sleep 0.2
        run1.stop
        sleep 0.4 # exceed stale threshold on the OLD timestamp

        run2 = task.async { tiny_stale.serve(sock2) }
        sock2.push_chunk(telemetry_push(control_block_values(switch: 1)))
        sleep 0.4
        expect(tiny_stale.snapshot[:switch]).to eq(1)
        run2.stop
      end
    end

    it 'uses the longer post-handshake threshold once any frame has been received' do
      # If we used the pre-handshake threshold (0.2s) after handshake, sleeping
      # 0.4s without further data would close the socket. With the two-threshold
      # design, the post-handshake threshold (1.0s) keeps it open through normal
      # cycle gaps.
      session = described_class.new(
        stale_before_handshake_sec: 0.2,
        stale_after_handshake_sec:  1.0,
        queue_limit: 4,
      )
      sock = FakeSocket.new

      Sync do |task|
        run = task.async { session.serve(sock) }
        sock.push_chunk(telemetry_push(control_block_values))
        sleep 0.5 # well past the pre-handshake threshold but under the post-
        expect(sock.closed?).to be(false)
        run.stop
      end
    end

    it 'closes a freshly-accepted socket that never sends anything (pre-handshake threshold)' do
      session = described_class.new(
        stale_before_handshake_sec: 0.2,
        stale_after_handshake_sec:  10.0,
        queue_limit: 4,
      )
      sock = FakeSocket.new

      Sync do |task|
        run = task.async { session.serve(sock) }
        sleep 0.5 # exceed the pre-handshake threshold without sending anything
        expect(sock.closed?).to be(true)
        run.stop
      end
    end

    it 'EVICT — request_evict! causes the serve loop to break within ~1 tick (preempt path)' do
      # Regression for the WiFi-reassoc connection storm: when ModbusListener
      # accepts a fresh socket while a prior session is still nominally
      # connected (zombie after WiFi reassoc), it calls request_evict! and
      # the serve loop must unwind cleanly so the new socket can take over.
      # Without this, recovery waits for the 60s/300s stale watchdog.
      session = described_class.new(
        stale_before_handshake_sec: 30.0, # well above test wait
        stale_after_handshake_sec:  30.0,
        queue_limit: 4,
      )
      sock = FakeSocket.new

      Sync do |task|
        run = task.async { session.serve(sock) }
        sleep 0.05 # let serve enter its loop
        expect(session.connected?).to be(true)

        session.request_evict!
        sleep 0.4 # ~2 ticks at PUMP_POLL_TICK_SEC=0.2

        expect(session.connected?).to be(false)
        expect(sock.closed?).to be(true)
        run.stop
      end
    end

    it 'healthz reports data_fresh: false when no telemetry has been received' do
      expect(described_class.new.healthz[:data_fresh]).to be(false)
    end

    it 'healthz reports data_fresh: true when a recent FC=0x10 push has updated the snapshot' do
      session = described_class.new(queue_limit: 4)
      sock = FakeSocket.new

      Sync do |task|
        run = task.async { session.serve(sock) }
        sock.push_chunk(telemetry_push(control_block_values))
        sleep 0.3
        expect(session.healthz[:data_fresh]).to be(true)
        run.stop
      end
    end

    it 'C0 — resolves the future when socket.write raises mid-dispatch (lost-future protection)' do
      bad_sock = Class.new(FakeSocket) do
        def initialize(*)
          super
          @write_count = 0
        end

        def write(bytes)
          @write_count += 1
          raise IOError, 'simulated wire failure' if @write_count > 1

          @writes << bytes
          bytes.bytesize
        end
      end.new

      result = nil
      Sync do |task|
        run = task.async { session.serve(bad_sock) }
        bad_sock.push_chunk(telemetry_push(control_block_values(switch: 0)))
        sleep 0.3 # session ACKs (write #1 — succeeds)
        future = session.enqueue(Poolpump::CommandTranslator.parse('on'), deadline: 5.0)
        sleep 0.4 # dispatch attempts FC=0x06 (write #2 — raises)
        result = future.wait
        run.stop
      end

      expect(result[:ok]).to be(false)
      expect(result[:reason]).to match(/dispatch-error.*IOError/)
    end

    it 'raises QueueFull at the configured limit' do
      tiny = described_class.new(queue_limit: 2)
      sock = FakeSocket.new(scripted_chunks: [telemetry_push(control_block_values)])

      Sync do |task|
        run = task.async { tiny.serve(sock) }
        sleep 0.2
        2.times { tiny.enqueue(Poolpump::CommandTranslator.parse('on'), deadline: 5.0) }
        expect {
          tiny.enqueue(Poolpump::CommandTranslator.parse('off'), deadline: 5.0)
        }.to raise_error(Poolpump::PumpSession::QueueFull)
        run.stop
      end
    end
  end
end
