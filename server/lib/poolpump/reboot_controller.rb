# lib/poolpump/reboot_controller.rb

require 'socket'

module Poolpump
  # Triggers a soft reboot of the HF-LPB130 WiFi module by sending the
  # AT+Z double-send recipe over UDP/48899. Same wire bytes the OEM Android
  # app's `Reprovision::Session` uses, but standalone (no dependency on the
  # `tools/reprovision.rb` CLI) so the emulator can call it from inside a
  # Docker container.
  #
  # CONFIRMED working: bounces only the WiFi module's TCP stack,
  # not the WiFi association — ping survives, Poolpump reconnects within ~35s.
  # Does NOT clear deeper controller-MCU wedges (those need the panel-button
  # arrow-key combo).
  #
  # Wraps three safety mechanisms:
  #   1. Cooldown — minimum gap between reboot attempts.
  #   2. Daily cap — bounded retries per rolling 24h window.
  #   3. Logged-loud — every attempt logs at WARN level.
  class RebootController
    HANDSHAKE = 'HF-A11ASSISTHREAD'.b.freeze
    REBOOT_SEQUENCE = ["AT+Z\r", "AT+Z\r", "AT+Q\r", "AT+Q\r"].map(&:b).freeze
    AT_PORT = 48_899
    INTER_CMD_GAP_SEC = 0.2

    DEFAULT_COOLDOWN_SEC = 300        # 5 min between reboot attempts
    DEFAULT_DAILY_LIMIT = 6           # max attempts per rolling 24h
    SECONDS_PER_DAY = 86_400

    def initialize(device_ip:,
                   cooldown_sec: DEFAULT_COOLDOWN_SEC,
                   daily_limit:  DEFAULT_DAILY_LIMIT,
                   logger: nil)
      @device_ip = device_ip
      @cooldown_sec = cooldown_sec
      @daily_limit = daily_limit
      @logger = logger
      @attempts = []         # monotonic timestamps of past reboot attempts
      @last_attempt_at = nil
    end

    # Attempt a reboot. Returns {ok: bool, reason: String?}. Possible reasons:
    #   nil          — reboot frame sent
    #   'cooldown'   — too soon since last attempt
    #   'daily-cap'  — hit the daily limit
    #   'send-error' — UDP send raised
    def reboot!(reason:)
      now = monotonic
      prune_old_attempts(now)

      if @last_attempt_at && (now - @last_attempt_at) < @cooldown_sec
        gap = (now - @last_attempt_at).to_i
        log "REBOOT skipped (cooldown — #{gap}s of #{@cooldown_sec}s elapsed); reason=#{reason}"
        return { ok: false, reason: 'cooldown' }
      end

      if @attempts.size >= @daily_limit
        log "REBOOT skipped (daily-cap — #{@attempts.size} attempts in last 24h); reason=#{reason}"
        return { ok: false, reason: 'daily-cap' }
      end

      log "REBOOT triggered → AT+Z double-send to #{@device_ip}; reason=#{reason}"
      begin
        send_reboot_sequence!
      rescue StandardError => e
        log "REBOOT send-error #{e.class}: #{e.message}"
        return { ok: false, reason: 'send-error' }
      end

      @attempts << now
      @last_attempt_at = now
      { ok: true, reason: nil }
    end

    def attempts_today
      prune_old_attempts(monotonic)
      @attempts.size
    end

    def stats
      {
        device_ip: @device_ip,
        attempts_today: attempts_today,
        last_attempt_ago_sec: @last_attempt_at && (monotonic - @last_attempt_at).round(1),
        cooldown_sec: @cooldown_sec,
        daily_limit: @daily_limit,
      }
    end

    private

    # Sends the bytes the OEM Android app's reboot flow sends:
    #   1. HF-A11ASSISTHREAD handshake (enter command mode)
    #   2. AT+Z (reboot — first one returns +ok if module's listening)
    #   3. AT+Z (second send — TIMEOUTs because module is rebooting)
    #   4. AT+Q (exit command mode — TIMEOUTs)
    #   5. AT+Q (defensive double-send)
    # We don't care about responses; the module's reboot is fire-and-forget.
    def send_reboot_sequence!
      sock = UDPSocket.new
      begin
        sock.connect(@device_ip, AT_PORT)
        sock.send(HANDSHAKE, 0)
        sleep INTER_CMD_GAP_SEC
        REBOOT_SEQUENCE.each do |cmd|
          sock.send(cmd, 0)
          sleep INTER_CMD_GAP_SEC
        end
      ensure
        sock.close
      end
    end

    def prune_old_attempts(now)
      cutoff = now - SECONDS_PER_DAY
      @attempts.reject! { |t| t < cutoff }
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def log(msg)
      return unless @logger

      @logger.call("[reboot_controller] #{msg}")
    end
  end
end
