#!/usr/bin/env bash
# mxl-selfheal.sh — a portable self-healer for the quickstart MXL switcher.
#
# Opt-in. quickstart.sh does NOT start this by default. Set MXL_SELFHEAL=1 when
# launching quickstart (or run this script yourself) to enable the watcher.
#
# The bare adopter stack has no watchdog. Across a long session two failures can
# black out the program with no automatic recovery:
#
#   1. SELECTOR DOWN — the input-selector pipeline stops (running:false, inputs:[]),
#      so every cut returns 409 "not attached" and the program freezes.
#   2. RELAY WAITING FOR AUDIO — mxl2webrtc defaults to mode:video+audio and waits
#      forever for an audio_pgm flow that a bare quickstart never starts, so the
#      WebRTC program monitor shows "stream not found" even though video exists.
#   3. SELECTOR WEDGED ON A GRAIN-TIMING ERROR — the selector reports running:true but
#      parks "read source grain N: Out of range - too late" from a jittery/relayed/
#      framerate-mismatched source, and every subsequent cut 415-rejects (PGM frozen).
#      We re-cut to a live source so the selector re-grabs from the current write head —
#      the "re-sync instead of die" strategy SwitchFrame's MXL reader uses.
#
# This watcher polls the LOCAL control ports (no external backend) and fixes
# exactly those two, idempotently. Safe to run as a plain loop, a systemd unit, or
# a cron. It only ever acts when something is actually broken.
#
#   tools/mxl-selfheal.sh            # one check+heal pass, then exit
#   tools/mxl-selfheal.sh --watch    # loop every MXL_SELFHEAL_INTERVAL (default 15s)
#   sudo MXL_SELFHEAL=1 scripts/quickstart.sh   # start watcher with the lab
#
# Config (env):
#   MXL_FACILITY_JSON   manifest with the selector inputs to restore (the one
#                       quickstart generated); else falls back to re-discovery.
#   MXL_SELFHEAL_INTERVAL   seconds between --watch passes (default 15)
#   SELECTOR_CONTAINER      default input-selector
#   RELAY_CONTAINER         default mxl2webrtc
set -u

INTERVAL="${MXL_SELFHEAL_INTERVAL:-15}"
SEL_CTR="${SELECTOR_CONTAINER:-input-selector}"
RELAY_CTR="${RELAY_CONTAINER:-mxl2webrtc}"
DOMAIN="${MXL_DOMAIN:-/mxl-domain}"
KEYER_FLOW=""   # discovered lazily

# Use `docker` directly if we can (quickstart runs as root), else `sudo docker`.
if docker ps >/dev/null 2>&1; then DOCKER="docker"; else DOCKER="sudo docker"; fi

# Runtime flow-UUID discovery (flow_by_role / advancing by role) — portable, no hardcoded ids.
_here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$_here/mxl-flows.sh" 2>/dev/null || true

