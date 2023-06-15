#!/usr/bin/env ruby
# Parse sniff.rb log output into a register-state map and print/diff/watch.
#
# The sniffer dumps every FC=0x10 (Write Multiple Registers) push as a
# header line + indented hex_dump rows. This tool reconstructs the bytes,
# extracts (start_addr, qty, values), and maintains a {addr => value} map.
# Use it to spot which registers move when you press buttons on the pump.
#
# Modes:
#   dump  <log>                 — print current register state from a log
#   diff  <baseline> <current>  — show addr=val that changed between two logs
#   watch <log>                 — tail the log; print every register change live
#
# Output format is `addr=value` (decimal addr, signed-decimal value, hex value
# in parens). Values are interpreted as big-endian 16-bit signed integers.
#
# Examples:
#   ruby tools/decode_telemetry.rb dump _data/baseline-rest-2026-04-30.log
#   ruby tools/decode_telemetry.rb diff _data/baseline-rest-*.log /tmp/sniff-poolpump.log
#   ruby tools/decode_telemetry.rb watch /tmp/sniff-poolpump.log

require 'optparse'

# ──────────────────────────────────────────────────────────────────────────
# Frame extraction from sniffer log
# ──────────────────────────────────────────────────────────────────────────

# Returns an Array of hex-decoded byte-strings, one per RECV FC=0x10 frame.
# Tolerates partial/streaming logs (incomplete trailing frame is dropped).
def parse_frames_from_log(io)
  frames = []
  current_bytes = nil
  io.each_line do |line|
    if line =~ /RECV\s+tid=\h+\s+pid=\d+\s+len=\d+\s+uid=\d+\s+fc=0x10\s+bytes=\d+/
      frames << current_bytes if current_bytes
      current_bytes = +''
    elsif current_bytes && line =~ /^\s+[0-9a-f]{4}\s+((?:[0-9a-f]{2}\s)+[0-9a-f]{2})/
      current_bytes << Regexp.last_match(1).delete(' ')
    elsif current_bytes && line !~ /^\s/
      frames << current_bytes
      current_bytes = nil
    end
  end
  frames << current_bytes if current_bytes
  frames.map { |hex| [hex].pack('H*') }
end

# Decode an FC=0x10 frame into [start_addr, [register_values_signed]].
# Wire layout: tid(2) pid(2) len(2) uid(1) fc(1) addr(2) qty(2) bc(1) data(N)
def decode_fc10(frame)
  return nil if frame.bytesize < 13

  fc = frame.getbyte(7)
  return nil unless fc == 0x10

  addr = frame.byteslice(8, 2).unpack1('n')
  qty  = frame.byteslice(10, 2).unpack1('n')
  bc   = frame.getbyte(12)
  return nil unless bc == qty * 2 && frame.bytesize >= 13 + bc

  values = frame.byteslice(13, bc).unpack('n*').map { |u| u >= 0x8000 ? u - 0x10000 : u }
  [addr, values]
end

# Build a {addr => value} hash from a parsed log. Later frames overwrite
# earlier ones (register state is the most recent push for each address).
def state_from_frames(frames)
  state = {}
  frames.each do |frame|
    decoded = decode_fc10(frame)
    next unless decoded

    addr, values = decoded
    values.each_with_index { |v, i| state[addr + i] = v }
  end
  state
end

def fmt(addr, value)
  hex = format('0x%04x', value & 0xffff)
  "#{addr.to_s.rjust(4)} = #{value.to_s.rjust(6)} (#{hex})"
end

# ──────────────────────────────────────────────────────────────────────────
# Modes
# ──────────────────────────────────────────────────────────────────────────

def cmd_dump(path)
  state = state_from_frames(parse_frames_from_log(File.open(path, 'rb')))
  state.sort.each { |addr, v| puts fmt(addr, v) }
  warn "(#{state.size} registers across #{state.keys.minmax.inspect})"
end

def cmd_diff(baseline_path, current_path)
  base = state_from_frames(parse_frames_from_log(File.open(baseline_path, 'rb')))
  curr = state_from_frames(parse_frames_from_log(File.open(current_path, 'rb')))
  changed = (base.keys | curr.keys).select { |a| base[a] != curr[a] }
  changed.sort.each do |addr|
    b = base[addr]
    c = curr[addr]
    puts "#{addr.to_s.rjust(4)}: #{(b || '—').to_s.rjust(6)} → #{(c || '—').to_s.rjust(6)}"
  end
  warn "(#{changed.size} changed; baseline=#{base.size} current=#{curr.size})"
end

def cmd_watch(path)
  state = {}
  buffer = +''
  File.open(path, 'rb') do |f|
    f.seek(0, IO::SEEK_END)
    loop do
      chunk = f.read
      if chunk.nil? || chunk.empty?
        sleep 0.5
        next
      end

      buffer << chunk
      # Process complete frames (header line + dump rows) — split on RECV markers
      while (idx = buffer.index(/^\[\d\d:\d\d:\d\d/, 1))
        frame_block = buffer.slice!(0, idx)
        process_block(frame_block, state)
      end
    end
  end
end

def process_block(block, state)
  frames = parse_frames_from_log(StringIO.new(block))
  frames.each do |frame|
    decoded = decode_fc10(frame)
    next unless decoded

    addr, values = decoded
    values.each_with_index do |v, i|
      a = addr + i
      old = state[a]
      next if old == v

      ts = Time.now.strftime('%H:%M:%S.%L')
      if old.nil?
        puts "[#{ts}] +#{fmt(a, v)}"
      else
        puts "[#{ts}]  #{a.to_s.rjust(4)}: #{old.to_s.rjust(6)} → #{v.to_s.rjust(6)}"
      end
      state[a] = v
    end
  end
  $stdout.flush
end

# ──────────────────────────────────────────────────────────────────────────
# CLI dispatcher
# ──────────────────────────────────────────────────────────────────────────

def usage(io = $stderr, code = 1)
  io.puts <<~USAGE
    usage:
      ruby tools/decode_telemetry.rb dump  <log>
      ruby tools/decode_telemetry.rb diff  <baseline-log> <current-log>
      ruby tools/decode_telemetry.rb watch <log>
  USAGE
  exit code
end

if __FILE__ == $PROGRAM_NAME
  require 'stringio'
  case ARGV.shift
  when 'dump'  then ARGV.size == 1 ? cmd_dump(ARGV[0])           : usage
  when 'diff'  then ARGV.size == 2 ? cmd_diff(ARGV[0], ARGV[1])  : usage
  when 'watch' then ARGV.size == 1 ? cmd_watch(ARGV[0])          : usage
  else usage
  end
end
