# Setup

Two halves: a **Quickstart** for the happy path (clone → `.env` → docker
→ commission → curl), and a **Debugging** section for re-decoding the
protocol or untangling things that wedge.

If your module reports a hostname *other* than `DOTELS-SWP` in `discover`,
the register addresses in `lib/poolpump/register_map.rb` may not match
yours — go straight to **Debugging**.

---

## Quickstart

### Find the module

Run from a device on the same L2 segment as the module — UDP broadcast
usually doesn't cross subnets. If your wired host is on one VLAN and the
module's on another, easiest fix is to run `discover` from a phone or
laptop joined to the same WiFi.

```bash
cd <repo>/server
ruby tools/reprovision.rb discover
```

If nothing answers, the module's WiFi creds are gone (factory-reset,
router password change, etc.) and it's broadcasting its own SoftAP at
`10.10.100.254`. Walk to the pump with a laptop and continue with
**Commission** below — otherwise skip to **Snapshot**.

> I had to press and hold "Boost" + "Left Arrow" on the pump panel to
> reset all WiFi settings, and reboot the module by pressing both arrow
> buttons. Your mileage may vary.

### Commission (only if discovery returned nothing)

Connect the laptop's WiFi to the SSID `HF-LPB130` (no password by
default), then:

```bash
# 1. confirm reachable on its SoftAP IP
ruby tools/reprovision.rb discover --target 10.10.100.254
# → 10.10.100.254  001122334455  DOTELS-SWP

# 2. snapshot whatever's there now (rollback target)
ruby tools/reprovision.rb show 10.10.100.254

# 3. one-shot: WiFi creds + server target + reboot
ruby tools/reprovision.rb commission 10.10.100.254 \
  --ssid <YourSSID> --psk '<your wifi password>' \
  --server-hostname <server-hostname> --port 502
```

> **One-shot bootstrap.** Once the module reboots, the SoftAP at
> `10.10.100.254` is gone — you only get one session to write the WiFi
> creds *and* the server target. Use `commission`, not `set-wifi`. Order
> matters (WSSSID → WSKEY → NETP → WMODE), `commission` does it for you.

Point `--server-hostname` at whatever's going to run the emulator long-term —
easiest is a hostname you control (DNS A-record at the Pi's LAN IP, TTL
300) so you never have to commission again if the host moves. The
HF-LPB130 only accepts hostnames, not IP literals — and only honours
DHCP-supplied DNS, so host the A-record at a public provider (Cloudflare,
Route 53) any router can resolve.

Wait ~10 s for the reboot, reconnect the laptop to your normal WiFi, run
`discover` again — the module should now show up at a `192.168.x.y` IP.

### Snapshot the current settings

```bash
ruby tools/reprovision.rb show 192.168.x.y
```

Writes a JSON file under `_data/snapshots/` (the exact path is printed
at the end of `show` output — copy it for `rollback`). Holds the verbatim
`AT+NETP=…` plus everything else. **This is your one-command rollback
target** — `repoint`, `set-wifi`, and `rollback` all refuse to run
without a recent snapshot existing first.

> Snapshots include the raw WiFi PSK. The file lives under `_data/`
> which is `.gitignored` — don't move it elsewhere without checking it
> stays ignored.

### Run the emulator

Production (Pi via Docker):

```bash
git clone <repo-url> ~/poolpump
cd ~/poolpump
# Create .env from .env.template — at minimum POOLPUMP_DEVICE_IP
docker compose up -d --build
docker compose logs -f poolpump-emulator
```

Dev host (high port, no `sudo`):

```bash
MODBUS_PORT=5020 HTTP_PORT=8090 bundle exec bin/poolpump-emulator
```

Smoke test before pointing the pump at it:

```bash
curl http://localhost:8090/healthz
# → {"connected":false,"last_seen_ago":null,...}  ← no module yet
```

### Point the pump at the emulator

**Path A — DNS indirection (recommended).** If you commissioned the
module against a hostname you control, the cutover is one A-record edit.
The current TCP session keeps using the old resolved IP until it drops;
new sessions resolve the new one. To force the cutover, stop the old
emulator — the module's `AT+TCPTO` (default 300 s) reconnect timer fires
and lands on the new host within seconds.

**Path B — repoint directly.** No DNS layer:

```bash
ruby tools/reprovision.rb show <pump-ip>            # snapshot first
ruby tools/reprovision.rb repoint <pump-ip> \
  --server-hostname <server-hostname> --port 502
```

