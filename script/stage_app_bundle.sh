#!/usr/bin/env bash
set -euo pipefail

APP_NAME="MeetingVault"
BUNDLE_ID="com.andrzej.MeetingVault"
MIN_SYSTEM_VERSION="26.0"
APP_VERSION="${MEETINGVAULT_APP_VERSION:-0.1.0}"
BUILD_NUMBER="${MEETINGVAULT_BUILD_NUMBER:-1}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="debug"
APP_BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"
SIGNING_IDENTITY="${MEETINGVAULT_SIGNING_IDENTITY:-auto}"
SIGNING_ENTITLEMENTS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --configuration)
      CONFIGURATION="${2:-}"
      shift 2
      ;;
    --app)
      APP_BUNDLE="${2:-}"
      shift 2
      ;;
    --signing-identity)
      SIGNING_IDENTITY="${2:-}"
      shift 2
      ;;
    --entitlements)
      SIGNING_ENTITLEMENTS="${2:-}"
      shift 2
      ;;
    -h|--help)
      echo "Usage: $0 [--configuration debug|release] [--app /path/to/MeetingVault.app] [--signing-identity auto|ad-hoc|none|IDENTITY] [--entitlements PATH]"
      exit 0
      ;;
    *)
      printf '[BLOCKED] Unknown argument: %s\n' "$1" >&2
      exit 2
      ;;
  esac
done

case "$CONFIGURATION" in
  debug)
    BUILD_ARGS=(--configuration debug)
    ;;
  release)
    BUILD_ARGS=(--configuration release)
    ;;
  *)
    printf '[BLOCKED] Configuration must be debug or release, found %s\n' "$CONFIGURATION" >&2
    exit 2
    ;;
esac

if [[ "$(basename "$APP_BUNDLE")" != "$APP_NAME.app" ]]; then
  printf '[BLOCKED] --app must end with exactly %s.app, found %s\n' "$APP_NAME" "$APP_BUNDLE" >&2
  exit 2
fi

APP_PARENT="$(dirname "$APP_BUNDLE")"
mkdir -p "$APP_PARENT"
APP_PARENT="$(cd "$APP_PARENT" && pwd -P)"
APP_BUNDLE="$APP_PARENT/$APP_NAME.app"
case "$APP_BUNDLE" in
  "/"|"$HOME"|"$ROOT_DIR"|"$ROOT_DIR/"|"$APP_PARENT")
    printf '[BLOCKED] Refusing unsafe app staging target: %s\n' "$APP_BUNDLE" >&2
    exit 2
    ;;
esac
if [[ -L "$APP_BUNDLE" ]]; then
  printf '[BLOCKED] Refusing symlink app staging target: %s\n' "$APP_BUNDLE" >&2
  exit 2
fi

APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_HELPERS="$APP_CONTENTS/Helpers"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
PRIVACY_MANIFEST="$ROOT_DIR/Sources/MeetingVault/Resources/PrivacyInfo.xcprivacy"
APP_ICON="$ROOT_DIR/Sources/MeetingVault/Resources/MeetingVault.icns"
APP_ICON_GENERATOR="$ROOT_DIR/script/generate_app_icon.swift"

cd "$ROOT_DIR"

"$ROOT_DIR/script/check_local_model_supply_chain.sh" >&2

swift build "${BUILD_ARGS[@]}" --product "$APP_NAME" >&2
swift build "${BUILD_ARGS[@]}" --product MeetingVaultLocalModelSelfCheck >&2
BUILD_BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"
BUILD_BINARY="$BUILD_BIN_DIR/$APP_NAME"
SELF_CHECK_BINARY="$BUILD_BIN_DIR/MeetingVaultLocalModelSelfCheck"

if [[ ! -f "$APP_ICON" ]]; then
  xcrun swift "$APP_ICON_GENERATOR" >&2
