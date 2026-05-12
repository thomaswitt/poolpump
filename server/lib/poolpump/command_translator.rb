# lib/poolpump/command_translator.rb

require_relative 'register_map'

module Poolpump
  # Translates the existing HTTP-API body verbs (the grammar the bash
  # `poolpump-server-handle-request.sh` accepts) into a sequence of
  # `[register_name, semantic_value]` writes for the PumpSession actor.
  #
  # The verb shape is preserved verbatim so the existing port-8090 contract
  # is byte-for-byte compatible.
  module CommandTranslator
    Command = Struct.new(:verb, :writes, keyword_init: true) do
      def to_s
        "#{verb} → #{writes.map { |n, v| "#{n}=#{v}" }.join(', ')}"
      end
    end

    class ParseError < StandardError; end

    SETTEMP_RE = /\Asettemp\s+(\d+)\z/
    # Pure setpoint write — no on/off, no mode side-effects. Used by the
    # Homey reconciler to sync the user's target_temperature into the pump's
    # stored setpoint *without* implicitly turning the pump on. The legacy
    # `settemp` (above) deliberately bundles switch=1+model=heat for the
    # "start heating to N" UX from the iOS app, but a state-machine
    # reconciler needs a side-effect-free version.
    SET_TARGET_RE = /\Aset-target\s+(\d+)\z/
    SETMODE_RE = /\Asetmode\s+(auto|cool|heat)\z/
    # Semantic values match the panel labels CONFIRMED 2026-05-12 — see
    # RegisterMap::Codecs::ModeEnum for the raw-byte mapping.
    MODE_VALUES = { 'heat' => 1, 'auto' => 2, 'cool' => 4 }.freeze
    # The Acquasource i-Series manual section 6 defines:
    #   * Setting range — heating: 15-40°C, cooling: 8-25°C
    #   * Operating ambient: -15°C to 43°C
    # We use the heating range as the API floor (15) and cap at 32°C as a
    # safety ceiling — pool comfort tops out around 30°C and the COP/energy
    # cost of pushing past that is not worth it for typical pool use.
    # The cloud's wider 8..40 was an artifact of cool-mode (which we never
    # use); the legacy iOS app slider was also mode-aware and adjusted bounds.
    TEMP_BOUNDS = (15..32).freeze

    # Function-register raw values — CONFIRMED by capturing each
    # OEM-app function tap against the cloud:
    #   smart  = 0x0000 (default; "robot" icon — let the unit pick)
    #   silent = 0x0010 (bit 4 — 20-50% capacity, night mode)
    #   boost  = 0x0400 (bit 10 — 20-100% capacity, fast heating)
    # These supersede the earlier Fairland/cloud-API guesses.
    FUNCTION_VALUES = {
      smart:  RegisterMap::Codecs::FUNCTION_RAW_SMART,
      silent: RegisterMap::Codecs::FUNCTION_RAW_SILENT,
      boost:  RegisterMap::Codecs::FUNCTION_RAW_BOOST,
    }.freeze

    module_function

    # Parse a single body string and return a Command, or raise ParseError.
    def parse(body)
      raise ParseError, 'empty body' if body.nil? || body.strip.empty?

      verb = body.strip
      case verb
      when 'on' then Command.new(verb: verb, writes: [[:switch, 1]])
      when 'off' then Command.new(verb: verb, writes: [[:switch, 0]])
      when 'mode-boost' then Command.new(verb: verb, writes: [[:function, FUNCTION_VALUES.fetch(:boost)]])
      when 'mode-silent' then Command.new(verb: verb, writes: [[:function, FUNCTION_VALUES.fetch(:silent)]])
      when 'mode-auto' then Command.new(verb: verb, writes: [[:function, FUNCTION_VALUES.fetch(:smart)]])
      when SETMODE_RE
        Command.new(verb: verb, writes: [[:model, MODE_VALUES.fetch(::Regexp.last_match(1))]])
      when SETTEMP_RE
        n = Integer(::Regexp.last_match(1))
        raise ParseError, "settemp value #{n} out of range #{TEMP_BOUNDS}" unless TEMP_BOUNDS.cover?(n)

        # The device has ONE setpoint register (CONFIRMED) — the legacy
        # 5-write sequence (switch+autotemp+cooltemp+heattemp+model=heat) is
        # collapsed to: turn on, set the single setpoint, switch to heat.
        # M1 — function is intentionally NOT reset to 0 here, preserving any
        # active boost/silence the user explicitly enabled.
        Command.new(verb: verb, writes: [
                      [:switch, 1],
                      [:settemp, n],
                      [:model, MODE_VALUES.fetch('heat')],
                    ])
      when SET_TARGET_RE
        n = Integer(::Regexp.last_match(1))
        raise ParseError, "set-target value #{n} out of range #{TEMP_BOUNDS}" unless TEMP_BOUNDS.cover?(n)

        # Pure setpoint write — no implicit switch=1, no model change.
        # Used by the Homey reconciler to keep the pump's stored setpoint
        # in sync with the user's `target_temperature` intent without
        # accidentally turning the pump on or flipping it to heat mode.
        Command.new(verb: verb, writes: [[:settemp, n]])
      else
        raise ParseError, "unknown verb: #{verb.inspect}"
      end
    end

    # Translate a Command's [name, value] writes into [write_address, raw_value]
    # tuples ready to feed into MBAP.fc06_request / MBAP.fc16_request.
    def to_register_writes(command, logger: nil)
      command.writes.map do |name, value|
        addr, raw = RegisterMap.encode_write(name, value, logger: logger)
        [addr, raw, name, value]
      end
    end
  end
end
