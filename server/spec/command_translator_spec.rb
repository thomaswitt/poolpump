# spec/command_translator_spec.rb

require 'spec_helper'
require 'poolpump/command_translator'

RSpec.describe Poolpump::CommandTranslator do
  describe '.parse' do
    it 'parses on/off as single switch writes' do
      expect(described_class.parse('on').writes).to eq([[:switch, 1]])
      expect(described_class.parse('off').writes).to eq([[:switch, 0]])
    end

    it 'parses mode-boost / mode-silent / mode-auto as function writes with confirmed bitmask values' do
      expect(described_class.parse('mode-boost').writes).to eq([[:function, 0x0400]])
      expect(described_class.parse('mode-silent').writes).to eq([[:function, 0x0010]])
      expect(described_class.parse('mode-auto').writes).to eq([[:function, 0x0000]])
    end

    it 'parses setmode cool|heat|auto into model writes (panel-confirmed semantics)' do
      expect(described_class.parse('setmode heat').writes).to eq([[:model, 1]])
      expect(described_class.parse('setmode auto').writes).to eq([[:model, 2]])
      expect(described_class.parse('setmode cool').writes).to eq([[:model, 4]])
    end

    it 'parses "settemp N" into a single-setpoint sequence (active + panel display + heat mode)' do
      writes = described_class.parse('settemp 28').writes
      expect(writes).to eq([
                             [:switch, 1],
                             [:settemp, 28],
                             [:panel_settemp, 28],
                             [:model, 1],
                           ])
    end

    it 'parses "set-target N" as the pure setpoint pair (active + panel) without side effects' do
      expect(described_class.parse('set-target 26').writes).to eq([
                                                                    [:settemp, 26],
                                                                    [:panel_settemp, 26],
                                                                  ])
    end

    it 'rejects out-of-range settemp values (15..32 — heating-mode floor + comfort/efficiency ceiling)' do
      expect { described_class.parse('settemp 5') }.to raise_error(described_class::ParseError, /out of range/)
      expect { described_class.parse('settemp 14') }.to raise_error(described_class::ParseError, /out of range/)
      expect { described_class.parse('settemp 33') }.to raise_error(described_class::ParseError, /out of range/)
      expect { described_class.parse('settemp 99') }.to raise_error(described_class::ParseError, /out of range/)
    end

    it 'accepts the edge values 15 and 32' do
      expect(described_class.parse('settemp 15').writes).to include([:settemp, 15])
      expect(described_class.parse('settemp 32').writes).to include([:settemp, 32])
    end

    it 'rejects empty / unknown verbs' do
      expect { described_class.parse('') }.to raise_error(described_class::ParseError, /empty/)
      expect { described_class.parse('frobulate') }.to raise_error(described_class::ParseError, /unknown verb/)
      expect { described_class.parse('setmode disco') }.to raise_error(described_class::ParseError, /unknown verb/)
    end

    it 'tolerates surrounding whitespace' do
      expect(described_class.parse(" on \n").writes).to eq([[:switch, 1]])
    end
  end

  describe '.to_register_writes' do
    it 'maps semantic writes to (address, raw, name, value) tuples' do
      cmd = described_class.parse('settemp 28')
      reg_writes = described_class.to_register_writes(cmd)
      # settemp 28 → raw 28 (plain integer °C, not half-degree offset)
      settemp_entry = reg_writes.find { |_, _, name, _| name == :settemp }
      expect(settemp_entry[0]).to eq(0x07d6)
      expect(settemp_entry[1]).to eq(28)
      # switch on → raw 1
      switch_entry = reg_writes.find { |_, _, name, _| name == :switch }
      expect(switch_entry[1]).to eq(1)
      # model heat (semantic=1, panel-confirmed) → raw 0x02
      model_entry = reg_writes.find { |_, _, name, _| name == :model }
      expect(model_entry[1]).to eq(0x02)
    end
  end
end
