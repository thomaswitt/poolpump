#!/usr/bin/env ruby
# Reprovisioning helper for Hi-Flying HF-A11 family WiFi modules (HF-LPB130 et al).
# Speaks the Hi-Flying UDP/48899 AT-command protocol from any laptop on the LAN.
#
# Pure stdlib: works with `ruby tools/reprovision.rb ...` — no `bundle install` needed.
#
# Subcommands:
#   discover [--target IP]
#   show     <ip> [--out DIR]
#   repoint  <ip> --server-hostname HOST [--port N] [--snapshot FILE]
#   set-wifi <ip> --ssid X --psk Y         [--snapshot FILE]
#   rollback <ip> --from SNAPSHOT
#
# The split between `repoint` (NETP only) and `set-wifi` (SSID/PSK) is deliberate:
# a typo in AT+WSKEY followed by AT+Z forces an enclosure-open factory reset.

require 'socket'
require 'optparse'
require 'json'
require 'time'
require 'fileutils'
require 'digest'
require 'bundler/setup'
require 'dotenv'

# Load defaults from a repo-root .env if present, so you can stash your
# module IP / WiFi creds once and skip retyping them on every invocation.
Dotenv.load(File.expand_path('../../.env', __dir__))

module Reprovision
  ASSIST_PORT = 48899
  ASSIST_PROBE = 'HF-A11ASSISTHREAD'.freeze
  AP_DEFAULT_IP = '10.10.100.254'.freeze
  RECV_BUFSZ = 1500
  DEFAULT_TIMEOUT = 2.0
  # P1 — snapshots contain raw AT+WSKEY (WiFi PSK). Default to the repo-root
  # `_data/` directory, which IS in the root .gitignore (`/_data/*`). Putting
  # them under `server/` anywhere would leak credentials as untracked files
  # since server/.gitignore doesn't cover those paths.
  DEFAULT_SNAPSHOT_DIR = File.expand_path('../../_data/snapshots', __dir__)

  class Error < StandardError; end
  class Timeout < Error; end
  class ModuleError < Error; end

  Found = Struct.new(:ip, :mac, :hostname, keyword_init: true) do
    def to_h_compact; to_h.compact end
  end

  module_function

  # ──────────────────────────────────────────────────────────────────────────
  # Wire protocol primitives
  # ──────────────────────────────────────────────────────────────────────────

  def open_udp(broadcast: false)
    sock = UDPSocket.new
    sock.setsockopt(Socket::SOL_SOCKET, Socket::SO_BROADCAST, true) if broadcast
    sock.setsockopt(Socket::SOL_SOCKET, Socket::SO_REUSEADDR, true)
    sock.bind('0.0.0.0', 0)
    sock
  end

  # Broadcast (or unicast) the assist probe and collect responders for `timeout` seconds.
  def discover(target: '255.255.255.255', timeout: 3.0)
    broadcast = target.end_with?('.255') || target == '255.255.255.255'
    sock = open_udp(broadcast: broadcast)
    sock.send(ASSIST_PROBE, 0, target, ASSIST_PORT)

    found = []
    deadline = monotonic + timeout
    loop do
      remaining = deadline - monotonic
      break if remaining <= 0
      break unless IO.select([sock], nil, nil, remaining)
      data, addr = sock.recvfrom(RECV_BUFSZ)
      payload = data.to_s.strip
      next if payload.empty? || payload == ASSIST_PROBE   # ignore our own echo

      ip, mac, host = payload.split(',', 3).map { |s| s&.strip }
      found << Found.new(ip: ip || addr[3], mac: mac, hostname: host)
    end
    # Deduplicate by IP — broadcast can produce two copies on multi-homed hosts.
    found.uniq { |f| f.ip }
  ensure
    sock&.close
  end

  # A persistent UDP/48899 session that handshakes ONCE then sends N AT
  # commands on the same socket. Mirrors the OEM Android app's flow
  # (CMDModeTryer → enterCMDMode → multiple `send`s on the same UdpUnicast
  # — see _data/android-app-dotels/dotels/smali/com/heatpump/rtuUtils/
  # ATCommand{,$CMDModeTryer}.smali). The single-shot `at_command` helper
  # is preserved as a thin wrapper for callers that only need one command.
  #
  # Why this matters: opening a NEW UDP socket per AT command (different
  # source port each time) makes the HF firmware's per-source-port command-
  # mode FSM treat each call as a fresh connection. Some commands then
  # come back +ERR=-1 or time out because the module hasn't fully settled
  # into cmd-mode. One socket → one handshake → all commands work.
  class Session
    SETTLE_AFTER_HANDSHAKE = 0.2 # seconds
    # Bounded recovery drain after a Timeout or ModuleError. The pre-send
    # `drain_pending` uses select(timeout=0) so it only sees packets
    # ALREADY in the kernel buffer; a late-arriving response from the
    # failed command can land between that drain and the next send, then
    # be picked up as the response to the WRONG command — shifting the
    # entire session's command/response alignment by one (observed in the
    # field on the DOTELS-SWP / VER 4.12.14 firmware). 300 ms is enough
    # to catch any packet the module was about to send when we gave up.
    DRAIN_AFTER_FAILURE_SEC = 0.3

    def initialize(ip)
      @ip = ip
      @sock = Reprovision.open_udp
      enter_cmd_mode!
    end

    def send(command, timeout: DEFAULT_TIMEOUT)
      # Drain any unsolicited packets sitting in the kernel buffer before
      # we send. The module replies to our `+ok` ACK with `+ERR=-1` (because
      # `+ok` isn't a valid AT command) — that reply arrives async and would
      # otherwise be returned as the response to the NEXT AT command,
      # masking real successes as fake failures. Same hazard for any earlier
      # AT command's late reply.
      drain_pending
      @sock.send("#{command}\r\n", 0, @ip, ASSIST_PORT)
      raw = Reprovision.recv_from(@sock, timeout: timeout, expected_ip: @ip)
      Reprovision.parse_at_response(raw, command)
    rescue Timeout, ModuleError
      drain_with_budget(DRAIN_AFTER_FAILURE_SEC)
      raise
    end

    def close
      @sock&.close
      @sock = nil
    end

    private

    def enter_cmd_mode!
      # 1. assist-thread handshake → module replies with "IP,MAC,HOSTNAME"
      @sock.send(ASSIST_PROBE, 0, @ip, ASSIST_PORT)
      Reprovision.drain_one(@sock, timeout: 0.4, expected_ip: @ip)
      # 2. ACK the handshake — required by some HF firmware variants
      #    (smali: ATCommand$CMDModeTryer.smali:181-183).
      @sock.send('+ok', 0, @ip, ASSIST_PORT)
      # 3. Brief settle so the module's FSM transitions to cmd-mode before
      #    the first real AT command arrives. Any reply to the `+ok` ACK
      #    will land during this window; the first Session#send will drain
      #    it before issuing the real command.
      sleep SETTLE_AFTER_HANDSHAKE
    end

    # Non-blocking drain — discard every packet currently sitting in the
    # kernel buffer for this socket. Returns count of packets discarded.
    def drain_pending
      count = 0
      loop do
        break unless IO.select([@sock], nil, nil, 0)

        @sock.recvfrom(RECV_BUFSZ)
        count += 1
      end
      count
    end

    # Bounded drain — wait up to `budget_sec` for late-arriving packets,
    # discarding each one. Used after Timeout/ModuleError so the next send
    # starts with a clean slate.
    def drain_with_budget(budget_sec)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + budget_sec
      count = 0
      loop do
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        break if remaining <= 0
        break unless IO.select([@sock], nil, nil, remaining)

        @sock.recvfrom(RECV_BUFSZ)
        count += 1
      end
      count
    end
  end

  # Single-shot convenience: open a session, send one command, close.
  # Returns the raw value string (everything after "+ok="), or "" for bare "+ok".
  def at_command(ip, command, timeout: DEFAULT_TIMEOUT)
    session = Session.new(ip)
    session.send(command, timeout: timeout)
  ensure
    session&.close
  end

  def parse_at_response(raw, command)
    s = raw.to_s.strip.gsub(/\r/, '')
    case s
    when /\A\+ok\s*=?\s*(.*)\z/m then Regexp.last_match(1).to_s
    when /\A\+ERR\s*=?\s*(.*)/m then raise ModuleError, "#{command} → +ERR=#{Regexp.last_match(1)}"
    else raise ModuleError, "#{command} → unexpected response #{s.inspect}"
    end
  end

  # Receive the next packet matching `expected_ip` (M2 — don't mistake a
  # response from another module on the LAN for ours). Loops past mismatches
  # until the deadline; raises Timeout if nothing matches in time.
  def recv_from(sock, timeout:, expected_ip:)
    deadline = monotonic + timeout
    loop do
      remaining = deadline - monotonic
      raise Timeout, "no response from #{expected_ip}" if remaining <= 0
      raise Timeout, "no response from #{expected_ip}" unless IO.select([sock], nil, nil, remaining)

      data, addr = sock.recvfrom(RECV_BUFSZ)
      return data if addr[3] == expected_ip
    end
  end

  # Discard up to one packet within the timeout, but only if it came from the
  # module we're talking to. Echoes from other modules on the same broadcast
  # domain are left in the kernel buffer for the next reader.
  def drain_one(sock, timeout:, expected_ip:)
    return unless IO.select([sock], nil, nil, timeout)

    data, addr = sock.recvfrom(RECV_BUFSZ)
    [data, addr] if addr[3] == expected_ip
  end

  def monotonic
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Snapshots — read the config we care about and persist it to disk so we
  # have a verbatim rollback target.
  # ──────────────────────────────────────────────────────────────────────────

  SNAPSHOT_QUERIES = %w[
    AT+VER
    AT+WMODE
    AT+WSSSID
    AT+WSKEY
    AT+NETP
    AT+WANN
    AT+TCPTO
    AT+TCPLK
    AT+WAP
    AT+WAKEY
    AT+WEBU
    AT+WEBVER
  ].freeze

  # Per-key masking: maps secret-bearing AT command → 0-based comma-segment
  # index of the secret. Different commands package secrets differently:
  #   AT+WSKEY  = "WPA2PSK,AES,<wifi-password>"     → seg 2
  #   AT+WAKEY  = "WPA2PSK,AES,<softap-password>"   → seg 2 (e.g. default 12345678)
  #   AT+WEBU   = "<username>,<password>"           → seg 1
  SECRET_KEYS = {
    'AT+WSKEY' => 2,
    'AT+WAKEY' => 2,
    'AT+WEBU'  => 1,
  }.freeze

  def snapshot(ip, output_dir: DEFAULT_SNAPSHOT_DIR)
    settings = {}
    session = Session.new(ip)
    begin
      SNAPSHOT_QUERIES.each do |q|
        begin
          settings[q] = session.send(q)
        rescue Error => e
          settings[q] = { error: e.message }
        end
      end
    ensure
      session.close
    end
    snap = {
      'taken_at' => Time.now.utc.iso8601,
      'module_ip' => ip,
      'settings' => settings,
    }
    # M3 — filename derives from the AT+NETP fingerprint so two snapshots from
    # the same IP with different settings sort distinctly. SHA1 over the NETP
    # string is plenty for this — purely cosmetic.
    netp = settings['AT+NETP']
    fingerprint = netp.is_a?(String) ? Digest::SHA1.hexdigest(netp)[0, 6] : 'nofp'
    FileUtils.mkdir_p(output_dir)
    path = File.join(output_dir,
                     "#{ip.tr('.', '-')}-#{fingerprint}-#{Time.now.utc.strftime('%Y%m%d-%H%M%S')}.json")
    File.write(path, JSON.pretty_generate(snap))
    [path, snap]
  end

  def load_snapshot(path)
    JSON.parse(File.read(path))
  end

  # Print the snapshot in human-friendly form, masking secrets unless --reveal.
  def render_snapshot(snap, reveal: false)
    out = []
    out << "module #{snap['module_ip']}  (snapshot taken_at #{snap['taken_at']})"
    snap['settings'].each do |k, v|
      shown = if SECRET_KEYS.key?(k) && !reveal && v.is_a?(String)
          mask_at = SECRET_KEYS[k]
          v.split(',').map.with_index { |part, i| i == mask_at ? '***' : part }.join(',')
      else
          v
      end
      out << format('  %-12s = %s', k, shown)
    end
    out.join("\n")
  end

  # ──────────────────────────────────────────────────────────────────────────
  # High-level mutations: commission, repoint, set-wifi, rollback.
  # All require a fresh snapshot to exist (or be passed) — no setting changes
  # without a known rollback target.
  #
  # Pick the right tool for the situation:
  #
  #   commission — module is in AP mode (broadcasting `HF-LPB130` at
  #                10.10.100.254). Sets WiFi creds AND server target in ONE
  #                session, then reboots. Use this for first-time setup or
  #                after a factory reset — once the module reboots into STA
  #                mode you lose access to 10.10.100.254 forever, so anything
  #                you don't write before the reboot is a separate trip.
  #
  #   repoint    — module is in STA mode on home WiFi. Just changes AT+NETP
  #                (server hostname/port). Safe — touches no WiFi creds.
  #
  #   set-wifi   — module is in AP mode and you only want to update WiFi
  #                creds (server target stays as snapshotted). Niche case;
  #                most "AP mode" trips want `commission` instead.
  #
  #   rollback   — restore AT+NETP from a snapshot file (e.g. back to the
  #                Chinese cloud as a safety net).
  # ──────────────────────────────────────────────────────────────────────────

  def require_recent_snapshot!(ip, snapshot_path: nil, max_age_min: 30)
    if snapshot_path
      raise Error, "snapshot file not found: #{snapshot_path}" unless File.exist?(snapshot_path)
      return load_snapshot(snapshot_path)
    end
    # auto-find newest snapshot for this IP
    candidates = Dir[File.join(DEFAULT_SNAPSHOT_DIR, "#{ip.tr('.', '-')}-*.json")]
                         .sort_by { |p| File.mtime(p) }
                         .reverse
    raise Error, "no snapshot found for #{ip}; run `show #{ip}` first" if candidates.empty?
    age_sec = Time.now - File.mtime(candidates.first)
    if age_sec > max_age_min * 60
      warn "WARN: newest snapshot for #{ip} is #{(age_sec / 60).to_i} minutes old; consider running `show` again."
    end
    load_snapshot(candidates.first)
  end

  def repoint(ip, server_hostname:, port: 502, snapshot_path: nil, dry_run: false)
    require_recent_snapshot!(ip, snapshot_path: snapshot_path)
    # Mixed-case "Client" — the DOTELS-SWP firmware rejects all-caps "CLIENT"
    # with +ERR=-9. See commission() for context.
    new_netp = "TCP,Client,#{port},#{server_hostname}"
    plan = [
      ['AT+NETP', "AT+NETP=#{new_netp}"],
      ['verify', 'AT+NETP', new_netp],
      ['reboot', 'AT+Z'],
    ]
    apply_plan(ip, plan, dry_run: dry_run)
  end

  # AP-mode bootstrap. Module is at 10.10.100.254 because it's not (yet)
  # joined to your WiFi. Writes EVERYTHING — WSSSID, WSKEY, NETP, WMODE —
  # then a single AT+Z. Once the module reboots, 10.10.100.254 is gone and
  # the module reappears on your WiFi already pointing at the new server.
  #
  # Order is critical: WMODE=STA goes LAST. The OEM firmware refuses to
  # flip to STA-only mode while WSSSID is still the factory default
  # `HF-LPB130-AP` — switching would cut off the SoftAP without valid STA
  # creds, leaving the module unreachable. Match the iOS app's order
  # exactly (visible in IMG_3700/3701): WSSSID → WSKEY → NETP → WMODE → Z.
  # Verify-readbacks happen AFTER all sets — same firmware variant rejects
  # interleaved set+query in the same session.
  def commission(ip, ssid:, psk:, server_hostname:, port: 502, snapshot_path: nil, dry_run: false)
    require_recent_snapshot!(ip, snapshot_path: snapshot_path)
    # The OEM firmware echoes NETP back as "TCP,Server,..." or "TCP,Client,..."
    # (mixed case). The all-uppercase "TCP,CLIENT,..." returns +ERR=-9 on the
    # DOTELS-SWP variant — apparently the protocol/mode enum is case-strict
    # on writes even though semantic_equal? is case-insensitive on reads.
    new_netp = "TCP,Client,#{port},#{server_hostname}"
    new_wskey = "WPA2PSK,AES,#{psk}"
    plan = [
      ['AT+WSSSID', "AT+WSSSID=#{ssid}"],
      ['AT+WSKEY', "AT+WSKEY=#{new_wskey}"],
      ['AT+NETP', "AT+NETP=#{new_netp}"],
      ['AT+WMODE', 'AT+WMODE=STA'],
      ['verify', 'AT+WSSSID', ssid],
      ['verify', 'AT+WSKEY', new_wskey],
      ['verify', 'AT+NETP', new_netp],
      ['verify', 'AT+WMODE', 'STA'],
      ['reboot', 'AT+Z'],
    ]
    apply_plan(ip, plan, dry_run: dry_run)
  end

  def set_wifi(ip, ssid:, psk:, snapshot_path: nil, dry_run: false)
    require_recent_snapshot!(ip, snapshot_path: snapshot_path)
    # H8 — verify each WiFi-credential write BEFORE rebooting. A typo on
    # AT+WSKEY followed by AT+Z is the canonical "needed factory reset"
    # bricking path; we refuse to reboot unless the module echoes back
    # exactly what we sent.
    plan = [
      ['AT+WMODE', 'AT+WMODE=STA'],
      ['verify', 'AT+WMODE', 'STA'],
      ['AT+WSSSID', "AT+WSSSID=#{ssid}"],
      ['verify', 'AT+WSSSID', ssid],
      ['AT+WSKEY', "AT+WSKEY=WPA2PSK,AES,#{psk}"],
      ['verify', 'AT+WSKEY', "WPA2PSK,AES,#{psk}"],
      ['reboot', 'AT+Z'],
    ]
    apply_plan(ip, plan, dry_run: dry_run)
  end

  def rollback(ip, snapshot_path:, dry_run: false)
    snap = load_snapshot(snapshot_path)
    netp = snap.dig('settings', 'AT+NETP')
    raise Error, 'snapshot has no AT+NETP value, refusing to rollback' unless netp.is_a?(String) && !netp.empty?

    plan = [
      ['AT+NETP', "AT+NETP=#{netp}"],
      ['verify', 'AT+NETP', netp],
      ['reboot', 'AT+Z'],
    ]
    apply_plan(ip, plan, dry_run: dry_run)
  end

  # Applies a plan of [label, cmd, optional_expected_value] tuples. A `verify`
  # step whose response doesn't match its expected value RAISES — H8: we'd
  # rather abort before AT+Z than reboot a misconfigured module.
  #
  # ALL commands run on a SINGLE Session — one assist-thread handshake at the
  # start, then N AT commands on the same socket. Mirrors the OEM app's flow
  # (see Session class for rationale).
  #
  # Inter-command delay: the OEM Android app waits 1000 ms between every AT
  # command (`TaskExecutor.scheduleTaskOnUiThread` in AddPumpActivity$6..$10).
  # Without it, WSSSID/WSKEY succeed but the immediately-following NETP
  # returns +ERR=-9 because the firmware's WiFi-reconfigure FSM is busy.
  # Override via env (e.g. `POOLPUMP_INTER_CMD_DELAY_SEC=0` in specs).
  INTER_CMD_DELAY_SEC = Float(ENV.fetch('POOLPUMP_INTER_CMD_DELAY_SEC', '1.0'))

  def apply_plan(ip, plan, dry_run:)
    if dry_run
      puts "DRY RUN — commands that would be sent to #{ip}:"
      plan.each { |label, cmd, _expected| puts "  #{label.ljust(10)} → #{cmd}" }
      return
    end
    session = Session.new(ip)
    plan.each_with_index do |(label, cmd, expected), i|
      sleep INTER_CMD_DELAY_SEC if i.positive?
      print "  #{label.ljust(10)} → #{cmd} ... "
      begin
        result = session.send(cmd, timeout: cmd == 'AT+Z' ? 0.5 : DEFAULT_TIMEOUT)
        puts (result.empty? ? 'ok' : "ok (#{result})")
        if label == 'verify' && expected && !semantic_equal?(cmd, expected, result)
          # H8 — refuse to proceed (next step is likely AT+Z).
          raise Error,
                "verify failed for #{cmd}: expected #{expected.inspect}, got #{result.inspect}. " \
                'Aborting — module not rebooted; current settings still in effect.'
        end
      rescue Timeout
        # AT+Z is expected to time out — module reboots before responding.
        raise unless cmd == 'AT+Z'

        puts 'reboot dispatched (no response — expected)'
      rescue ModuleError => e
        # Some HF-LPB130 firmwares (DOTELS-SWP / VER 4.12.14, observed in
        # the field) respond +ERR=-9 to AT+NETP set-commands even when the
        # value gets committed internally — verified via a subsequent show.
        # If a downstream `verify` step covers this same setting, defer to
        # it as the source of truth. H8 brick-protection still holds: a
        # genuinely uncommitted setting will fail the verify and abort
        # before AT+Z. Verify steps themselves never get this softening —
        # if a read raises, it's a real failure.
        raise if label == 'verify' || !verify_downstream?(plan, cmd, i)

        puts "soft +ERR (#{e.message.split('→').last.strip}); deferring to downstream verify"
      end
    end
    puts 'done. allow ~10 seconds for the module to rejoin WiFi after reboot.'
  ensure
    session&.close
  end

  # Does the plan have a `verify` step AFTER `current_index` for the same
  # AT field as `set_cmd`? Used to decide whether a +ERR on a write can be
  # softened (the verify will catch any real problem before AT+Z runs).
  def verify_downstream?(plan, set_cmd, current_index)
    setting = set_cmd.split('=', 2).first # "AT+NETP=foo" → "AT+NETP"
    plan[(current_index + 1)..].any? { |step| step[0] == 'verify' && step[1] == setting }
  end

  # P2 — modules normalize some response casing. AT+NETP is the canonical
  # case (set with TCP,CLIENT,..., read back as TCP,Client,...); without
  # this helper the verify step would fail and abort the AT+Z reboot,
  # leaving the module pointed at the OLD server with the new setting
  # silently committed. Comparison rules per command:
  #
  #   AT+NETP    — protocol/mode/host case-insensitive, port as integer
  #   AT+WMODE   — case-insensitive AND requesting STA is satisfied by APSTA
  #                (DOTELS-SWP firmware keeps the AP interface up while we're
  #                still talking to it via SoftAP; observed empirically that
  #                AT+Z still reboots into a working STA-only mode afterwards).
  #                Asymmetric: requesting AP is NOT satisfied by APSTA — that
  #                would mean STA is also active and would leak onto a network
  #                we didn't ask the module to join.
  #   anything else — exact match (WSSSID and WSKEY are intentionally
  #                   case-sensitive: SSIDs CAN be case-distinct, PSKs ARE)
  def semantic_equal?(cmd, expected, actual)
    return false if expected.nil? || actual.nil?

    case cmd
    when 'AT+NETP' then norm_netp(expected) == norm_netp(actual)
    when 'AT+WMODE' then wmode_equal?(expected, actual)
    else expected.to_s == actual.to_s
    end
  end

  def wmode_equal?(expected, actual)
    e = expected.to_s.upcase
    a = actual.to_s.upcase
    return true if e == a
    e == 'STA' && a == 'APSTA'
  end

  def norm_netp(s)
    parts = s.to_s.split(',', 4).map { |p| p&.strip }
    return [s.to_s] unless parts.length == 4

    proto, mode, port, host = parts
    [proto.to_s.downcase, mode.to_s.downcase, port.to_i, host.to_s.downcase]
  end
