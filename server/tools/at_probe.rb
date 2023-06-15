#!/usr/bin/env ruby
# Quick AT-command tester — open a single Reprovision::Session, send one
# (or several piped) AT commands, print raw responses. For when commission
# / repoint return cryptic +ERR codes and you want to bisect what the
# module accepts.
#
# Usage:
#   ruby tools/at_probe.rb <ip> 'AT+VER'
#   ruby tools/at_probe.rb 10.10.100.254 'AT+NETP=TCP,Client,502,1.2.3.4'
#
# Multiple commands in one session (handshake once, send all):
#   ruby tools/at_probe.rb 10.10.100.254 'AT+VER' 'AT+WMODE' 'AT+NETP'
#
# Pipe form:
#   echo 'AT+NETP=TCP,Client,80,foo.com' | ruby tools/at_probe.rb 10.10.100.254
#
# All commands run on a SINGLE UDP session (the reason most things work
# in `show` but fail when isolated). Errors are printed but don't abort
# the rest of the batch.

require 'bundler/setup'
require_relative 'reprovision'

ip = ARGV.shift or abort 'usage: ruby tools/at_probe.rb <ip> <cmd> [<cmd> ...]'
cmds = ARGV.dup
cmds.concat($stdin.each_line.map(&:strip).reject(&:empty?)) unless $stdin.tty?
abort 'no commands given' if cmds.empty?

puts "→ open session to #{ip} (handshake once)"
session = Reprovision::Session.new(ip)
begin
  cmds.each do |cmd|
    print "  #{cmd}  "
    begin
      result = session.send(cmd)
      puts "→ +ok#{result.empty? ? '' : "=#{result}"}"
    rescue Reprovision::ModuleError => e
      puts "→ #{e.message.split(' → ').last}"
    rescue Reprovision::Timeout
      puts '→ TIMEOUT (no response)'
    end
  end
ensure
  session.close
end
