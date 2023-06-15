# spec/at_modbus_spec.rb

require 'spec_helper'
require 'tools/at_modbus'

RSpec.describe ATModbus do
  describe '.crc16' do
    # Reference vector from the Modbus RTU spec (Polynomial 0xA001).
    # Frame: 01 03 00 00 00 01  →  CRC 0x0A84 (little-endian on the wire = '840a')
    it 'matches the canonical CRC for slave 1, FC=0x03, addr=0, qty=1' do
      pdu = [0x01, 0x03, 0x00, 0x00, 0x00, 0x01].pack('C*')
      expect(described_class.crc16(pdu).unpack1('H*')).to eq('840a')
    end

    it 'is symmetric — running CRC over (frame + CRC) leaves CRC of the full bytes equal to 0' do
      # Standard Modbus property: CRC(payload + CRC(payload)) == 0 (LE).
      pdu = [0x01, 0x03, 0x00, 0x00, 0x00, 0x01].pack('C*')
      crc = described_class.crc16(pdu)
      expect(described_class.crc16(pdu + crc)).to eq("\x00\x00".b)
    end
  end

  describe '.build_read_request' do
    it 'constructs an 8-byte FC=0x03 read frame with CRC appended' do
      req = described_class.build_read_request(slave_id: 1, start_addr: 2000, qty: 7)
      expect(req.bytesize).to eq(8)
      slave, fc, addr, qty = req.byteslice(0, 6).unpack('C C n n')
      expect([slave, fc, addr, qty]).to eq([1, 0x03, 2000, 7])
      # CRC is the last 2 bytes; verify it round-trips through our own crc16.
      expect(described_class.crc16(req.byteslice(0, 6))).to eq(req.byteslice(6, 2))
    end
  end

  describe '.parse_read_response' do
    it 'extracts qty register values from a valid RTU response' do
      # slave=1 fc=03 bc=06 data=0x0001 0x0002 0x0003 + CRC
      pdu = [0x01, 0x03, 0x06, 0x00, 0x01, 0x00, 0x02, 0x00, 0x03].pack('C*')
      frame = pdu + described_class.crc16(pdu)
      expect(described_class.parse_read_response(frame)).to eq([1, 2, 3])
    end

    it 'raises on a Modbus exception response (FC | 0x80)' do
      # slave=1 fc=0x83 (exception for 0x03) ex_code=0x02 (illegal data addr) + CRC
      pdu = [0x01, 0x83, 0x02].pack('C*')
      frame = pdu + described_class.crc16(pdu)
      expect { described_class.parse_read_response(frame) }.to raise_error(/Modbus exception.*code=0x2/)
    end

    it 'raises on CRC mismatch (catches corrupted-on-wire responses)' do
      pdu = [0x01, 0x03, 0x02, 0x00, 0x42].pack('C*')
      bad_crc = "\xFF\xFF".b
      expect { described_class.parse_read_response(pdu + bad_crc) }.to raise_error(/CRC mismatch/)
    end

    it 'raises on truncated frames' do
      expect { described_class.parse_read_response("\x01\x03".b) }.to raise_error(/too short/)
    end
  end
end
