#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATE_STAMP="$(date -u +%F)"
OUTPUT="$ROOT_DIR/docs/evidence/clean-checkout-smoke-$DATE_STAMP.json"
SOURCE_REF="HEAD"
RUN_TESTS=1
RUN_APP_VERIFY=1
RUN_HEADROOM_CHECK=1
LONG_RECORDING_REQUIRED_BYTES=8516050944
RECOMMENDED_VERIFICATION_BYTES=12811018240
VOLUME_AVAILABLE_BYTES=null
VOLUME_TOTAL_BYTES=null

usage() {
  cat <<USAGE
Usage: $0 [--output PATH] [--source-ref REF] [--skip-tests] [--skip-app-verify] [--skip-headroom-check]

Clones the committed MeetingVault tree into a temporary directory, checks out
the requested ref, then verifies a clean-checkout build, tests, and real .app
launch through script/build_and_run.sh. Untracked local files are outside the
committed source ref and do not block this smoke; tracked changes still do.

The evidence JSON is bounded: it stores command names, statuses, durations, and
privacy flags, but not build logs, transcript text, audio, keys, or local data.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      OUTPUT="${2:-}"
      if [[ -z "$OUTPUT" ]]; then
        echo "--output requires a path" >&2
        exit 2
      fi
      shift 2
      ;;
    --source-ref)
      SOURCE_REF="${2:-}"
      if [[ -z "$SOURCE_REF" ]]; then
        echo "--source-ref requires a git ref" >&2
        exit 2
      fi
      shift 2
      ;;
    --skip-tests)
      RUN_TESTS=0
      shift
      ;;
    --skip-app-verify)
      RUN_APP_VERIFY=0
      shift
      ;;
    --skip-headroom-check)
      RUN_HEADROOM_CHECK=0
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/}"
  printf '%s' "$value"
}

iso_now() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

steps_json=""
issues_json=""
fail_count=0

append_issue() {
  local issue="$1"
  if [[ -n "$issues_json" ]]; then
    issues_json+=","
  fi
  issues_json+="\"$(json_escape "$issue")\""
}

append_step() {
  local name="$1"
  local status="$2"
  local exit_code="$3"
  local duration="$4"
  if [[ -n "$steps_json" ]]; then
    steps_json+=","
  fi
  steps_json+="{\"name\":\"$(json_escape "$name")\",\"status\":\"$status\",\"exitCode\":$exit_code,\"durationSeconds\":$duration}"
  if [[ "$status" != "pass" && "$status" != "skipped" ]]; then
    fail_count=$((fail_count + 1))
    append_issue "$name failed with exit code $exit_code."
  fi
}

run_step() {
  local name="$1"
  shift
  local start end duration exit_code
  start="$(date +%s)"
  set +e
  "$@" >/dev/null 2>&1
  exit_code=$?
  set -e
  end="$(date +%s)"
  duration=$((end - start))
  if [[ "$exit_code" -eq 0 ]]; then
    append_step "$name" "pass" "$exit_code" "$duration"
  else
    append_step "$name" "fail" "$exit_code" "$duration"
  fi
  return "$exit_code"
}

write_report() {
  local status="$1"
  local clone_deleted="$2"
  mkdir -p "$(dirname "$OUTPUT")"
  cat >"$OUTPUT" <<JSON
{
  "timestamp": "$(iso_now)",
  "status": "$status",
  "sourcePath": "$(json_escape "$ROOT_DIR")",
  "sourceBranch": "$(json_escape "$SOURCE_BRANCH")",
  "sourceCommit": "$SOURCE_COMMIT",
  "sourceRef": "$(json_escape "$SOURCE_REF")",
  "sourceWasCleanBeforeSmoke": $SOURCE_WAS_CLEAN,
  "clonePathDeleted": $clone_deleted,
  "runTests": $RUN_TESTS_JSON,
  "runAppVerify": $RUN_APP_VERIFY_JSON,
  "runHeadroomCheck": $RUN_HEADROOM_CHECK_JSON,
  "volumeAvailableBytes": $VOLUME_AVAILABLE_BYTES,
  "volumeTotalBytes": $VOLUME_TOTAL_BYTES,
  "requiredLongRecordingBytes": $LONG_RECORDING_REQUIRED_BYTES,
  "recommendedVerificationBytes": $RECOMMENDED_VERIFICATION_BYTES,
  "privateAudioRecorded": false,
  "microphoneOpened": false,
  "externalNetworkRequested": false,
  "rawTranscriptStored": false,
  "rawAudioStored": false,
  "rawLogsStored": false,
  "steps": [$steps_json],
  "issues": [$issues_json]
}
JSON
}

if [[ "$(git -C "$ROOT_DIR" rev-parse --is-inside-work-tree 2>/dev/null || true)" != "true" ]]; then
    echo "MeetingVault repo is not git-initialized: $ROOT_DIR" >&2
    exit 1
