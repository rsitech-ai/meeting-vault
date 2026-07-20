# MeetingVault 0.1.0 release notes

MeetingVault 0.1.0 is the proposed first public prerelease of the native, local-first macOS meeting workspace.

## Highlights

- Consent-aware microphone and optional system-audio recording
- Apple Speech and explicitly installed local transcription paths
- Encrypted local meeting bundles with recovery and retention controls
- Search, playback, transcript editing, confidence review, export, and reviewed system handoffs
- On-device titles, summaries, and transcript-grounded questions when Apple Foundation Models is available

## Install

Download the versioned ZIP and matching `.sha256` file from the GitHub release. Verify the checksum, unzip the archive, and move `MeetingVault.app` to `/Applications`. Do not bypass Gatekeeper for an archive presented as an official release.

## Compatibility and limitations

- Requires an Apple silicon Mac running macOS 26 or later.
- This is prerelease software; storage formats and behavior can change before 1.0.
- Apple Speech availability and server processing depend on locale, device capability, and Apple services.
- Apple Foundation Models features require Apple Intelligence availability on the current Mac.
- There is no automatic updater in 0.1.0.
- Recording legality and consent requirements vary. Confirm consent from every participant and follow applicable policies.

## Upgrade notes

There is no earlier public MeetingVault release to migrate from. Back up important user-created exports before replacing a development build. Do not assume forks or locally modified builds share the official bundle, signing, or data-compatibility guarantees.

## Verification

An official release must include a Developer ID signature, accepted notarization ticket, stapled ticket, successful Gatekeeper assessment, versioned architecture-specific ZIP, SHA-256 file, and matching source tag. The release must remain a draft if any of those gates is missing.

## Security and privacy reports

Do not attach real recordings, transcripts, credentials, or recovery keys to public issues. Follow [Security Policy](../SECURITY.md) to report suspected vulnerabilities privately.

## Source and license

The complete corresponding source is licensed under Apache-2.0 and maintained by RSI Tech. See [License](../LICENSE), [Notice](../NOTICE), [Privacy](../PRIVACY.md), and [Releasing](../RELEASING.md).
