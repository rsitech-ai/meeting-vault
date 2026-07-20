#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATE="$(date +%F)"
OUTPUT="$ROOT_DIR/docs/evidence/release-packaging-smoke-$DATE.json"
STAGED_APP=""

usage() {
  cat <<USAGE
Usage: $0 [--evidence-date YYYY-MM-DD] [--output docs/evidence/release-packaging-smoke-$DATE.json] [--staged-app PATH]

Exercises MeetingVault's fail-closed release packaging path for both direct and
Mac App Store modes. It stages temporary Release app bundles through
script/package_release.sh, records bounded status/exit-code evidence, and never
uploads, notarizes, opens the microphone, or stores raw packaging output.

Use --staged-app only for focused verifier tests that need to exercise the
packaging evidence contract without rebuilding the app. Normal release evidence
should omit it so the smoke stages a fresh Release app.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --evidence-date)
      DATE="${2:-}"
      shift 2
      ;;
    --output)
      OUTPUT="${2:-}"
      shift 2
      ;;
    --staged-app)
      STAGED_APP="${2:-}"
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

if [[ ! "$DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
  printf '[BLOCKED] --evidence-date must be YYYY-MM-DD, found %s\n' "$DATE" >&2
  exit 2
fi

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/MeetingVaultPackagingSmoke.XXXXXX")"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

mkdir -p "$(dirname "$OUTPUT")"
cd "$ROOT_DIR"

base_app="$tmp_dir/base/MeetingVault.app"
mkdir -p "$(dirname "$base_app")"
if [[ -n "$STAGED_APP" ]]; then
  if [[ -d "$STAGED_APP" ]]; then
    cp -R "$STAGED_APP" "$base_app"
    stage_code=0
  else
    printf '[BLOCKED] --staged-app must point to an existing app bundle: %s\n' "$STAGED_APP" >&2
    exit 2
  fi
else
  set +e
  "$ROOT_DIR/script/stage_app_bundle.sh" --configuration release --app "$base_app" >"$tmp_dir/stage.out" 2>"$tmp_dir/stage.err"
  stage_code=$?
  set -e
fi

run_mode() {
  local mode="$1"
  local app="$tmp_dir/$mode/MeetingVault.app"
  mkdir -p "$(dirname "$app")"
  if [[ "$stage_code" -ne 0 || ! -d "$base_app" ]]; then
    printf '%s' "Release app staging failed" >"$tmp_dir/$mode.err"
    printf '%s' "$stage_code" >"$tmp_dir/$mode.exit"
    return
  fi
  cp -R "$base_app" "$app"
  set +e
  "$ROOT_DIR/script/package_release.sh" --skip-stage --mode "$mode" --app "$app" >"$tmp_dir/$mode.out" 2>"$tmp_dir/$mode.err"
  local code=$?
  set -e
  printf '%s' "$code" >"$tmp_dir/$mode.exit"
}

run_mode direct
run_mode app-store

source_commit="$(git rev-parse HEAD 2>/dev/null || printf 'unknown')"
identity_output="$(security find-identity -p codesigning -v 2>/dev/null || true)"
direct_identity_installed=false
apple_distribution_installed=false
provisioning_profile_configured=false
notary_credentials_configured=false
if printf '%s\n' "$identity_output" | grep -Eq 'Developer ID Application'; then
  direct_identity_installed=true
fi
if printf '%s\n' "$identity_output" | grep -Eq 'Apple Distribution'; then
  apple_distribution_installed=true
fi
if [[ -n "${MEETINGVAULT_PROVISIONING_PROFILE:-}" && -f "${MEETINGVAULT_PROVISIONING_PROFILE:-}" ]]; then
  provisioning_profile_configured=true
fi
if [[ -n "${NOTARYTOOL_PROFILE:-}" || ( -n "${APPLE_ID:-}" && -n "${APPLE_TEAM_ID:-}" && -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" ) ]]; then
  notary_credentials_configured=true
fi

python3 - \
  "$tmp_dir" \
  "$OUTPUT" \
  "$DATE" \
  "$source_commit" \
  "$direct_identity_installed" \
  "$apple_distribution_installed" \
  "$provisioning_profile_configured" \
  "$notary_credentials_configured" <<'PY'
import json
import pathlib
import sys

tmp = pathlib.Path(sys.argv[1])
output = pathlib.Path(sys.argv[2])
date = sys.argv[3]
source_commit = sys.argv[4]
direct_identity_installed = sys.argv[5] == "true"
apple_distribution_installed = sys.argv[6] == "true"
provisioning_profile_configured = sys.argv[7] == "true"
notary_credentials_configured = sys.argv[8] == "true"

def read_text(path):
    try:
        return path.read_text(errors="replace")
    except FileNotFoundError:
        return ""

def classify(mode):
    exit_code = int(read_text(tmp / f"{mode}.exit") or "99")
    stdout = read_text(tmp / f"{mode}.out")
    stderr = read_text(tmp / f"{mode}.err")
    combined = f"{stdout}\n{stderr}"
    app_path = tmp / mode / "MeetingVault.app"
    notarization_archive = tmp / mode / "MeetingVault-notarization.zip"
    pre_notary_gate_passed = "[OK] Pre-notary signing gate passed" in combined
    signing_identity_usable = exit_code == 0 or pre_notary_gate_passed

    if exit_code == 0:
        commands = []
        manual_step = "No manual prerequisite remains for this packaging mode."
        return {
            "mode": mode,
            "status": "pass",
            "exitCode": exit_code,
            "blocker": "none",
            "artifactStaged": app_path.exists(),
            "packageGatePassed": True,
            "preNotaryGatePassed": pre_notary_gate_passed if mode == "direct" else False,
            "notarizationArchiveCreated": notarization_archive.exists() if mode == "direct" else False,
            "notarizationSubmitted": mode == "direct",
            "signingIdentityUsable": True,
            "manualStep": manual_step,
            "nextManualCommands": commands,
        }

    blocker = "unexpected-packaging-failure"
    expected = False
    manual_step = "Inspect the bounded package gate status and rerun the packaging smoke after fixing the prerequisite."
    commands = []
    if mode == "direct":
        if "No Developer ID Application signing identity found" in combined:
            blocker = "missing-developer-id-application-identity"
            expected = True
            signing_identity_usable = False
            manual_step = "Install a Developer ID Application certificate for the selected Apple Developer team, then run the direct package gate."
        elif "Developer ID Application private key is not usable by codesign" in combined:
            blocker = "developer-id-private-key-unusable"
            expected = True
            signing_identity_usable = False
            manual_step = "Authorize codesign to use the Developer ID Application private key in Keychain Access, or reinstall the certificate and private key, then rerun the direct package gate."
        elif "Developer ID Application private key authorization timed out" in combined:
            blocker = "developer-id-private-key-authorization-timeout"
            expected = True
            signing_identity_usable = False
            manual_step = "Approve codesign access to the Developer ID Application private key in Keychain Access, then rerun the direct package gate."
        elif "Distribution signing failed for Developer ID Application" in combined:
            blocker = "developer-id-signing-failed"
            expected = True
            signing_identity_usable = False
            manual_step = "Validate the staged app bundle and Developer ID private-key access locally, then rerun the direct package gate."
        elif "Notarization not requested" in combined:
            blocker = "notarization-not-requested"
            expected = True
            signing_identity_usable = True
            manual_step = "Review the pre-notary archive, configure a notarytool Keychain profile, then rerun packaging with explicit notarization enabled."
        elif "Notarization credentials missing" in combined:
            blocker = "missing-notary-credentials"
            expected = True
            signing_identity_usable = True
            manual_step = "Store App Store Connect notarization credentials in a notarytool Keychain profile, then rerun the direct package gate with that profile."
        elif "Signed package did not pass the direct release gate" in combined:
            blocker = "direct-release-signing-gate-blocked"
            expected = True
            manual_step = "Inspect the local direct signing gate summary, then fix identity, hardened runtime, Gatekeeper, or notarization prerequisites."
        commands = [
            "security find-identity -p codesigning -v",
            "script/check_release_signing.sh --mode direct --phase pre-notary --app dist/release/MeetingVault.app",
            "script/package_release.sh --mode direct --app dist/release/MeetingVault.app --notarize --notarytool-profile <profile>",
            "script/check_release_signing.sh --mode direct --phase post-notary --app dist/release/MeetingVault.app",
        ]
        if not notary_credentials_configured:
            commands.append("Create a notarytool Keychain profile with xcrun notarytool store-credentials before notarization.")
        commands.append("This smoke never submits notarization; only package_release.sh --notarize may submit it.")
    else:
        if "App Store mode requires a valid provisioning profile path" in combined:
            blocker = "missing-app-store-provisioning-profile"
            expected = True
            manual_step = "Provide a valid App Store provisioning profile with --provisioning-profile or MEETINGVAULT_PROVISIONING_PROFILE, then run the app-store package gate."
        elif "No Apple Distribution signing identity found" in combined:
            blocker = "missing-apple-distribution-identity"
            expected = True
            manual_step = "Install or configure the Apple Distribution certificate for the selected team, then run the app-store package gate."
        elif "Signed package did not pass the app-store release gate" in combined:
            blocker = "app-store-release-signing-gate-blocked"
            expected = True
            manual_step = "Inspect the app-store signing gate summary, then fix identity, sandbox entitlements, embedded provisioning, or package validation."
        commands = [
            "security find-identity -p codesigning -v",
            "script/package_release.sh --mode app-store --app dist/release/MeetingVault.app --provisioning-profile <profile.provisionprofile>",
            "script/check_release_signing.sh --mode app-store --app dist/release/MeetingVault.app",
        ]

    return {
        "mode": mode,
        "status": "blocked" if expected else "fail",
        "exitCode": exit_code,
        "blocker": blocker,
        "artifactStaged": app_path.exists(),
        "packageGatePassed": False,
        "preNotaryGatePassed": pre_notary_gate_passed if mode == "direct" else False,
        "notarizationArchiveCreated": notarization_archive.exists() if mode == "direct" else False,
        "notarizationSubmitted": False,
        "signingIdentityUsable": signing_identity_usable,
        "manualStep": manual_step,
        "nextManualCommands": commands,
    }

direct = classify("direct")
app_store = classify("app-store")
issues = []
for result in (direct, app_store):
    if result["status"] == "fail":
        issues.append(f"{result['mode']} packaging failed unexpectedly: {result['blocker']}")

if direct["packageGatePassed"]:
    recommended_path = "direct"
elif app_store["packageGatePassed"]:
    recommended_path = "app-store"
elif direct["preNotaryGatePassed"] and direct["notarizationArchiveCreated"]:
    recommended_path = "direct-needs-notarization"
elif direct_identity_installed and not direct["signingIdentityUsable"]:
    recommended_path = "direct-needs-key-access"
elif direct_identity_installed and notary_credentials_configured:
    recommended_path = "direct-needs-package-gate"
elif apple_distribution_installed and provisioning_profile_configured:
    recommended_path = "app-store-needs-package-gate"
else:
    recommended_path = "blocked-no-local-distribution-prerequisites"

report = {
    "date": date,
    "sourceCommit": source_commit,
    "status": "pass" if not issues else "fail",
    "artifact": "temporary release app bundles",
    "recommendedDistributionPath": recommended_path,
    "distributionPrerequisites": {
        "developerIDApplicationIdentityInstalled": direct_identity_installed,
        "developerIDApplicationIdentityUsable": direct["signingIdentityUsable"],
        "appleDistributionIdentityInstalled": apple_distribution_installed,
        "appStoreProvisioningProfileConfigured": provisioning_profile_configured,
        "notaryCredentialsConfigured": notary_credentials_configured,
    },
    "distributionReady": direct["packageGatePassed"] or app_store["packageGatePassed"],
    "notarizationSubmitted": False,
    "externalUploadAttempted": False,
    "privateAudioRecorded": False,
    "microphoneOpened": False,
    "externalNetworkRequested": False,
    "rawPackagingOutputStored": False,
    "rawSigningOutputStored": False,
    "temporaryBundlesDeleted": True,
    "direct": direct,
    "appStore": app_store,
    "issues": issues,
}
output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
if issues:
    print(f"[FAIL] Release packaging smoke failed: {output}", file=sys.stderr)
    sys.exit(1)
print(f"[OK] Release packaging smoke passed: {output}")
PY
