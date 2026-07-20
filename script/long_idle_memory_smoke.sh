#!/usr/bin/env bash
set -euo pipefail

APP_NAME="MeetingVault"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="$ROOT_DIR/dist/release/$APP_NAME.app"
DATE="$(date +%F)"
OUTPUT="$ROOT_DIR/docs/evidence/long-idle-memory-smoke-$DATE.json"
SAMPLE_SECONDS="${MEETINGVAULT_LONG_IDLE_SECONDS:-60}"
SAMPLE_INTERVAL="${MEETINGVAULT_LONG_IDLE_INTERVAL:-5}"
WARMUP_SECONDS="${MEETINGVAULT_LONG_IDLE_WARMUP_SECONDS:-10}"
MAX_RSS_KB="${MEETINGVAULT_LONG_IDLE_MAX_RSS_KB:-600000}"
MAX_GROWTH_KB="${MEETINGVAULT_LONG_IDLE_MAX_GROWTH_KB:-75000}"
RESTART=0
SKIP_STAGE=0
SMOKE_LIBRARY_ROOT="${TMPDIR:-/tmp}/MeetingVaultLongIdleMemorySmoke"

usage() {
  cat <<USAGE
Usage: $0 [--output docs/evidence/long-idle-memory-smoke-$DATE.json] [--app dist/release/MeetingVault.app] [--seconds 60] [--interval 5] [--warmup 10] [--max-rss-kb 600000] [--max-growth-kb 75000] [--restart] [--skip-stage]

Stages a Release app unless --skip-stage is set, launches an isolated Library
workspace, waits for initial app startup to settle, samples resident memory
while idle, and writes bounded JSON evidence. This smoke does not record audio,
read transcripts, capture screenshots, or store raw logs/UI text.
USAGE
}

require_non_negative_int() {
  local value="$1"
  local label="$2"
  if [[ ! "$value" =~ ^[0-9]+$ ]]; then
    printf '[BLOCKED] %s requires a non-negative integer, found %s\n' "$label" "$value" >&2
    exit 2
  fi
}

require_positive_int() {
  local value="$1"
  local label="$2"
  require_non_negative_int "$value" "$label"
  if [[ "$value" -lt 1 ]]; then
    printf '[BLOCKED] %s requires a positive integer, found %s\n' "$label" "$value" >&2
    exit 2
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      OUTPUT="${2:-}"
      shift 2
      ;;
    --app)
      APP_BUNDLE="${2:-}"
      shift 2
      ;;
    --seconds)
      SAMPLE_SECONDS="${2:-}"
      require_positive_int "$SAMPLE_SECONDS" "--seconds"
      shift 2
      ;;
    --interval)
      SAMPLE_INTERVAL="${2:-}"
      require_positive_int "$SAMPLE_INTERVAL" "--interval"
      shift 2
      ;;
    --warmup)
      WARMUP_SECONDS="${2:-}"
      require_non_negative_int "$WARMUP_SECONDS" "--warmup"
      shift 2
      ;;
    --max-rss-kb)
      MAX_RSS_KB="${2:-}"
      require_positive_int "$MAX_RSS_KB" "--max-rss-kb"
      shift 2
      ;;
    --max-growth-kb)
      MAX_GROWTH_KB="${2:-}"
      require_non_negative_int "$MAX_GROWTH_KB" "--max-growth-kb"
      shift 2
      ;;
    --restart)
      RESTART=1
      shift
      ;;
    --skip-stage)
      SKIP_STAGE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf '[BLOCKED] Unknown argument: %s\n' "$1" >&2
      exit 2
      ;;
  esac
done

if [[ "$SAMPLE_INTERVAL" -gt "$SAMPLE_SECONDS" ]]; then
  printf '[BLOCKED] --interval must be less than or equal to --seconds\n' >&2
  exit 2
fi

now_ms() {
  perl -MTime::HiRes=time -e 'printf "%.0f\n", time() * 1000'
}

json_escape() {
  python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().rstrip("\n"))[1:-1])'
}

running_pids() {
  pgrep -x "$APP_NAME" || true
}

wait_for_exit() {
  local deadline=$((SECONDS + 10))
  while [[ "$SECONDS" -lt "$deadline" ]]; do
    if [[ -z "$(running_pids)" ]]; then
      return 0
    fi
    sleep 0.25
  done
  return 1
}

wait_for_launch() {
  local deadline=$((SECONDS + 20))
  while [[ "$SECONDS" -lt "$deadline" ]]; do
    local pid
    pid="$(running_pids | head -1)"
    if [[ -n "$pid" ]]; then
      printf '%s\n' "$pid"
      return 0
    fi
    sleep 0.1
  done
  return 1
}

rss_for_pid() {
  ps -o rss= -p "$1" | tr -d ' '
}

cd "$ROOT_DIR"
mkdir -p "$(dirname "$OUTPUT")"

if [[ "$SKIP_STAGE" -eq 0 ]]; then
  "$ROOT_DIR/script/stage_app_bundle.sh" --configuration release --app "$APP_BUNDLE" >/dev/null
fi

if [[ ! -d "$APP_BUNDLE" ]]; then
  printf '[BLOCKED] App bundle missing at %s\n' "$APP_BUNDLE" >&2
  exit 1
fi

