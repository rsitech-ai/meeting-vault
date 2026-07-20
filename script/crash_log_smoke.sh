#!/usr/bin/env bash
set -euo pipefail

APP_NAME="MeetingVault"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="$ROOT_DIR/dist/release/$APP_NAME.app"
OUTPUT="$ROOT_DIR/docs/evidence/crash-log-smoke-$(date +%F).json"
RESTART=0
SKIP_STAGE=0
LOG_WINDOW="${MEETINGVAULT_LOG_WINDOW:-2m}"
SETTLE_SECONDS="${MEETINGVAULT_CRASH_LOG_SETTLE_SECONDS:-4}"

usage() {
  cat <<USAGE
Usage: $0 [--app /path/to/MeetingVault.app] [--output docs/evidence/crash-log-smoke.json] [--restart] [--skip-stage] [--log-window 2m]

Stages a release app unless --skip-stage is set, launches it, confirms the
process stays alive, scans for new MeetingVault diagnostic reports, and writes
privacy-safe JSON evidence. If MeetingVault is already running, pass --restart
for a clean launch smoke.
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
    --log-window)
      LOG_WINDOW="${2:-}"
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
    printf '[BLOCKED] %s is already running (pid %s). Re-run with --restart for a clean crash/log smoke.\n' "$APP_NAME" "$(printf '%s' "$existing_pids" | tr '\n' ' ')" >&2
    exit 1
  fi
  kill $existing_pids >/dev/null 2>&1 || true
  if ! wait_for_exit; then
    printf '[BLOCKED] %s did not quit cleanly for restart smoke.\n' "$APP_NAME" >&2
    exit 1
  fi
fi

marker="$(mktemp "${TMPDIR:-/tmp}/meetingvault-crash-log-marker.XXXXXX")"
log_file="$(mktemp "${TMPDIR:-/tmp}/meetingvault-log.XXXXXX")"
log_err="$(mktemp "${TMPDIR:-/tmp}/meetingvault-log-error.XXXXXX")"
trap 'rm -f "$marker" "$log_file" "$log_err"' EXIT
touch "$marker"
log_start_time="$(date '+%Y-%m-%d %H:%M:%S')"

open -n "$APP_BUNDLE"
pid="$(wait_for_launch)"
sleep "$SETTLE_SECONDS"

process_alive=0
if ps -p "$pid" >/dev/null 2>&1; then
  process_alive=1
fi

crash_reports_json="$(
  python3 - "$marker" <<'PY'
import datetime
import json
import os
import sys

marker = os.path.getmtime(sys.argv[1])
directories = [
    os.path.expanduser("~/Library/Logs/DiagnosticReports"),
    "/Library/Logs/DiagnosticReports",
]
suffixes = (".crash", ".ips", ".diag")
matches = []

for directory in directories:
    if not os.path.isdir(directory):
        continue
    try:
        names = os.listdir(directory)
    except OSError:
        continue
    for name in names:
        if not name.startswith("MeetingVault") or not name.endswith(suffixes):
            continue
        path = os.path.join(directory, name)
        try:
            stat = os.stat(path)
        except OSError:
            continue
        if stat.st_mtime >= marker:
            matches.append(
                {
                    "path": path,
                    "modifiedAt": datetime.datetime.fromtimestamp(
                        stat.st_mtime,
                        tz=datetime.timezone.utc,
                    ).isoformat().replace("+00:00", "Z"),
                    "bytes": stat.st_size,
                }
            )

matches.sort(key=lambda row: row["modifiedAt"], reverse=True)
print(json.dumps(matches))
PY
)"

