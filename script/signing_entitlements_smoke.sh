#!/usr/bin/env bash
set -euo pipefail

APP_NAME="MeetingVault"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATE="$(date +%F)"
OUTPUT="$ROOT_DIR/docs/evidence/signing-entitlements-smoke-$DATE.json"
DIRECT_ENTITLEMENTS="$ROOT_DIR/config/entitlements/direct-distribution.plist"
APP_STORE_ENTITLEMENTS="$ROOT_DIR/config/entitlements/app-store.plist"

usage() {
  cat <<USAGE
Usage: $0 [--output docs/evidence/signing-entitlements-smoke-$DATE.json]

Stages a Release app, signs temporary copies ad-hoc with the production
entitlement files, and verifies that the local signing arguments bind the
expected entitlements and hardened runtime. This is a local packaging smoke,
not distribution signing, notarization, or App Store upload.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      OUTPUT="${2:-}"
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

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/MeetingVaultSigningSmoke.XXXXXX")"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

issues=()
add_issue() {
  issues+=("$1")
}

run_or_issue() {
  local label="$1"
  shift
  if ! "$@" >"$tmp_dir/$label.out" 2>&1; then
    add_issue "$label failed"
    return 1
  fi
  return 0
}

contains() {
  local file="$1"
  local pattern="$2"
  grep -q "$pattern" "$file"
}

json_bool() {
  if [[ "$1" == "true" ]]; then
    printf 'true'
  else
    printf 'false'
  fi
}

json_issues() {
  if [[ "${#issues[@]}" -eq 0 ]]; then
    printf '[]'
    return
  fi

  printf '['
  local first=true
  local issue
  for issue in "${issues[@]}"; do
    if [[ "$first" == "true" ]]; then
      first=false
    else
      printf ','
    fi
    printf '"%s"' "$issue"
  done
  printf ']'
}

cd "$ROOT_DIR"
mkdir -p "$(dirname "$OUTPUT")"

base_app="$tmp_dir/$APP_NAME.app"
direct_app="$tmp_dir/direct.app"
app_store_app="$tmp_dir/app-store.app"

run_or_issue stage-app "$ROOT_DIR/script/stage_app_bundle.sh" --configuration release --app "$base_app" || true

if [[ -d "$base_app" ]]; then
  cp -R "$base_app" "$direct_app"
  cp -R "$base_app" "$app_store_app"
else
  add_issue "release app was not staged"
fi

if [[ -d "$direct_app" ]]; then
  run_or_issue direct-codesign codesign --force --options runtime --entitlements "$DIRECT_ENTITLEMENTS" --sign - "$direct_app" || true
  codesign --verify --strict --verbose=2 "$direct_app" >"$tmp_dir/direct-verify.out" 2>&1 || add_issue "direct ad-hoc signature did not verify"
  codesign -dvvv --entitlements :- "$direct_app" >"$tmp_dir/direct-detail.out" 2>&1 || add_issue "direct signing details unavailable"
else
  add_issue "direct smoke app missing"
fi

if [[ -d "$app_store_app" ]]; then
  run_or_issue app-store-codesign codesign --force --entitlements "$APP_STORE_ENTITLEMENTS" --sign - "$app_store_app" || true
  codesign --verify --strict --verbose=2 "$app_store_app" >"$tmp_dir/app-store-verify.out" 2>&1 || add_issue "app-store ad-hoc signature did not verify"
  codesign -dvvv --entitlements :- "$app_store_app" >"$tmp_dir/app-store-detail.out" 2>&1 || add_issue "app-store signing details unavailable"
else
  add_issue "app-store smoke app missing"
fi

direct_signature_verifies=false
direct_info_plist_sealed=false
direct_hardened_runtime=false
direct_has_sandbox=false
app_store_signature_verifies=false
app_store_info_plist_sealed=false
app_store_has_sandbox=false
app_store_has_audio_input=false
app_store_has_user_selected_rw=false
app_store_has_addressbook=false
app_store_has_calendars=false

if [[ -f "$tmp_dir/direct-verify.out" ]] && contains "$tmp_dir/direct-verify.out" "valid on disk"; then
  direct_signature_verifies=true
else
  add_issue "direct ad-hoc signature was not valid on disk"
fi

if [[ -f "$tmp_dir/direct-detail.out" ]] && contains "$tmp_dir/direct-detail.out" "Info.plist entries=" && ! contains "$tmp_dir/direct-detail.out" "Info.plist=not bound"; then
  direct_info_plist_sealed=true
else
  add_issue "direct ad-hoc signature did not seal Info.plist"
fi

if [[ -f "$tmp_dir/direct-detail.out" ]] && contains "$tmp_dir/direct-detail.out" "runtime"; then
  direct_hardened_runtime=true
else
  add_issue "direct ad-hoc signature did not carry hardened runtime"
fi

if [[ -f "$tmp_dir/direct-detail.out" ]] && contains "$tmp_dir/direct-detail.out" "com.apple.security.app-sandbox"; then
  direct_has_sandbox=true
  add_issue "direct entitlement template unexpectedly enables App Sandbox"
fi

if [[ -f "$tmp_dir/app-store-verify.out" ]] && contains "$tmp_dir/app-store-verify.out" "valid on disk"; then
  app_store_signature_verifies=true
else
  add_issue "app-store ad-hoc signature was not valid on disk"
fi

if [[ -f "$tmp_dir/app-store-detail.out" ]] && contains "$tmp_dir/app-store-detail.out" "Info.plist entries=" && ! contains "$tmp_dir/app-store-detail.out" "Info.plist=not bound"; then
  app_store_info_plist_sealed=true
else
  add_issue "app-store ad-hoc signature did not seal Info.plist"
fi

if [[ -f "$tmp_dir/app-store-detail.out" ]] && contains "$tmp_dir/app-store-detail.out" "com.apple.security.app-sandbox"; then
  app_store_has_sandbox=true
else
  add_issue "app-store entitlement template did not bind App Sandbox"
fi

if [[ -f "$tmp_dir/app-store-detail.out" ]] && contains "$tmp_dir/app-store-detail.out" "com.apple.security.device.audio-input"; then
  app_store_has_audio_input=true
else
  add_issue "app-store entitlement template did not bind audio-input entitlement"
fi

if [[ -f "$tmp_dir/app-store-detail.out" ]] && contains "$tmp_dir/app-store-detail.out" "com.apple.security.files.user-selected.read-write"; then
  app_store_has_user_selected_rw=true
else
  add_issue "app-store entitlement template did not bind user-selected read-write entitlement"
fi

if [[ -f "$tmp_dir/app-store-detail.out" ]] && contains "$tmp_dir/app-store-detail.out" "com.apple.security.personal-information.addressbook"; then
  app_store_has_addressbook=true
else
  add_issue "app-store entitlement template did not bind addressbook entitlement"
fi

if [[ -f "$tmp_dir/app-store-detail.out" ]] && contains "$tmp_dir/app-store-detail.out" "com.apple.security.personal-information.calendars"; then
  app_store_has_calendars=true
else
  add_issue "app-store entitlement template did not bind calendars entitlement"
fi

status="pass"
if [[ "${#issues[@]}" -gt 0 ]]; then
  status="fail"
fi

cat >"$OUTPUT" <<JSON
{
  "date": "$DATE",
  "status": "$status",
  "artifact": "temporary release app copies",
  "distributionReady": false,
  "notarizationSubmitted": false,
  "externalUploadAttempted": false,
  "rawSigningOutputStored": false,
  "temporaryBundlesDeleted": true,
  "direct": {
    "entitlements": "config/entitlements/direct-distribution.plist",
    "signature": "adhoc",
    "codeSignatureVerifies": $(json_bool "$direct_signature_verifies"),
    "infoPlistSealed": $(json_bool "$direct_info_plist_sealed"),
    "hardenedRuntime": $(json_bool "$direct_hardened_runtime"),
    "appSandbox": $(json_bool "$direct_has_sandbox")
  },
  "appStore": {
    "entitlements": "config/entitlements/app-store.plist",
    "signature": "adhoc",
    "codeSignatureVerifies": $(json_bool "$app_store_signature_verifies"),
    "infoPlistSealed": $(json_bool "$app_store_info_plist_sealed"),
    "appSandbox": $(json_bool "$app_store_has_sandbox"),
    "audioInput": $(json_bool "$app_store_has_audio_input"),
    "userSelectedReadWrite": $(json_bool "$app_store_has_user_selected_rw"),
    "addressbook": $(json_bool "$app_store_has_addressbook"),
    "calendars": $(json_bool "$app_store_has_calendars")
  },
  "issues": $(json_issues)
}
JSON

if [[ "$status" == "pass" ]]; then
  printf '[OK] Signing entitlement smoke passed: %s\n' "$OUTPUT"
else
  printf '[FAIL] Signing entitlement smoke failed: %s\n' "$OUTPUT" >&2
  exit 1
fi
