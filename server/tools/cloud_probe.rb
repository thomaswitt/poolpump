#!/usr/bin/env ruby
# Read-only cloud probe — Phase 0.5 behavioural oracle.
#
# Talks to the still-alive Chinese cloud at fzdbiology.com:8080 and
# captures full getRtuRealTime JSON snapshots so the wire-level Phase 1
# sniffer has ground-truth field-name vocabulary to diff against.
#
# Stdlib + dotenv gem. Run via `bundle exec ruby tools/cloud_probe.rb …`
# (or with `bundle install` already on $LOAD_PATH).
#
# Subcommands:
#   login                          smoke-test creds, print {userId, token}
#   status                         fetch getRtuRealTime, save baseline JSON
#   watch [--interval SEC]         poll getRtuRealTime every SEC, save each snapshot
#   diff <a.json> <b.json>         field-by-field deltas between two saved baselines
#
# Credentials live in `.env` (gitignored):
#   POOLPUMP_CLOUD_EMAIL=...
#   POOLPUMP_CLOUD_PASSWORD='...'
#   POOLPUMP_CLOUD_RTU_ID=12345678
#   POOLPUMP_CLOUD_HOST=www.fzdbiology.com:8080   # optional
#
# **Read-only by design.** No `saveCode.do` writes. State changes are
# driven by you toggling settings on the pump's physical panel between
# `watch` snapshots.

require 'net/http'
require 'uri'
require 'json'
require 'optparse'
require 'time'
require 'fileutils'
require 'bundler/setup'
require 'dotenv'

Dotenv.load(File.expand_path('../../.env', __dir__))

