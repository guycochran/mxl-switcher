#!/usr/bin/env bash
set -euo pipefail

# Reproducible same-host CPU comparison for a switcher whose working video
# format is 1920x1080p30 v210. The NDI phase includes the full usable boundary:
# encode, receive/decode, convert back to v210, publish to MXL, then attach the
# same MXL readers used in the native phase. It never touches an existing MXL
# domain or container outside the exact mxl-transport-benchmark-* namespace.
#
# Required:
#   NDI_CONFIG=/path/to/ndi-config.v1.json/directory \
#     ./tools/benchmark_mxl_vs_ndi.sh
# Optional: DURATION=60 WARMUP=15 INTERVAL=2 FANOUTS="1 2" IMAGE=...

DURATION="${DURATION:-60}"
WARMUP="${WARMUP:-15}"
INTERVAL="${INTERVAL:-2}"
FANOUTS="${FANOUTS:-1 2}"
IMAGE="${IMAGE:-mxl-lab:latest}"
NDI_CONFIG="${NDI_CONFIG:?set NDI_CONFIG to the directory containing ndi-config.v1.json}"
ROOT="${ROOT:-${PWD}/mxl-transport-benchmark}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
EVIDENCE="$ROOT/evidence-$STAMP"
DOMAIN="/dev/shm/mxl-transport-benchmark-$STAMP"
MXL_DOMAIN="$DOMAIN/mxl-domain"
FRAMES="$DOMAIN/source-frames"
PREFIX="mxl-transport-benchmark"
FLOW_ID="${FLOW_ID:-$(python3 -c 'import uuid; print(uuid.uuid4())')}"
NDI_BRIDGE_FLOW="${NDI_BRIDGE_FLOW:-$(python3 -c 'import uuid; print(uuid.uuid4())')}"
NDI_SHORT_NAME="MXL-NDI-CPU-BENCH-$STAMP"

mkdir -p "$EVIDENCE" "$DOMAIN" "$MXL_DOMAIN" "$FRAMES"
printf '%s\n' "$EVIDENCE" > /tmp/mxl-transport-benchmark-active
printf '%s\n' "$$" > /tmp/mxl-transport-benchmark.pid
printf 'timestamp,phase,fanout,container,cpu_percent,memory_usage\n' > "$EVIDENCE/resources.csv"

phase_names=()

