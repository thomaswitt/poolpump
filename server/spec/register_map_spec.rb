# spec/register_map_spec.rb

require 'spec_helper'
require 'poolpump/register_map'

RSpec.describe Poolpump::RegisterMap do
  describe Poolpump::RegisterMap::Codecs::TempOffset18Half do
    it 'round-trips integer °C in the 18..32 range' do
      (18..32).each do |c|
        raw = described_class.encode(c)
        expect(raw).to be_between(96, 124)
        expect(described_class.decode(raw)).to eq(c.to_f)
      end
    end

    it 'decodes to half-degree precision' do
      expect(described_class.decode(97)).to eq(18.5)
      expect(described_class.decode(124)).to eq(32.0)
    end

    it 'encodes the example value 30 °C as raw 120' do
      expect(described_class.encode(30)).to eq(120)
    end
  end

  describe Poolpump::RegisterMap::Codecs::Int16 do
    it 'decodes the high half of the range as negative' do
      expect(described_class.decode(0xFFFE)).to eq(-2)
      expect(described_class.decode(0x0000)).to eq(0)
      expect(described_class.decode(0x7FFF)).to eq(32767)
    end

    it 'encodes negatives back to the high half' do
      expect(described_class.encode(-2) & 0xFFFF).to eq(0xFFFE)
    end
  end

  describe Poolpump::RegisterMap::Codecs::ModeEnum do
    it 'maps semantic model values to the confirmed Modbus bitmask values' do
      # Panel-confirmed 2026-05-12: semantic 1=heat, 2=auto, 4=cool.
      # Codec direction unchanged from original RE; only labels were wrong.
      expect(described_class.encode(1)).to eq(0x02) # heat
      expect(described_class.encode(2)).to eq(0x04) # auto
      expect(described_class.encode(4)).to eq(0x01) # cool
    end

    it 'decodes Modbus bitmask values back to semantic model values' do
      expect(described_class.decode(0x01)).to eq(4) # cool
      expect(described_class.decode(0x02)).to eq(1) # heat
      expect(described_class.decode(0x04)).to eq(2) # auto
    end

    it 'raises on unknown semantic values' do
      expect { described_class.encode(99) }.to raise_error(ArgumentError, /unknown enum value/)
    end
  end

  describe '.decode_block (control block at addr 2000)' do
    it 'decodes the 7-register CONFIRMED control block into named fields' do
      # Layout: model, switch, function, ?, ?, ?, settemp (regs 2000..2006)
      values = [0x04, 0x01, 0x0010, 0, 0, 0, 28]
      decoded = described_class.decode_block(Poolpump::RegisterMap::TELEMETRY_BLOCK_START, values)
      expect(decoded[:model]).to eq(2)        # raw 0x04 → semantic 2 (auto)
      expect(decoded[:switch]).to eq(1)
      expect(decoded[:function]).to eq(0x0010) # raw passes through (silent bit)
      expect(decoded[:settemp]).to eq(28)
    end

    it 'preserves unknown addresses under raw_<hex> keys' do
      decoded = described_class.decode_block(0x9000, [42])
      expect(decoded[:raw_9000]).to eq(42)
    end

    it 'decodes a PQ Parameter Table (block 300) push into named sensor fields' do
      # Captured from a real Poolpump push (tid=0x0af4, addr=0x012c, qty=27).
      # See _data/PROTOCOL-FINDINGS-2026-04-30.md for the byte-level decoding.
      values = [
        0,    # 300: PQ01 compressor freq Hz (off)
        96,   # 301: PQ02 EEV open ÷5
        17,   # 302: PQ03 ambient air °C → :ap2
        18,   # 303: PQ04 outlet water °C → :ap3
        17,   # 304: PQ05 discharge refrig
        17,   # 305: PQ06 suction refrig
        17,   # 306: PQ07 air heat-exchanger
        18,   # 307: PQ08 outlet refrig EXV
        0,    # 308: PQ09 water pump → :ap8
        0,    # 309: PQ10 4-way valve → :pb11
        0, 0, 0, 0, 0, # 310-314: PQ11-15 reserved
        0,    # 315: PQ16 compressor current ÷10
        23,   # 316: PQ17 voltage ×10 → 230 V mains ★
        0, 0, 0, # 317-319: PQ18-20 reserved
        0,    # 320: PQ21 fan speed ×15
        64,   # 321: PQ22 DC link voltage ×5 → 320 V ★
        0,    # 322: PQ23 DC link current
        25,   # 323: PQ24 PFC temp °C
        25,   # 324: PQ25 IPM temp °C
        0,    # 325: PQ26 compressor target freq
        100,  # 326: extra register beyond PQ table
      ]
      decoded = described_class.decode_block(300, values)
      expect(decoded[:ap2]).to eq(17)        # ambient
      expect(decoded[:ap3]).to eq(18)        # outlet water
      expect(decoded[:ap8]).to eq(0)         # water pump off
      expect(decoded[:pa15]).to eq(0)        # compressor freq
      expect(decoded[:pb11]).to eq(0)        # 4-way valve / op state
      # PQ17 voltage decoded via TenFold codec (raw 23 → 230 V).
      expect(decoded[:pa17]).to eq(230)
    end

    it 'exposes regs 2003-2005 (purpose unknown) as raw_07d3..raw_07d5' do
      values = [0x01, 0x01, 0x0000, 9, 28, 45, 30]
      decoded = described_class.decode_block(Poolpump::RegisterMap::TELEMETRY_BLOCK_START, values)
      expect(decoded[:raw_07d3]).to eq(9)
      expect(decoded[:raw_07d4]).to eq(28)
      expect(decoded[:raw_07d5]).to eq(45)
    end
  end

  describe '.semantic_snapshot' do
    it 'maps decoded keys to the 14-field shape with the same names as the existing API' do
      decoded = {
        switch: 1, model: 4, function: 0, settemp: 28,
        pa10: 30, ap3: 28, ap2: 22, pa15: 0, ap8: 0,
        pb11: 0, pa13: 0,
      }
      snap = described_class.semantic_snapshot(decoded)
      expect(snap.keys).to eq(%w[
                             SWITCHED_ON COMPRESSOR_RATE TEMP_AMBIENT TEMP_OUTLET TEMP_INLET
                             TEMP_TARGET TEMP_TARGET_AUTO TEMP_TARGET_COOL BOOST SILENCE
                             STATUS_WATERPUMP STATUS_MODE STATUS_MALFUNC STATUS_OPERATION
                             AC_VOLTAGE MOTOR_CURRENT_A DC_LINK_VOLTAGE_V DC_LINK_CURRENT_A COMPRESSOR_LOAD_PCT MAX_INPUT_W
                           ])
      expect(snap['STATUS_MALFUNC']).to eq('none')
      expect(snap['TEMP_INLET']).to eq(30)
      expect(snap['STATUS_MODE']).to eq(4)
      expect(snap['BOOST']).to eq(0)
      expect(snap['SILENCE']).to eq(0)
    end

    it 'surfaces the single setpoint in all three legacy TEMP_TARGET_* fields' do
      snap = described_class.semantic_snapshot(settemp: 27)
      expect(snap['TEMP_TARGET']).to eq(27)
      expect(snap['TEMP_TARGET_AUTO']).to eq(27)
      expect(snap['TEMP_TARGET_COOL']).to eq(27)
    end

    it 'derives BOOST=1 when function=0x0400 (boost bit)' do
      snap = described_class.semantic_snapshot(function: 0x0400)
      expect(snap['BOOST']).to eq(1)
      expect(snap['SILENCE']).to eq(0)
    end

    it 'derives SILENCE=1 when function=0x0010 (silent bit)' do
      snap = described_class.semantic_snapshot(function: 0x0010)
      expect(snap['SILENCE']).to eq(1)
      expect(snap['BOOST']).to eq(0)
    end

    it 'derives BOOST=0 SILENCE=0 when function=0 (smart/default)' do
      snap = described_class.semantic_snapshot(function: 0)
      expect(snap['BOOST']).to eq(0)
      expect(snap['SILENCE']).to eq(0)
    end

    it 'leaves BOOST/SILENCE nil when function is unknown (no telemetry yet)' do
      snap = described_class.semantic_snapshot({})
      expect(snap['BOOST']).to be_nil
      expect(snap['SILENCE']).to be_nil
    end

    it 'reports STATUS_MALFUNC as the full code+description when pa13 is in the validated P-code range (1-7)' do
      snap = described_class.semantic_snapshot(pa13: 1)
      expect(snap['STATUS_MALFUNC']).to start_with('P01: Water flow protection')
    end

    it 'reports STATUS_MALFUNC as "FAULT (unknown raw=N)" for codes outside the validated range (E-codes TBD)' do
      snap = described_class.semantic_snapshot(pa13: 42)
      expect(snap['STATUS_MALFUNC']).to start_with('FAULT (unknown raw=42)')
    end

    it 'reports STATUS_MALFUNC as "none" when fault aggregator is zero' do
      snap = described_class.semantic_snapshot(pa13: 0)
      expect(snap['STATUS_MALFUNC']).to eq('none')
    end
  end

  describe '.encode_write' do
    it 'returns the confirmed write_address and raw value for switch on' do
      addr, raw = described_class.encode_write(:switch, 1)
      expect(addr).to eq(0x07d1)
      expect(raw).to eq(1)
    end

    it 'encodes setpoint as plain integer °C (no half-degree offset)' do
      addr, raw = described_class.encode_write(:settemp, 30)
      expect(addr).to eq(0x07d6)
      expect(raw).to eq(30)
    end

    it 'encodes semantic mode 2 (auto) as Modbus raw 0x04' do
      addr, raw = described_class.encode_write(:model, 2)
      expect(addr).to eq(0x07d0)
      expect(raw).to eq(0x04)
    end

    it 'encodes semantic mode 4 (cool) as Modbus raw 0x01' do
      _addr, raw = described_class.encode_write(:model, 4)
      expect(raw).to eq(0x01)
    end

    it 'raises on read-only registers' do
      expect { described_class.encode_write(:ap2, 25) }.to raise_error(ArgumentError, /read-only/)
    end

    it 'raises on unknown register names' do
      expect { described_class.encode_write(:not_a_thing, 1) }.to raise_error(ArgumentError, /no register/)
    end
  end
end