module CloudProbe
  DEFAULT_HOST = 'www.fzdbiology.com:8080'.freeze
  USER_AGENT = 'PoolHeatPump/2.0.0 (iPhone; iOS 16.5; Scale/3.00)'.freeze
  # Repo-root `_data/` (gitignored via `/_data/*`), not server/_data — same
  # convention as DEFAULT_SNAPSHOT_DIR in tools/reprovision.rb.
  DEFAULT_BASELINE_DIR = File.expand_path('../../_data/cloud-baselines', __dir__)
  DEFAULT_TIMEOUT = 10 # seconds

  class Error < StandardError; end
  class CredentialsMissing < Error; end
  class CloudError < Error; end

  module_function

  # ── credentials ─────────────────────────────────────────────────────────

  def env!
    {
      email: ENV.fetch('POOLPUMP_CLOUD_EMAIL') { raise CredentialsMissing, 'POOLPUMP_CLOUD_EMAIL not set (add to .env)' },
      password: ENV.fetch('POOLPUMP_CLOUD_PASSWORD') { raise CredentialsMissing, 'POOLPUMP_CLOUD_PASSWORD not set (add to .env)' },
      rtu_id: ENV.fetch('POOLPUMP_CLOUD_RTU_ID') { raise CredentialsMissing, 'POOLPUMP_CLOUD_RTU_ID not set (add to .env)' },
      host: ENV.fetch('POOLPUMP_CLOUD_HOST', DEFAULT_HOST),
    }
  end

  # ── HTTP primitives ─────────────────────────────────────────────────────

  def http(host_port)
    host, port = host_port.split(':', 2)
    h = Net::HTTP.new(host, Integer(port || 80))
    h.read_timeout = DEFAULT_TIMEOUT
    h.open_timeout = DEFAULT_TIMEOUT
    h
  end

  def base_headers(user_id: nil, token: nil)
    headers = {
      'Accept' => 'application/json',
      'User-Agent' => USER_AGENT,
    }
    headers['userId'] = user_id.to_s if user_id
    headers['token'] = token.to_s if token
    headers
  end

  # ── high-level calls ────────────────────────────────────────────────────

  # Returns {user_id:, token:} or raises.
  def login(host:, email:, password:)
    req = Net::HTTP::Post.new('/scadaiot/user/loginUser.do', base_headers.merge('Content-Type' => 'application/x-www-form-urlencoded'))
    req.body = URI.encode_www_form(email: email, password: password)
    resp = http(host).request(req)
    body = JSON.parse(resp.body)
    raise CloudError, "loginUser.do → resultCode=#{body['resultCode']} (#{body['resultMsg']})" unless body['resultCode'] == 1

    { user_id: body.dig('data', 'userId'), token: body.dig('data', 'token') }
  rescue JSON::ParserError => e
    raise CloudError, "loginUser.do returned non-JSON: #{e.message}"
  end

  # Returns the FULL parsed response Hash (including `data` and `resultCode`).
  # Does NOT raise on resultCode=0 — an offline device still returns a valid
  # envelope (`{resultCode: 0, data: null, resultMsg: "Failed to get parameters"}`)
  # and the caller wants to see that for diagnostic purposes. Only HTTP-layer
  # parse failures raise.
  def get_realtime(host:, user_id:, token:, rtu_id:)
    req = Net::HTTP::Get.new("/scadaiot/rtuModel/getRtuRealTime.do?rtuId=#{rtu_id}",
                             base_headers(user_id: user_id, token: token))
    resp = http(host).request(req)
    JSON.parse(resp.body)
  rescue JSON::ParserError => e
    raise CloudError, "getRtuRealTime.do returned non-JSON: #{e.message}"
  end

  # Cloud's device-registry endpoint. Returns rich metadata even when the
  # device is offline: rtuName, rtuCode (MAC), rtuType, modelName, last-seen
  # timestamp (`endRtuTime`), `onlineState`. Used as a fallback when
  # getRtuRealTime returns null.
  def get_view(host:, user_id:, token:)
    req = Net::HTTP::Get.new("/scadaiot/rtuModel/getRtuView.do?userId=#{user_id}",
                             base_headers(user_id: user_id, token: token))
    resp = http(host).request(req)
    JSON.parse(resp.body)
  rescue JSON::ParserError => e
    raise CloudError, "getRtuView.do returned non-JSON: #{e.message}"
  end

  # Decode the cloud's millisecond-epoch timestamps to a human ISO-8601 string.
  def format_epoch_ms(ms)
    return nil if ms.nil?

    Time.at(ms / 1000.0).utc.strftime('%Y-%m-%d %H:%M:%S UTC')
  end

  # Pull the device record matching rtu_id out of the getRtuView response.
  def find_device(view_envelope, rtu_id:)
    Array(view_envelope['data']).find { |d| d['rtuId'].to_s == rtu_id.to_s }
  end

  # ── snapshot persistence ────────────────────────────────────────────────

  def save_snapshot(envelope, dir:, rtu_id:)
    FileUtils.mkdir_p(dir)
    ts = Time.now.utc.strftime('%Y%m%d-%H%M%S')
    path = File.join(dir, "#{rtu_id}-#{ts}.json")
    payload = {
      'taken_at' => Time.now.utc.iso8601,
      'rtu_id' => rtu_id.to_s,
      'envelope' => envelope,
    }
    File.write(path, JSON.pretty_generate(payload))
    path
  end

  def load_snapshot(path)
    JSON.parse(File.read(path))
  end

  # ── pure helpers (specced) ──────────────────────────────────────────────

  # Returns nested data hash, regardless of whether the file is the saved
  # envelope (`{taken_at, rtu_id, envelope: {data: {...}}}`) or the raw
  # cloud response (`{data: {...}}`).
  def extract_data(snapshot)
    snapshot.dig('envelope', 'data') || snapshot['data'] || snapshot
  end

  # Diff two `data` hashes. Returns:
  #   { changed: { key => [a_value, b_value] }, only_a: {...}, only_b: {...} }
  def diff_data(a, b)
    keys_a = a.keys
    keys_b = b.keys
    common = keys_a & keys_b

    changed = {}
    common.each do |k|
      changed[k] = [a[k], b[k]] unless a[k] == b[k]
    end

    {
      changed: changed,
      only_a: a.slice(*(keys_a - keys_b)),
      only_b: b.slice(*(keys_b - keys_a)),
    }
  end

  # Pretty-print a diff result.
  def render_diff(diff, label_a: 'A', label_b: 'B')
    out = []
    if diff[:changed].empty? && diff[:only_a].empty? && diff[:only_b].empty?
      out << '(no differences)'
      return out.join("\n")
    end

    if diff[:changed].any?
      out << "CHANGED (#{diff[:changed].size}):"
      diff[:changed].sort_by { |k, _| k.to_s }.each do |k, (av, bv)|
        out << format('  %-22s %s → %s', k, av.inspect, bv.inspect)
      end
    end

    unless diff[:only_a].empty?
      out << ''
      out << "ONLY IN #{label_a} (#{diff[:only_a].size}):"
      diff[:only_a].sort_by { |k, _| k.to_s }.each { |k, v| out << "  #{k} = #{v.inspect}" }
    end

    unless diff[:only_b].empty?
      out << ''
      out << "ONLY IN #{label_b} (#{diff[:only_b].size}):"
      diff[:only_b].sort_by { |k, _| k.to_s }.each { |k, v| out << "  #{k} = #{v.inspect}" }
    end

    out.join("\n")
  end

  # ── summary printer used by status / watch ──────────────────────────────

  def summarize(envelope)
    data = envelope['data']
    return "OFFLINE — getRtuRealTime returned no data (resultCode=#{envelope['resultCode']})" if data.nil? || (data.respond_to?(:empty?) && data.empty?)

    interesting = data.slice('switch', 'model', 'pa10', 'ap2', 'ap3', 'heattemp', 'autotemp', 'cooltemp')
    "ONLINE fields=#{data.size}  #{interesting.map { |k, v| "#{k}=#{v}" }.join(' ')}"
  end

  # Render the offline-diagnostic block from a getRtuView device record.
  def summarize_view(device)
    return '(no device record found in getRtuView response)' if device.nil?

    last_seen = format_epoch_ms(device['endRtuTime'])
    created = format_epoch_ms(device['updateDate'])
    [
      "rtuName    : #{device['rtuName'].inspect}",
      "rtuCode    : #{device['rtuCode']}",
      "rtuType    : #{device['rtuType']} (model: #{device['modelName']})",
      "onlineState: #{device['onlineState']}  #{device['onlineState'].zero? ? '(OFFLINE)' : '(online)'}",
      "last_seen  : #{last_seen}",
      "created    : #{created}",
    ].join("\n  ")
  end