end

# ──────────────────────────────────────────────────────────────────────────
# CLI dispatcher (only when invoked directly, not when required from specs)
# ──────────────────────────────────────────────────────────────────────────

if __FILE__ == $PROGRAM_NAME
  def usage(io = $stderr, code = 1)
    io.puts <<~USAGE
              usage: #{File.basename($PROGRAM_NAME)} <subcommand> [options]

              subcommands:
                discover    [--target IP]                       broadcast (default) or query a specific IP
                show        <ip> [--reveal] [--out DIR]         read & save current AT settings

                commission  <ip> --ssid X --psk Y               AP-MODE BOOTSTRAP: set WiFi creds AND
                            --server-hostname HOST [--port N]           server target in one session, then reboot.
                            [--snapshot FILE] [--dry-run]       Use this when reaching the module via
                                                                10.10.100.254 (HF-LPB130 SoftAP).

                repoint     <ip> --server-hostname HOST [--port N]      STA-MODE: change ONLY AT+NETP, then reboot.
                            [--snapshot FILE] [--dry-run]

                set-wifi    <ip> --ssid X --psk Y               AP-MODE WIFI-ONLY: change WiFi creds, leave
                            [--snapshot FILE] [--dry-run]       server unchanged. Niche — usually you want
                                                                `commission` instead.

                rollback    <ip> --from SNAPSHOT [--dry-run]    write AT+NETP back to captured value

                reboot      <ip>                                soft-reboot the WiFi module (AT+Z double-send;
                                                                ping survives, ~35s recovery)

              defaults from .env (optional, see .env.template):
                <ip>          ← POOLPUMP_MODULE_IP
                --server-hostname   ← POOLPUMP_SERVER_HOSTNAME
                --port        ← POOLPUMP_SERVER_PORT (default 502)
                --ssid        ← POOLPUMP_WIFI_SSID
                --psk         ← POOLPUMP_WIFI_PSK

              examples:
                ruby tools/reprovision.rb discover
                ruby tools/reprovision.rb discover --target 10.10.100.254
                ruby tools/reprovision.rb show 10.10.100.254
                ruby tools/reprovision.rb commission 10.10.100.254 \\
                  --ssid MyWifi --psk 'wifi password' \\
                  --server-hostname homeserver.example.com --port 502
                ruby tools/reprovision.rb repoint 192.168.0.42 --server-hostname homeserver.example.com
                ruby tools/reprovision.rb rollback 192.168.0.42 --from /absolute/path/to/192-168-0-42-<fp>-<ts>.json
                  # Use the EXACT path printed by `show` (printed as a
                  # copy-pasteable command at the end of its output). Never
                  # pass a shell wildcard — `*.json` may match multiple
                  # snapshots, and the CLI refuses if more than one path
                  # ends up on the line.
            USAGE
    exit code
  end

  cmd = ARGV.shift or usage

  # Per-arg ENV defaults — set these in `.env` to skip retyping. Positional
  # `<ip>` arguments fall back to POOLPUMP_MODULE_IP if not given on the line.
  default_module_ip = ENV.fetch('POOLPUMP_MODULE_IP', nil)
  default_server_hostname = ENV.fetch('POOLPUMP_SERVER_HOSTNAME', nil)
  default_server_port = Integer(ENV.fetch('POOLPUMP_SERVER_PORT', '502'))
  default_wifi_ssid = ENV.fetch('POOLPUMP_WIFI_SSID', nil)
  default_wifi_psk = ENV.fetch('POOLPUMP_WIFI_PSK', nil)

  # Pull <ip> from ARGV if present, else from POOLPUMP_MODULE_IP, else fail.
  pop_ip = lambda do
    ip = ARGV.first && !ARGV.first.start_with?('--') ? ARGV.shift : default_module_ip
    unless ip
      warn 'missing <ip> (set POOLPUMP_MODULE_IP in .env, or pass it as the first argument)'
      usage
    end
    ip
  end

  # Defense-in-depth: every mutation command calls this AFTER OptionParser
  # to refuse leftover positional args. Without it, `--psk my wifi password`
  # silently parses as `--psk=my` and writes a wrong PSK before reboot —
  # a brick-grade footgun. Same shape catches `--server-hostname host 5020`
  # (where `5020` is leftover and `--port` defaults to 502 silently).
  reject_leftover_args = lambda do |subcmd|
    return if ARGV.empty?

    warn "#{subcmd}: unexpected extra arguments after option parsing: #{ARGV.inspect}"
    warn 'Hint: shell-quote any value that contains spaces, e.g. --psk \'my wifi password\'.'
    exit 2
  end

  case cmd
  when '-h', '--help', 'help'
    usage($stdout, 0)
  when 'discover'
    target = '255.255.255.255'
    timeout = 3.0
    OptionParser.new do |o|
      o.on('--target IP') { |v| target = v }
      o.on('--timeout SEC', Float) { |v| timeout = v }
    end.parse!(ARGV)
    found = Reprovision.discover(target: target, timeout: timeout)
    if found.empty?
      warn "no modules responded on #{target}:#{Reprovision::ASSIST_PORT} within #{timeout}s"
      warn "tip: if the module is in AP mode, try: --target #{Reprovision::AP_DEFAULT_IP}"
      exit 2
    end
    found.each { |f| puts [f.ip, f.mac, f.hostname].compact.join('  ') }
  when 'show'
    ip = pop_ip.call
    reveal = false
    out_dir = Reprovision::DEFAULT_SNAPSHOT_DIR
    OptionParser.new do |o|
      o.on('--reveal') { reveal = true }
      o.on('--out DIR') { |v| out_dir = v }
    end.parse!(ARGV)
    reject_leftover_args.call('show')
    path, snap = Reprovision.snapshot(ip, output_dir: out_dir)
    puts Reprovision.render_snapshot(snap, reveal: reveal)
    puts
    puts "snapshot saved → #{path}"
    puts
    puts 'rollback hint (copy-paste verbatim, paths are absolute):'
    puts "  ruby tools/reprovision.rb rollback #{ip} --from #{path}"
  when 'repoint'
    ip = pop_ip.call
    server_hostname = default_server_hostname
    port = default_server_port
    snap = nil
    dry = false
    OptionParser.new do |o|
      o.on('--server-hostname HOST') { |v| server_hostname = v }
      o.on('--port N', Integer) { |v| port = v }
      o.on('--snapshot FILE') { |v| snap = v }
      o.on('--dry-run') { dry = true }
    end.parse!(ARGV)
    reject_leftover_args.call('repoint')
    unless server_hostname
      warn 'missing --server-hostname (set POOLPUMP_SERVER_HOSTNAME in .env, or pass it explicitly)'
      usage
    end
    Reprovision.repoint(ip, server_hostname: server_hostname, port: port, snapshot_path: snap, dry_run: dry)
  when 'set-wifi'
    ip = pop_ip.call
    ssid = default_wifi_ssid
    psk = default_wifi_psk
    snap = nil
    dry = false
    OptionParser.new do |o|
      o.on('--ssid X') { |v| ssid = v }
      o.on('--psk Y') { |v| psk = v }
      o.on('--snapshot FILE') { |v| snap = v }
      o.on('--dry-run') { dry = true }
    end.parse!(ARGV)
    reject_leftover_args.call('set-wifi')
    unless ssid && psk
      warn 'missing --ssid / --psk (set POOLPUMP_WIFI_SSID and POOLPUMP_WIFI_PSK in .env, or pass them explicitly)'
      usage
    end
    Reprovision.set_wifi(ip, ssid: ssid, psk: psk, snapshot_path: snap, dry_run: dry)
  when 'commission'
    ip = pop_ip.call
    ssid = default_wifi_ssid
    psk = default_wifi_psk
    server_hostname = default_server_hostname
    port = default_server_port
    snap = nil
    dry = false
    OptionParser.new do |o|
      o.on('--ssid X') { |v| ssid = v }
      o.on('--psk Y') { |v| psk = v }
      o.on('--server-hostname HOST') { |v| server_hostname = v }
      o.on('--port N', Integer) { |v| port = v }
      o.on('--snapshot FILE') { |v| snap = v }
      o.on('--dry-run') { dry = true }
    end.parse!(ARGV)
    reject_leftover_args.call('commission')
    missing = []
    missing << '--ssid (POOLPUMP_WIFI_SSID)' unless ssid
    missing << '--psk (POOLPUMP_WIFI_PSK)' unless psk
    missing << '--server-hostname (POOLPUMP_SERVER_HOSTNAME)' unless server_hostname
    unless missing.empty?
      warn "commission: missing required args: #{missing.join(', ')}"
      warn 'Tip: stash defaults in .env (see .env.template) so you only ever pass the IP.'
      usage
    end
    Reprovision.commission(ip, ssid: ssid, psk: psk, server_hostname: server_hostname, port: port,
                               snapshot_path: snap, dry_run: dry)
  when 'rollback'
    ip = pop_ip.call
    snap = nil
    dry = false
    OptionParser.new do |o|
      o.on('--from FILE') { |v| snap = v }
      o.on('--dry-run') { dry = true }
    end.parse!(ARGV)
    usage unless snap
    reject_leftover_args.call('rollback')
    Reprovision.rollback(ip, snapshot_path: snap, dry_run: dry)
  when 'reboot'
    ip = pop_ip.call
    OptionParser.new.parse!(ARGV)
    reject_leftover_args.call('reboot')
    # Soft reboot of the WiFi module via the AT+Z double-send recipe
    # (CONFIRMED working). Bounces only the module's TCP/Modbus
    # layer, not the WiFi association — ping survives, recovery in ~35s.
    # Same wire bytes the emulator's POST /reboot route + auto-watchdog use.
    require_relative '../lib/poolpump/reboot_controller'
    ctrl = Poolpump::RebootController.new(
      device_ip:    ip,
      cooldown_sec: 0,            # CLI-explicit reboots bypass cooldown
      daily_limit:  1_000_000,
      logger:       ->(m) { puts m },
    )
    result = ctrl.reboot!(reason: 'cli')
    if result[:ok]
      puts "→ AT+Z reboot dispatched to #{ip}. Allow ~35s for the WiFi module to reconnect."
    else
      abort "reboot failed: #{result[:reason]}"
    end
  else
    warn "unknown subcommand: #{cmd}"
    usage
  end
end # if __FILE__ == $PROGRAM_NAME
