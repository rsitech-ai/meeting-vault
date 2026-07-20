#!/usr/bin/env bash
set -euo pipefail

APP_NAME="MeetingVault"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="$ROOT_DIR/dist/release/$APP_NAME.app"
OUTPUT="$ROOT_DIR/docs/evidence/performance-smoke-$(date +%F).json"
RESTART=0
SKIP_STAGE=0
MAX_LAUNCH_MS="${MEETINGVAULT_MAX_LAUNCH_MS:-15000}"
MAX_RSS_KB="${MEETINGVAULT_MAX_RSS_KB:-600000}"
MAX_IDLE_CPU_PERCENT="${MEETINGVAULT_MAX_IDLE_CPU_PERCENT:-10}"
IDLE_WAIT_SECONDS="${MEETINGVAULT_IDLE_WAIT_SECONDS:-2}"
APP_ARGS=()

usage() {
  cat <<USAGE
Usage: $0 [--app /path/to/MeetingVault.app] [--output docs/evidence/performance-smoke.json] [--restart] [--skip-stage] [--idle-wait SECONDS] [--max-idle-cpu PERCENT] [--workspace NAME] [--ui-smoke-library-root PATH] [--ui-smoke-retention-days DAYS] [--app-arg VALUE]

Stages a release app unless --skip-stage is set, launches it, records launch
latency and resident memory, and writes JSON evidence. If MeetingVault is
already running, pass --restart to quit it first.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)
      APP_BUNDLE="${2:-}"
      shift 2
      ;;
    --output)
      OUTPUT="${2:-}"
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
    --idle-wait)
      IDLE_WAIT_SECONDS="${2:-}"
      if [[ ! "$IDLE_WAIT_SECONDS" =~ ^[0-9]+$ ]]; then
        printf '[BLOCKED] --idle-wait requires a non-negative integer number of seconds\n' >&2
        exit 2
      fi
      shift 2
      ;;
    --max-idle-cpu)
      MAX_IDLE_CPU_PERCENT="${2:-}"
      if ! python3 - "$MAX_IDLE_CPU_PERCENT" <<'PY'
import sys
try:
    value = float(sys.argv[1])
except ValueError:
    sys.exit(1)
sys.exit(0 if value >= 0 else 1)
PY
      then
        printf '[BLOCKED] --max-idle-cpu requires a non-negative number\n' >&2
        exit 2
      fi
      shift 2
      ;;
    --workspace)
      WORKSPACE="${2:-}"
      case "$WORKSPACE" in
        meetings|library|recorder|intelligence|diagnostics)
          APP_ARGS+=(--workspace "$WORKSPACE")
          ;;
        *)
          printf '[BLOCKED] --workspace requires meetings, library, recorder, intelligence, or diagnostics\n' >&2
          exit 2
          ;;
      esac
      shift 2
      ;;
    --ui-smoke-library-root)
      UI_SMOKE_LIBRARY_ROOT="${2:-}"
      if [[ -z "$UI_SMOKE_LIBRARY_ROOT" ]]; then
        printf '[BLOCKED] --ui-smoke-library-root requires a path\n' >&2
        exit 2
      fi
      APP_ARGS+=(--ui-smoke-library-root "$UI_SMOKE_LIBRARY_ROOT")
      shift 2
      ;;
    --ui-smoke-retention-days)
      UI_SMOKE_RETENTION_DAYS="${2:-}"
      if [[ ! "$UI_SMOKE_RETENTION_DAYS" =~ ^[0-9]+$ ]] || [[ "$UI_SMOKE_RETENTION_DAYS" -lt 1 ]]; then
        printf '[BLOCKED] --ui-smoke-retention-days requires a positive integer\n' >&2
        exit 2
      fi
      APP_ARGS+=(--ui-smoke-retention-days "$UI_SMOKE_RETENTION_DAYS")
      shift 2
      ;;
    --app-arg)
      APP_ARG="${2:-}"
      if [[ -z "$APP_ARG" ]]; then
        printf '[BLOCKED] --app-arg requires a value\n' >&2
        exit 2
      fi
      APP_ARGS+=("$APP_ARG")
      shift 2
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
    printf '[BLOCKED] %s is already running (pid %s). Re-run with --restart for a clean launch smoke.\n' "$APP_NAME" "$(printf '%s' "$existing_pids" | tr '\n' ' ')" >&2
    exit 1
  fi
  # `osascript tell application ... to quit` can block if the app is not responding.
  # `--restart` is an explicit smoke-test mode, so terminate the existing app
  # process and require it to exit before measuring a clean launch.
  kill $existing_pids >/dev/null 2>&1 || true
  if ! wait_for_exit; then
    printf '[BLOCKED] %s did not quit cleanly for restart smoke.\n' "$APP_NAME" >&2
    exit 1
  fi
