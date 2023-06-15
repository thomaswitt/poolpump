# poolpump - How to free your pool heat pump from an unencrypted Chinese cloud server

Background: <https://thomas-witt.com/blog/how-to-free-a-pool-heat-pump-from-an-unencrypted-chinese-server/>

Local replacement server for the unencrypted Chinese cloud that used to control
a pool heat pump branded "AcquaSource" - sold under several other names too
(google `47.254.152.109` and you'll find Mundoclima, Thermway, Proteam, AES
and more). Stop it from phoning home and run your own control server!

The pump's Hi-Flying **HF-LPB130** WiFi module dials a TCP server and
exchanges Modbus-over-TCP frames; we now host that server on the LAN and
expose a small HTTP API to home automation.

## Architecture

```text
Pump MCU --(UART/Modbus RTU)-- HF-LPB130 --(WiFi)--> local server
                                                       |
                                                       +-- TCP  :502   Modbus
                                                       +-- HTTP :8090  control API
```

Single Ruby process (`server/bin/poolpump-emulator`), one async reactor,
both ports.

tl;dr: see [SETUP.md](SETUP.md).

## Layout

```text
Dockerfile / docker-compose.yml   one service on :502 + :8090
poolpump.sh                       demo CLI - POSTs to localhost:8090
server/                           Ruby emulator
  bin/poolpump-emulator           entry point (one process, both ports)
  lib/poolpump/                   MBAP framing, register map, HTTP API
  tools/                          reprovision, sniff, cloud_probe, replay
  spec/                           RSpec - `bundle exec rake` runs all
```

## CLI

`poolpump.sh` is a thin curl wrapper:

```text
status                 ./poolpump.sh status
raw                    ./poolpump.sh raw       (full register snapshot)
on / off               ./poolpump.sh on   /   off
mode-silent / -boost   ./poolpump.sh mode-silent       (also: -auto)
settemp 28             ./poolpump.sh settemp 28
setmode auto|cool|heat ./poolpump.sh setmode heat
watertemp              ./poolpump.sh watertemp
reboot                 ./poolpump.sh reboot    (soft-reboot WiFi module)
health                 ./poolpump.sh health    (alias: healthz)
```

No auth, no TLS - **LAN only, never expose `:8090` to the internet.**

## Protocol notes

The wire protocol was decoded against an AcquaSource pump identifying as
`DOTELS-SWP`. If your module reports a different hostname in `discover`,
the addresses in `lib/poolpump/register_map.rb` may not match - the
**Debugging** section in `SETUP.md` walks through the re-validation
workflow.

## Running tests

```bash
cd server && bundle install && bundle exec rspec
```

## Risk surface

- Port 502 needs root outside Docker. Inside Docker, no.
- The HTTP API on :8090 has no auth and no TLS. LAN only.
- Control registers (mode / on-off / function / setpoint) are CONFIRMED.
- Read-only sensors are mostly CONFIRMED via the manual's PQ table;
  `STATUS_MALFUNC` returns the full code+description when known (e.g.
  `"P01: Water flow protection - …"`) and `"FAULT (unknown raw=N)"` for
  codes we haven't mapped yet.

## Further Reading / related repos

- [`s10l/deye-logger-at-cmd`](https://github.com/s10l/deye-logger-at-cmd) - solar inverter
  loggers using the same module, with documented `AT+` commands for changing
  the cloud server.
- [`Hypfer/deye-microinverter-cloud-free`](https://github.com/Hypfer/deye-microinverter-cloud-free) - exactly
  the same idea I was about to attempt, but for solar inverters:
  redirect the module from the vendor cloud to your own server.
- [`davidrapan/ha-solarman`](https://github.com/davidrapan/ha-solarman) - a
  Home Assistant integration for the same family of devices.
