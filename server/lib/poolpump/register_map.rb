# lib/poolpump/register_map.rb

module Poolpump
  # Bidirectional mapping between the pump's Modbus register space and the
  # semantic field names the existing HTTP API speaks.
  #
  #   raw 16-bit register value  ←→  semantic Ruby value (Float / Integer / Symbol)
  #
  # Two layers:
  #
  #   * Codecs    — pure functions: encode/decode a single register.
  #   * Registers — declarative table: address + name + codec + write addr + confidence.
  #
  # Address space confirmed by dual capture:
  #   * `tools/sniff.rb` against real Poolpump (telemetry pushes)
  #   * `tools/cloud_replay.rb` against fzdbiology.com:502 (control writes)
  #
  # See `_data/PROTOCOL-FINDINGS-2026-04-30.md` for the full decode log.
  module RegisterMap
    # ──────────────────────────────────────────────────────────────────────
    # Codecs
    # ──────────────────────────────────────────────────────────────────────
    module Codecs
      module Identity
        def self.decode(raw); raw end
        def self.encode(val); val.to_i & 0xFFFF end
      end

      module Bool
        def self.decode(raw); raw.to_i != 0 ? 1 : 0 end
        def self.encode(val); val.to_i != 0 ? 1 : 0 end
      end

      # Half-degree offset encoding from the Fairland reference. Kept available
      # in case some HYPOTHESIZED read-only register turns out to use it; the
      # confirmed setpoint at reg 2006 uses Identity (plain integer °C).
      module TempOffset18Half
        def self.decode(raw); (raw.to_f - 96) / 2.0 + 18.0 end
        def self.encode(val); ((val.to_f - 18.0) * 2.0).round + 96 end
      end

      # Two's-complement signed 16-bit (for things like "ambient °C below freezing").
      module Int16
        def self.decode(raw)
          v = raw.to_i & 0xFFFF
          v >= 0x8000 ? v - 0x10000 : v
        end

        def self.encode(val)
          (val.to_i & 0xFFFF)
        end
      end

      # 0.1°C fixed-point (raw / 10), signed for sub-zero. Used by block 1000
      # (water_io) which stores inlet/outlet at half-degree precision —
      # confirmed against panel readings: raw 225 = 22.5°C inlet,
      # raw 234 = 23.4°C outlet. Different block, different convention than
      # the integer PQ table at block 300 (which also has outlet but only at
      # whole-degree precision).
      module TenthDeg
        def self.decode(raw)
          v = raw.to_i & 0xFFFF
          v -= 0x10000 if v >= 0x8000
          v / 10.0
        end

        def self.encode(val)
          (val.to_f * 10).round & 0xFFFF
        end
      end

      # Decimal-by-10 (raw × 10). Used by PQ17 (mains voltage), where the
      # manual states "Displayed value ×10" — i.e. the register holds the
      # voltage divided by 10. Raw 23 → 230 V. Signed for completeness even
      # though voltage shouldn't go negative.
      module TenFold
        def self.decode(raw)
          v = raw.to_i & 0xFFFF
          v -= 0x10000 if v >= 0x8000
          v * 10
        end

        def self.encode(val)
          (val.to_i / 10) & 0xFFFF
        end
      end

      # Decimal-by-5 (raw × 5). Used by PQ22 (DC link voltage). Raw 70 → 350V.
      module FiveFold
        def self.decode(raw)
          v = raw.to_i & 0xFFFF
          v -= 0x10000 if v >= 0x8000
          v * 5
        end

        def self.encode(val)
          (val.to_i / 5) & 0xFFFF
        end
      end

      # Mode register (model field): semantic 1=heat, 2=auto, 4=cool —
      # CONFIRMED 2026-05-12 by walking the panel through each mode and
      # reading the post-codec value via /raw. (The earlier "API 1=cool…"
      # comment was a reverse-engineering error inherited from the cloud
      # mapping; both reads and writes used the wrong labels symmetrically,
      # so `setmode heat` was actually setting AUTO etc.)
      # Modbus side is still bit-encoded:
      #   raw 0x01 → semantic 4 (cool)
      #   raw 0x02 → semantic 1 (heat)
      #   raw 0x04 → semantic 2 (auto)
      class Enum
        def initialize(table) # { raw_value => semantic_value, ... }
          @raw_to_sem = table
          @sem_to_raw = table.invert
        end

        def decode(raw); @raw_to_sem.fetch(raw, raw) end
        def encode(val); @sem_to_raw.fetch(val) { raise ArgumentError, "unknown enum value #{val.inspect}; known: #{@sem_to_raw.keys}" } end
      end

      # See ModeEnum comment above for the panel-confirmed mapping.
      # The codec direction (raw → semantic) is unchanged from the original
      # reverse-engineering; only the human labels at both ends moved.
      ModeEnum = Enum.new(0x01 => 4, 0x02 => 1, 0x04 => 2)

      # `function` register stores the bitmask value directly. CONFIRMED
      # against the OEM cloud:
      #   raw 0x0000 = Smart (default; "robot" icon — let unit decide)
      #   raw 0x0010 = Silent (bit 4 — 20-50% capacity, night mode)
      #   raw 0x0400 = Boost  (bit 10 — 20-100% capacity, fast heating)
      # Stored as raw integer; the semantic_snapshot derives the API's
      # legacy BOOST / SILENCE boolean fields from these raw values.
      FUNCTION_RAW_SMART  = 0x0000
      FUNCTION_RAW_SILENT = 0x0010
      FUNCTION_RAW_BOOST  = 0x0400
    end

    # ──────────────────────────────────────────────────────────────────────
    # Register definitions
    #
    # `name`             — semantic key matching existing API (`switch`, `pa10`, …)
    # `read_address`     — where the value appears in the FC=0x10 telemetry push
    # `write_address`    — where master writes go (FC=0x06/0x10); nil if read-only
    # `codec`            — Codecs::* module/instance
    # `confidence`       — :CONFIRMED (verified live) | :HYPOTHESIZED (needs more capture)
    # ──────────────────────────────────────────────────────────────────────

    Definition = Struct.new(:name, :read_address, :write_address, :codec, :confidence,
                            keyword_init: true)

    # The control register block — Poolpump pushes regs 2000-2006 every cycle as
    # the smallest of seven telemetry blocks (~17s full cycle). The cloud writes
    # back to the same addresses with FC=0x06 (uid=0x81) on user actions.
    TELEMETRY_BLOCK_START = 0x07d0   # 2000 — start of control block (CONFIRMED)
    TELEMETRY_BLOCK_QTY   = 0x0007   # 7 registers (CONFIRMED)

    # Other captured telemetry blocks:
    #   addr 100  (61 regs) — config/limits (HYPOTHESIZED purpose)
    #   addr 200  (61 regs) — sensor readings, mostly signed temperatures
    #   addr 300  (27 regs) — PQ Parameter Table (CONFIRMED via byte decode
    #                         of `0x012c qty=27` capture against manual table:
    #                         reg(299+N) = PQ item N for N=1..26.
    #                         reg 316 decoded to raw 23 → 230V mains, and
    #                         reg 321 to raw 64 → 320V DC link — physically
    #                         correct for European single-phase install.)
    #   addr 500  (61 regs) — alarm/protection bitmap (HYPOTHESIZED — fault
    #                         bit isolation needs no-fault baseline diff).
    #   addr 600  (27 regs) — sub-mode states (HYPOTHESIZED).
    #   addr 1000 (8  regs) — counters (rare cadence; HYPOTHESIZED).
    #   addr 2000 (7  regs) — control state (CONFIRMED — see above).
    #   addr 2100 (61 regs) — setpoints + history (HYPOTHESIZED).

    DEFINITIONS = [
      # ── Control block (2000-2006) — CONFIRMED ─────────────────────────
      Definition.new(name: :model,    read_address: 0x07d0, write_address: 0x07d0, codec: Codecs::ModeEnum, confidence: :CONFIRMED),
      Definition.new(name: :switch,   read_address: 0x07d1, write_address: 0x07d1, codec: Codecs::Bool,     confidence: :CONFIRMED),
      Definition.new(name: :function, read_address: 0x07d2, write_address: 0x07d2, codec: Codecs::Identity, confidence: :CONFIRMED), # raw bitmask: 0x0000=smart, 0x0010=silent, 0x0400=boost
      # regs 2003-2005 captured as 9, 28, 45 in baseline — purpose unknown, exposed as raw.
      Definition.new(name: :settemp,  read_address: 0x07d6, write_address: 0x07d6, codec: Codecs::Identity, confidence: :CONFIRMED),

      # ── Read-only sensors — PQ Parameter Table (block 300) ─────────────
      # CONFIRMED via direct byte-decode against the manual's PQ
      # table. Three of these (ambient, outlet water, water pump status) had
      # cleanest validation — values matched expected physical state for a
      # pump in P01 fault. Two (compressor "rate" and operation state) are
      # marked HYPOTHESIZED because the legacy API field name doesn't quite
      # match the underlying PQ semantic (compressor freq Hz vs the legacy
      # "rate" %; 4-way valve vs the legacy "operation state").
      Definition.new(name: :ap2,  read_address: 302, write_address: nil, codec: Codecs::Int16,    confidence: :CONFIRMED),    # PQ03 — ambient air temp °C
      Definition.new(name: :ap3,  read_address: 303, write_address: nil, codec: Codecs::Int16,    confidence: :CONFIRMED),    # PQ04 — outlet water temp °C
      Definition.new(name: :ap8,  read_address: 308, write_address: nil, codec: Codecs::Bool,     confidence: :CONFIRMED),    # PQ09 — water pump status 0/1
      Definition.new(name: :pa15, read_address: 300, write_address: nil, codec: Codecs::Identity, confidence: :HYPOTHESIZED), # PQ01 — compressor freq Hz (legacy field is "rate" %; semantic mismatch)
      Definition.new(name: :pb11, read_address: 309, write_address: nil, codec: Codecs::Identity, confidence: :HYPOTHESIZED), # PQ10 — 4-way valve status (legacy field is "operation state"; closest proxy)

      # ── Electrical readings ────────────────────────────────────────────
      # Per manual section 10:
      #   PQ16 = compressor current (displayed value /10) → A   (motor-side, NOT mains!)
      #   PQ17 = mains voltage      (displayed value ×10) → V
      #   PQ22 = DC link voltage    (displayed value ×5)  → V
      #   PQ23 = DC link current    (integer)              → A
      # Validated against Phase 1 grid meter:
      #   raw_013c = 22 → 220V mains (matches European single-phase supply)
      #   With compressor at 48Hz: pa16 = 0.5A but Phase 1 delta = 2206W.
      #   So PQ16 is POST-inverter motor winding current, not mains current —
      #   manual's "compressor current" label is technically correct but
      #   misleading. The DC link product (V_dc × I_dc) ÷ 0.85 estimates
      #   true mains draw within ±15% (validated at 48Hz: 350×5÷0.85=2059W
      #   vs measured 2206W).
      Definition.new(name: :pa16, read_address: 315, write_address: nil, codec: Codecs::TenthDeg, confidence: :CONFIRMED), # PQ16 — motor winding current ÷10 → A (NOT mains!)
      Definition.new(name: :pa17, read_address: 316, write_address: nil, codec: Codecs::TenFold,  confidence: :CONFIRMED), # PQ17 — mains voltage ×10 → V
      Definition.new(name: :pa22, read_address: 321, write_address: nil, codec: Codecs::FiveFold, confidence: :CONFIRMED), # PQ22 — DC link voltage ×5 → V
      Definition.new(name: :pa23, read_address: 322, write_address: nil, codec: Codecs::Identity, confidence: :CONFIRMED), # PQ23 — DC link current → A

      # ── Inlet water temp — addr 1001 (block 1000, "water_io") — CONFIRMED ──
      # The pump pushes a small 8-reg block at addr 1000 (we previously
      # mislabeled as "counters") that holds inlet+outlet water temps in
      # 0.1°C fixed-point (TenthDeg codec). Validated by walking the panel:
      #   panel "inlet 22.5°C"  ↔ raw 225 at reg 1001 ✓
      #   panel "outlet 23.4°C" ↔ raw 234 at reg 1003 ✓
      # The PQ table (block 300) ALSO has outlet (PQ04, integer precision)
      # — we keep ap3 mapped there for backward compat; consumers wanting
      # 0.1°C outlet read raw_03eb directly until/unless we add a separate
      # field for it.
      Definition.new(name: :pa10, read_address: 1001, write_address: nil, codec: Codecs::TenthDeg, confidence: :CONFIRMED),

      # ── Fault aggregator (block 500, 61 booleans) ──────────────────────
      # HYPOTHESIZED address: reg 500 itself — the captured baseline shows
      # value 1 at this offset which is consistent with "any fault active"
      # given Poolpump is in P01 (water flow) right now. Bit-by-bit decoding
      # to map P01-P11 / E01-E51 needs a no-fault baseline (pool refilled)
      # to diff against the current P01 capture.
      Definition.new(name: :pa13, read_address: 500, write_address: nil, codec: Codecs::Identity, confidence: :HYPOTHESIZED),
    ].freeze

    BY_NAME = DEFINITIONS.each_with_object({}) { |d, h| h[d.name] = d }.freeze
    BY_READ_ADDR = DEFINITIONS.each_with_object({}) { |d, h| h[d.read_address] = d }.freeze
    BY_WRITE_ADDR = DEFINITIONS.reject { |d| d.write_address.nil? }
                               .each_with_object({}) { |d, h| h[d.write_address] = d }
                               .freeze

    module_function

    # Decode a FC=0x10 telemetry push (start_addr + array of register values)
    # into a hash of semantic { name => value } pairs. Values for unknown
    # addresses are exposed under :"raw_<hex>" keys so we don't lose data
    # while we're still fitting the map.
    def decode_block(start_addr, values)
      out = {}
      values.each_with_index do |raw, i|
        addr = start_addr + i
        if (defn = BY_READ_ADDR[addr])
          out[defn.name] = defn.codec.decode(raw)
        else
          out[:"raw_#{format('%04x', addr)}"] = raw
        end
      end
      out
    end

    # Map decoded semantic state into the 14-field shape the existing
    # `poolpump-server-handle-request.sh` returned. Unknown / missing values
    # surface as nil — better than a fake number.
    #
    # The legacy API exposed three TEMP_TARGET_* fields (heat/auto/cool) but
    # the device only has one setpoint register. We surface the same value
    # in all three slots to preserve the API contract.
    #
    # BOOST and SILENCE are derived from the raw function register:
    #   function 0x0400 → BOOST=1, function 0x0010 → SILENCE=1, else 0.
    def semantic_snapshot(decoded)
      fn = decoded[:function]
      st = decoded[:settemp]
      v_ac    = decoded[:pa17]          # mains voltage (V)
      i_motor = decoded[:pa16]          # post-inverter motor winding current (A) — NOT mains
      v_dc    = decoded[:pa22]          # DC link voltage (V)
      i_dc    = decoded[:pa23]          # DC link "current" — actual unit unclear
      hz      = decoded[:pa15]          # compressor frequency (Hz)
      switch_on = decoded[:switch]
      # We don't expose a Watt estimate — investigation showed
      # the pump simply doesn't expose mains current accurately:
      #   * PQ16 is post-inverter motor winding current, useless for mains
      #   * PQ23 (DC link "current") doesn't scale linearly with grid draw
      #   * Compressor freq alone has too much load-state variation to
      #     convert to absolute Watts (heat pump throttles via EEV/fan/etc)
      # Instead we surface COMPRESSOR_LOAD_PCT — Hz / 90 × 100 — a clean
      # "how hard is the compressor working right now" indicator. The
      # operator can multiply by MAX_INPUT_W (4490W from i25 manual) for
      # a rough upper-bound estimate. For billing-grade Watts, install a
      # Shelly EM or similar inline meter at the pump's mains feed.
      load_pct = if switch_on != 1
                   0
      elsif hz && hz.positive?
                   ([hz.to_f / COMPRESSOR_HZ_MAX, 1.0].min * 100).round
      else
                   0 # pump on, compressor idle
      end
      {
        'SWITCHED_ON' => decoded[:switch],
        'COMPRESSOR_RATE' => decoded[:pa15],
        'TEMP_AMBIENT' => decoded[:ap2],
        'TEMP_OUTLET' => decoded[:ap3],
        'TEMP_INLET' => decoded[:pa10],
        'TEMP_TARGET' => st,
        'TEMP_TARGET_AUTO' => st,
        'TEMP_TARGET_COOL' => st,
        'BOOST' => fn.nil? ? nil : (fn == Codecs::FUNCTION_RAW_BOOST ? 1 : 0),
        'SILENCE' => fn.nil? ? nil : (fn == Codecs::FUNCTION_RAW_SILENT ? 1 : 0),
        'STATUS_WATERPUMP' => decoded[:ap8],
        'STATUS_MODE' => decoded[:model],
        'STATUS_MALFUNC' => fault_label(decoded[:pa13]),
        'STATUS_OPERATION' => decoded[:pb11],
        # Electrical readings — raw values from pump's PQ16/17/22/23.
        # MOTOR_CURRENT_A is post-inverter motor winding current, NOT mains.
        # No watt estimate exposed — see semantic_snapshot comment for why.
        # Operators wanting Watts: install a Shelly EM at the mains feed.
        'AC_VOLTAGE' => v_ac,
        'MOTOR_CURRENT_A' => i_motor,
        'DC_LINK_VOLTAGE_V' => v_dc,
        'DC_LINK_CURRENT_A' => i_dc,
        'COMPRESSOR_LOAD_PCT' => load_pct,
        'MAX_INPUT_W' => POWER_MAX_INPUT_W,
      }
    end

    # Encode a (name, semantic value) pair as a (write_address, raw_value)
    # suitable for FC=0x06 / FC=0x10. Raises if `name` is not writable.
    #
    # Writes to :HYPOTHESIZED registers log a warning but proceed by default.
    # Set ENV['POOLPUMP_STRICT']='1' to refuse them.
    def encode_write(name, value, logger: nil)
      defn = BY_NAME.fetch(name) { raise ArgumentError, "no register named #{name.inspect}" }
      raise ArgumentError, "register #{name} is read-only" if defn.write_address.nil?

      if defn.confidence == :HYPOTHESIZED
        if ENV['POOLPUMP_STRICT'] == '1'
          raise ArgumentError, "register #{name} is :HYPOTHESIZED — refusing under POOLPUMP_STRICT=1"
        end

        logger&.call("WARN write to :HYPOTHESIZED register #{name} (addr=0x#{defn.write_address.to_s(16)}); confirm via tools/sniff.rb")
      end

      [defn.write_address, defn.codec.encode(value)]
    end

    # ──────────────────────────────────────────────────────────────────────
    # Humanizers — operator-readable rendering of decoded snapshot values.
    # Used by PumpSession's PUSH and HEARTBEAT log lines, and by HttpApi
    # /raw. Single source of truth so logs and HTTP agree on units/labels.
    # Anomalous values are flagged with `*?*` so an operator scanning a log
    # can spot them without parsing every line.
    # ──────────────────────────────────────────────────────────────────────

    # Stable order — most operationally meaningful first (mode/setpoint),
    # then sensors, then status flags. Determines column order in
    # `humanize` output.
    #
    # `pb11` (4-way valve) is intentionally OMITTED — its raw 0/1 doesn't
    # map to anything operator-meaningful yet (we don't know which value
    # means cool-position vs heat-position). Showing `valve=1` is worse
    # than showing nothing because it implies meaningful info. Add back
    # once we decode the bit.
    HUMANIZE_ORDER = %i[switch model function settemp ap2 ap3 pa10 ap8 pa15 pa16 pa17 pa22 pa23 pa13].freeze

    # i25 specs from manual section 3 (page 11):
    #   Max input:    4.49 kW          (hard system ceiling)
    #   Max current:  19.52 A          (mains)
    #   Comp input @ 60 rps: 2.765 kW  (rated operating point)
    # Compressor frequency we observe in PQ01 ranges 0-89Hz in normal use.
    # Empirically the pump reaches 89Hz at Boost — using 90 as the max for
    # load-% calculation gives 99% at boost, ~56% at silent silent cruise.
    POWER_MAX_INPUT_W     = 4490
    COMPRESSOR_HZ_MAX     = 90
    POWER_STANDBY_W       = 95

    # Render one (name, value) pair as a "label=value[unit][*?*]" string,
    # or nil if the value is missing. Returns nil for unknown names so
    # callers can chain through .compact.
    def humanize_pair(name, value)
      return nil if value.nil?

      case name
      when :switch then "switch=#{value.to_i == 1 ? 'on' : 'off'}"
      when :model
        label = { 1 => 'heat', 2 => 'auto', 4 => 'cool' }[value] || "?#{value}*?*"
        "mode=#{label}"
      when :function
        label = case value
        when Codecs::FUNCTION_RAW_SMART  then 'smart'
        when Codecs::FUNCTION_RAW_SILENT then 'silent'
        when Codecs::FUNCTION_RAW_BOOST  then 'boost'
        else "raw=0x#{value.to_s(16)}*?*"
        end
        "fn=#{label}"
      when :settemp  then "set=#{value}°C#{value < 15 || value > 32 ? '*?*' : ''}"
      when :ap2      then "ambient=#{value}°C#{value < -20 || value > 50 ? '*?*' : ''}"
      when :ap3      then "outlet=#{value}°C#{value < -10 || value > 60 ? '*?*' : ''}"
      when :pa10     then "inlet=#{value}°C#{value < -10 || value > 60 ? '*?*' : ''}"
      when :ap8      then "pump=#{value.to_i == 1 ? 'on' : 'off'}"
      when :pa15     then "compressor=#{value}Hz"
      when :pa16     then "Imotor=#{value}A"   # post-inverter motor winding, NOT mains
      when :pa17     then "Vac=#{value}V#{value < 200 || value > 250 ? '*?*' : ''}"
      when :pa22     then "Vdc=#{value}V"
      when :pa23     then "Idc=#{value}A"
      when :pb11     then "valve=#{value}"
      when :pa13
        if value.to_i.zero?
          'fault=ok'
        else
          name = FAULT_RAW_TO_NAME[value.to_i]
          name ? "fault=#{name}*?*" : "fault=raw#{value}*?*"
        end
      end
    end

    # Render a decoded hash as a single space-joined "label=value" string.
    # Appends `power≈NW` from the DC-link product (calibrated against grid
    # meter at one operating point ±15%) when V_dc + I_dc are both present.
    def humanize(decoded)
      parts = HUMANIZE_ORDER.map { |k| humanize_pair(k, decoded[k]) }.compact
      v_dc = decoded[:pa22]
      i_dc = decoded[:pa23]
      # Compressor load % of rated max (Hz / 90 × 100). Honest indicator
      # of how hard the compressor is working — beats a fake Watt number.
      hz = decoded[:pa15]
      sw = decoded[:switch]
      if sw == 1 && hz && hz.positive?
        pct = ([hz.to_f / COMPRESSOR_HZ_MAX, 1.0].min * 100).round
        parts << "load=#{pct}%"
      end
      parts.join(' ')
    end

    # FULL fault-code dictionary from i25 manual section 13 (page 35-39).
    # Every code the manual documents is here verbatim — keyed by the
    # canonical code name (P01, E08, etc), value = human-readable description
    # combining the manual's "Error or protection", "Analysis" and "Solution"
    # columns into a single actionable line.
    FAULT_CODES_BY_NAME = {
      # ── Protections (P-codes) — pump may auto-recover ────────────────
      'P01' => 'Water flow protection — no flow / blocked filter / faulty flow switch. Open valve, replace flow switch, or clean Y-shape filter.',
      'P02' => 'Refrigerant high-pressure protection — too little water flow / faulty HP switch / blocked refrigerant / EEV deadlock. Increase pump flow, replace HP switch, change filter, or replace EEV.',
      'P03' => 'Refrigerant low-pressure protection — lack of refrigerant / blocked filter / outside operating range. Repair leak and recharge, replace filter, or wait for ambient to recover.',
      'P04' => 'Over-heat protection of air-side heat-exchanger pipe — fan area blocked / coil dirty / sensor faulty / refrigerant leak. Clear blowing area, clean coil, replace sensor, or repair leak.',
      'P05' => 'Discharge temperature protection — discharge sensor faulty. Replace the sensor.',
      'P06' => 'Anti-freeze protection of outlet water — water flow not enough / plate heat-exchanger blocked / Y-shape filter blocked / water flow over-load. Remove air, blow heat-exchanger reverse, clean filter, increase bypass, or repair leak.',
      'P07' => 'Low-temperature protection of air-side heat-exchanger pipe — lack of refrigerant / water blocked / refrigerant blocked. Repair leak, clean Y-shape filter, or clean refrigerant filter.',
      # ── Errors (E-codes) — typically need manual intervention ────────
      'E01' => 'Communication failure between controller and unit — communication cable broken. Check if cable is broken; reconnect or replace.',
      'E02' => 'Discharge temperature sensor failure — sensor damaged/faulty. Check sensor resistance; replace.',
      'E03' => 'Temperature sensor failure of air-side heat-exchanger pipe — sensor damaged/faulty. Check sensor resistance; replace.',
      'E04' => 'Air ambient temperature sensor failure — sensor damaged/faulty. Check sensor resistance; replace.',
      'E05' => 'Temperature sensor failure of EXV inlet pipe — sensor damaged/faulty. Check sensor resistance; replace.',
      'E06' => 'Suction temperature sensor failure — sensor damaged/faulty. Check sensor resistance; replace.',
      'E08' => 'Inlet water temperature sensor failure — sensor damaged/faulty. Check sensor resistance; replace.',
      'E09' => 'Outlet water temperature sensor failure — sensor damaged/faulty. Check sensor resistance; replace.',
      'E10' => 'Communication failure between PCB and drive modular board — communication cable broken. Check cable; reconnect or replace.',
      'E15' => 'Over-low DC link voltage — incorrect wire connection or IPM failure. Check wires; reconnect or change IPM.',
      'E16' => 'Over-high DC link voltage — incorrect wire connection or IPM failure. Check wires; reconnect or change IPM.',
      'E17' => 'Current protection of AC power supply — incorrect wire connection or IPM failure. Check wires; reconnect or change IPM.',
      'E18' => 'IPM failure — incorrect wire connection or IPM failure. Check wires; reconnect or change IPM.',
      'E19' => 'PFC modular failure — incorrect wire connection or IPM failure. Check wires; reconnect or change IPM.',
      'E20' => 'Compressor start failure — incorrect wire connection or IPM failure. Check wires; reconnect or change IPM.',
      'E21' => 'Phase lack of compressor power supply — incorrect wire connection or IPM failure. Check wires; reconnect or change IPM.',
      'E22' => 'Drive modular reset — incorrect wire connection or IPM failure. Check wires; reconnect or change IPM.',
      'E23' => 'Over-load current protection of compressor — incorrect wire connection or IPM failure. Check wires; reconnect or change IPM.',
      'E24' => 'Over-high temperature protection of PFC modular — incorrect wire connection or IPM failure. Check wires; reconnect or change IPM.',
      'E25' => 'Electrical circuit failure — incorrect wire connection or IPM failure. Check wires; reconnect or change IPM.',
      'E26' => "Compressor's motor speed out of control — incorrect wire connection or IPM failure. Check wires; reconnect or change IPM.",
      'E27' => 'Temperature sensor failure of PFC module — incorrect wire connection or IPM failure. Check wires; reconnect or change IPM.',
      'E28' => 'Communication failure — incorrect wire connection or IPM failure. Check wires; reconnect or change IPM.',
      'E29' => 'Over-high temperature of IPM — incorrect wire connection or IPM failure. Check wires; reconnect or change IPM.',
      'E30' => 'Temperature sensor failure of IPM — incorrect wire connection or IPM failure. Check wires; reconnect or change IPM.',
      'E37' => 'Limit frequency according to modular current — incorrect wire connection or IPM failure. Check wires; reconnect or change IPM.',
      'E38' => 'Limit frequency according to modular voltage — incorrect wire connection or IPM failure. Check wires; reconnect or change IPM.',
      'E51' => 'Communication failure of fan motor — incorrect wire connection or IPM failure. Check wires; reconnect or change IPM.',
    }.freeze

    # raw pa13 value → code-name mapping.
    # P-codes 1-7: VALIDATED (pump in known P01 → pa13=1 ✓).
    # E-codes: encoding TBD — when an E-code shows up on the panel and pa13
    # has a corresponding raw value, add it here. Until then, fault_label
    # returns "FAULT (unknown raw=N)" with the dictionary printable for
    # forensics so the operator can cross-reference manually.
    FAULT_RAW_TO_NAME = {
      1 => 'P01', 2 => 'P02', 3 => 'P03', 4 => 'P04',
      5 => 'P05', 6 => 'P06', 7 => 'P07',
      # E-codes: extend as observed.
    }.freeze

    # Returns one of:
    #   nil                                  — no telemetry yet
    #   'none'                               — no active fault
    #   'P01: Water flow protection — ...'   — known code (full description)
    #   'FAULT (unknown raw=42)'             — pa13 has a value we haven't
    #                                          mapped yet; check pump panel
    def fault_label(raw)
      return nil if raw.nil?
      n = raw.to_i
      return 'none' if n.zero?

      name = FAULT_RAW_TO_NAME[n]
      return "FAULT (unknown raw=#{n}) — check pump panel for code, see manual §13" unless name

      desc = FAULT_CODES_BY_NAME[name]
      "#{name}: #{desc}"
    end
  end
end
