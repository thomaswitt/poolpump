#!/usr/bin/env ruby
# Read Poolpump registers via the AT-command channel (UDP/48899) using the
# `AT+INVDATA=<len>,<rtu-hex>` command — a Modbus-RTU-over-AT path that
# bypasses the regular TCP/502/MBAP socket entirely.
#
# Why this matters: when Poolpump's TCP/Modbus FSM wedges (TCP open, no
# pushes, won't echo writes — the deeper-than-WiFi-module wedge that
# normally requires a panel-button reset to clear), the AT channel may
# still be responsive. This gives us a read-only diagnostic to confirm
# whether the controller MCU is alive at all.
#
# Discovered via the Deye logger tool (s10l/deye-logger-at-cmd) which uses
# the same primitive on Deye solar inverters' HF-LPB100 modules.
#
# Tested against Poolpump (DOTELS-SWP / HF-LPB130, MAC 00:11:22:33:44:55):
# returns TIMEOUT — the AT+INVDATA path is **NOT enabled** on this OEM
# firmware variant. So this tool is useless on Poolpump specifically; kept in
# the repo as a working reference for HF-LPB modules where the path IS
# enabled (Deye inverters via HFeasy-style firmware, etc.).
#
# Implication for Poolpump diagnostics: when the Modbus FSM wedges, the only
# remote-recovery options are AT+Z (bounces WiFi module — sometimes shakes
# Modbus loose) or the panel-button arrow-key combo (always works,
# requires walking to the pump).
#
# Usage:
#   ruby tools/at_modbus.rb <ip> read <slave-id> <start-addr> <qty>
#
# Example (read the 7-register control block at 2000):
#   ruby tools/at_modbus.rb 192.168.0.42 read 1 2000 7

require_relative 'reprovision'

module ATModbus
  module_function

  # Standard Modbus RTU CRC16 (poly 0xA001, init 0xFFFF, little-endian
  # output). Same algorithm every Modbus client uses; reproduced here so
  # this tool stays standalone (no rmodbus / modbus-master dependency).
  def crc16(bytes)
    crc = 0xFFFF
    bytes.each_byte do |b|
      crc ^= b
      8.times do
        crc = ((crc & 1) != 0) ? ((crc >> 1) ^ 0xA001) : (crc >> 1)
      end
    end
    [crc & 0xFFFF].pack('v') # little-endian — RTU convention
  end

  # Build a Modbus-RTU FC=0x03 (Read Holding Registers) request:
  #   <slave:1> <fc:1> <start_addr:2 BE> <qty:2 BE> <crc:2 LE>
  def build_read_request(slave_id:, start_addr:, qty:)
    pdu = [slave_id, 0x03, start_addr, qty].pack('C C n n')
    pdu + crc16(pdu)
  end

  # Parse an RTU response of shape:
  #   <slave:1> <fc:1> <byte_count:1> <register_data:N> <crc:2 LE>
  # Returns an array of 16-bit unsigned integers (one per register), or
  # raises on bad framing / CRC / Modbus exception (FC | 0x80).
  def parse_read_response(bytes)
    raise "response too short (#{bytes.bytesize}B)" if bytes.bytesize < 5

    slave, fc = bytes.byteslice(0, 2).unpack('C C')
    if fc & 0x80 != 0
      ex_code = bytes.getbyte(2)
      raise "Modbus exception: slave=#{slave} fc=0x#{fc.to_s(16)} code=0x#{ex_code.to_s(16)}"
    end
    raise "expected fc=0x03, got 0x#{fc.to_s(16)}" unless fc == 0x03

    bc = bytes.getbyte(2)
    raise "byte count #{bc} doesn't match frame size #{bytes.bytesize}" unless bytes.bytesize == 3 + bc + 2

    expected_crc = crc16(bytes.byteslice(0, 3 + bc))
    actual_crc   = bytes.byteslice(3 + bc, 2)
    raise "CRC mismatch: expected #{expected_crc.unpack1('H*')} got #{actual_crc.unpack1('H*')}" unless expected_crc == actual_crc

    bytes.byteslice(3, bc).unpack("n#{bc / 2}")
  end

  # Send a built request through the existing AT channel and return the
  # parsed register values. Reuses Reprovision::Session so the handshake
  # and inter-command pacing already validated against DOTELS-SWP keep
  # applying here.
  def read_registers(ip, slave_id:, start_addr:, qty:)
    request_bytes = build_read_request(slave_id: slave_id, start_addr: start_addr, qty: qty)
    request_hex = request_bytes.unpack1('H*').upcase
    cmd = "AT+INVDATA=#{request_bytes.bytesize},#{request_hex}"

    session = Reprovision::Session.new(ip)
    begin
      raw_response = session.send(cmd, timeout: 3.0)
    ensure
      session.close
    end

    # Response from `Session#send` strips the `+ok=` envelope and returns
    # the value (here: the RTU response in hex). Decode hex back to bytes
    # before parsing.
    response_bytes = [raw_response.delete(' ')].pack('H*')
    parse_read_response(response_bytes)
  end
end

if __FILE__ == $PROGRAM_NAME
  if ARGV.length < 5 || ARGV[1] != 'read'
    abort <<~USAGE
      usage: ruby tools/at_modbus.rb <ip> read <slave-id> <start-addr> <qty>

      Reads <qty> holding registers starting at <start-addr> from device <slave-id>
      via the AT+INVDATA UDP/48899 channel (alternative to TCP/502/MBAP).

      Example — read the 7 control registers at addr 2000 from Poolpump:
        ruby tools/at_modbus.rb 192.168.0.42 read 1 2000 7
    USAGE
  end

  ip       = ARGV[0]
  slave_id = Integer(ARGV[2])
  addr     = Integer(ARGV[3])
  qty      = Integer(ARGV[4])

  begin
    values = ATModbus.read_registers(ip, slave_id: slave_id, start_addr: addr, qty: qty)
    values.each_with_index do |v, i|
      puts format('  reg %4d = %5d (0x%04x)', addr + i, v, v)
    end
  rescue Reprovision::Timeout
    abort 'TIMEOUT — module did not respond. Either the AT+INVDATA path is not enabled on this firmware, or the module is offline.'
  rescue Reprovision::ModuleError => e
    abort "module rejected the AT+INVDATA call: #{e.message}"
  rescue StandardError => e
    abort "error: #{e.class}: #{e.message}"
  end
end