fi

SOURCE_BRANCH="$(git -C "$ROOT_DIR" branch --show-current)"
SOURCE_COMMIT="$(git -C "$ROOT_DIR" rev-parse "$SOURCE_REF")"
SOURCE_STATUS="$(git -C "$ROOT_DIR" status --short --untracked-files=no --ignored=no)"
SOURCE_WAS_CLEAN=true
if [[ -n "$SOURCE_STATUS" ]]; then
  SOURCE_WAS_CLEAN=false
  echo "Source repo must be clean before clean-checkout smoke." >&2
  echo "$SOURCE_STATUS" >&2
  exit 1
fi

RUN_TESTS_JSON=false
if [[ "$RUN_TESTS" -eq 1 ]]; then
  RUN_TESTS_JSON=true
fi
RUN_APP_VERIFY_JSON=false
if [[ "$RUN_APP_VERIFY" -eq 1 ]]; then
  RUN_APP_VERIFY_JSON=true
fi
RUN_HEADROOM_CHECK_JSON=false
if [[ "$RUN_HEADROOM_CHECK" -eq 1 ]]; then
  RUN_HEADROOM_CHECK_JSON=true
fi

if [[ "$RUN_HEADROOM_CHECK" -eq 1 ]]; then
  VOLUME_AVAILABLE_BYTES="$(df -kP "$ROOT_DIR" | awk 'NR == 2 { printf "%.0f", $4 * 1024 }')"
  VOLUME_TOTAL_BYTES="$(df -kP "$ROOT_DIR" | awk 'NR == 2 { printf "%.0f", $2 * 1024 }')"
  if [[ -z "$VOLUME_AVAILABLE_BYTES" ]]; then
    VOLUME_AVAILABLE_BYTES=null
    append_step "workspace headroom" "fail" 1 0
    append_issue "Workspace volume capacity could not be measured."
    write_report "fail" true
    echo "Clean-checkout smoke blocked before clone: workspace volume capacity could not be measured." >&2
    exit 1
  fi
  if [[ "$VOLUME_AVAILABLE_BYTES" -lt "$RECOMMENDED_VERIFICATION_BYTES" ]]; then
    append_step "workspace headroom" "fail" 1 0
    append_issue "Workspace volume has $VOLUME_AVAILABLE_BYTES bytes available; $RECOMMENDED_VERIFICATION_BYTES bytes are recommended before clone/build/test/app verification."
    write_report "fail" true
    echo "Clean-checkout smoke blocked before clone: workspace volume headroom is too low." >&2
    exit 1
  fi
  append_step "workspace headroom" "pass" 0 0
else
  append_step "workspace headroom" "skipped" 0 0
fi

TMP_ROOT="${TMPDIR:-/tmp}/MeetingVaultCleanCheckoutSmoke-$(uuidgen)"
CLONE_DIR="$TMP_ROOT/meeting_vault"
mkdir -p "$TMP_ROOT"

cleanup() {
  rm -rf "$TMP_ROOT" >/dev/null 2>&1 || true
}
trap cleanup EXIT

run_step "git clone" git clone --quiet "file://$ROOT_DIR" "$CLONE_DIR" || true
if [[ ! -d "$CLONE_DIR/.git" ]]; then
  write_report "fail" false
  exit 1
fi

run_step "checkout source ref" git -C "$CLONE_DIR" checkout --quiet --detach "$SOURCE_COMMIT" || true
run_step "verify clean clone" bash -c "test -z \"\$(git -C \"\$0\" status --short --ignored=no)\"" "$CLONE_DIR" || true
run_step "swift build" bash -c "cd \"\$0\" && swift build" "$CLONE_DIR" || true

if [[ "$RUN_TESTS" -eq 1 ]]; then
  run_step "swift test" bash -c "cd \"\$0\" && MEETINGVAULT_SKIP_RELEASE_EVIDENCE_PIN_TESTS=1 swift test" "$CLONE_DIR" || true
else
  append_step "swift test" "skipped" 0 0
fi

if [[ "$RUN_APP_VERIFY" -eq 1 ]]; then
  UI_ROOT="$TMP_ROOT/ui-library"
  run_step "app launch verify" bash -c "cd \"\$0\" && ./script/build_and_run.sh --verify --workspace recorder --ui-smoke-library-root \"\$1\" --key-provider local-file" "$CLONE_DIR" "$UI_ROOT" || true
  pkill -x MeetingVault >/dev/null 2>&1 || true
else
  append_step "app launch verify" "skipped" 0 0
fi

rm -rf "$TMP_ROOT"
trap - EXIT

if [[ "$fail_count" -eq 0 ]]; then
  write_report "pass" true
  echo "Clean-checkout smoke passed: $OUTPUT"
  exit 0
else
  write_report "fail" true
  echo "Clean-checkout smoke failed: $OUTPUT" >&2
  exit 1
fi
