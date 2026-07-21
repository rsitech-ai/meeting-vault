#!/usr/bin/env bash
set -u

APP_PATH="dist/MeetingVault.app"
MODE="direct"
PHASE="post-notary"
EXPECTED_BUNDLE_ID="com.andrzej.MeetingVault"
EXPECTED_MIN_SYSTEM_VERSION="26.0"
APP_NAME="MeetingVault"
PRIVACY_MANIFEST_NAME="PrivacyInfo.xcprivacy"
APP_ICON_NAME="MeetingVault.icns"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)
      APP_PATH="${2:-}"
      shift 2
      ;;
    --mode)
      MODE="${2:-}"
      shift 2
      ;;
    --phase)
      PHASE="${2:-}"
      shift 2
      ;;
    -h|--help)
      echo "Usage: $0 [--app dist/MeetingVault.app] [--mode direct|app-store] [--phase pre-notary|post-notary]"
      exit 0
      ;;
    *)
      printf '[BLOCKED] Unknown argument: %s\n' "$1"
      exit 2
      ;;
  esac
done

blocked=0

info() { printf '[INFO] %s\n' "$*"; }
ok() { printf '[OK] %s\n' "$*"; }
block() {
  printf '[BLOCKED] %s\n' "$*"
  blocked=1
}

require_file() {
  if [[ -f "$1" ]]; then
    ok "$2"
  else
    block "$2 missing at $1"
  fi
}

require_dir() {
  if [[ -d "$1" ]]; then
    ok "$2"
  else
    block "$2 missing at $1"
  fi
}

if [[ "$MODE" != "direct" && "$MODE" != "app-store" ]]; then
  block "Mode must be direct or app-store"
fi
if [[ "$PHASE" != "pre-notary" && "$PHASE" != "post-notary" ]]; then
  block "Phase must be pre-notary or post-notary"
fi
if [[ "$MODE" == "app-store" && "$PHASE" != "post-notary" ]]; then
  block "App Store validation supports only the post-notary phase"
fi

INFO_PLIST="$APP_PATH/Contents/Info.plist"
APP_BINARY="$APP_PATH/Contents/MacOS/$APP_NAME"
PRIVACY_MANIFEST="$APP_PATH/Contents/Resources/$PRIVACY_MANIFEST_NAME"
APP_ICON="$APP_PATH/Contents/Resources/$APP_ICON_NAME"
PROJECT_LICENSE="$APP_PATH/Contents/Resources/Legal/LICENSE"
PROJECT_NOTICE="$APP_PATH/Contents/Resources/Legal/NOTICE"
PROVISIONING_PROFILE="$APP_PATH/Contents/embedded.provisionprofile"

require_dir "$APP_PATH" "App bundle"
require_file "$INFO_PLIST" "Info.plist"
require_file "$APP_BINARY" "Main executable"
require_file "$PROJECT_LICENSE" "Apache-2.0 license"
require_file "$PROJECT_NOTICE" "Project notice"

plist_value() {
  if [[ -f "$INFO_PLIST" ]]; then
    /usr/libexec/PlistBuddy -c "Print :$1" "$INFO_PLIST" 2>/dev/null || true
  fi
}

check_plist_value() {
  local key="$1"
  local expected="$2"
  local label="$3"
  local value
  value="$(plist_value "$key")"
  if [[ "$value" == "$expected" ]]; then
    ok "$label"
  else
    block "$label expected '$expected', found '${value:-missing}'"
  fi
}

check_plist_present() {
  local key="$1"
  local label="$2"
  local value
  value="$(plist_value "$key")"
  if [[ -n "$value" ]]; then
    ok "$label"
  else
    block "$label missing"
  fi
}

