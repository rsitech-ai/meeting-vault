# Releasing MeetingVault

MeetingVault is distributed directly through GitHub Releases. A release is publishable only after its source commit, archive, signature, notarization ticket, checksum, and release notes agree.

## One-time setup

1. Join the Apple Developer Program and install a `Developer ID Application` certificate with its private key in the login Keychain.
2. Create an App Store Connect API key or app-specific password suitable for notarization.
3. Store credentials in Keychain without putting secrets in shell history or the repository:

   ```bash
   xcrun notarytool store-credentials MeetingVault-Notary
   ```

   Any Keychain profile created with `notarytool store-credentials` for the
   same Apple Developer account may be passed to packaging. Prefer a
   MeetingVault-specific profile name so credentials stay easy to rotate.

4. Confirm the identity is visible and usable:

   ```bash
   security find-identity -p codesigning -v
   ```

If `codesign` waits for or rejects private-key access, authorize `/usr/bin/codesign` in Keychain Access or reinstall a complete certificate/private-key pair. Certificate visibility alone does not prove that signing is usable.

## Candidate checks

From a clean source commit:

```bash
swift test
swift build -c release -Xswiftc -warnings-as-errors
bash -n script/*.sh
git diff --check
script/clean_checkout_smoke.sh
```

Review open privacy/security issues and complete the approved non-private real-capture, long-recording, clean-machine permission, accessibility, sleep/wake, and system-integration gates relevant to the candidate. These checks cannot be replaced by build logs.

## Sign without submitting

```bash
script/package_release.sh --mode direct
```

The script stages an unsigned Release bundle, signs it with Developer ID and hardened runtime, validates the signature/entitlements, creates `MeetingVault-notarization.zip`, and intentionally exits with code 3 before any Apple submission. Review this archive and the source commit.

## Notarize and create the final archive

```bash
script/package_release.sh \
  --mode direct \
  --notarize \
  --notarytool-profile MeetingVault-Notary
```

The script submits the reviewed archive, requires an `Accepted` result, staples and validates the ticket, runs Gatekeeper assessment, and creates a versioned architecture-specific ZIP plus `.sha256` file. Raw notarization output is kept temporary so credentials or account metadata are not committed accidentally.

Independently verify before upload:

```bash
codesign --verify --deep --strict --verbose=2 dist/release/MeetingVault.app
xcrun stapler validate dist/release/MeetingVault.app
spctl -a -vv --type execute dist/release/MeetingVault.app
shasum -a 256 -c dist/release/MeetingVault-*.zip.sha256
```

## Publish

1. Export the clean public source tree with `script/export_public_source.sh --output /tmp/meeting-vault-public`.
2. Confirm public CI is green at the same source commit.
3. Create a signed Git tag matching `CFBundleShortVersionString`.
4. Create a GitHub prerelease while the version is below 1.0.
5. Start from `docs/release-notes-0.1.0.md`, update it to match the candidate exactly, upload the final ZIP and checksum, and link to the exact source tag.
6. Download the published archive on a separate clean macOS user or machine, verify the checksum, launch it normally, and confirm first-run permission recovery without bypassing Gatekeeper.

Do not publish a binary release if any signing, notarization, Gatekeeper, checksum, clean-install, or source-correspondence gate is unknown or blocked.
