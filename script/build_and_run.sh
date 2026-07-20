#!/usr/bin/env bash
set -euo pipefail

APP_NAME="MeetingVault"
BUNDLE_ID="com.andrzej.MeetingVault"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="run"
APP_ARGS=()
KEY_PROVIDER_ARG_SEEN=0
RELEASE_BLOCKER_REPORT="$ROOT_DIR/docs/evidence/release-blocker-doctor-2026-07-01.json"

while [[ $# -gt 0 ]]; do
  case "$1" in
    run|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify)
      MODE="$1"
      shift
      ;;
    -h|--help)
      echo "usage: $0 [run|--debug|--logs|--telemetry|--verify] [--workspace meetings|library|recorder|intelligence|diagnostics] [--intelligence-tab agent|playback|editor|review|summary|decisions|actions|questions|risks|exports] [--appearance light|dark|system] [--reduce-motion on|off|system] [--contrast increased|normal|system] [--ui-smoke-library-root PATH] [--ui-smoke-retention-days DAYS] [--ui-smoke-storage-bytes BYTES] [--ui-smoke-permissions authorized|denied|restricted|not-determined|unknown] [--ui-smoke-meeting-context] [--release-blocker-report PATH] [--key-provider local-file|keychain]"
      exit 0
      ;;
    --workspace)
      WORKSPACE="${2:-}"
      if [[ -z "$WORKSPACE" ]]; then
        echo "--workspace requires meetings, library, recorder, intelligence, or diagnostics" >&2
        exit 2
      fi
      APP_ARGS+=(--workspace "$WORKSPACE")
      shift 2
      ;;
    --intelligence-tab)
      INTELLIGENCE_TAB="${2:-}"
      case "$INTELLIGENCE_TAB" in
        agent|playback|editor|review|summary|decisions|actions|questions|risks|exports)
          ;;
        *)
          echo "--intelligence-tab requires agent, playback, editor, review, summary, decisions, actions, questions, risks, or exports" >&2
          exit 2
          ;;
      esac
      APP_ARGS+=(--intelligence-tab "$INTELLIGENCE_TAB")
      shift 2
      ;;
    --appearance)
      APPEARANCE="${2:-}"
      case "$APPEARANCE" in
        light|dark|system)
          ;;
        *)
          echo "--appearance requires light, dark, or system" >&2
          exit 2
          ;;
      esac
      APP_ARGS+=(--appearance "$APPEARANCE")
      shift 2
      ;;
    --reduce-motion)
      REDUCE_MOTION="${2:-}"
      case "$REDUCE_MOTION" in
        on|off|system)
          ;;
        *)
          echo "--reduce-motion requires on, off, or system" >&2
          exit 2
          ;;
      esac
      APP_ARGS+=(--reduce-motion "$REDUCE_MOTION")
      shift 2
      ;;
    --contrast)
      CONTRAST="${2:-}"
      case "$CONTRAST" in
        increased|normal|system)
          ;;
        *)
          echo "--contrast requires increased, normal, or system" >&2
          exit 2
          ;;
      esac
      APP_ARGS+=(--contrast "$CONTRAST")
      shift 2
      ;;
    --ui-smoke-library-root)
      UI_SMOKE_LIBRARY_ROOT="${2:-}"
      if [[ -z "$UI_SMOKE_LIBRARY_ROOT" ]]; then
        echo "--ui-smoke-library-root requires a path" >&2
        exit 2
      fi
      APP_ARGS+=(--ui-smoke-library-root "$UI_SMOKE_LIBRARY_ROOT")
      shift 2
      ;;
    --ui-smoke-retention-days)
      UI_SMOKE_RETENTION_DAYS="${2:-}"
      if [[ ! "$UI_SMOKE_RETENTION_DAYS" =~ ^[0-9]+$ ]] || [[ "$UI_SMOKE_RETENTION_DAYS" -lt 1 ]]; then
        echo "--ui-smoke-retention-days requires a positive integer" >&2
        exit 2
      fi
      APP_ARGS+=(--ui-smoke-retention-days "$UI_SMOKE_RETENTION_DAYS")
      shift 2
      ;;
    --ui-smoke-storage-bytes)
      UI_SMOKE_STORAGE_BYTES="${2:-}"
      if [[ ! "$UI_SMOKE_STORAGE_BYTES" =~ ^[0-9]+$ ]]; then
        echo "--ui-smoke-storage-bytes requires a non-negative integer" >&2
        exit 2
      fi
      APP_ARGS+=(--ui-smoke-storage-bytes "$UI_SMOKE_STORAGE_BYTES")
      shift 2
      ;;
    --ui-smoke-permissions)
      UI_SMOKE_PERMISSIONS="${2:-}"
      case "$UI_SMOKE_PERMISSIONS" in
        authorized|allow|allowed|ready|denied|restricted|not-determined|notdetermined|prompt|unknown)
          ;;
        *)
          echo "--ui-smoke-permissions requires authorized, denied, restricted, not-determined, or unknown" >&2
          exit 2
          ;;
      esac
      APP_ARGS+=(--ui-smoke-permissions "$UI_SMOKE_PERMISSIONS")
      shift 2
      ;;
    --ui-smoke-meeting-context)
      APP_ARGS+=(--ui-smoke-meeting-context)
      shift
      ;;
    --key-provider)
      KEY_PROVIDER="${2:-}"
      case "$KEY_PROVIDER" in
        local-file|keychain)
          ;;
        *)
          echo "--key-provider requires local-file or keychain" >&2
          exit 2
          ;;
      esac
      KEY_PROVIDER_ARG_SEEN=1
      APP_ARGS+=(--key-provider "$KEY_PROVIDER")
      shift 2
      ;;
    --release-blocker-report)
      RELEASE_BLOCKER_REPORT="${2:-}"
      if [[ -z "$RELEASE_BLOCKER_REPORT" ]]; then
        echo "--release-blocker-report requires a path" >&2
        exit 2
      fi
      shift 2
      ;;
    *)
      echo "usage: $0 [run|--debug|--logs|--telemetry|--verify] [--workspace meetings|library|recorder|intelligence|diagnostics] [--intelligence-tab agent|playback|editor|review|summary|decisions|actions|questions|risks|exports] [--appearance light|dark|system] [--reduce-motion on|off|system] [--contrast increased|normal|system] [--ui-smoke-library-root PATH] [--ui-smoke-retention-days DAYS] [--ui-smoke-storage-bytes BYTES] [--ui-smoke-permissions authorized|denied|restricted|not-determined|unknown] [--ui-smoke-meeting-context] [--release-blocker-report PATH] [--key-provider local-file|keychain]" >&2
      exit 2
      ;;
  esac