check_plist_value "CFBundleIdentifier" "$EXPECTED_BUNDLE_ID" "Bundle identifier"
check_plist_value "CFBundleExecutable" "$APP_NAME" "Bundle executable"
check_plist_value "CFBundlePackageType" "APPL" "Bundle package type"
check_plist_value "CFBundleIconFile" "MeetingVault" "Bundle icon declaration"
check_plist_value "LSMinimumSystemVersion" "$EXPECTED_MIN_SYSTEM_VERSION" "Minimum macOS version"
check_plist_present "NSAudioCaptureUsageDescription" "Audio capture purpose string"
check_plist_present "NSMicrophoneUsageDescription" "Microphone purpose string"
check_plist_present "NSSpeechRecognitionUsageDescription" "Speech recognition purpose string"
check_plist_present "NSCalendarsFullAccessUsageDescription" "Calendar purpose string"
check_plist_present "NSRemindersFullAccessUsageDescription" "Reminders purpose string"
check_plist_present "NSContactsUsageDescription" "Contacts purpose string"

version="$(plist_value "CFBundleShortVersionString")"
if [[ "$version" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]; then
  ok "Release version $version"
else
  block "CFBundleShortVersionString must be a dotted numeric release version, found '${version:-missing}'"
fi

build_number="$(plist_value "CFBundleVersion")"
if [[ "$build_number" =~ ^[0-9]+$ ]]; then
  ok "Build number $build_number"
else
  block "CFBundleVersion must be a numeric build number, found '${build_number:-missing}'"
fi

if [[ -f "$PRIVACY_MANIFEST" ]]; then
  if plutil -lint "$PRIVACY_MANIFEST" >/dev/null 2>&1; then
    ok "Privacy manifest is present and valid"
  else
    block "Privacy manifest is present but invalid"
  fi
else
  block "Privacy manifest missing at $PRIVACY_MANIFEST"
fi

if [[ -f "$APP_ICON" ]]; then
  if [[ -s "$APP_ICON" ]]; then
    ok "App icon is present"
  else
    block "App icon exists but is empty at $APP_ICON"
  fi
else
  block "App icon missing at $APP_ICON"
fi

identity_output="$(security find-identity -p codesigning -v 2>/dev/null || true)"
if [[ "$MODE" == "direct" ]]; then
  if printf '%s\n' "$identity_output" | grep -Eq 'Developer ID Application'; then
    ok "Developer ID Application identity installed"
  else
    block "No Developer ID Application signing identity found. Manual step: install a Developer ID Application certificate for direct distribution."
  fi
else
  if printf '%s\n' "$identity_output" | grep -Eq 'Apple Distribution'; then
    ok "Apple Distribution identity installed"
  else
    block "No Apple Distribution signing identity found. Manual step: install/configure the Apple Distribution certificate for the selected team."
  fi
fi

codesign_output="$(codesign -dvvv --entitlements :- "$APP_PATH" 2>&1 || true)"
codesign_verify_output="$(codesign --verify --deep --strict --verbose=2 "$APP_PATH" 2>&1 || true)"
if printf '%s\n' "$codesign_verify_output" | grep -Eq 'valid on disk|satisfies its Designated Requirement'; then
  ok "Code signature verifies on disk"
else
  block "Code signature verification failed: $(printf '%s\n' "$codesign_verify_output" | head -1)"
fi

helper_binary="$APP_PATH/Contents/Helpers/MeetingVaultLocalModelSelfCheck"
if [[ -f "$helper_binary" ]]; then
  helper_output="$(codesign -dvvv "$helper_binary" 2>&1 || true)"
  if printf '%s\n' "$helper_output" | grep -q 'Signature=adhoc'; then
    block "Nested helper is ad-hoc signed; resign Contents/Helpers with the distribution identity before notarization"
  elif [[ "$MODE" == "direct" ]] && printf '%s\n' "$helper_output" | grep -Eq 'Authority=Developer ID Application'; then
    if printf '%s\n' "$helper_output" | grep -q 'runtime'; then
      ok "Nested helper is Developer ID signed with hardened runtime"
    else
      block "Nested helper is missing hardened runtime"
    fi
    if printf '%s\n' "$helper_output" | grep -Eq 'Timestamp|Signed Time'; then
      ok "Nested helper includes a secure timestamp"
    else
      block "Nested helper signature is missing a secure timestamp"
    fi
  elif [[ "$MODE" == "app-store" ]] && printf '%s\n' "$helper_output" | grep -Eq 'Authority=Apple Distribution'; then
    ok "Nested helper is Apple Distribution signed"
  else
    block "Nested helper is not signed with the required $MODE distribution authority"
  fi
fi

if printf '%s\n' "$codesign_output" | grep -q 'code object is not signed at all'; then
  block "App is unsigned"
elif printf '%s\n' "$codesign_output" | grep -q 'Signature=adhoc'; then
  block "App is ad-hoc signed, not distribution-signed"
elif [[ "$MODE" == "direct" ]] && printf '%s\n' "$codesign_output" | grep -Eq 'Authority=Developer ID Application'; then
  ok "App is signed with Developer ID Application authority"
elif [[ "$MODE" == "app-store" ]] && printf '%s\n' "$codesign_output" | grep -Eq 'Authority=Apple Distribution'; then
  ok "App is signed with Apple Distribution authority"
else
  block "App is not signed with the required $MODE distribution authority"
fi

if printf '%s\n' "$codesign_output" | grep -q 'code object is not signed at all'; then
  block "Info.plist is not sealed because the app is unsigned"
elif printf '%s\n' "$codesign_output" | grep -q 'Info.plist=not bound'; then
  block "Info.plist is not sealed by the code signature"
else
  ok "Info.plist is sealed by the code signature"
fi

if [[ "$MODE" == "direct" ]]; then
  if printf '%s\n' "$codesign_output" | grep -q 'runtime'; then
    ok "Hardened runtime is enabled"
  else
    block "Hardened runtime is missing. Manual step: sign the app with --options runtime for Developer ID distribution."
  fi

fi

if [[ "$MODE" == "app-store" ]]; then
  if [[ -f "$PROVISIONING_PROFILE" ]]; then
    if security cms -D -i "$PROVISIONING_PROFILE" >/dev/null 2>&1; then
      ok "Embedded provisioning profile is present and decodable"
    else
      block "Embedded provisioning profile is present but not decodable"
    fi
  else
    block "Embedded provisioning profile missing. Manual step: embed a valid App Store provisioning profile."
  fi

  if printf '%s\n' "$codesign_output" | grep -q '<key>com.apple.security.app-sandbox</key>'; then
    ok "App Sandbox entitlement is present"
  else
    block "App Sandbox entitlement missing. Manual step: enable sandbox and review the smallest entitlement set for Mac App Store."
  fi

  if printf '%s\n' "$codesign_output" | grep -q '<key>com.apple.security.personal-information.addressbook</key>'; then
    ok "Contacts entitlement is present"
  else
    block "Contacts entitlement missing. Manual step: include addressbook entitlement for confirmed Contacts handoff."
  fi

  if printf '%s\n' "$codesign_output" | grep -q '<key>com.apple.security.personal-information.calendars</key>'; then
    ok "Calendar/Reminders entitlement is present"
  else
    block "Calendar/Reminders entitlement missing. Manual step: include calendars entitlement for confirmed Calendar and Reminders handoff."
  fi
fi

if [[ "$MODE" == "direct" && "$PHASE" == "pre-notary" ]]; then
  info "Stapler and Gatekeeper validation are deferred until Apple accepts notarization"
else
  if [[ "$MODE" == "direct" ]]; then
    stapler_output="$(xcrun stapler validate "$APP_PATH" 2>&1 || true)"
    if printf '%s\n' "$stapler_output" | grep -Eq 'worked!|valid'; then
      ok "Notarization ticket is stapled and validates"
    else
      block "Stapled notarization ticket did not validate"
    fi
  fi

  spctl_output="$(spctl -a -vv --type execute "$APP_PATH" 2>&1 || true)"
  if printf '%s\n' "$spctl_output" | grep -Eq 'accepted'; then
    ok "Gatekeeper assessment accepted the app"
  else
    block "Gatekeeper assessment did not accept the app: $(printf '%s\n' "$spctl_output" | head -1)"
  fi
fi

if [[ "$blocked" -eq 0 ]]; then
  ok "Release signing gate passed for $MODE ($PHASE)"
else
  info "Release signing gate failed closed for $MODE ($PHASE)"
fi

exit "$blocked"