cleanup_phase() {
  if ((${#phase_names[@]})); then
    for name in "${phase_names[@]}"; do
      docker logs "$name" > "$EVIDENCE/${name}.log" 2>&1 || true
    done
    docker rm -f "${phase_names[@]}" >/dev/null 2>&1 || true
  fi
  phase_names=()
}

cleanup_all() {
  rc=$?
  cleanup_phase
  printf '%s\n' "$rc" > "$EVIDENCE/exit-status.txt"
  rm -f /tmp/mxl-transport-benchmark.pid
  docker run --rm -v "$DOMAIN:/domain" --entrypoint sh alpine:3.20 -c 'rm -rf /domain/*' >/dev/null 2>&1 || true
  rmdir "$DOMAIN" 2>/dev/null || true
}
trap cleanup_all EXIT

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ "$DURATION" =~ ^[1-9][0-9]*$ ]] || die "DURATION must be a positive integer"
[[ "$WARMUP" =~ ^[0-9]+$ ]] || die "WARMUP must be a non-negative integer"
[[ -d "$NDI_CONFIG" ]] || die "NDI config directory is missing: $NDI_CONFIG"

mapfile -t stale_containers < <(docker ps -aq --filter "name=^/${PREFIX}-")
if ((${#stale_containers[@]})); then
  docker rm -f "${stale_containers[@]}" >/dev/null
fi

sample_phase() {
  local phase="$1" fanout="$2" started
  started="$(date +%s)"
  while (( $(date +%s) - started < DURATION )); do
    local now name cpu mem
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    for name in "${phase_names[@]}"; do
      [[ "$(docker inspect -f '{{.State.Status}}|{{.RestartCount}}' "$name" 2>/dev/null || true)" == "running|0" ]] || die "$name stopped or restarted"
    done
    while IFS='|' read -r name cpu mem; do
      [[ -n "$name" ]] || continue
      printf '%s,%s,%s,%s,%s,%s\n' "$now" "$phase" "$fanout" "$name" "${cpu%%%}" "$mem" >> "$EVIDENCE/resources.csv"
    done < <(docker stats --no-stream --format '{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}' "${phase_names[@]}")
    sleep "$INTERVAL"
  done
}

validate_readers() {
  local phase="$1" fanout="$2" idx name line drops rendered current average steady
  for idx in $(seq 1 "$fanout"); do
    name="${PREFIX}-${phase}-reader-${fanout}-${idx}"
    line="$(docker logs "$name" 2>&1 | grep 'last-message = rendered:' | tail -n 1 || true)"
    drops="$(sed -n 's/.*dropped: \([0-9][0-9]*\).*/\1/p' <<<"$line")"
    rendered="$(sed -n 's/.*rendered: \([0-9][0-9]*\).*/\1/p' <<<"$line")"
    current="$(sed -n 's/.*current: \([0-9.][0-9.]*\).*/\1/p' <<<"$line")"
    average="$(sed -n 's/.*average: \([0-9.][0-9.]*\).*/\1/p' <<<"$line")"
    steady="$(docker logs "$name" 2>&1 | grep 'last-message = rendered:' | tail -n 10 | sed -n 's/.*current: \([0-9.][0-9.]*\).*/\1/p' | sort -n | awk '{a[NR]=$1} END {if (!NR) print 0; else if (NR%2) print a[(NR+1)/2]; else printf "%.2f\n", (a[NR/2]+a[NR/2+1])/2}')"
    printf '%s,%s,%s,%s,%s,%s,%s,%s\n' "$phase" "$fanout" "$idx" "${rendered:-0}" "${drops:-unknown}" "${current:-0}" "${average:-0}" "${steady:-0}" >> "$EVIDENCE/readers.csv"
    [[ -n "$line" && "$drops" == "0" ]] || die "$name did not deliver clean video"
    awk -v rate="${steady:-0}" 'BEGIN { exit !(rate >= 28.0 && rate <= 32.0) }' || die "$name steady-state rate was outside 28-32 fps: ${steady:-missing}"
  done
}

printf 'phase,fanout,reader,rendered,dropped,current_fps,average_fps,steady_median_fps\n' > "$EVIDENCE/readers.csv"

# Generate the moving source once, before measurement. Replaying these exact
# v210 frames prevents single-core test-pattern rendering from becoming the
# bottleneck and gives both phases identical source pixels.
docker run --rm -v "$FRAMES:/frames" --entrypoint gst-launch-1.0 "$IMAGE" -q \
  videotestsrc num-buffers=60 pattern=ball \
  '!' video/x-raw,width=1920,height=1080,framerate=30/1,format=v210 \
  '!' multifilesink location=/frames/frame-%02d.v210

run_mxl() {
  local fanout="$1" producer idx reader
  producer="${PREFIX}-mxl-producer-${fanout}"
  phase_names=("$producer")
  docker run -d --name "$producer" -v "$MXL_DOMAIN:/mxl-domain" -v "$FRAMES:/frames:ro" \
    --entrypoint gst-launch-1.0 "$IMAGE" -e \
    multifilesrc loop=true start-index=0 stop-index=59 location=/frames/frame-%02d.v210 \
    '!' rawvideoparse format=v210 width=1920 height=1080 framerate=30/1 \
    '!' identity sync=true \
    '!' mxlsink domain=/mxl-domain flow-id="$FLOW_ID" sync=false >/dev/null
  sleep 4
  for idx in $(seq 1 "$fanout"); do
    reader="${PREFIX}-mxl-reader-${fanout}-${idx}"
    phase_names+=("$reader")
    docker run -d --name "$reader" -v "$MXL_DOMAIN:/mxl-domain" \
      --entrypoint gst-launch-1.0 "$IMAGE" -v \
      mxlsrc domain=/mxl-domain video-flow-id="$FLOW_ID" \
      '!' fpsdisplaysink video-sink=fakesink text-overlay=false sync=false fps-update-interval=1000 >/dev/null
  done
  sleep "$WARMUP"
  sample_phase mxl "$fanout"
  validate_readers mxl "$fanout"
  cleanup_phase
  docker run --rm -v "$MXL_DOMAIN:/domain" --entrypoint sh alpine:3.20 -c 'rm -rf /domain/*'
}

run_ndi() {
  local fanout="$1" producer bridge idx reader sender_name
  producer="${PREFIX}-ndi-producer-${fanout}"
  phase_names=("$producer")
  docker run -d --name "$producer" --network host -v "$NDI_CONFIG:/root/.ndi:ro" -v "$FRAMES:/frames:ro" \
    --entrypoint gst-launch-1.0 "$IMAGE" -e \
    multifilesrc loop=true start-index=0 stop-index=59 location=/frames/frame-%02d.v210 \
    '!' rawvideoparse format=v210 width=1920 height=1080 framerate=30/1 \
    '!' identity sync=true \
    '!' videoconvert '!' video/x-raw,format=UYVY \
    '!' ndisink ndi-name="$NDI_SHORT_NAME" sync=false >/dev/null
  sleep 5
  sender_name="$(docker exec "$producer" hostname | tr '[:lower:]' '[:upper:]') ($NDI_SHORT_NAME)"
  printf 'ndi_sender_name=%s\n' "$sender_name" >> "$EVIDENCE/environment.txt"
  bridge="${PREFIX}-ndi-bridge-${fanout}"
  phase_names+=("$bridge")
  docker run -d --name "$bridge" --network host \
    -v "$NDI_CONFIG:/root/.ndi:ro" -v "$MXL_DOMAIN:/mxl-domain" \
    --entrypoint gst-launch-1.0 "$IMAGE" -e \
    ndisrc ndi-name="$sender_name" receiver-ndi-name="MXL-NDI-BENCH-BRIDGE-${fanout}" timestamp-mode=receive-time \
    '!' ndisrcdemux name=d d.video '!' queue max-size-buffers=4 leaky=downstream \
    '!' videoscale add-borders=true \
    '!' video/x-raw,width=1920,height=1080,pixel-aspect-ratio=1/1 \
    '!' videoconvert '!' video/x-raw,format=v210 \
    '!' videorate '!' video/x-raw,framerate=30/1 \
    '!' mxlsink domain=/mxl-domain flow-id="$NDI_BRIDGE_FLOW" >/dev/null
  sleep 5
  for idx in $(seq 1 "$fanout"); do
    reader="${PREFIX}-ndi-reader-${fanout}-${idx}"
    phase_names+=("$reader")
    docker run -d --name "$reader" -v "$MXL_DOMAIN:/mxl-domain" \
      --entrypoint gst-launch-1.0 "$IMAGE" -v \
      mxlsrc domain=/mxl-domain video-flow-id="$NDI_BRIDGE_FLOW" \
      '!' fpsdisplaysink video-sink=fakesink text-overlay=false sync=false fps-update-interval=1000 >/dev/null
  done
  sleep "$WARMUP"
  sample_phase ndi "$fanout"
  validate_readers ndi "$fanout"
  cleanup_phase
  docker run --rm -v "$MXL_DOMAIN:/domain" --entrypoint sh alpine:3.20 -c 'rm -rf /domain/*'
}

{
  printf 'date_utc=%s\n' "$STAMP"
  printf 'host_cpu=%s\n' "$(lscpu | sed -n 's/^Model name:[[:space:]]*//p' | head -n 1)"
  printf 'logical_cpus=%s\n' "$(nproc)"
  printf 'image=%s\n' "$IMAGE"
  printf 'kernel=%s\n' "$(uname -r)"
  printf 'mxl_plugin=%s\n' "$(docker run --rm --entrypoint gst-inspect-1.0 "$IMAGE" mxlsrc 2>/dev/null | sed -n 's/^  Version[[:space:]]*//p' | head -n 1)"
  printf 'ndi_plugin=%s\n' "$(docker run --rm --entrypoint gst-inspect-1.0 "$IMAGE" ndisrc 2>/dev/null | sed -n 's/^  Version[[:space:]]*//p' | head -n 1)"
  printf 'resolution=1920x1080\nframe_rate=30/1\nsource_format=v210\nsource_frames=60-pre-generated-moving-frames\nndi_wire_input=UYVY\n'
  printf 'duration_seconds=%s\nwarmup_seconds=%s\nsample_interval_seconds=%s\n' "$DURATION" "$WARMUP" "$INTERVAL"
} > "$EVIDENCE/environment.txt"

for fanout in $FANOUTS; do
  run_mxl "$fanout"
  sleep 5
  run_ndi "$fanout"
  sleep 5
done

printf 'completed=true\n' > "$EVIDENCE/summary.txt"
printf 'Evidence: %s\n' "$EVIDENCE"
