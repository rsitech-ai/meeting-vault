#!/usr/bin/env bash
set -euo pipefail

APP_NAME="MeetingVault"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="direct"
APP_BUNDLE="$ROOT_DIR/dist/release/$APP_NAME.app"
IDENTITY=""
PROVISIONING_PROFILE="${MEETINGVAULT_PROVISIONING_PROFILE:-}"
DIRECT_ENTITLEMENTS="$ROOT_DIR/config/entitlements/direct-distribution.plist"
APP_STORE_ENTITLEMENTS="$ROOT_DIR/config/entitlements/app-store.plist"
SKIP_STAGE=false
NOTARIZE=false
NOTARY_PROFILE="${NOTARYTOOL_PROFILE:-}"
SIGNING_TIMEOUT_SECONDS="${MEETINGVAULT_SIGNING_TIMEOUT_SECONDS:-30}"

usage() {
  cat <<USAGE
Usage: $0 [--mode direct|app-store] [--app dist/release/MeetingVault.app] [--identity "Signing Identity"] [--provisioning-profile profile.provisionprofile] [--skip-stage] [--notarize] [--notarytool-profile PROFILE]

Builds a Release .app bundle and signs it only when local distribution
prerequisites are present. Direct mode separates pre-notary validation from
post-notary Gatekeeper validation. Notarization is submitted only when the
caller passes both --notarize and --notarytool-profile (or NOTARYTOOL_PROFILE).
This script never uploads to App Store Connect.

Use --skip-stage only when a Release app bundle has already been staged at
--app and the caller wants to reuse that artifact for bounded packaging checks.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      MODE="${2:-}"
      shift 2
      ;;
    --app)
      APP_BUNDLE="${2:-}"
      shift 2
      ;;
    --identity)
      IDENTITY="${2:-}"
      shift 2
      ;;
    --provisioning-profile)
      PROVISIONING_PROFILE="${2:-}"
      shift 2
      ;;
    --skip-stage)
      SKIP_STAGE=true
      shift
      ;;
    --notarize)
      NOTARIZE=true
      shift
      ;;
    --notarytool-profile)
      NOTARY_PROFILE="${2:-}"
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

case "$MODE" in
  direct|app-store)
    ;;
  *)
    printf '[BLOCKED] Mode must be direct or app-store, found %s\n' "$MODE" >&2
    exit 2
    ;;
esac

if [[ "$MODE" != "direct" && "$NOTARIZE" == "true" ]]; then
  printf '[BLOCKED] --notarize is supported only for direct distribution.\n' >&2
  exit 2
fi

cd "$ROOT_DIR"

"$ROOT_DIR/script/check_local_model_supply_chain.sh"

if [[ "$SKIP_STAGE" == "true" ]]; then
  if [[ ! -d "$APP_BUNDLE" ]]; then
    printf '[BLOCKED] --skip-stage requires an existing app bundle at %s\n' "$APP_BUNDLE" >&2
    exit 1
  fi
  printf '[INFO] Reusing staged Release app at %s\n' "$APP_BUNDLE"
else
  printf '[INFO] Staging Release app at %s\n' "$APP_BUNDLE"
  "$ROOT_DIR/script/stage_app_bundle.sh" --configuration release --app "$APP_BUNDLE" --signing-identity none >/dev/null
fi

identity_pattern="Developer ID Application"
entitlements="$DIRECT_ENTITLEMENTS"
if [[ "$MODE" == "app-store" ]]; then
  identity_pattern="Apple Distribution"
  entitlements="$APP_STORE_ENTITLEMENTS"
fi

if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(
    security find-identity -p codesigning -v 2>/dev/null |
      awk -v pattern="$identity_pattern" '
        index($0, pattern) {
          if (match($0, /"[^"]+"/)) {
            print substr($0, RSTART + 1, RLENGTH - 2)
            exit
          }
        }
      '
  )"
fi