done

if [[ "$KEY_PROVIDER_ARG_SEEN" -eq 0 ]]; then
  APP_ARGS+=(--key-provider local-file)
fi

cd "$ROOT_DIR"

mkdir -p "$ROOT_DIR/.build"
LOCK_DIR="$ROOT_DIR/.build/meetingvault-run.lock"
LOCK_WAIT_SECONDS=20
LOCK_DEADLINE=$((SECONDS + LOCK_WAIT_SECONDS))
while ! mkdir "$LOCK_DIR" >/dev/null 2>&1; do
  if [[ "$SECONDS" -ge "$LOCK_DEADLINE" ]]; then
    echo "Timed out waiting for MeetingVault launch lock" >&2
    exit 1
  fi
  sleep 0.25
done
trap 'rmdir "$LOCK_DIR" >/dev/null 2>&1 || true' EXIT

pkill -x "$APP_NAME" >/dev/null 2>&1 || true
for _ in {1..40}; do
  if ! pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    break
  fi
  sleep 0.25
done
if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
  pkill -9 -x "$APP_NAME" >/dev/null 2>&1 || true
  for _ in {1..20}; do
    if ! pgrep -x "$APP_NAME" >/dev/null 2>&1; then
      break
    fi
    sleep 0.25
  done
fi

APP_BUNDLE="$(MEETINGVAULT_SIGNING_IDENTITY="${MEETINGVAULT_SIGNING_IDENTITY:-ad-hoc}" "$ROOT_DIR/script/stage_app_bundle.sh")"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

open_app() {
  if [[ ${#APP_ARGS[@]} -gt 0 ]]; then
    MEETINGVAULT_RELEASE_BLOCKER_REPORT="$RELEASE_BLOCKER_REPORT" /usr/bin/open -n "$APP_BUNDLE" --args "${APP_ARGS[@]}"
  else
    MEETINGVAULT_RELEASE_BLOCKER_REPORT="$RELEASE_BLOCKER_REPORT" /usr/bin/open -n "$APP_BUNDLE"
  fi
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 2
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify] [--workspace meetings|library|recorder|intelligence|diagnostics] [--intelligence-tab agent|playback|editor|review|summary|decisions|actions|questions|risks|exports] [--appearance light|dark|system] [--reduce-motion on|off|system] [--contrast increased|normal|system] [--ui-smoke-library-root PATH] [--ui-smoke-retention-days DAYS] [--ui-smoke-storage-bytes BYTES] [--ui-smoke-permissions authorized|denied|restricted|not-determined|unknown] [--ui-smoke-meeting-context] [--release-blocker-report PATH] [--key-provider local-file|keychain]" >&2
    exit 2
    ;;
esac
