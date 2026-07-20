# Public Source Boundary

The public repository contains the complete source required to build, test, modify, and redistribute the MeetingVault product: Swift sources, product tests, resources, package manifest, entitlements, local smoke tools, direct-release tooling, public policies, contributor templates, architecture and troubleshooting guides, and CI configuration.

The private development repository can additionally contain raw or bounded release evidence, machine-specific test histories, internal plans, and the repository-owned `ReleaseGateApprovedReportTests.swift` evidence-pinning harness. Those materials are not needed to build or exercise the product and may refer to private machines or approved local fixtures, so the exporter excludes them.

`SOURCE_COMMIT` records the private source commit from which a public tree was exported. The public repository starts from a fresh, sanitized Git history so private development metadata and superseded release history are not published. Official source tags and binary releases must point to matching product source. The export script requires a clean tracked tree unless its explicitly test-only `--allow-dirty` option is used.

No closed-source framework, hosted service, paid module, license key, or separately distributed product component is required to build or use MeetingVault. Apple operating-system frameworks remain subject to Apple's platform terms.
