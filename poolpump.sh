#!/bin/bash
# Thin CLI shim around the local poolpump-emulator HTTP API on port 8090.
# Same verb surface as the legacy script, just no cloud round-trip.

set -e

if [ $# -lt 1 ]; then
  echo "*** Usage: $(basename "$0") (status|raw|on|off|mode-boost|mode-silent|mode-auto|watertemp|settemp|setmode|reboot|health) [newtemp|newmode]"
  exit 1
fi

# Resolve target host. Auto-sources .env from this script's directory so
# the same vars docker compose reads also drive this script — no separate
# config to maintain. Override priority:
#   1. POOLPUMP_HOST=host:port    (explicit; wins over everything)
#   2. MODBUS_HOST_BIND + HTTP_HOST_PORT  (from .env — same vars compose uses)
#   3. localhost:8090             (fallback for "I'm on the same host as the container")
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SCRIPT_DIR/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/.env"
  set +a
fi
if [ -z "${POOLPUMP_HOST:-}" ]; then
  bind="${MODBUS_HOST_BIND:-}"
  port="${HTTP_HOST_PORT:-8090}"
  # 0.0.0.0 means "all interfaces" — for client-side queries that's just localhost.
  if [ -z "$bind" ] || [ "$bind" = "0.0.0.0" ]; then
    bind="localhost"
  fi
  POOLPUMP_HOST="${bind}:${port}"
fi
URL="http://${POOLPUMP_HOST}"

# Expect 200 on success, anything else surfaces the body for triage.
function check_response() {
  local body="$1" code="$2"
  if [ "$code" != "200" ]; then
    echo >&2 "API call failed (HTTP $code)"
    echo >&2 "$body"
    exit 1
  fi
}

function get_status() {
  local body
  body=$(curl -sS -m 5 -w '\n__HTTP__%{http_code}' "$URL/")
  local http=${body##*__HTTP__}; body=${body%$'\n__HTTP__'*}
  check_response "$body" "$http"
  echo "$body"
}

function post_verb() {
  local verb="$1"
  local body
  body=$(curl -sS -m 8 -X POST --data "$verb" -w '\n__HTTP__%{http_code}' "$URL/")
  local http=${body##*__HTTP__}; body=${body%$'\n__HTTP__'*}
  check_response "$body" "$http"
  echo "$body"
}

case "$1" in
  status)
    # Pretty-print via jq for readability — the fields list is now wide
    # enough (16+ entries including AC_VOLTAGE/CURRENT/POWER_ESTIMATE_W)
    # that an unformatted blob is hard to scan. `jq .` adds nothing else,
    # just indentation.
    get_status | jq .
    ;;

  watertemp)
    get_status | jq .TEMP_INLET
    ;;

  on|off|mode-boost|mode-silent|mode-auto)
    post_verb "$1"
    ;;

  reboot)
    # Soft-reboot the WiFi module via the emulator's POST /reboot route
    # (AT+Z double-send recipe). Subject to cooldown + daily-cap.
    body=$(curl -sS -m 8 -X POST -w '\n__HTTP__%{http_code}' "$URL/reboot")
    http=${body##*__HTTP__}; body=${body%$'\n__HTTP__'*}
    case "$http" in
      200) echo "$body" ;;
      429) echo >&2 "reboot rejected (cooldown or daily cap)"; echo "$body" ;;
      503) echo >&2 "reboot not configured (POOLPUMP_DEVICE_IP not set on the emulator)"; echo "$body"; exit 1 ;;
      *)   echo >&2 "reboot failed (HTTP $http)"; echo "$body"; exit 1 ;;
    esac
    ;;

  settemp)
    if [[ -z "$2" || $2 -lt 1 ]]; then echo "Need temperature as 2nd arg"; exit 1; fi
    post_verb "settemp $2"
    ;;

  setmode)
    case "$2" in
      auto|cool|heat) post_verb "setmode $2" ;;
      *) echo "Allowed modes: auto cool heat"; exit 1 ;;
    esac
    ;;

  raw)
    curl -sS "$URL/raw"
    ;;

  health|healthz)
    curl -sS "$URL/healthz" | jq
    ;;

  *)
    echo "*** Unknown verb: $1"
    exit 1
    ;;
esac