end

# ──────────────────────────────────────────────────────────────────────────
# CLI dispatcher
# ──────────────────────────────────────────────────────────────────────────

if __FILE__ == $PROGRAM_NAME
  def usage(io = $stderr, code = 1)
    io.puts <<~USAGE
              usage: #{File.basename($PROGRAM_NAME)} <subcommand> [options]

              subcommands:
                login                                  smoke-test creds (POST loginUser)
                status [--out DIR]                     fetch one getRtuRealTime + save baseline JSON
                watch  [--interval SEC] [--out DIR]    poll every SEC (default 5), save each snapshot
                diff   <a.json> <b.json>               show field-by-field deltas between two baselines

              env (load via .env, see .env.template):
                POOLPUMP_CLOUD_EMAIL
                POOLPUMP_CLOUD_PASSWORD
                POOLPUMP_CLOUD_RTU_ID
                POOLPUMP_CLOUD_HOST=www.fzdbiology.com:8080  (optional)

              examples:
                ruby tools/cloud_probe.rb login
                ruby tools/cloud_probe.rb status
                ruby tools/cloud_probe.rb watch --interval 5
                ruby tools/cloud_probe.rb diff before.json after.json
            USAGE
    exit code
  end

  cmd = ARGV.shift or usage

  begin
    case cmd
    when '-h', '--help', 'help'
      usage($stdout, 0)
    when 'login'
      e = CloudProbe.env!
      session = CloudProbe.login(host: e[:host], email: e[:email], password: e[:password])
      puts "login OK — userId=#{session[:user_id]} token=#{session[:token]}"
    when 'status'
      out = CloudProbe::DEFAULT_BASELINE_DIR
      OptionParser.new { |o| o.on('--out DIR') { |v| out = v } }.parse!(ARGV)
      raise 'status: unexpected extra arguments' unless ARGV.empty?

      e = CloudProbe.env!
      session = CloudProbe.login(host: e[:host], email: e[:email], password: e[:password])
      envelope = CloudProbe.get_realtime(host: e[:host], user_id: session[:user_id], token: session[:token], rtu_id: e[:rtu_id])
      path = CloudProbe.save_snapshot(envelope, dir: out, rtu_id: e[:rtu_id])
      puts "[#{Time.now.strftime('%H:%M:%S')}] #{CloudProbe.summarize(envelope)}"
      puts "saved → #{path}"

      # If the device is offline, getRtuRealTime tells us nothing — fall back
      # to getRtuView for the registry metadata so the diagnostic isn't empty.
      if envelope['data'].nil? || (envelope['data'].respond_to?(:empty?) && envelope['data'].empty?)
        view = CloudProbe.get_view(host: e[:host], user_id: session[:user_id], token: session[:token])
        device = CloudProbe.find_device(view, rtu_id: e[:rtu_id])
        puts
        puts 'device registry (from getRtuView):'
        puts "  #{CloudProbe.summarize_view(device)}"
      end
    when 'watch'
      out = CloudProbe::DEFAULT_BASELINE_DIR
      interval = 5
      OptionParser.new do |o|
        o.on('--out DIR') { |v| out = v }
        o.on('--interval SEC', Integer) { |v| interval = v }
      end.parse!(ARGV)
      raise 'watch: unexpected extra arguments' unless ARGV.empty?

      e = CloudProbe.env!
      session = CloudProbe.login(host: e[:host], email: e[:email], password: e[:password])
      puts "watching every #{interval}s — Ctrl-C to stop. Saves to #{out}"
      loop do
        envelope = CloudProbe.get_realtime(host: e[:host], user_id: session[:user_id], token: session[:token], rtu_id: e[:rtu_id])
        path = CloudProbe.save_snapshot(envelope, dir: out, rtu_id: e[:rtu_id])
        puts "[#{Time.now.strftime('%H:%M:%S')}] #{CloudProbe.summarize(envelope)}  → #{File.basename(path)}"
        sleep interval
      end
    when 'diff'
      path_a = ARGV.shift or usage
      path_b = ARGV.shift or usage
      # Mirror the strict-parsing convention from tools/reprovision.rb —
      # `diff a b c` would silently drop `c` otherwise.
      unless ARGV.empty?
        warn "diff: unexpected extra arguments after the two snapshot paths: #{ARGV.inspect}"
        warn 'diff takes exactly two paths. Pass the EXACT files printed by `status` / `watch`.'
        exit 2
      end
      a = CloudProbe.extract_data(CloudProbe.load_snapshot(path_a))
      b = CloudProbe.extract_data(CloudProbe.load_snapshot(path_b))
      puts "Comparing #{File.basename(path_a)} vs #{File.basename(path_b)}:"
      puts
      puts CloudProbe.render_diff(CloudProbe.diff_data(a, b),
                                  label_a: File.basename(path_a),
                                  label_b: File.basename(path_b))
    else
      warn "unknown subcommand: #{cmd}"
      usage
    end
  rescue CloudProbe::CredentialsMissing => err
    warn "missing credentials: #{err.message}"
    warn 'Tip: copy .env.template to .env and fill in POOLPUMP_CLOUD_* values.'
    exit 2
  rescue CloudProbe::CloudError => err
    warn "cloud error: #{err.message}"
    exit 3
  rescue Interrupt
    warn "\nstopped"
    exit 0
  end
end # if __FILE__ == $PROGRAM_NAME
