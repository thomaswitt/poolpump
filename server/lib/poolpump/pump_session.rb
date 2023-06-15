# lib/poolpump/pump_session.rb

require 'async'
require 'async/queue'
require 'async/notification'
require 'async/promise'
require 'socket'
require_relative 'mbap'
require_relative 'register_map'
require_relative 'command_translator'

module Poolpump
  # The PumpSession actor — single fiber owns the one TCP socket the WiFi
  # module dials in on. HTTP handlers never touch the socket; they just
  # `enqueue` a Command and `await` its result via an `Async::Promise`.
  #
  # Control model: Phase-1.5 "Outcome B" — the device pushes FC=0x10 telemetry
  # at its own cadence; we ACK every push and emit unsolicited writes for
  # queued commands between pushes. A command is considered "successful" only
  # after the next telemetry push echoes its target value (loop closure).
  class PumpSession
    # `tids` records the TIDs of every FC=0x06/FC=0x10 frame we sent for this
    # command so we can match incoming echo frames back to the originating
    # command and resolve its future fast (~150ms in practice). Telemetry-based
    # confirmation remains as a fallback if echoes are ever missed.
    Command = Struct.new(:verb, :writes, :result, :deadline_at, :tids, keyword_init: true)

    PUMP_POLL_TICK_SEC = 0.2          # wake every 200ms to drain queue / expire deadlines
    DEFAULT_QUEUE_LIMIT = 32

    # Friendly names for the eight register blocks Poolpump pushes per cycle.
    # Used in log output so operators don't have to memorise hex addresses
    # (`0x012c` means "the PQ Parameter Table sensors block", not "an opaque
    # 27-register dump"). The hex address is still logged alongside, so the
    # name is decoration not replacement — debuggers can still grep by addr.
    BLOCK_NAMES = {
      0x07d0 => 'control',     # 7 regs:  switch, model, function, ?, ?, ?, settemp
      0x012c => 'sensors',     # 27 regs: PQ Parameter Table (manual section 10)
      0x01f4 => 'alarms',      # 61 regs: fault/protection bitmap (P/E codes; bit layout TODO)
      0x0258 => 'submode',     # 27 regs: sub-mode + timer states (HYPOTHESIZED)
      0x03e8 => 'water_io',    # 8  regs: inlet+outlet temps at 0.1°C precision (CONFIRMED)
      0x0064 => 'config1',     # 61 regs: config/limits (HYPOTHESIZED)
      0x00c8 => 'config2',     # 61 regs: secondary sensor block (HYPOTHESIZED)
      0x0834 => 'history',     # 61 regs: setpoints + recent history (HYPOTHESIZED)
    }.freeze

    # How often to emit a "HEARTBEAT" summary line — operator-friendly proof
    # of life with the current decoded state. Independent of Poolpump's push
    # cadence; just a periodic synthesis of @last_snapshot.
    HEARTBEAT_SEC = 60
    # Two-threshold staleness watchdog. Diagnosed from a 14h
    # overnight log: a single 30s threshold was firing mid-cycle (Poolpump's full
    # register sweep is ~17s with up to ~10s gaps between blocks), and each
    # interruption put the device into a "TCP open, no data" wedge for ~45min.
    # Net result: only 0.5% of TCP accepts completed the FC=0x41 handshake.
    #
    # The two thresholds split the lifecycle:
    #   * BEFORE handshake — Poolpump's first FC=0x41 has been observed to take
    #     up to ~8s after TCP-establish; 60s gives plenty of headroom without
    #     leaking sockets that genuinely never sent anything.
    #   * AFTER handshake — once we know Poolpump is talking, give it 5 minutes
    #     of silence before closing. Any cycle gap we've actually observed
    #     fits comfortably under that, but a truly-dead connection still gets
    #     reaped within minutes.
    DEFAULT_STALE_BEFORE_HANDSHAKE_SEC = 60
    DEFAULT_STALE_AFTER_HANDSHAKE_SEC  = 300
    # If the snapshot is older than this, /healthz reports data_fresh: false
    # — Homey Flows can branch on that to alert on stale data even when
    # the TCP connection is up.
    SNAPSHOT_FRESH_SEC = 60
    # CONFIRMED: cloud uses uid=0x81 (not standard Modbus 0x01) for
    # device-bound writes. Poolpump's firmware appears to use the high bit as a
    # marker distinguishing cloud-issued commands from device-state echoes.
    CLOUD_WRITE_UID = 0x81

    attr_reader :last_seen_at, :last_snapshot_at, :pending_queue

    def initialize(queue_limit: DEFAULT_QUEUE_LIMIT,
                   stale_before_handshake_sec: DEFAULT_STALE_BEFORE_HANDSHAKE_SEC,
                   stale_after_handshake_sec:  DEFAULT_STALE_AFTER_HANDSHAKE_SEC,
                   logger: nil)
      @last_snapshot = {}
      @last_snapshot_at = nil
      @last_seen_at = nil
      @socket = nil
      @tid_counter = 0
      @in_flight = []
      @queue_limit = queue_limit
      @stale_before_handshake_sec = stale_before_handshake_sec
      @stale_after_handshake_sec  = stale_after_handshake_sec
      @handshake_complete = false
      @pending_queue = Async::Queue.new
      @logger = logger
    end

    # ─── public API ────────────────────────────────────────────────────────

    # Enqueue a parsed CommandTranslator::Command. Returns an Async::Promise
    # that resolves to {ok: bool, reason: String?} once either:
    #   * the next telemetry push echoes the write back (success), or
    #   * the deadline passes (failure), or
    #   * the session goes stale (failure), or
    #   * dispatch raises (failure with the underlying class+message).
    def enqueue(parsed_command, deadline: 3.0)
      raise SessionStale, 'no module connected' unless connected?
      raise QueueFull, "pending_queue at #{@queue_limit}" if pending_queue.size >= @queue_limit

      cmd = Command.new(
        verb: parsed_command.verb,
        writes: parsed_command.writes,
        result: Async::Promise.new,
        deadline_at: monotonic + deadline,
        tids: [],
      )
      @pending_queue.enqueue(cmd)
      cmd.result
    end

    def snapshot
      @last_snapshot.dup
    end

    def healthz
      snapshot_age = @last_snapshot_at && (monotonic - @last_snapshot_at).round(2)
      {
        connected: connected?,
        # `data_fresh` distinguishes "TCP connection is up" from "we have
        # current telemetry". Poolpump can sit with TCP open for hours without
        # pushing data — `connected:true` alone misleads home automation.
        data_fresh: !snapshot_age.nil? && snapshot_age < SNAPSHOT_FRESH_SEC,
        last_seen_ago: @last_seen_at && (monotonic - @last_seen_at).round(2),
        snapshot_age_sec: snapshot_age,
        queue_depth: @pending_queue.size,
        in_flight: @in_flight.size,
      }
    end

    def connected?
      !@socket.nil?
    end

    # Cooperative stop signal — ModbusListener#run polls this between accepts
    # and the serve loop polls it between ticks. Sets a flag from a SIGINT/TERM
    # trap so the reactor can unwind without raising mid-syscall.
    def request_stop!
      @stopping = true
    end

    def stopping?
      @stopping == true
    end

    # Cooperative eviction signal — ModbusListener#run sets this when a fresh
    # ACCEPT arrives while a session is already "connected", because the new
    # socket is by definition live and the old one must be a zombie (Poolpump
    # has no reason to dial twice unless it lost track of the prior socket).
    # The serve loop checks this flag once per PUMP_POLL_TICK_SEC (200ms) and
    # unwinds cleanly so the new socket can take over.
    #
    # Why a flag instead of closing the socket directly: closing from the
    # listener fiber while serve() is mid-readpartial races with the serve
    # loop's `ensure` block — the old `@socket = nil` could clobber the new
    # serve's freshly-set @socket. The cooperative pattern avoids that.
    def request_evict!
      @evict_requested = true
    end

    def evict_requested?
      @evict_requested == true
    end

    # ─── owned-by-listener entrypoint ──────────────────────────────────────

    # Take ownership of the socket and drive the session loop. Returns when
    # the connection is closed.
    def serve(socket)
      raise 'session already serving a socket' if @socket

      @socket = socket
      # P1 — reset per-socket staleness tracking. Without this, after the
      # first socket goes stale, every reconnect inherits the old timestamp
      # and `close_if_stale` drops it before the first new push arrives.
      # Seeding to monotonic gives the pre-handshake grace window for the new
      # connection to produce its first frame.
      @last_seen_at = monotonic
      # Reset handshake state — every new socket starts in the "we haven't
      # heard anything yet" phase and uses the pre-handshake threshold.
      @handshake_complete = false
      # Reset eviction flag — only applies to the prior session, not this one.
      @evict_requested = false
      # Reset heartbeat clock — first heartbeat fires HEARTBEAT_SEC after
      # this socket starts, not based on the previous socket's timing.
      @last_heartbeat_at = monotonic
      buf = String.new(encoding: Encoding::BINARY)
      task = Async::Task.current

      @evicted_this_session = false
      loop do
        break if stopping?
        if evict_requested?
          # No log line here — the listener prints a one-line HANDOVER
          # summary that covers this transition with operator-useful
          # context (prior idle duration, handover time). Logging here
          # too would just noise up the log with implementation detail.
          @evicted_this_session = true
          break
        end

        dispatch_pending(socket)
        expire_in_flight
        close_if_stale(socket)
        emit_heartbeat_if_due

        begin
          task.with_timeout(PUMP_POLL_TICK_SEC) do
            chunk = socket.readpartial(8192)
            raise EOFError if chunk.nil? || chunk.empty?

            buf << chunk
            while (frame = MBAP.take_frame(buf))
              handle_frame(socket, frame)
            end
          end
        rescue Async::TimeoutError
          # tick — fall through to next loop iteration
        rescue MBAP::MalformedFrame => e
          log "MALFORMED #{e.message} — closing socket; module will reconnect"
          break
        end
      end
      @evicted_this_session ? :evicted : nil
    rescue EOFError, Errno::ECONNRESET, IOError
      log 'CLOSED by peer'
      nil
    ensure
      begin
        socket.close
      rescue StandardError
        nil
      end
      @socket = nil
      fail_all_pending('session-stale')
    end

    # ─── internals ─────────────────────────────────────────────────────────

    private

    def handle_frame(socket, frame)
      @last_seen_at = monotonic
      # First frame received on this socket — switch to the longer
      # post-handshake stale threshold. Poolpump's normal cycle has gaps that
      # exceed the pre-handshake threshold, but only AFTER it's started
      # talking; the "established" state deserves more patience.
      @handshake_complete = true
      case frame.fc
      when 0x10
        # Poolpump pushes one register block per FC=0x10 frame. ACK first
        # (kept tight so the device's FSM stays in push mode), then decode.
        ack = MBAP.fc16_ack(frame)
        socket.write(ack)
        addr, values = MBAP.decode_fc16_push(frame)
        return unless values

        decoded = RegisterMap.decode_block(addr, values)
        # Merge — telemetry arrives as 7 separate blocks at different addrs;
        # we keep the union, not just the most recent block.
        @last_snapshot = @last_snapshot.merge(decoded)
        @last_snapshot_at = monotonic
        confirm_in_flight(@last_snapshot)
        log_push(addr, values, decoded)
      when 0x41
        # Vendor registration heartbeat. CONFIRMED required for Poolpump to
        # transition into FC=0x10 telemetry-push mode; without our ACK,
        # the device retries and never sends real data.
        ack = MBAP.fc41_ack(frame)
        socket.write(ack)
        log "← FC41 vendor-heartbeat (tid=0x#{frame.tid.to_s(16)}); → ACK"
      when 0x06 # echo of a master FC=0x06 write
        # Don't log echoes — they're internal plumbing. The operationally
        # meaningful event (command outcome) is reported by the HTTP layer
        # once the future resolves: `[http] ← CMD … → 200 (… in NNNms)`.
        # Logging echo here would just duplicate that signal one line earlier.
        confirm_in_flight_by_echo(frame.tid)
      when 0x86, 0x90 # FC=0x06 / FC=0x10 exception responses (function | 0x80)
        ex_code = frame.bytes.getbyte(8)
        log "⚠ ← EXCEPTION fc=0x#{frame.fc.to_s(16)} code=0x#{ex_code.to_s(16)} tid=0x#{frame.tid.to_s(16)} *?* (device rejected our write)"
      when 0x03 # response to FC=0x03 read — Phase 1.5 outcome A (not used today)
        log "← MASTER-READ-REPLY tid=0x#{frame.tid.to_s(16)} (control-model A path active)"
      else
        log "⚠ ← UNHANDLED fc=0x#{frame.fc.to_s(16)} tid=0x#{frame.tid.to_s(16)} *?*"
      end
    end

    # Operator-readable PUSH log line. Format:
    #   ← PUSH <block_name> (0x<addr>, <n> regs) <humanized k=v pairs>
    # For blocks we don't decode yet (alarms, counters, config1/2, history,
    # submode), the trailing humanized part is omitted entirely — the
    # block name + reg count alone confirms the cycle is healthy. If you
    # want the raw values for those blocks, hit GET /raw.
    def log_push(addr, values, decoded)
      block_name = BLOCK_NAMES[addr] || "unknown(0x#{addr.to_s(16)})"
      humanized = RegisterMap.humanize(decoded)
      tail = humanized.empty? ? '' : " #{humanized}"
      log format('← PUSH %-8s (0x%04x, %2d regs)%s', block_name, addr, values.length, tail)
    end

    # Periodic "proof of life" log line. Independent of Poolpump's push
    # cadence so an operator skimming the logs sees an obvious every-N-second
    # state summary.
    #
    # Three failure modes the line spells out (so an operator doesn't have
    # to interpret cryptic "no decoded fields"):
    #   * No telemetry at all — fresh socket, waiting for first push.
    #   * Telemetry STALE — snapshot exists but is older than SNAPSHOT_FRESH_SEC.
    #   * Telemetry partial — only raw blocks (counters/alarms/config) pushed
    #     since last heartbeat; no control or sensors data yet. This often
    #     signals a slow/incomplete cycle on Poolpump's side.
    def emit_heartbeat_if_due
      now = monotonic
      return if now - @last_heartbeat_at < HEARTBEAT_SEC

      @last_heartbeat_at = now
      humanized = RegisterMap.humanize(@last_snapshot)

      message = if @last_snapshot_at.nil?
                  '♥ HEARTBEAT — no telemetry received yet on this socket *?*'
      else
                  age = (now - @last_snapshot_at).round(1)
                  if age > SNAPSHOT_FRESH_SEC
                    "♥ HEARTBEAT — telemetry STALE *?* (last push #{age}s ago) #{humanized}".rstrip
                  elsif humanized.empty?
                    "♥ HEARTBEAT — telemetry partial *?* (only raw blocks since last push #{age}s ago; control/sensors blocks missing this cycle)"
                  else
                    "♥ HEARTBEAT (last push #{age}s ago) #{humanized}"
                  end
      end
      log message
    end

    # H1 — serial dispatch (one in-flight at a time). Each register write
    # is sent as a separate FC=0x06 single-register frame.
    #
    # The earlier "contiguous-address FC=0x10 batching" optimization broke
    # Poolpump: empirically when we sent FC=0x10 writes from the
    # cloud side, the device closed the TCP session and we lost the in-flight
    # commands. The OEM cloud only ever uses single FC=0x06 writes (verified
    # in `_data/cloud-replay-control-decoded-2026-04-30.log` — every command
    # was a 12-byte FC=0x06 frame). Poolpump's firmware appears to refuse
    # FC=0x10 from a master/cloud-side uid=0x81 source.
    #
    # C0 — any per-command failure resolves the future and removes the cmd
    # from the queue; the future is never lost.
    def dispatch_pending(socket)
      return unless @in_flight.empty?
      return if @pending_queue.empty?

      cmd = @pending_queue.dequeue
      if monotonic > cmd.deadline_at
        cmd.result.resolve(ok: false, reason: 'queue-timeout-before-dispatch')
        return
      end

      begin
        cmd.writes.each do |name, value|
          addr, raw = RegisterMap.encode_write(name, value, logger: @logger)
          @tid_counter = (@tid_counter + 1) & 0xFFFF
          frame = MBAP.fc06_request(tid: @tid_counter, address: addr, value: raw, uid: CLOUD_WRITE_UID)
          socket.write(frame)
          cmd.tids << @tid_counter
          # Direction → for "we sent to device". Humanized field=value next
          # to the raw addr/value so operators see intent ("set=28°C") and
          # debuggers can still cross-reference the wire bytes.
          humanized = RegisterMap.humanize_pair(name, value) || "#{name}=#{value}"
          log format('→ WRITE %s (cmd=%s tid=0x%x uid=0x%x addr=0x%04x raw=0x%04x)',
                     humanized, cmd.verb, @tid_counter, CLOUD_WRITE_UID, addr, raw)
        end
        @in_flight << cmd
      rescue StandardError => e
        # C0 — never lose the future. Resolve with a clear reason.
        cmd.result.resolve(ok: false, reason: "dispatch-error: #{e.class}: #{e.message}") unless cmd.result.resolved?
      end
    end

    # Primary confirmation path: each cmd records the TIDs of the FC=0x06 /
    # FC=0x10 frames it sent. When the device echoes a FC=0x06 frame back
    # (within ~150ms in practice), strike that TID off the cmd's list. When
    # all of a cmd's TIDs have been echoed, resolve its future as ok.
    #
    # Why echo-based rather than telemetry-based: Poolpump's full telemetry
    # cycle is ~17s and the control block (where written values appear) is
    # at the start of the cycle. Waiting for the next telemetry push would
    # exceed any reasonable HTTP deadline (default 3s).
    def confirm_in_flight_by_echo(tid)
      @in_flight.delete_if do |cmd|
        next false unless cmd.tids.delete(tid)
        next false unless cmd.tids.empty?

        cmd.result.resolve(ok: true) unless cmd.result.resolved?
        true
      end
    end

    # Fallback path: if a telemetry push happens to confirm the written
    # values (because the control block landed within the deadline), accept
    # that too. This is belt-and-braces — modern firmware always echoes,
    # but if echo handling ever breaks, telemetry catches the close.
    def confirm_in_flight(decoded)
      now = monotonic
      @in_flight.delete_if do |cmd|
        all_match = cmd.writes.all? { |name, value| values_match(decoded[name], value) }
        if all_match
          cmd.result.resolve(ok: true) unless cmd.result.resolved?
          true
        elsif now > cmd.deadline_at
          cmd.result.resolve(ok: false, reason: 'echo-timeout') unless cmd.result.resolved?
          true
        else
          false
        end
      end
    end

    def expire_in_flight
      now = monotonic
      @in_flight.delete_if do |cmd|
        if now > cmd.deadline_at
          cmd.result.resolve(ok: false, reason: 'echo-timeout') unless cmd.result.resolved?
          true
        else
          false
        end
      end
    end

    # H2 — if we haven't heard from the module in a while, force-close the
    # socket so the module's reconnect timer (AT+TCPTO) fires deterministically.
    # Two-threshold: short before-handshake window (catches sockets that never
    # send anything), much longer after-handshake window (gives Poolpump room
    # for its full register sweep + occasional gap without yanking the rug).
    def close_if_stale(socket)
      return unless @last_seen_at

      threshold = @handshake_complete ? @stale_after_handshake_sec : @stale_before_handshake_sec
      return if monotonic - @last_seen_at < threshold

      label = @handshake_complete ? 'post-handshake' : 'pre-handshake'
      log "STALE no telemetry for >#{threshold}s (#{label}); closing socket"
      socket.close
    end

    def fail_all_pending(reason)
      @in_flight.each { |cmd| cmd.result.resolve(ok: false, reason: reason) unless cmd.result.resolved? }
      @in_flight.clear
      until @pending_queue.empty?
        cmd = @pending_queue.dequeue
        cmd.result.resolve(ok: false, reason: reason) unless cmd.result.resolved?
      end
    end

    # Loose equality for echo-confirmation. Temperatures encoded with
    # half-degree precision can show up as e.g. 27.5 vs 28.
    def values_match(snapshot_val, target_val)
      return false if snapshot_val.nil?

      if snapshot_val.is_a?(Float) || target_val.is_a?(Float)
        (snapshot_val.to_f - target_val.to_f).abs < 0.6
      else
        snapshot_val == target_val
      end
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def log(msg)
      return unless @logger

      @logger.call("[pump_session] #{msg}")
    end

    public

    class SessionStale < StandardError; end
    class QueueFull < StandardError; end
  end

  # Thin TCPServer wrapper that accepts the one expected connection and hands
  # it to the PumpSession. Additional connections are logged and dropped.
  # H7 — uses Socket primitive so SO_REUSEADDR is set BEFORE bind (the
  # TCPServer convenience constructor binds atomically and no longer accepts
  # the sockopt change).
  class ModbusListener
    def initialize(host: '0.0.0.0', port: 502, session:, logger: nil)
      @host = host
      @port = port
      @session = session
      @logger = logger
    end

    # How long to wait for an in-progress serve loop to unwind after we set
    # the eviction flag. The serve loop checks the flag once per 200ms tick,
    # so 1s is ~5 ticks of headroom. If it doesn't unwind in that window the
    # old socket may be wedged in readpartial and we fall back to REJECT.
    EVICT_TIMEOUT_SEC = 1.0
    EVICT_POLL_INTERVAL_SEC = 0.05

    def run
      server = Socket.new(:INET, :STREAM)
      server.setsockopt(:SOCKET, :REUSEADDR, true)
      server.bind(Addrinfo.tcp(@host, @port))
      server.listen(4)
      log "listening on #{@host}:#{@port}"
      loop do
        break if @session.stopping?

        peer, addrinfo = server.accept
        addr = "#{addrinfo.ip_address}:#{addrinfo.ip_port}"
        # Kernel-level keepalive: detect actually-dead TCP sessions (no
        # FIN/RST seen) without relying on application-layer timeouts.
        # Belt-and-braces alongside `close_if_stale` in PumpSession.
        peer.setsockopt(:SOCKET, :KEEPALIVE, true)

        # Preempt-on-ACCEPT — when Poolpump dials in fresh, our prior session is
        # by definition stale (Poolpump has no reason to dial twice while still
        # talking on the old socket). Most common trigger is WiFi reassoc:
        # the AP loses Poolpump's old TCP session silently (no FIN reaches us),
        # Poolpump reconnects, opens a new TCP, but our app still holds the
        # zombie. Without preemption we'd reject every new socket until the
        # 300s post-handshake watchdog reaped the zombie. With preemption,
        # recovery is ~200ms.
        #
        # Log shape: one HANDOVER line with the prior session's idle duration
        # (the operator's most useful diagnostic — long idle = wedge; short
        # idle = pump-side TCP confusion). The prior session's GONE log line
        # is suppressed by checking serve()'s :evicted return value below.
        if @session.connected?
          prior_last_seen = @session.last_seen_at
          prior_idle_sec  = prior_last_seen ? (monotonic - prior_last_seen).round(1) : nil
          preempt_started = monotonic
          @session.request_evict!
          unless wait_for_eviction
            log "REJECT #{addr} — preempt did not complete in #{EVICT_TIMEOUT_SEC}s; old session may be wedged in readpartial *?*"
            peer.close
            next
          end
          handover_ms = ((monotonic - preempt_started) * 1000).round
          idle_part   = prior_idle_sec ? "prior session was idle #{prior_idle_sec}s" : 'prior session had no telemetry yet'
          log "↻ HANDOVER #{addr} — #{idle_part}; handover took #{handover_ms}ms"
        else
          log "ACCEPT #{addr}"
        end

        Async do
          outcome = @session.serve(peer)
          # Suppress GONE on eviction — the HANDOVER line above already
          # told the operator the old session was retired in favour of
          # the new ACCEPT. Logging GONE too would say the same thing twice.
          log "GONE   #{addr}" unless outcome == :evicted
        end
      end
    ensure
      begin
        server&.close
      rescue StandardError
        nil
      end
    end

    private

    # Cooperative wait for the prior serve loop to release `@session`. Returns
    # true if the session reported `connected? == false` within the timeout,
    # false otherwise. The `sleep` is fiber-aware (Async patches it via
    # Fiber.scheduler), so the serve fiber gets CPU to observe the flag.
    def wait_for_eviction
      deadline = monotonic + EVICT_TIMEOUT_SEC
      until monotonic >= deadline
        return true unless @session.connected?

        sleep EVICT_POLL_INTERVAL_SEC
      end
      !@session.connected?
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def log(msg)
      return unless @logger

      @logger.call("[modbus_listener] #{msg}")
    end
  end
end
