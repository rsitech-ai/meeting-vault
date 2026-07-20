# Contributing to MeetingVault

Thank you for helping improve MeetingVault. Contributions are accepted under the same Apache-2.0 terms as the project.

## Before opening a change

1. Search existing issues and pull requests.
2. Open an issue first for substantial product, privacy, storage-format, entitlement, or release-process changes.
3. Keep meeting content, credentials, signing material, personal paths, and private evidence out of the repository.
4. Use synthetic or explicitly approved non-private fixtures in tests and screenshots.

## Development workflow

Create a focused branch, make the smallest coherent change, and run:

```bash
swift test
swift build -c release -Xswiftc -warnings-as-errors
bash -n script/*.sh
git diff --check
```

For app-facing changes, also run `./script/build_and_run.sh --verify` and describe the manual interaction or accessibility checks performed.

The package boundaries and release path are described in [Architecture](docs/architecture.md). See [Support](SUPPORT.md) and [Troubleshooting](docs/troubleshooting.md) before reporting an environment-specific failure.

## Pull requests

A pull request should explain the user outcome, privacy/security impact, verification performed, and any remaining manual or external blocker. Do not describe a build as signed, notarized, or release-ready without the corresponding evidence.

Unless you explicitly state otherwise, a contribution intentionally submitted for inclusion in MeetingVault is licensed under Apache-2.0, as described in Section 5 of the license. A separate contributor license agreement is not required.

## Design constraints

- Keep meeting data local unless the user explicitly invokes an Apple service or reviewed export/handoff.
- Require clear consent and visible recording state.
- Keep pure logic separate from I/O and make boundary failures explicit.
- Do not add telemetry, advertising, DRM, account requirements, or paid feature gates.
- Minimize dependencies and document any new network or entitlement surface.