fi

start_ms="$(now_ms)"
if [[ ${#APP_ARGS[@]} -gt 0 ]]; then
  open -n "$APP_BUNDLE" --args "${APP_ARGS[@]}"
else
  open -n "$APP_BUNDLE"
fi
pid="$(wait_for_launch)"
launch_ms=$(( $(now_ms) - start_ms ))

sleep "$IDLE_WAIT_SECONDS"

if ! ps -p "$pid" >/dev/null 2>&1; then
  printf '[BLOCKED] %s exited during smoke.\n' "$APP_NAME" >&2
  exit 1
fi

rss_kb="$(ps -o rss= -p "$pid" | tr -d ' ')"
vsz_kb="$(ps -o vsz= -p "$pid" | tr -d ' ')"
pcpu="$({ top -l 2 -s 1 -pid "$pid" -stats pid,cpu -ncols 2 || true; } | awk -v target="$pid" '$1 == target { value=$2 } END { gsub(/%/, "", value); print value }')"
if [[ -z "$pcpu" ]]; then
  printf '[BLOCKED] Could not sample an idle CPU interval for pid %s.\n' "$pid" >&2
  exit 1
fi
etime="$(ps -o etime= -p "$pid" | tr -d ' ')"
timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
app_path_escaped="$(printf '%s' "$APP_BUNDLE" | json_escape)"
app_args_json="$(
  if [[ ${#APP_ARGS[@]} -eq 0 ]]; then
    printf '[]'
  else
    printf '%s\0' "${APP_ARGS[@]}" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.buffer.read().decode().split("\0")[:-1]))'
  fi
)"

status="pass"
if [[ "$launch_ms" -gt "$MAX_LAUNCH_MS" || "$rss_kb" -gt "$MAX_RSS_KB" ]]; then
  status="fail"
fi
if ! python3 - "$pcpu" "$MAX_IDLE_CPU_PERCENT" <<'PY'
import sys
cpu = float(sys.argv[1])
threshold = float(sys.argv[2])
sys.exit(0 if cpu <= threshold else 1)
PY
then
  status="fail"
fi

cat >"$OUTPUT" <<JSON
{
  "timestamp": "$timestamp",
  "status": "$status",
  "app": "$app_path_escaped",
  "appArguments": $app_args_json,
  "pid": $pid,
  "launchMs": $launch_ms,
  "rssKB": $rss_kb,
  "vszKB": $vsz_kb,
  "idleWaitSeconds": $IDLE_WAIT_SECONDS,
  "idleCPUPercent": $pcpu,
  "elapsed": "$etime",
  "thresholds": {
    "maxLaunchMs": $MAX_LAUNCH_MS,
    "maxRSSKB": $MAX_RSS_KB,
    "maxIdleCPUPercent": $MAX_IDLE_CPU_PERCENT
  }
}
JSON

if [[ "$status" != "pass" ]]; then
  printf '[BLOCKED] Performance smoke failed: launchMs=%s rssKB=%s idleCPU=%s evidence=%s\n' "$launch_ms" "$rss_kb" "$pcpu" "$OUTPUT" >&2
  exit 1
fi

printf '[OK] Performance smoke passed: launchMs=%s rssKB=%s idleCPU=%s pid=%s evidence=%s\n' "$launch_ms" "$rss_kb" "$pcpu" "$pid" "$OUTPUT"