fi

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES" "$APP_HELPERS"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"
cp "$SELF_CHECK_BINARY" "$APP_HELPERS/MeetingVaultLocalModelSelfCheck"
chmod +x "$APP_HELPERS/MeetingVaultLocalModelSelfCheck"
cp "$PRIVACY_MANIFEST" "$APP_RESOURCES/PrivacyInfo.xcprivacy"
cp "$APP_ICON" "$APP_RESOURCES/MeetingVault.icns"
mkdir -p "$APP_RESOURCES/Legal"
cp "$ROOT_DIR/LICENSE" "$APP_RESOURCES/Legal/LICENSE"
cp "$ROOT_DIR/NOTICE" "$APP_RESOURCES/Legal/NOTICE"
resource_bundle_count=0
for resource_bundle in "$BUILD_BIN_DIR"/MeetingVault_*.bundle; do
  [[ -d "$resource_bundle" ]] || continue
  cp -R "$resource_bundle" "$APP_RESOURCES/$(basename "$resource_bundle")"
  resource_bundle_count=$((resource_bundle_count + 1))
done
if [[ "$resource_bundle_count" -lt 2 ]]; then
  printf '[BLOCKED] Expected MeetingVault app and core resource bundles were not built.\n' >&2
  exit 1
fi
for required_resource in LocalModels.json FluidAudio.txt LocalModels.txt fastcluster-LICENSE.md vbx-LICENSE.md; do
  if ! find "$APP_RESOURCES" -path "*MeetingVault_MeetingVaultCore.bundle/$required_resource" -type f -print -quit | grep -q .; then
    printf '[BLOCKED] Core resource was not staged: %s\n' "$required_resource" >&2
    exit 1
  fi
done
for legal_resource in LICENSE NOTICE; do
  if [[ ! -s "$APP_RESOURCES/Legal/$legal_resource" ]]; then
    printf '[BLOCKED] Project legal resource was not staged: %s\n' "$legal_resource" >&2
    exit 1
  fi
done

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleIconFile</key>
  <string>MeetingVault</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_NUMBER</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSAudioCaptureUsageDescription</key>
  <string>MeetingVault records system audio you choose so it can create local meeting transcripts and summaries.</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>MeetingVault records your microphone when you choose to include your own voice in meeting notes.</string>
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>MeetingVault transcribes selected meeting audio into local notes and summaries.</string>
  <key>NSCalendarsFullAccessUsageDescription</key>
  <string>MeetingVault writes reviewed meeting follow-up events only after you confirm a Calendar handoff.</string>
  <key>NSRemindersFullAccessUsageDescription</key>
  <string>MeetingVault writes reviewed meeting follow-up reminders only after you confirm a Reminders handoff.</string>
  <key>NSContactsUsageDescription</key>
  <string>MeetingVault writes reviewed contact follow-up cards only after you confirm a Contacts handoff.</string>
</dict>
</plist>
PLIST

if [[ -z "$SIGNING_ENTITLEMENTS" ]]; then
  case "$CONFIGURATION" in
    debug)
      SIGNING_ENTITLEMENTS="$ROOT_DIR/config/entitlements/development.plist"
      ;;
    release)
      SIGNING_ENTITLEMENTS="$ROOT_DIR/config/entitlements/direct-distribution.plist"
      ;;
  esac
fi

resolved_signing_identity="$SIGNING_IDENTITY"
if [[ "$SIGNING_IDENTITY" == "auto" ]]; then
  resolved_signing_identity="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F '\"' '/Apple Development:/{print $2; exit}')"
  if [[ -z "$resolved_signing_identity" ]]; then
    resolved_signing_identity="-"
  fi
elif [[ "$SIGNING_IDENTITY" == "ad-hoc" ]]; then
  resolved_signing_identity="-"
fi

if [[ "$resolved_signing_identity" != "none" ]]; then
  codesign --force --options runtime --sign "$resolved_signing_identity" "$APP_HELPERS/MeetingVaultLocalModelSelfCheck" >&2
  codesign --force --options runtime --entitlements "$SIGNING_ENTITLEMENTS" --sign "$resolved_signing_identity" "$APP_BUNDLE" >&2
fi

printf '%s\n' "$APP_BUNDLE"