`repoint` writes NETP, verifies, fires `AT+Z`. Each `AT+Z` reboot is a
chance for the STA-rejoin path to wedge for a few minutes — that's
exactly why DNS indirection (Path A) is preferred once you're past first
commission.

> **Don't run two `reprovision.rb` invocations against the same module
> at the same time** — the HF firmware tracks command-mode state per UDP
> source port and the second one will get `+ERR=-1` on everything past
> the handshake.

### Verify end-to-end

```bash
curl http://<pi-ip>:8090/healthz             # connected:true after pump
curl http://<pi-ip>:8090/                    # current snapshot
curl -X POST -d on http://<pi-ip>:8090/      # turn pump on
curl -X POST -d "settemp 28" http://<pi-ip>:8090/
```

Each control command should round-trip in 2–3 s. Listen for the pump and
watch the panel — first real round-trip.

### Rollback

```bash
ruby tools/reprovision.rb rollback <pump-ip> \
  --from /absolute/path/to/<pump-ip>-<fingerprint>-<ts>.json
# Use the exact path printed at the end of `show` output. NEVER use a
# shell wildcard — multiple snapshots may match and the CLI refuses if
# more than one is supplied.
```

Puts NETP back at whatever the most-recent snapshot captured (typically
the previous server, or the original Chinese cloud if you snapshotted
very early). If you used DNS indirection, just flip the A-record — the
pump disconnects on TCP error and falls into reconnect-retry until
something answers.

---

## Debugging

Two reasons to come here:

1. Your module reports a hostname *other* than `DOTELS-SWP` and the
   register addresses don't match — you'll need to re-decode the
   protocol against your firmware variant.
2. Something's misbehaving (pump went silent, `commission` fails on
   verify, `+ERR=-N` codes, etc.) and you want to know what to try.

### Cloud baseline (read-only oracle)

Before redirecting the module, capture a few JSON snapshots from the
still-alive Chinese cloud at `fzdbiology.com:8080`. The cloud knows
every field name the device exposes plus (if your module is currently
online) the live values. Diffing two snapshots either side of a panel
toggle gives you confirmed mappings like *"pressing heat-mode changed
`model` from 4→2"* — ground-truth for cross-referencing the sniffer's
wire bytes against field names.

Read-only by design — only `loginUser` + `getRtuRealTime`. State changes
happen on the panel, not via cloud commands.

```bash
# 1. Add credentials to .env (gitignored — see .env.template):
#    POOLPUMP_CLOUD_EMAIL, POOLPUMP_CLOUD_PASSWORD, POOLPUMP_CLOUD_RTU_ID

# 2. Capture and diff
ruby tools/cloud_probe.rb login                  # smoke-test creds
ruby tools/cloud_probe.rb status                 # baseline → _data/
ruby tools/cloud_probe.rb watch --interval 5     # poll while toggling
ruby tools/cloud_probe.rb diff <a.json> <b.json> # see what changed
```

If `status` returns empty / "OFFLINE", the module isn't reaching the
cloud — confirms why you're cutting the cord (the field vocabulary is
still useful). If `status` returns rich data, the module IS still
reaching the cloud from this LAN — failure mode is reliability, not
reachability.

### Re-running the protocol decode (sniff + cloud-replay)

Stop the production emulator, run the active sniffer in its place — the
module reconnects to whatever's listening on the port it was pointed at,
no NETP change required:

```bash
PORT=5020 ruby tools/sniff.rb
```

Two firewall gotchas that will eat hours if you don't know them:

- **macOS:** System Settings → Network → Firewall → "Allow incoming
  connections" for `ruby`. Without this the module sends SYN, never
  gets SYN-ACK, and the sniffer stays silent — looks identical to
  "module is offline" in the logs.
- **Linux:** if `ufw` / `firewalld` is on, allow inbound TCP/5020
  (later TCP/502 + TCP/8090 for the production emulator).

If the module isn't already pointed at this host, repoint it:

```bash
ruby tools/reprovision.rb repoint 192.168.x.y \
  --server-hostname <sniffer-hostname> --port 5020
```

Within ~10 s the sniffer should print `ACCEPT 192.168.x.y:<port>` and
start hex-dumping FC=0x10 telemetry frames every couple of seconds.

### Control-model probe

After ~30 s of stable telemetry, kill the sniffer and restart it with
the probe flag — answers "does the device respond to master-side reads,
or do we have to derive state from its pushes?":

```bash
PORT=5020 ruby tools/sniff.rb --probe-fc03 0,1
```

