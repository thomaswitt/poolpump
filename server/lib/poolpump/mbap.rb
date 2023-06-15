# lib/poolpump/mbap.rb

module Poolpump
  # MBAP = Modbus Application Protocol header. Wire layout:
  #
  #   <TID:2><PID:2><LEN:2><UID:1><FC:1><PDU...>
  #
  # LEN counts UID+FC+PDU (i.e. everything after itself). Total frame size
  # therefore is `6 + LEN`.
  #
  # This module deliberately speaks vanilla MBAP (no Modbus RTU CRC) — the
  # HF-LPB130 acts as a transparent byte pipe and what we observe over TCP
  # matches the standard. If Phase-1 capture turns up a non-standard wrapper,
  # this is the one place we patch.
  module MBAP
    HEADER_SIZE = 7
    LENGTH_OFFSET = 4

    Frame = Struct.new(:tid, :pid, :length, :uid, :fc, :bytes, keyword_init: true) do
      def pdu; bytes.byteslice(HEADER_SIZE, bytes.bytesize - HEADER_SIZE) end
      def to_s; bytes end
    end

    module_function

    # Lower bound: UID(1) + FC(1). Upper bound: per Modbus spec the PDU is at
    # most 253 bytes, so MBAP length ≤ 254. Anything outside this range is
    # garbage on the wire — drop it rather than buffer forever.
    MIN_LENGTH = 2
    MAX_LENGTH = 254

    class MalformedFrame < StandardError; end

    # Pulls the next complete frame off the front of `buf` (in place), returns
    # nil if we don't yet have a full frame's worth of bytes, or raises
    # MalformedFrame on a header that can never be valid (caller should reset
    # the buffer + close the socket).
    def take_frame(buf)
      return nil if buf.bytesize < HEADER_SIZE
      tid, pid, length, uid = buf.byteslice(0, HEADER_SIZE).unpack('n n n C')
      raise MalformedFrame, "PID=#{pid} (expected 0)" unless pid.zero?
      raise MalformedFrame, "length=#{length} (must be #{MIN_LENGTH}..#{MAX_LENGTH})" unless (MIN_LENGTH..MAX_LENGTH).cover?(length)
      total = 6 + length
      return nil if buf.bytesize < total
      bytes = buf.byteslice(0, total)
      buf.replace(buf.byteslice(total..-1) || '')
      Frame.new(tid: tid, pid: pid, length: length, uid: uid, fc: bytes.getbyte(7), bytes: bytes)
    end

    # Build the standard 12-byte response to a device-initiated FC=0x10
    # (Write Multiple Registers) push. Mirrors TID/UID, echoes start+qty.
    def fc16_ack(req_frame)
      _fc, start_addr, qty = req_frame.pdu.unpack('C n n')
      [req_frame.tid, 0, 6, req_frame.uid, 0x10, start_addr, qty].pack('n n n C C n n')
    end

    # Build the 12-byte cloud-style ACK for a device FC=0x41 vendor heartbeat.
    # CONFIRMED by capturing fzdbiology.com:502's response:
    #
    #   <tid_echo:2> 00 00 00 06 01 41 00 00 00 05
    #
    # Echoes the device's TID, fixed length=6, uid=0x01, fc=0x41, plus a
    # constant 4-byte payload `00 00 00 05`. Poolpump accepts this ACK and
    # transitions into FC=0x10 telemetry-push mode within ~2s.
    #
    # Compared to the older `echo` strategy (which echoed the full 23-byte
    # device frame back), this saves ~half the wire bytes per heartbeat and
    # matches what the OEM cloud actually sends. Both work; this is canonical.
    FC41_ACK_PAYLOAD = "\x00\x00\x00\x05".b

    def fc41_ack(req_frame)
      pdu = "\x01\x41".b + FC41_ACK_PAYLOAD
      [req_frame.tid, 0, pdu.bytesize].pack('n n n') + pdu
    end

    # Master-side Read Holding Registers request (FC=0x03). Returns 12 bytes.
    def fc03_request(tid:, start_addr:, qty:, uid: 1)
      [tid, 0, 6, uid, 0x03, start_addr, qty].pack('n n n C C n n')
    end

    # Master-side Read Input Registers request (FC=0x04). Returns 12 bytes.
    def fc04_request(tid:, start_addr:, qty:, uid: 1)
      [tid, 0, 6, uid, 0x04, start_addr, qty].pack('n n n C C n n')
    end

    # Master-side Write Single Register request (FC=0x06). Returns 12 bytes.
    def fc06_request(tid:, address:, value:, uid: 1)
      [tid, 0, 6, uid, 0x06, address, value & 0xFFFF].pack('n n n C C n n')
    end

    # Master-side Write Single Coil request (FC=0x05). value: true → 0xFF00, false → 0x0000.
    def fc05_request(tid:, address:, on:, uid: 1)
      [tid, 0, 6, uid, 0x05, address, on ? 0xFF00 : 0x0000].pack('n n n C C n n')
    end

    # Master-side Write Multiple Registers request (FC=0x10). Values: array of 16-bit ints.
    # MBAP length = UID(1) + FC(1) + START(2) + QTY(2) + BC(1) + DATA(qty*2) = 7 + qty*2.
    def fc16_request(tid:, start_addr:, values:, uid: 1)
      qty = values.length
      byte_cnt = qty * 2
      mbap_len = 7 + byte_cnt
      header = [tid, 0, mbap_len, uid].pack('n n n C')
      body = ([0x10, start_addr, qty, byte_cnt] + values.map { |v| v & 0xFFFF }).pack("C n n C n#{qty}")
      header + body
    end

    # Decode a Read Holding Registers / Read Input Registers response into an
    # array of 16-bit unsigned integers (one per register). Returns nil if the
    # frame's PDU is malformed.
    def decode_read_response(frame)
      pdu = frame.pdu
      fc, byte_count = pdu.unpack('C C')
      return nil unless [0x03, 0x04].include?(fc)
      return nil unless pdu.bytesize >= 2 + byte_count
      pdu.byteslice(2, byte_count).unpack("n#{byte_count / 2}")
    end

    # Decode a Write Multiple Registers PUSH (device-initiated FC=0x10) into
    # the same shape — start_address + array of register values.
    def decode_fc16_push(frame)
      pdu = frame.pdu
      fc, start_addr, qty, byte_count = pdu.unpack('C n n C')
      return nil unless fc == 0x10
      return nil unless pdu.bytesize >= 6 + byte_count
      values = pdu.byteslice(6, byte_count).unpack("n#{byte_count / 2}")
      return nil unless values.length == qty
      [start_addr, values]
    end
  end
end