log(){ printf '%s mxl-selfheal: %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }
_get(){ curl -s -m 5 "http://127.0.0.1:$1$2" 2>/dev/null; }
_post(){ curl -s -m 25 -X POST -H 'Content-Type: application/json' -d "$3" "http://127.0.0.1:$1$2" 2>/dev/null; }
_json(){ python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('$1',''))" 2>/dev/null; }
# head index of a flow uuid (empty if unreadable), and a 1s advancing check.
headidx(){ $DOCKER exec "$SEL_CTR" sh -c "/opt/mxl/tools/mxl-info/mxl-info -d $DOMAIN -f $1 2>/dev/null" 2>/dev/null | grep -i 'Head index' | grep -oE '[0-9]+' | head -1; }
advancing(){ _a=$(headidx "$1"); sleep 1; _b=$(headidx "$1"); [ -n "$_a" ] && [ -n "$_b" ] && [ "$_b" -gt "$_a" ] 2>/dev/null; }

# UUIDs that actually exist in the domain right now (one per line).
existing_flows(){
  $DOCKER exec "$SEL_CTR" sh -c "/opt/mxl/tools/mxl-info/mxl-info -d $DOMAIN -l" 2>/dev/null \
    | grep -oE '[0-9a-f-]{36}' | sort -u
}

# selector inputs to restore: the manifest's inputs INTERSECTED with the flows that
# actually exist. Restarting with a flow that isn't present makes the selector start
# FAIL (found on HW — the manifest lists 4, but a fresh/partial facility may have
# only 2), so we must never wire a phantom flow. Falls back to the two base sources
# by label if no manifest is given.
selector_inputs_json(){
  local present; present=$(existing_flows)
  [ -n "$present" ] || return 1   # can't read the domain — don't guess
  if [ -n "${MXL_FACILITY_JSON:-}" ] && [ -f "$MXL_FACILITY_JSON" ]; then
    MXL_PRESENT="$present" python3 - "$MXL_FACILITY_JSON" <<'PY' 2>/dev/null && return 0
import json, os, sys
d = json.load(open(sys.argv[1]))
vf = d.get("video_flows", {})
roles = d.get("program", {}).get("selector_inputs") or d.get("program", {}).get("layout_inputs") or []
present = set(os.environ.get("MXL_PRESENT", "").split())
uuids = [vf[r]["uuid"] for r in roles if r in vf and vf[r]["uuid"] in present]
# only emit if we found at least one real, present source
if uuids:
    print(json.dumps(uuids))
else:
    sys.exit(1)
PY
  fi
  # fallback: discover pattern + clip by label, keep only the present ones
  local pat clip out=()
  pat=$($DOCKER exec "$SEL_CTR" sh -c "/opt/mxl/tools/mxl-info/mxl-info -d $DOMAIN -l" 2>/dev/null \
    | grep -E "^\s+Video : [0-9a-f-]{36} - Pattern Video\$" | grep -oE '[0-9a-f-]{36}' | head -1)
  clip=$($DOCKER exec "$SEL_CTR" sh -c "/opt/mxl/tools/mxl-info/mxl-info -d $DOMAIN -l" 2>/dev/null \
    | grep -E "^\s+Video : [0-9a-f-]{36} - Clip Video\$" | grep -oE '[0-9a-f-]{36}' | head -1)
  for u in "$pat" "$clip"; do
    [ -n "$u" ] && printf '%s\n' "$present" | grep -qx "$u" && out+=("$u")
  done
  [ ${#out[@]} -gt 0 ] && printf '[%s]' "$(printf '"%s",' "${out[@]}" | sed 's/,$//')"
}

keyer_out_flow(){
  [ -n "$KEYER_FLOW" ] && { printf '%s' "$KEYER_FLOW"; return; }
  KEYER_FLOW=$($DOCKER exec "$SEL_CTR" sh -c "/opt/mxl/tools/mxl-info/mxl-info -d $DOMAIN -l" 2>/dev/null \
    | grep -E "^\s+Video : [0-9a-f-]{36} - Keyer PGM\$" | grep -oE '[0-9a-f-]{36}' | head -1)
  printf '%s' "$KEYER_FLOW"
}

# ── heal 1: selector down → restart with its inputs + re-cut to slot 0 ──────────
heal_selector(){
  local st running
  st=$(_get 9604 /pipeline/status) || return 0
  running=$(printf '%s' "$st" | _json running)
  [ "$running" = "True" ] && return 0   # healthy
  local inputs; inputs=$(selector_inputs_json)
  [ -n "$inputs" ] || { log "selector down but no inputs to restore (manifest + discovery empty) — skipping"; return 0; }
  log "SELECTOR DOWN (running=$running) — restarting with inputs $inputs"
  _post 9604 /pipeline/start "{\"domain_path\":\"$DOMAIN\",\"input_flow_uuids\":$inputs,\"grouphint\":\"Input-Selector\",\"description\":\"program out\",\"label\":\"Selector PGM\"}" >/dev/null
  sleep 2
  _post 9604 /pipeline/active-input '{"slot":0}' >/dev/null
  log "selector restarted"
}

# ── heal 2: relay waiting for audio → (re)start it video-only ───────────────────
heal_relay(){
  local st running mode
  st=$($DOCKER exec "$RELAY_CTR" sh -c "curl -s -m5 http://127.0.0.1:9600/pipeline/status" 2>/dev/null) || return 0
  running=$(printf '%s' "$st" | _json running)
  mode=$(printf '%s' "$st" | _json mode)
  # broken state = not running, OR running in a mode that waits for an absent audio flow
  if [ "$running" = "True" ] && [ "$mode" = "video" ]; then return 0; fi
  local key; key=$(keyer_out_flow)
  [ -n "$key" ] || { log "relay unhealthy but keyer flow not found yet — skipping"; return 0; }
  log "RELAY unhealthy (running=$running mode=$mode) — restarting VIDEO-ONLY on keyer $key"
  $DOCKER exec "$RELAY_CTR" sh -c "curl -s -m5 -X POST http://127.0.0.1:9600/pipeline/stop >/dev/null; sleep 1; \
    curl -s -m8 -X POST -H 'Content-Type: application/json' \
    -d '{\"domain_path\":\"$DOMAIN\",\"video_flow_uuid\":\"$key\",\"audio_flow_uuid\":null,\"mode\":\"video\"}' \
    http://127.0.0.1:9600/pipeline/start >/dev/null" 2>/dev/null
  log "relay restarted video-only"
}

# ── heal 3: selector WEDGED on a grain-timing error → re-sync (don't die) ───────
# The CBC input-selector reports `running:true` but parks an error like
#   "read source grain 53749…: Out of range - too late"
# when its active source delivers a grain outside the readable window (a jittery /
# relayed / framerate-mismatched source — HW Oct: PTZ over the Azure relay wedged it
# on every cut; all further cuts 415-reject and PGM freezes). The selector does NOT
# self-recover — but re-cutting the active input makes it re-grab from the CURRENT
# write head, exactly the "re-sync to head instead of dying" strategy SwitchFrame's
# MXL reader uses (server/mxl/reader.go: "On 'too late' errors, re-sync to the
# current write head instead of dying"). We can't patch CBC's Rust, so we apply the
# same idea at our layer: on a too-late error, re-cut to a VERIFIED-ADVANCING slot
# (prefer the one it's already on if that's live, else the first advancing source).
_wedge_last_heal=0
heal_selector_wedge(){
  local st err active uuids
  st=$(_get 9604 /pipeline/status); [ -n "$st" ] || return 0
  err=$(printf '%s' "$st" | _json error)
  # only the grain-timing wedge — leave other errors to heal_selector / operators
  case "$err" in
    *"Out of range"*|*"too late"*|*"too early"*) : ;;
    *) return 0 ;;
  esac
  local now; now=$(date +%s)
  [ $((now - _wedge_last_heal)) -lt 20 ] && return 0   # brief cooldown; one re-sync per ~20s
  # the slot list + current active, to choose a live re-cut target
  uuids=$(printf '%s' "$st" | python3 -c "import sys,json;print(' '.join(json.load(sys.stdin).get('input_flow_uuids',[])))" 2>/dev/null)
  active=$(printf '%s' "$st" | _json active_input)
  log "SELECTOR WEDGED (error: $err) — re-syncing (re-cut to a live source)"
  # pick a target: first slot whose flow is ADVANCING. Walk from slot 0 so the
  # always-on Pattern/Playout are the guaranteed fallback; prefer a non-active live
  # slot so we actually move off the stuck source if it's the dead one.
  local idx=0 target="" i=0
  for u in $uuids; do
    if advancing "$u"; then target=$i; [ "$i" != "$active" ] && break; fi
    i=$((i+1))
  done
  [ -n "$target" ] || target=0
  # re-cut: this forces the selector router to re-attach the slot from the live head.
  _post 9604 /pipeline/active-input "{\"slot\":$target}" >/dev/null
  _wedge_last_heal=$now
  # verify it cleared
  sleep 1
  local e2; e2=$(_get 9604 /pipeline/status | _json error)
  case "$e2" in
    *"Out of range"*|*"too late"*|*"too early"*)
      log "still wedged after re-cut to slot $target — leaving for next pass" ;;
    *) log "selector re-synced (cut to slot $target, error cleared)" ;;
  esac
}

pass(){ heal_selector; heal_selector_wedge; heal_relay; }

if [ "${1:-}" = "--watch" ]; then
  log "watching (every ${INTERVAL}s) — selector down + selector wedge (too-late re-sync) + relay"
  while :; do pass; sleep "$INTERVAL"; done
else
  pass
fi
