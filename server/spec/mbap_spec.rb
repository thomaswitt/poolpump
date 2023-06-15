# spec/mbap_spec.rb

require 'spec_helper'
require 'poolpump/mbap'

RSpec.describe Poolpump::MBAP do
  describe '.take_frame' do
    it 'returns nil with fewer than 7 buffered bytes' do
      buf = "\x00\x01\x00\x00".dup
      expect(described_class.take_frame(buf)).to be_nil
      expect(buf.bytesize).to eq(4)
    end

    it 'returns nil when the MBAP length says we need more bytes than we have' do
      buf = "\x00\x01\x00\x00\x00\x06\x01\x10".dup
      expect(described_class.take_frame(buf)).to be_nil
      expect(buf.bytesize).to eq(8)
    end

    it 'parses a complete FC=0x03 request and consumes it from the buffer' do
      buf = "\x00\x42\x00\x00\x00\x06\x01\x03\x00\x00\x00\x01".dup
      f = described_class.take_frame(buf)
      expect(f.tid).to eq(0x42)
      expect(f.length).to eq(6)
      expect(f.uid).to eq(1)
      expect(f.fc).to eq(0x03)
      expect(buf).to eq('')
    end

    it 'leaves the next frame in the buffer for the next call' do
      f1 = "\x00\x01\x00\x00\x00\x06\x01\x03\x00\x00\x00\x01"
      f2 = "\x00\x02\x00\x00\x00\x06\x01\x06\x00\x00\xff\x00"
      buf = (f1 + f2).dup.force_encoding(Encoding::BINARY)
      expect(described_class.take_frame(buf).fc).to eq(0x03)
      expect(described_class.take_frame(buf).fc).to eq(0x06)
      expect(buf).to eq('')
    end

    it 'rejects PID != 0 with MalformedFrame (H4)' do
      buf = "\x00\x01\x12\x34\x00\x06\x01\x03\x00\x00\x00\x01".dup # PID=0x1234
      expect { described_class.take_frame(buf) }.to raise_error(Poolpump::MBAP::MalformedFrame, /PID/)
    end

    it 'rejects length=0 with MalformedFrame (H4)' do
      buf = "\x00\x01\x00\x00\x00\x00\x01".dup
      expect { described_class.take_frame(buf) }.to raise_error(Poolpump::MBAP::MalformedFrame, /length/)
    end

    it 'rejects length=0xFFFF with MalformedFrame (H4)' do
      buf = "\x00\x01\x00\x00\xFF\xFF\x01\x03".dup
      expect { described_class.take_frame(buf) }.to raise_error(Poolpump::MBAP::MalformedFrame, /length/)
    end

    it 'survives byte-by-byte fragmentation' do
      whole = "\x00\x01\x00\x00\x00\x06\x01\x03\x00\x00\x00\x01"
      buf = String.new(encoding: Encoding::BINARY)
      result = nil
      whole.each_byte do |b|
        buf << b.chr.b
        result = described_class.take_frame(buf)
      end
      expect(result).not_to be_nil
      expect(result.fc).to eq(0x03)
    end

    it 'parses a 67-byte FC=0x10 telemetry push matching the size from received-data-tcpdump' do
      # Reproduce the shape of the real captured frame:
      # MBAP(7) + FC(1) + START(2) + QTY(2) + BC(1) + DATA(54) = 67 bytes; LEN=0x3d.
      header = [0x61ae, 0, 0x3d, 0x01].pack('n n n C')
      pdu = [0x10, 0x012c, 0x001b, 0x36].pack('C n n C') + ("\x00".b * 0x36)
      raw = (header + pdu).b
      expect(raw.bytesize).to eq(67)
      f = described_class.take_frame(raw.dup)
      expect(f.tid).to eq(0x61ae)
      expect(f.length).to eq(0x3d)
      expect(f.fc).to eq(0x10)
      expect(f.bytes.bytesize).to eq(67)
    end
  end

  describe '.fc16_ack' do
    it 'returns the canonical 12-byte ack mirroring TID/UID and echoing start+qty' do
      data = "\x00" * 0x36
      raw = "\xCA\xFE\x00\x00\x00\x3D\x01" + "\x10\x01\x2C\x00\x1B\x36" + data
      frame = described_class.take_frame(raw.b.dup)
      ack = described_class.fc16_ack(frame)
      expect(ack.bytesize).to eq(12)
      tid, pid, len, uid, fc, addr, qty = ack.unpack('n n n C C n n')
      expect([tid, pid, len, uid, fc, addr, qty]).to eq([0xCAFE, 0, 6, 1, 0x10, 0x012C, 0x001B])
    end
  end

  describe '.fc41_ack (cloud-format heartbeat reply)' do
    # The real device frame Poolpump sends every 2s: tid + pid + len(17) + uid +
    # fc=0x41 + 9-byte vendor payload + 6-byte MAC = 23 bytes.
    let(:device_heartbeat) do
      mac = "\x34\xea\xe7\x42\x51\xca".b
      vendor = "\x00\x00\x00\x05\x0a\x00\x03\x00\x03".b
      pdu = "\x01\x41".b + vendor + mac
      ([0x0aec, 0, pdu.bytesize].pack('n n n') + pdu).b
    end

    it 'returns the cloud-format 12-byte ACK echoing TID and using the constant 4-byte payload' do
      frame = described_class.take_frame(device_heartbeat.dup)
      ack = described_class.fc41_ack(frame)
      expect(ack.bytesize).to eq(12)
      tid, pid, len, uid, fc = ack.unpack('n n n C C')
      expect([tid, pid, len, uid, fc]).to eq([0x0aec, 0, 6, 0x01, 0x41])
      # Payload is the 4-byte constant `00 00 00 05` observed against fzdbiology.com:502.
      expect(ack.byteslice(8, 4)).to eq(described_class::FC41_ACK_PAYLOAD)
    end

    it 'matches the byte-for-byte cloud capture' do
      # Captured from fzdbiology.com:502 in response to tid=0x0001 heartbeat.
      expected = "\x00\x01\x00\x00\x00\x06\x01\x41\x00\x00\x00\x05".b
      mac = "\x34\xea\xe7\x42\x51\xca".b
      vendor = "\x00\x00\x00\x05\x0a\x00\x03\x00\x03".b
      pdu = "\x01\x41".b + vendor + mac
      raw = ([0x0001, 0, pdu.bytesize].pack('n n n') + pdu).b
      frame = described_class.take_frame(raw.dup)
      expect(described_class.fc41_ack(frame)).to eq(expected)
    end
  end

  describe '.fc03_request / .fc04_request / .fc06_request / .fc05_request' do
    it 'fc03_request builds a 12-byte read-holding-registers PDU' do
      req = described_class.fc03_request(tid: 0x4242, start_addr: 0, qty: 1)
      expect(req.bytesize).to eq(12)
      expect(req.unpack('n n n C C n n')).to eq([0x4242, 0, 6, 1, 0x03, 0, 1])
    end

    it 'fc04_request mirrors fc03 but with FC=0x04' do
      req = described_class.fc04_request(tid: 1, start_addr: 5, qty: 2)
      expect(req.unpack('n n n C C n n')[4]).to eq(0x04)
    end

    it 'fc06_request packs single-register write' do
      req = described_class.fc06_request(tid: 1, address: 0x0002, value: 124)
      expect(req.unpack('n n n C C n n')).to eq([1, 0, 6, 1, 0x06, 0x0002, 124])
    end

    it 'fc05_request maps on:true → 0xFF00 and on:false → 0x0000' do
      on_req = described_class.fc05_request(tid: 1, address: 0, on: true)
      off_req = described_class.fc05_request(tid: 1, address: 0, on: false)
      expect(on_req.unpack('n n n C C n n').last).to eq(0xFF00)
      expect(off_req.unpack('n n n C C n n').last).to eq(0x0000)
    end
  end

  describe '.fc16_request' do
    it 'packs a write-multiple-registers request with byte count and length set correctly' do
      req = described_class.fc16_request(tid: 0xAA, start_addr: 0x10, values: [0x1111, 0x2222, 0x3333])
      # MBAP header (7) + FC(1) + START(2) + QTY(2) + BC(1) + DATA(6) = 19 total
      expect(req.bytesize).to eq(19)
      tid, pid, len, uid, fc, start_addr, qty, bc = req.unpack('n n n C C n n C')
      expect([tid, pid, len, uid, fc, start_addr, qty, bc]).to eq([0xAA, 0, 13, 1, 0x10, 0x10, 3, 6])
      values = req.byteslice(13, 6).unpack('n n n')
      expect(values).to eq([0x1111, 0x2222, 0x3333])
    end
  end

  describe '.decode_read_response' do
    it 'decodes a 5-register FC=0x03 response into 16-bit ints' do
      pdu = "\x03\x0a\x00\x01\x00\x02\x00\x03\x00\x04\x00\x05"
      raw = "\x00\x01\x00\x00\x00\x0d\x01" + pdu
      frame = described_class.take_frame(raw.b.dup)
      expect(described_class.decode_read_response(frame)).to eq([1, 2, 3, 4, 5])
    end

    it 'returns nil for unrelated function codes' do
      raw = "\x00\x01\x00\x00\x00\x06\x01\x10\x00\x00\x00\x01"
      frame = described_class.take_frame(raw.b.dup)
      expect(described_class.decode_read_response(frame)).to be_nil
    end
  end

  describe '.decode_fc16_push' do
    it 'extracts start address and register array from a device-initiated push' do
      # FC=0x10, START=0x012C, QTY=3, BC=6, DATA= 1, 2, 3
      pdu = "\x10\x01\x2c\x00\x03\x06\x00\x01\x00\x02\x00\x03"
      raw = "\xca\xfe\x00\x00\x00\x0d\x01" + pdu
      frame = described_class.take_frame(raw.b.dup)
      addr, vals = described_class.decode_fc16_push(frame)
      expect(addr).to eq(0x012C)
      expect(vals).to eq([1, 2, 3])
    end
  end
end
