# Architecture

MeetingVault is a Swift Package Manager macOS application with a local-first core and explicit operating-system integration boundaries.

## Components

- `MeetingVaultCore` contains models and services for capture, transcription, encrypted bundles, search, playback, editing, export, recovery, local models, and reviewed system handoffs.
- `MeetingVault` contains the SwiftUI application, stores, platform wiring, and user-facing workspaces.
- The remaining executable targets are bounded diagnostics and smoke tools used by local and release validation.
- `Tests/MeetingVaultCoreTests` exercises pure and persistence logic. `Tests/MeetingVaultAppTests` covers application-store behavior, presentation contracts, and production wiring.

## Data flow

1. The user selects capture sources and starts a consent-aware recording.
2. Capture frames are written to app-managed encrypted meeting bundles and passed to the selected transcription path.
3. Final transcript state feeds local search, playback cues, confidence review, summaries, and transcript-grounded questions.
4. Transcript corrections update versioned transcript state and regenerate dependent artifacts before the new state is presented as complete.
5. Export and Calendar, Contacts, or Reminders handoffs occur only after an explicit user action and destination review.

Meeting content has no project-operated backend. Apple Speech may communicate with Apple as described in [Privacy](../PRIVACY.md). Local model downloads are declared by a checksummed manifest, validated before use, and kept out of source and release archives.

## Persistence and recovery

Meeting bundles are the durable source of truth. Search indexes and derived intelligence can be rebuilt from bundle artifacts. Recovery markers make interrupted transcript corrections and recordings explicit rather than silently accepting partially regenerated state.

Development builds use a file-backed local key by default to avoid misleading Keychain prompts after ad-hoc rebuilds. Distribution builds use the signed configuration and Keychain path described in [Releasing](../RELEASING.md).

## Release boundary

`script/stage_app_bundle.sh` stages the application bundle. `script/package_release.sh` owns signing, notarization, stapling, Gatekeeper validation, archive naming, and checksums. `script/export_public_source.sh` creates the corresponding public source tree without private evidence or generated build output.
