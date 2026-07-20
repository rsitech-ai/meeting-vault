# Security Policy

## Supported versions

Security fixes are provided for the latest published prerelease. Until the first public release exists, use the current default branch and treat all builds as development software.

## Report a vulnerability

Please use [GitHub private vulnerability reporting](https://github.com/rsitech-ai/meeting-vault/security/advisories/new). If that route is unavailable, email [info@rsitech.ai](mailto:info@rsitech.ai). Do not open a public issue for a suspected vulnerability involving encryption, meeting-data disclosure, permissions, signing, update delivery, or command execution.

Include the affected commit or version, macOS version, reproduction steps, impact, and a minimal non-private proof. Never send real meeting recordings, transcripts, credentials, recovery keys, Apple signing certificates, or notarization profiles.

You should receive an acknowledgement within seven days. Coordinated disclosure timing will be agreed after validation and a fix plan. Good-faith research that avoids privacy violations, service disruption, persistence, and access to other people's data is welcome.

Official release archives are accompanied by SHA-256 files and must be Developer ID signed, notarized, stapled, and accepted by Gatekeeper. The project does not recommend bypassing Gatekeeper for an archive presented as an official release.