if [[ -z "$IDENTITY" ]]; then
  printf '[BLOCKED] No %s signing identity found.\n' "$identity_pattern" >&2
  if [[ "$MODE" == "direct" ]]; then
    printf '[BLOCKED] Manual step: install a Developer ID Application certificate for direct distribution.\n' >&2
  else
    printf '[BLOCKED] Manual step: install/configure the Apple Distribution certificate for the selected team.\n' >&2
  fi
  exit 1
fi

if [[ "$MODE" == "app-store" ]]; then
  if [[ -z "$PROVISIONING_PROFILE" || ! -f "$PROVISIONING_PROFILE" ]]; then
    printf '[BLOCKED] App Store mode requires a valid provisioning profile path.\n' >&2
    printf '[BLOCKED] Manual step: pass --provisioning-profile or set MEETINGVAULT_PROVISIONING_PROFILE.\n' >&2
    exit 1
  fi
  cp "$PROVISIONING_PROFILE" "$APP_BUNDLE/Contents/embedded.provisionprofile"
fi

if [[ ! -f "$entitlements" ]]; then
  printf '[BLOCKED] Entitlements file missing at %s\n' "$entitlements" >&2
  exit 1
fi

sign_args=(--force --timestamp --entitlements "$entitlements" --sign "$IDENTITY")
if [[ "$MODE" == "direct" ]]; then
  sign_args=(--force --timestamp --options runtime --entitlements "$entitlements" --sign "$IDENTITY")
fi

printf '[INFO] Signing %s with %s\n' "$APP_BUNDLE" "$IDENTITY"
signing_log="$(mktemp "${TMPDIR:-/tmp}/MeetingVaultCodesign.XXXXXX")"
cleanup_signing_log() {
  rm -f "$signing_log"
}
trap cleanup_signing_log EXIT

# Sign nested Mach-O helpers inside-out before the outer .app. Staging may leave
# linker-signed ad-hoc helpers that notarization rejects.
nested_sign_args=(--force --timestamp --sign "$IDENTITY")
if [[ "$MODE" == "direct" ]]; then
  nested_sign_args=(--force --timestamp --options runtime --sign "$IDENTITY")
fi
if [[ -d "$APP_BUNDLE/Contents/Helpers" ]]; then
  while IFS= read -r -d '' nested_binary; do
    if ! file "$nested_binary" | grep -q 'Mach-O'; then
      continue
    fi
    printf '[INFO] Signing nested binary %s\n' "$nested_binary"
    if ! codesign "${nested_sign_args[@]}" "$nested_binary" >>"$signing_log" 2>&1; then
      if grep -q 'errSecInternalComponent' "$signing_log"; then
        printf '[BLOCKED] %s private key is not usable by codesign in this session. Authorize or repair the signing-key access control, then retry.\n' "$identity_pattern" >&2
      else
        printf '[BLOCKED] Nested binary signing failed for %s.\n' "$nested_binary" >&2
      fi
      exit 1
    fi
  done < <(find "$APP_BUNDLE/Contents/Helpers" -type f -perm -111 -print0)
fi

codesign "${sign_args[@]}" "$APP_BUNDLE" >"$signing_log" 2>&1 &
codesign_pid=$!
(
  sleep "$SIGNING_TIMEOUT_SECONDS"
  kill -TERM "$codesign_pid" 2>/dev/null || true
) &
timeout_pid=$!
set +e
wait "$codesign_pid"
codesign_status=$?
set -e
kill -TERM "$timeout_pid" 2>/dev/null || true
wait "$timeout_pid" 2>/dev/null || true
if [[ "$codesign_status" -ne 0 ]]; then
  if grep -q 'errSecInternalComponent' "$signing_log"; then
    printf '[BLOCKED] %s private key is not usable by codesign in this session. Authorize or repair the signing-key access control, then retry.\n' "$identity_pattern" >&2
  elif [[ "$codesign_status" -eq 143 ]]; then
    printf '[BLOCKED] %s private key authorization timed out after %s seconds. Authorize codesign in Keychain Access, then retry.\n' "$identity_pattern" "$SIGNING_TIMEOUT_SECONDS" >&2
  else
    printf '[BLOCKED] Distribution signing failed for %s. Inspect the local Keychain and codesign configuration.\n' "$identity_pattern" >&2
  fi
  exit 1
