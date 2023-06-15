# lib/poolpump/http_api.rb

require 'json'
require 'rack'
require_relative 'pump_session'
require_relative 'command_translator'
require_relative 'register_map'

module Poolpump
  # Rack app preserving the existing port-8090 contract from
  # `_data/legacy/poolpump-server-handle-request.sh`:
  #
  #   GET  /          → 200 + 14-field semantic snapshot JSON
  #   POST /          → 200 + {resultCode:1, ...} on success; 4xx/5xx + legacy
  #                     `{resultCode:0, result:"error", message:"..."}` shape on failure
  #
  # Plus debug endpoints:
  #
  #   GET  /healthz   → connection / queue stats
  #   GET  /raw       → last raw register snapshot
  #
  # The HTTP layer never touches the Modbus socket — it only enqueues a
  # parsed Command and awaits the returned Async::Promise.
  class HttpApi
    DEFAULT_DEADLINE = 3.0

    LEGACY_INVALID_VERB_MSG = 'Invalid command sent in POST body'.freeze
    LEGACY_GENERIC_ERR_MSG = 'Failed to parse output or the terminal is not online'.freeze

    def initialize(session:, deadline: DEFAULT_DEADLINE, reboot_controller: nil, logger: nil)
      @session = session
      @deadline = deadline
      @reboot_controller = reboot_controller
      @logger = logger
    end

    def call(env)
      req = Rack::Request.new(env)
      # Each handler returns [status, headers, body, log_summary]. The 4th
      # element (or nil) is operator-readable context for the HTTP access
      # log — "no telemetry yet", "device echoed in 230ms", "timeout 3s",
      # etc. Far more useful than a bare "GET / → 500".
      result = case [req.request_method, req.path_info]
      in ['GET', '/'] then status_json
      in ['POST', '/'] then handle_command(req)
      in ['GET', '/healthz'] then health_json
      in ['GET', '/raw'] then raw_dump
      in ['POST', '/reboot'] then handle_reboot
      else with_summary(json(404, error_body('Not Found')), 'unknown route')
      end
      log_request(req, result)
      result[0, 3] # Rack only sees [status, headers, body]; strip the summary.
    end

    private

    # Tag a Rack-shape response with an operator-readable summary string for
    # the HTTP log. Keeps handlers concise while preserving Rack contract.
    def with_summary(rack_triple, summary)
      [*rack_triple, summary]
    end

    def status_json
      snapshot = @session.snapshot
      if snapshot.empty?
        with_summary(json(500, error_body(LEGACY_GENERIC_ERR_MSG)),
                     'no telemetry yet — device not pushing data')
      else
        with_summary(json(200, RegisterMap.semantic_snapshot(snapshot)), nil)
      end
    end

    def handle_command(req)
      body = req.body&.read.to_s
      cmd = CommandTranslator.parse(body)
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      future = @session.enqueue(cmd, deadline: @deadline)
      result = future.wait
      elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round

      if result[:ok]
        with_summary(json(200, success_body(cmd.verb)),
                     "#{cmd.verb} confirmed in #{elapsed_ms}ms")
      else
        # Distinguish timeout (deadline expired) from other failures —
        # operationally very different. "Timeout" means the write probably
        # went out and the device may yet apply it; "rejected" means the
        # device actively refused or the dispatch errored.
        summary = if result[:reason].to_s.match?(/timeout/i)
                    "#{cmd.verb} TIMEOUT after #{elapsed_ms}ms (deadline #{@deadline}s) — device may still apply the write later"
        else
                    "#{cmd.verb} failed: #{result[:reason]}"
        end
        with_summary(json(500, error_body(LEGACY_GENERIC_ERR_MSG, reason: result[:reason], verb: cmd.verb)),
                     summary)
      end
    rescue CommandTranslator::ParseError => e
      with_summary(json(400, error_body(LEGACY_INVALID_VERB_MSG, reason: "parse-error: #{e.message}")),
                   "parse error: #{e.message}")
    rescue PumpSession::SessionStale, PumpSession::QueueFull => e
      reason = e.class.name.split('::').last.downcase
      with_summary(json(503, error_body(LEGACY_GENERIC_ERR_MSG, reason: reason, detail: e.message)),
                   "rejected: #{reason} — #{e.message}")
    end

    def health_json
      stats = @session.healthz
      stats[:reboot] = @reboot_controller.stats if @reboot_controller
      with_summary(json(200, stats), nil)
    end

    # POST /reboot — trigger an AT+Z double-send to the configured device IP.
    # Same recipe used by `tools/reprovision.rb reboot`. Subject to the
    # RebootController's cooldown + daily-cap safety mechanisms.
    def handle_reboot
      unless @reboot_controller
        return with_summary(json(503, error_body('reboot not configured', reason: 'no-reboot-controller')),
                            'reboot not configured (POOLPUMP_DEVICE_IP unset)')
      end

      result = @reboot_controller.reboot!(reason: 'http-api')
      if result[:ok]
        with_summary(json(200, success_body('reboot').merge(reboot: @reboot_controller.stats)),
                     "AT+Z dispatched (attempts today: #{@reboot_controller.stats[:attempts_today]})")
      else
        # 429 Too Many Requests fits both 'cooldown' and 'daily-cap' semantics.
        status = %w[cooldown daily-cap].include?(result[:reason]) ? 429 : 502
        with_summary(json(status, error_body('reboot rejected', reason: result[:reason], reboot: @reboot_controller.stats)),
                     "rejected: #{result[:reason]}")
      end
    end

    def raw_dump
      snapshot = @session.snapshot
      humanized = RegisterMap.humanize(snapshot)
      humanized = '(no decoded fields yet — telemetry not received)' if humanized.empty?
      lines = snapshot.map { |k, v| format('  %-12s %s', k, v.inspect) }
      body = +"# Humanized\n#{humanized}\n\n# Raw decoded snapshot (#{snapshot.size} keys)\n"
      body << lines.join("\n") << "\n"
      with_summary([200, { 'content-type' => 'text/plain' }, [body]], "#{snapshot.size} keys")
    end

    # One-line access log so an operator can see in `docker logs` when
    # status / commands / reboots come in. Skipped for /healthz to avoid
    # drowning the logs when an external monitor polls it every few seconds.
    #
    # Format:
    #   [http]   ← STATUS query → 200 (snapshot fresh)
    #   [http]   ← STATUS query → 500 (no telemetry yet — device not pushing data)
    #   [http]   ← CMD mode-silent → 200 (mode-silent confirmed in 230ms)
    #   [http]   ← CMD mode-silent → 500 (mode-silent TIMEOUT after 3001ms — device may still apply later)
    #   [http]   ← REBOOT trigger → 200 (AT+Z dispatched, attempts today: 2)
    def log_request(req, result)
      return unless @logger
      return if req.path_info == '/healthz'

      status, _headers, _body, summary = result
      intent = describe_intent(req)
      summary_part = summary.nil? || summary.empty? ? '' : " (#{summary})"
      @logger.call(format('[http]   ← %s → %d%s', intent, status, summary_part))
    end

    # Derive a human-readable intent label from the Rack request. We can't
    # always extract the verb (POST body has been read by handle_command),
    # so the label here is the route's intent, not the per-call detail —
    # the per-call detail goes in the summary instead.
    def describe_intent(req)
      case [req.request_method, req.path_info]
      when ['GET', '/']        then 'STATUS query'
      when ['POST', '/']       then 'CMD'
      when ['GET', '/raw']     then '/raw dump'
      when ['POST', '/reboot'] then 'REBOOT trigger'
      else "#{req.request_method} #{req.path_info}"
      end
    end

    # ─── response shapes ───────────────────────────────────────────────────

    # POST success — preserves the legacy `{resultCode:1}` envelope (so any
    # caller checking `.resultCode` keeps working) AND attaches the post-exec
    # snapshot so callers can verify the change took effect without a second
    # HTTP round-trip.
    def success_body(verb)
      {
        resultCode: 1,
        result: 'ok',
        verb: verb,
        snapshot: RegisterMap.semantic_snapshot(@session.snapshot),
      }
    end

    # All error paths mirror the legacy shape exactly:
    #   { "resultCode": 0, "result": "error", "message": "..." }
    # plus optional `reason`/`verb`/`detail` for new clients that want context.
    def error_body(message, **extra)
      base = { resultCode: 0, result: 'error', message: message }
      base.merge(extra.compact)
    end

    def json(status, body)
      [status, { 'content-type' => 'application/json' }, [JSON.generate(body) + "\n"]]
    end
  end
end