Wait for the `CONTROL-MODEL OUTCOME A/B/C` line:

- **A** — device replied to FC=0x03. Master polling works.
- **B** — device ignored the probe. Derive state from pushes only
  (default).
- **C** — device returned an exception. Same as B but watch for refused
  writes.

The DOTELS-SWP firmware lands on **B** — the emulator already assumes
that.

### Cloud-replay (decoding control commands)

The other half: connect to `fzdbiology.com:502` pretending to be the
device (using its real MAC), then have the OEM iOS app installed on a
phone and tap things. Every button press becomes a 12-byte FC=0x06 frame
on your replay socket — line up "I pressed boost" against
`addr=0x07d2 value=0x0400` to nail down each register's meaning.

```bash
ruby tools/cloud_replay.rb --duration 600       # 10-minute capture
```

That's how the existing register map at addr 2000-2006 was decoded.

### Validating sensor addresses against the manual's PQ table

The read-only sensor addresses (TEMP_AMBIENT/INLET/OUTLET,
COMPRESSOR_RATE, STATUS_WATERPUMP, STATUS_OPERATION) are `:CONFIRMED`
against the manual's PQ Parameter Table at register block 300 plus the
`water_io` block at 1000. The fault aggregator (`pa13`, addr 500) is
still `:HYPOTHESIZED` — bit-by-bit decoding to map P01-P11 / E01-E51
needs a no-fault baseline (pool refilled) to diff against the current
P01 capture. Workflow:

```bash
ruby tools/sniff.rb > _data/baseline.log
# Toggle one setting at a time on the panel, ~20 s between presses for
# a full telemetry cycle.
ruby tools/decode_telemetry.rb diff \
  _data/baseline.log _data/after.log
# → register addresses where values changed, before/after
```

When you find a register whose value tracks a known physical sensor
(e.g. ambient drops at sundown), update its `read_address` in
`DEFINITIONS` and bump `confidence:` from `:HYPOTHESIZED` to
`:CONFIRMED`. Once everything's confirmed you can also set
`POOLPUMP_STRICT=1` to refuse writes to any remaining hypothesized
registers.

### When things go wrong

- **`+ERR=-1` from the module on AT commands** — usually a session/order
  issue. Either you opened a new UDP socket per command (don't — single
  session, one handshake, then N AT commands), or you tried
  `AT+WMODE=STA` before writing valid WiFi creds. `commission` does the
  right thing automatically.
- **`+ERR=-9` on `AT+NETP`** — "command not allowed in current state",
  the WiFi-reconfigure FSM is busy. The 1000 ms inter-command delay in
  `reprovision.rb` (matching the OEM Android app) usually prevents this;
  if you hit it, retry after a few seconds.
- **`commission` aborts with "verify failed for AT+WMODE: expected STA,
  got APSTA"** — fixed in code: `semantic_equal?` accepts APSTA as
  satisfying a STA request, because the OEM firmware keeps the AP
  interface up while you're still talking to it via SoftAP and only
  drops it on the post-`AT+Z` reboot.
- **Pump connects to the emulator (TCP ESTABLISHED) but sends zero
  bytes** — the firmware's application FSM has wedged. Soft remedies
  don't help; only a physical power-cycle clears it.
- **Pump reboots after a click in the HF-LPB130 web UI on `:80`** —
  that's the "Save & Reboot" button, not a crash. Page returns
  保存成功！请等待设备重启完成。 ("Save successful — wait for device to
  finish rebooting"). Ping disappears for ~30-90 s. If it doesn't come
  back in 5 min, power-cycle.
- **Stale-socket close in the emulator log** — full telemetry cycle is
  ~17 s. Watchdog is `DEFAULT_STALE_BEFORE_HANDSHAKE_SEC = 60` and
  `DEFAULT_STALE_AFTER_HANDSHAKE_SEC = 300` (in
  `server/lib/poolpump/pump_session.rb`). Bump if your environment is
  noisy — no env override today.
- **HTTP `POST /<verb>` returns `echo-timeout`** — the emulator's
  `dispatch_pending` waits for the device to echo our FC=0x06 within
  the HTTP deadline (3 s by default). 99% of the time you see ~150 ms;
  if the pump is silent (see above) the deadline fires.
- **DNS-pointed hostname doesn't resolve from the pump** — HF-LPB130
  honours DHCP DNS only. If your A-record lives at a provider your
  router doesn't query, the pump silently fails to connect. Host the
  A-record at a public resolver (Cloudflare, Route 53).
