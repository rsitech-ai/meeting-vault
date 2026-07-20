# Troubleshooting

## The app does not launch from source

Run `./script/build_and_run.sh --verify` from the repository root. Confirm `swift --version` reports Swift 6 or later and that the active toolchain provides the macOS 26 SDK. The script reports the staged app path and fails if the foreground process exits during the launch check.

## Recording is unavailable

Open Recording Setup and read the exact readiness message for the selected microphone or system-audio source. macOS grants microphone and Screen & System Audio Recording access separately. After changing a privacy permission in System Settings, relaunch MeetingVault before retrying.

## Transcription is unavailable

Apple Speech requires Speech Recognition permission and may depend on locale, assets, network access, or Apple service availability. Local transcription requires every checksummed model unit shown in Models & Privacy to finish installation and self-check. The app should identify the unavailable provider rather than silently switching privacy modes.

## Apple Intelligence features are unavailable

Titles, summaries, and transcript-grounded answers require Apple Foundation Models availability on the current Mac. Recording, playback, editing, search, and export remain local workflows when those features are unavailable.

## An official archive is rejected by macOS

Do not bypass Gatekeeper. Verify the archive checksum from the GitHub release, then report the release name, macOS version, and the exact Gatekeeper message without including meeting data. An official archive must be Developer ID signed, notarized, stapled, and accepted by Gatekeeper.

## A development rebuild asks for a Keychain password

The default source workflow uses a file-backed development key. If you intentionally launched with `./script/build_and_run.sh --key-provider keychain`, Keychain authorization is expected. Return to the default command for normal source development.

## Preparing a useful report

Use the issue form and a synthetic fixture. Include the MeetingVault version or full commit, macOS version, Mac model, installation source, reproduction steps, and redacted diagnostics. Follow [Security Policy](../SECURITY.md) for suspected vulnerabilities or privacy exposure.