fi
cleanup_signing_log
trap - EXIT

if [[ "$MODE" == "app-store" ]]; then
  printf '[INFO] Running App Store release signing gate\n'
  "$ROOT_DIR/script/check_release_signing.sh" --app "$APP_BUNDLE" --mode app-store --phase post-notary
  printf '[OK] Signed App Store package passed the local gate: %s\n' "$APP_BUNDLE"
  exit 0
fi

printf '[INFO] Running direct pre-notary signing gate\n'
"$ROOT_DIR/script/check_release_signing.sh" --app "$APP_BUNDLE" --mode direct --phase pre-notary
printf '[OK] Pre-notary signing gate passed: %s\n' "$APP_BUNDLE"

NOTARIZATION_ARCHIVE="${APP_BUNDLE%.app}-notarization.zip"
rm -f "$NOTARIZATION_ARCHIVE"
ditto -c -k --keepParent "$APP_BUNDLE" "$NOTARIZATION_ARCHIVE"
printf '[OK] Created notarization archive: %s\n' "$NOTARIZATION_ARCHIVE"

if [[ "$NOTARIZE" != "true" ]]; then
  printf '[BLOCKED] Notarization not requested. Re-run with --notarize --notarytool-profile PROFILE after reviewing the pre-notary artifact.\n' >&2
  exit 3
fi
if [[ -z "$NOTARY_PROFILE" ]]; then
  printf '[BLOCKED] Notarization credentials missing. Pass --notarytool-profile or set NOTARYTOOL_PROFILE.\n' >&2
  exit 1
fi

notary_result="$(mktemp "${TMPDIR:-/tmp}/MeetingVaultNotaryResult.XXXXXX.json")"
cleanup_notary_result() {
  rm -f "$notary_result"
}
trap cleanup_notary_result EXIT
printf '[INFO] Submitting the reviewed archive to Apple notarization\n'
if ! xcrun notarytool submit "$NOTARIZATION_ARCHIVE" \
  --wait \
  --keychain-profile "$NOTARY_PROFILE" \
  --output-format json >"$notary_result" 2>/dev/null; then
  printf '[BLOCKED] Apple notarization submission failed or was rejected. Inspect the notary history/log locally before retrying.\n' >&2
  exit 1
fi

notary_status="$(plutil -extract status raw -o - "$notary_result" 2>/dev/null || true)"
if [[ "$notary_status" != "Accepted" ]]; then
  printf '[BLOCKED] Apple notarization did not return Accepted (status: %s).\n' "${notary_status:-missing}" >&2
  exit 1
fi
cleanup_notary_result
trap - EXIT
printf '[OK] Apple notarization accepted the submission\n'

xcrun stapler staple "$APP_BUNDLE" >/dev/null
xcrun stapler validate "$APP_BUNDLE" >/dev/null
"$ROOT_DIR/script/check_release_signing.sh" --app "$APP_BUNDLE" --mode direct --phase post-notary

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_BUNDLE/Contents/Info.plist")"
architectures="$(lipo -archs "$APP_BUNDLE/Contents/MacOS/$APP_NAME" | tr ' ' '-')"
FINAL_ARCHIVE="${APP_BUNDLE%.app}-${version}-${architectures}.zip"
rm -f "$FINAL_ARCHIVE" "$FINAL_ARCHIVE.sha256"
ditto -c -k --keepParent "$APP_BUNDLE" "$FINAL_ARCHIVE"
checksum="$(shasum -a 256 "$FINAL_ARCHIVE" | awk '{print $1}')"
printf '%s  %s\n' "$checksum" "$(basename "$FINAL_ARCHIVE")" >"$FINAL_ARCHIVE.sha256"
printf '[OK] Created stapled release archive: %s\n' "$FINAL_ARCHIVE"
printf '[OK] Created SHA-256 file: %s\n' "$FINAL_ARCHIVE.sha256"
