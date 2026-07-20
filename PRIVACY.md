# Privacy

MeetingVault is designed for local-first meeting work. It does not include developer-operated accounts, analytics, advertising, telemetry, or a transcription backend.

## Data stored on the Mac

Meeting recordings, transcripts, generated artifacts, search data, import metadata, privacy-audit records, and recovery state are stored locally. Meeting bundles and audio chunks are encrypted by the app. Exports are written only to a location selected by the user.

Deleting a meeting removes the app-managed meeting bundle and its search records, subject to normal filesystem and backup behavior. A user-created export is independent and must be deleted separately.

## Apple services

- Apple Speech provides live or final transcription. Depending on language, device capability, and service availability, Apple may process recorded voice on its servers. Speech Recognition permission is requested before use.
- Apple Foundation Models provides on-device titles, summaries, and transcript-grounded answers when Apple Intelligence is available.
- Keychain can protect the local encryption key in distribution builds.
- Apple notarization is used only while publishing the application binary; meeting data is never part of the submission.

## Permissions

MeetingVault may request microphone, Speech Recognition, and Screen & System Audio Recording permissions for capture. It may request Calendar, Reminders, or Contacts access only when the user reviews and confirms a corresponding system handoff. File access is user-selected.

The app should remain useful when optional permissions or model assets are unavailable, while clearly identifying the affected feature.

## Network behavior

The application has no project-operated network service and does not send meeting content to the project maintainers. Operating-system frameworks, especially Apple Speech, can communicate with Apple as described above. GitHub is used outside the app to distribute releases and source code.

## Sensitive-data guidance

Obtain consent from every participant before recording. Avoid attaching real recordings or transcripts to public issues. Use synthetic fixtures when reporting bugs, and report security-sensitive privacy failures through [SECURITY.md](SECURITY.md).

This document describes the project source and official build configuration. Forks and modified builds can behave differently; review their source and distributor disclosures.