log_status="unavailable"
log_line_count=0
log_error_or_fault_count=0
swiftui_invalid_configuration_count=0
if command -v log >/dev/null 2>&1; then
  if log show --start "$log_start_time" --style compact --predicate "process == \"$APP_NAME\"" >"$log_file" 2>"$log_err"; then
    log_status="ok"
    log_line_count="$(grep -cve '^[[:space:]]*$' "$log_file" || true)"
    log_error_or_fault_count="$(grep -Eic '(^|[[:space:]])(error|fault)([[:space:]]|:|$)' "$log_file" || true)"
    swiftui_invalid_configuration_count="$(grep -Eic 'SwiftUI:Invalid Configuration|Invalid Configuration.*maximum length' "$log_file" || true)"
  else
    log_status="failed"
  fi
fi

timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
crash_count="$(CRASH_REPORTS_JSON="$crash_reports_json" python3 -c 'import json,os; print(len(json.loads(os.environ["CRASH_REPORTS_JSON"])))')"
status="pass"
if [[ "$process_alive" -ne 1 || "$crash_count" -gt 0 ]]; then
  status="fail"
fi
if [[ "$swiftui_invalid_configuration_count" -gt 0 ]]; then
  status="fail"
fi

export OUTPUT_JSON_TIMESTAMP="$timestamp"
export OUTPUT_JSON_STATUS="$status"
export OUTPUT_JSON_APP="$APP_BUNDLE"
export OUTPUT_JSON_PID="$pid"
export OUTPUT_JSON_PROCESS_ALIVE="$process_alive"
export OUTPUT_JSON_CRASH_REPORTS="$crash_reports_json"
export OUTPUT_JSON_LOG_STATUS="$log_status"
export OUTPUT_JSON_LOG_WINDOW="$LOG_WINDOW"
export OUTPUT_JSON_LOG_LINE_COUNT="$log_line_count"
export OUTPUT_JSON_LOG_ERROR_OR_FAULT_COUNT="$log_error_or_fault_count"
export OUTPUT_JSON_SWIFTUI_INVALID_CONFIGURATION_COUNT="$swiftui_invalid_configuration_count"

python3 - <<'PY' >"$OUTPUT"
import json
import os

payload = {
    "timestamp": os.environ["OUTPUT_JSON_TIMESTAMP"],
    "status": os.environ["OUTPUT_JSON_STATUS"],
    "app": os.environ["OUTPUT_JSON_APP"],
    "pid": int(os.environ["OUTPUT_JSON_PID"]),
    "processAlive": os.environ["OUTPUT_JSON_PROCESS_ALIVE"] == "1",
    "newDiagnosticReports": json.loads(os.environ["OUTPUT_JSON_CRASH_REPORTS"]),
    "logReview": {
        "status": os.environ["OUTPUT_JSON_LOG_STATUS"],
        "window": os.environ["OUTPUT_JSON_LOG_WINDOW"],
        "lineCount": int(os.environ["OUTPUT_JSON_LOG_LINE_COUNT"]),
        "errorOrFaultLineCount": int(os.environ["OUTPUT_JSON_LOG_ERROR_OR_FAULT_COUNT"]),
        "swiftUIInvalidConfigurationLineCount": int(os.environ["OUTPUT_JSON_SWIFTUI_INVALID_CONFIGURATION_COUNT"]),
        "rawMessagesStored": False,
    },
}
print(json.dumps(payload, indent=2))
PY

if [[ "$status" != "pass" ]]; then
  printf '[BLOCKED] Crash/log smoke failed: processAlive=%s newDiagnosticReports=%s swiftUIInvalidConfigurationLines=%s evidence=%s\n' "$process_alive" "$crash_count" "$swiftui_invalid_configuration_count" "$OUTPUT" >&2
  exit 1
fi

printf '[OK] Crash/log smoke passed: processAlive=%s newDiagnosticReports=%s logStatus=%s logLines=%s logErrorsOrFaults=%s swiftUIInvalidConfigurationLines=%s evidence=%s\n' \
  "$process_alive" "$crash_count" "$log_status" "$log_line_count" "$log_error_or_fault_count" "$swiftui_invalid_configuration_count" "$OUTPUT"