existing_pids="$(running_pids)"
if [[ -n "$existing_pids" ]]; then
  if [[ "$RESTART" -ne 1 ]]; then
    printf '[BLOCKED] %s is already running (pid %s). Re-run with --restart for a clean long-idle smoke.\n' "$APP_NAME" "$(printf '%s' "$existing_pids" | tr '\n' ' ')" >&2
    exit 1
  fi
  kill $existing_pids >/dev/null 2>&1 || true
  if ! wait_for_exit; then
    printf '[BLOCKED] %s did not quit cleanly for long-idle smoke.\n' "$APP_NAME" >&2
    exit 1
  fi
fi

rm -rf "$SMOKE_LIBRARY_ROOT"
mkdir -p "$SMOKE_LIBRARY_ROOT"

start_ms="$(now_ms)"
open -n "$APP_BUNDLE" --args \
  --workspace meetings \
  --ui-smoke-library-root "$SMOKE_LIBRARY_ROOT" \
  --ui-smoke-retention-days 1
pid="$(wait_for_launch)"
launch_ms=$(( $(now_ms) - start_ms ))

sleep "$WARMUP_SECONDS"

samples_elapsed=()
samples_rss=()
deadline=$((SECONDS + SAMPLE_SECONDS))
elapsed=0

while true; do
  if ! ps -p "$pid" >/dev/null 2>&1; then
    printf '[BLOCKED] %s exited during long-idle smoke.\n' "$APP_NAME" >&2
    exit 1
  fi

  rss="$(rss_for_pid "$pid")"
  if [[ -z "$rss" ]]; then
    printf '[BLOCKED] Unable to read RSS for %s pid %s\n' "$APP_NAME" "$pid" >&2
    exit 1
  fi
  samples_elapsed+=("$elapsed")
  samples_rss+=("$rss")

  if [[ "$SECONDS" -ge "$deadline" ]]; then
    break
  fi

  sleep "$SAMPLE_INTERVAL"
  elapsed=$((elapsed + SAMPLE_INTERVAL))
  if [[ "$elapsed" -gt "$SAMPLE_SECONDS" ]]; then
    elapsed="$SAMPLE_SECONDS"
  fi
done

first_rss="${samples_rss[0]}"
last_index=$((${#samples_rss[@]} - 1))
last_rss="${samples_rss[$last_index]}"
peak_rss="$first_rss"
for sample in "${samples_rss[@]}"; do
  if [[ "$sample" -gt "$peak_rss" ]]; then
    peak_rss="$sample"
  fi
done
growth_kb=$((last_rss - first_rss))
if [[ "$growth_kb" -lt 0 ]]; then
  growth_kb=0
fi

status="pass"
issues=()
if [[ "$peak_rss" -gt "$MAX_RSS_KB" ]]; then
  status="fail"
  issues+=("peak RSS exceeded threshold")
fi
if [[ "$growth_kb" -gt "$MAX_GROWTH_KB" ]]; then
  status="fail"
  issues+=("RSS growth exceeded threshold")
fi

samples_json="$(
  python3 - "$SAMPLE_SECONDS" "$SAMPLE_INTERVAL" "${samples_elapsed[@]}" -- "${samples_rss[@]}" <<'PY'
import json
import sys

args = sys.argv[3:]
divider = args.index("--")
elapsed = [int(value) for value in args[:divider]]
rss = [int(value) for value in args[divider + 1:]]
print(json.dumps([
    {"elapsedSeconds": elapsed_value, "rssKB": rss_value}
    for elapsed_value, rss_value in zip(elapsed, rss)
]))
PY
)"
if [[ "${#issues[@]}" -eq 0 ]]; then
  issues_json="[]"
else
  issues_json="$(
    printf '%s\0' "${issues[@]}" | python3 -c 'import json,sys; print(json.dumps([v for v in sys.stdin.buffer.read().decode().split("\0") if v]))'
  )"
fi
app_path_escaped="$(printf '%s' "$APP_BUNDLE" | json_escape)"
library_root_escaped="$(printf '%s' "$SMOKE_LIBRARY_ROOT" | json_escape)"
timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

cat >"$OUTPUT" <<JSON
{
  "timestamp": "$timestamp",
  "status": "$status",
  "app": "$app_path_escaped",
  "pid": $pid,
  "launchMs": $launch_ms,
  "workspace": "meetings",
  "isolatedSmokeStorage": true,
  "smokeLibraryRoot": "$library_root_escaped",
  "warmupSeconds": $WARMUP_SECONDS,
  "sampleSeconds": $SAMPLE_SECONDS,
  "sampleIntervalSeconds": $SAMPLE_INTERVAL,
  "sampleCount": ${#samples_rss[@]},
  "firstRSSKB": $first_rss,
  "lastRSSKB": $last_rss,
  "peakRSSKB": $peak_rss,
  "rssGrowthKB": $growth_kb,
  "thresholds": {
    "maxRSSKB": $MAX_RSS_KB,
    "maxGrowthKB": $MAX_GROWTH_KB
  },
  "samples": $samples_json,
  "privateAudioRecorded": false,
  "microphoneOpened": false,
  "rawTranscriptStored": false,
  "rawAudioStored": false,
  "rawLogsStored": false,
  "rawUITextStored": false,
  "issues": $issues_json
}
JSON

if [[ "$status" != "pass" ]]; then
  printf '[BLOCKED] Long-idle memory smoke failed: peakRSSKB=%s growthKB=%s evidence=%s\n' "$peak_rss" "$growth_kb" "$OUTPUT" >&2
  exit 1
fi

printf '[OK] Long-idle memory smoke passed: peakRSSKB=%s growthKB=%s samples=%s evidence=%s\n' "$peak_rss" "$growth_kb" "${#samples_rss[@]}" "$OUTPUT"
