#!/usr/bin/env swift
import Foundation

struct EvidenceCheck: Codable {
    var id: String
    var path: String
    var expectedStatus: String
    var actualStatus: String?
    var requiredForLocalReady: Bool
    var requiredForReleaseCandidate: Bool
    var passed: Bool
    var issues: [String]
}

struct ReleaseReadinessAuditReport: Codable {
    var timestamp: String
    var status: String
    var label: String
    var sourceCommit: String
    var cleanCheckoutSourceCommit: String?
    var sourceDrift: SourceDriftReport
    var localReady: Bool
    var releaseCandidateReady: Bool
    var readyForAppStoreSubmission: Bool
    var checks: [EvidenceCheck]
    var releaseCandidateBlockers: [String]
    var manualApprovalBlockers: [String]
    var operatorBlockers: [String]
    var privacy: PrivacyFlags
    var rawTranscriptStored: Bool
    var rawAudioStored: Bool
    var rawModelOutputStored: Bool
    var rawLogsStored: Bool
    var rawUITextStored: Bool
    var issues: [String]
}

struct PrivacyFlags: Codable {
    var privateAudioRecorded: Bool
    var microphoneOpened: Bool
    var externalNetworkRequested: Bool
    var downloadRequested: Bool
    var externalUploadAttempted: Bool
    var notarizationSubmitted: Bool
}

struct SourceDriftReport: Codable {
    var checked: Bool
    var currentCommit: String
    var cleanCheckoutCommit: String?
    var changedPathsSinceCleanCheckout: [String]
    var uncommittedPaths: [String]
    var blockingPaths: [String]
    var uncommittedBlockingPaths: [String]
    var ignoredPaths: [String]
    var blocksLocalReady: Bool
    var issues: [String]
}

struct EvidenceDefinition {
    var id: String
    var relativePath: String
    var expectedStatus: String = "pass"
    var requiredForLocalReady: Bool = true
    var requiredForReleaseCandidate: Bool = true
}

enum ReleaseReadinessAudit {
    static func main() {
        let rootURL = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let date = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
        var outputURL = rootURL
            .appendingPathComponent("docs", isDirectory: true)
            .appendingPathComponent("evidence", isDirectory: true)
            .appendingPathComponent("release-readiness-audit-\(date).json")
        var evidenceDate = today()
        var headroomEvidenceURL: URL?
        var headroomEvidenceProvided = false
        var requireLocalReady = false
        var requireReleaseCandidate = false

        var iterator = CommandLine.arguments.dropFirst().makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--output":
                guard let value = iterator.next() else {
                    fputs("--output requires a path\n", stderr)
                    exit(2)
                }
                outputURL = URL(fileURLWithPath: value)
            case "--evidence-date":
                guard let value = iterator.next() else {
                    fputs("--evidence-date requires YYYY-MM-DD\n", stderr)
                    exit(2)
                }
                guard isValidEvidenceDate(value) else {
                    fputs("--evidence-date must use YYYY-MM-DD\n", stderr)
                    exit(2)
                }
                evidenceDate = value
            case "--headroom-evidence":
                guard let value = iterator.next(), !value.isEmpty else {
                    fputs("--headroom-evidence requires a path\n", stderr)
                    exit(2)
                }
                headroomEvidenceURL = URL(fileURLWithPath: value)
                headroomEvidenceProvided = true
            case "--require-local-ready":
                requireLocalReady = true
            case "--require-release-candidate":
                requireReleaseCandidate = true
            case "--help", "-h":
                print("""
                usage: script/release_readiness_audit.swift [--output PATH] [--evidence-date YYYY-MM-DD] [--headroom-evidence PATH] [--require-local-ready] [--require-release-candidate]

                Aggregates bounded MeetingVault evidence into an honest readiness label.
                The audit reads existing JSON smoke reports, does not record private audio,
                does not open the microphone, does not submit notarization, and does not
                upload externally. By default it reads today's evidence set; use
                --evidence-date to audit a specific committed evidence set reproducibly.
                It exits non-zero only when a requested readiness level is not met.
                """)
                exit(0)
            default:
                fputs("unknown argument: \(argument)\n", stderr)
                exit(2)
            }
        }

        let resolvedHeadroomEvidenceURL = headroomEvidenceURL ?? defaultHeadroomEvidenceURL(
            rootURL: rootURL,
            evidenceDate: evidenceDate
        )
        let report = buildReport(
            rootURL: rootURL,
            evidenceDate: evidenceDate,
            headroomEvidenceURL: resolvedHeadroomEvidenceURL,
            headroomEvidenceRequired: headroomEvidenceProvided
        )
        do {
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(report)
            try data.write(to: outputURL, options: .atomic)
        } catch {
            fputs("failed to write release readiness audit: \(error.localizedDescription)\n", stderr)
            exit(1)
        }

        print("Wrote \(outputURL.path)")
        print("label=\(report.label) localReady=\(report.localReady) releaseCandidateReady=\(report.releaseCandidateReady)")
        if requireReleaseCandidate && !report.releaseCandidateReady {
            exit(1)
        }
        if requireLocalReady && !report.localReady {
            exit(1)
        }
        exit(0)
    }

    private static func buildReport(
        rootURL: URL,
        evidenceDate: String,
        headroomEvidenceURL: URL?,
        headroomEvidenceRequired: Bool
    ) -> ReleaseReadinessAuditReport {
        let definitions = [
            EvidenceDefinition(
                id: "clean-checkout",
                relativePath: "docs/evidence/clean-checkout-smoke-\(evidenceDate).json"
            ),
            EvidenceDefinition(
                id: "accessibility-smoke",
                relativePath: "docs/evidence/accessibility-smoke-\(evidenceDate).json"
            ),
            EvidenceDefinition(
                id: "keyboard-smoke",
                relativePath: "docs/evidence/keyboard-smoke-\(evidenceDate).json"
            ),
            EvidenceDefinition(
                id: "interaction-smoke",
                relativePath: "docs/evidence/interaction-smoke-\(evidenceDate).json"
            ),
            EvidenceDefinition(
                id: "primary-console-more-tab-interaction",
                relativePath: "docs/evidence/interaction-smoke-\(evidenceDate)-more-tab.json"
            ),
            EvidenceDefinition(
                id: "primary-console-more-tab-accessibility",
                relativePath: "docs/evidence/accessibility-smoke-\(evidenceDate)-more-tab.json"
            ),
            EvidenceDefinition(
                id: "primary-console-more-tab-visual-minimum-light",
                relativePath: "docs/evidence/visual-matrix-\(evidenceDate)-more-tab-minimum-light.json"
            ),
            EvidenceDefinition(
                id: "primary-console-top-transport-interaction",
                relativePath: "docs/evidence/interaction-smoke-\(evidenceDate)-top-transport.json"
            ),
            EvidenceDefinition(
                id: "primary-console-primary-transport-accessibility",
                relativePath: "docs/evidence/accessibility-smoke-\(evidenceDate)-primary-transport.json"
            ),
            EvidenceDefinition(
                id: "primary-console-primary-transport-interaction",
                relativePath: "docs/evidence/interaction-smoke-\(evidenceDate)-primary-transport.json"
            ),
            EvidenceDefinition(
                id: "primary-console-primary-transport-visual-minimum-light",
                relativePath: "docs/evidence/visual-matrix-\(evidenceDate)-primary-transport-minimum-light.json"
            ),
            EvidenceDefinition(
                id: "primary-console-top-transport-visual-minimum-light",
                relativePath: "docs/evidence/visual-matrix-\(evidenceDate)-top-transport-minimum-light.json"
            ),
            EvidenceDefinition(
                id: "primary-console-library-agent-route-interaction",
                relativePath: "docs/evidence/interaction-smoke-\(evidenceDate)-library-agent-route.json"
            ),
            EvidenceDefinition(
                id: "primary-console-library-agent-route-accessibility",
                relativePath: "docs/evidence/accessibility-smoke-\(evidenceDate)-library-agent-route.json"
            ),
            EvidenceDefinition(
                id: "primary-console-library-agent-route-visual-minimum-light",
                relativePath: "docs/evidence/visual-matrix-\(evidenceDate)-library-agent-route-minimum-light.json"
            ),
            EvidenceDefinition(
                id: "relaunch-prompt-smoke",
                relativePath: "docs/evidence/relaunch-prompt-smoke-\(evidenceDate).json"
            ),
            EvidenceDefinition(
                id: "system-keychain-relaunch-prompt-smoke",
                relativePath: "docs/evidence/system-keychain-relaunch-prompt-smoke-\(evidenceDate).json",
                requiredForLocalReady: false,
                requiredForReleaseCandidate: false
            ),
            EvidenceDefinition(
                id: "visual-minimum-light",
                relativePath: "docs/evidence/visual-matrix-\(evidenceDate)-minimum-light.json"
            ),
            EvidenceDefinition(
                id: "visual-wide-dark",
                relativePath: "docs/evidence/visual-matrix-\(evidenceDate)-wide-dark.json"
            ),
            EvidenceDefinition(
                id: "visual-accessibility-minimum-light",
                relativePath: "docs/evidence/visual-accessibility-matrix-\(evidenceDate)-minimum-light.json"
            ),
            EvidenceDefinition(
                id: "disk-pressure",
                relativePath: "docs/evidence/disk-pressure-smoke-\(evidenceDate).json"
            ),
            EvidenceDefinition(
                id: "long-idle-memory",
                relativePath: "docs/evidence/long-idle-memory-smoke-\(evidenceDate).json"
            ),
            EvidenceDefinition(
                id: "long-recording-stress",
                relativePath: "docs/evidence/long-recording-stress-smoke-\(evidenceDate).json"
            ),
            EvidenceDefinition(
                id: "local-recording-import",
                relativePath: "docs/evidence/local-recording-import-smoke-\(evidenceDate).json"
            ),
            EvidenceDefinition(
                id: "log-redaction-smoke",
                relativePath: "docs/evidence/log-redaction-smoke-\(evidenceDate).json"
            ),
            EvidenceDefinition(
                id: "app-shortcuts-catalog",
                relativePath: "docs/evidence/app-shortcuts-catalog-smoke-\(evidenceDate).json"
            ),
            EvidenceDefinition(
                id: "provider-readiness-doctor",
                relativePath: "docs/evidence/provider-readiness-doctor-\(evidenceDate).json"
            ),
            EvidenceDefinition(
                id: "crash-log-smoke",
                relativePath: "docs/evidence/crash-log-smoke-\(evidenceDate).json"
            ),
            EvidenceDefinition(
                id: "isolated-library-performance",
                relativePath: "docs/evidence/performance-smoke-isolated-library-\(evidenceDate).json"
            ),
            EvidenceDefinition(
                id: "signing-entitlements",
                relativePath: "docs/evidence/signing-entitlements-smoke-\(evidenceDate).json"
            ),
            EvidenceDefinition(
                id: "release-packaging",
                relativePath: "docs/evidence/release-packaging-smoke-\(evidenceDate).json"
            ),
            EvidenceDefinition(
                id: "distribution-release",
                relativePath: "docs/evidence/distribution-release-gate-\(evidenceDate).json",
                expectedStatus: "pass",
                requiredForLocalReady: false,
                requiredForReleaseCandidate: true
            ),
            EvidenceDefinition(
                id: "app-store-assets",
                relativePath: "docs/evidence/app-store-assets-smoke-\(evidenceDate).json"
            ),
            EvidenceDefinition(
                id: "app-store-privacy",
                relativePath: "docs/evidence/app-store-privacy-smoke-\(evidenceDate).json"
            ),
            EvidenceDefinition(
                id: "foundation-models-fixture",
                relativePath: "docs/evidence/foundation-models-fixture-smoke-\(evidenceDate).json"
            ),
            EvidenceDefinition(
                id: "foundation-models-local-import",
                relativePath: "docs/evidence/foundation-models-local-import-smoke-\(evidenceDate).json",
                expectedStatus: "pass",
                requiredForLocalReady: false,
                requiredForReleaseCandidate: false
            ),
            EvidenceDefinition(
                id: "foundation-models-english-import",
                relativePath: "docs/evidence/foundation-models-english-import-smoke-\(evidenceDate).json",
                expectedStatus: "pass",
                requiredForLocalReady: false,
                requiredForReleaseCandidate: false
            ),
            EvidenceDefinition(
                id: "release-docs-freshness",
                relativePath: "docs/evidence/release-docs-freshness-smoke-\(evidenceDate).json"
            ),
            EvidenceDefinition(
                id: "apple-speech-permission",
                relativePath: "docs/evidence/apple-speech-permission-smoke-\(evidenceDate).json",
                expectedStatus: "pass",
                requiredForLocalReady: false,
                requiredForReleaseCandidate: true
            ),
            EvidenceDefinition(
                id: "provider-smoke-matrix",
                relativePath: "docs/evidence/provider-smoke-matrix-\(evidenceDate).json",
                expectedStatus: "pass",
                requiredForLocalReady: false,
                requiredForReleaseCandidate: true
            ),
            EvidenceDefinition(
                id: "capture-provider-smoke",
                relativePath: "docs/evidence/capture-provider-smoke-\(evidenceDate).json",
                expectedStatus: "pass",
                requiredForLocalReady: false,
                requiredForReleaseCandidate: true
            ),
            EvidenceDefinition(
                id: "real-provider-long-recording",
                relativePath: "docs/evidence/real-provider-long-recording-smoke-\(evidenceDate).json",
                expectedStatus: "pass",
                requiredForLocalReady: false,
                requiredForReleaseCandidate: true
            ),
            EvidenceDefinition(
                id: "real-capture-playback-release",
                relativePath: "docs/evidence/real-capture-playback-release-gate-\(evidenceDate).json",
                expectedStatus: "pass",
                requiredForLocalReady: false,
                requiredForReleaseCandidate: true
            ),
            EvidenceDefinition(
                id: "manual-accessibility-release",
                relativePath: "docs/evidence/manual-accessibility-release-gate-\(evidenceDate).json",
                expectedStatus: "pass",
                requiredForLocalReady: false,
                requiredForReleaseCandidate: true
            ),
            EvidenceDefinition(
                id: "clean-machine-release",
                relativePath: "docs/evidence/clean-machine-release-gate-\(evidenceDate).json",
                expectedStatus: "pass",
                requiredForLocalReady: false,
                requiredForReleaseCandidate: true
            ),
            EvidenceDefinition(
                id: "sleep-wake-release",
                relativePath: "docs/evidence/sleep-wake-release-gate-\(evidenceDate).json",
                expectedStatus: "pass",
                requiredForLocalReady: false,
                requiredForReleaseCandidate: true
            ),
            EvidenceDefinition(
                id: "shortcuts-release",
                relativePath: "docs/evidence/shortcuts-release-gate-\(evidenceDate).json",
                expectedStatus: "pass",
                requiredForLocalReady: false,
                requiredForReleaseCandidate: true
            ),
            EvidenceDefinition(
                id: "system-integration-release",
                relativePath: "docs/evidence/system-integration-release-gate-\(evidenceDate).json",
                expectedStatus: "pass",
                requiredForLocalReady: false,
                requiredForReleaseCandidate: true
            )
        ]

        var evidenceObjects: [String: [String: Any]] = [:]
        let headroomEvidence = headroomEvidenceURL.flatMap { readJSONObject(at: resolvedURL($0, rootURL: rootURL)) }
        if let headroomEvidence {
            evidenceObjects["workspace-headroom"] = headroomEvidence
        }
        let checks = definitions.map { definition in
            let url = rootURL.appendingPathComponent(definition.relativePath)
            guard let object = readJSONObject(at: url) else {
                return EvidenceCheck(
                    id: definition.id,
                    path: definition.relativePath,
                    expectedStatus: definition.expectedStatus,
                    actualStatus: nil,
                    requiredForLocalReady: definition.requiredForLocalReady,
                    requiredForReleaseCandidate: definition.requiredForReleaseCandidate,
                    passed: false,
                    issues: ["Missing or unreadable evidence JSON."]
                )
            }

            evidenceObjects[definition.id] = object
            let status = object["status"] as? String
            let evidenceIssues = stringArray(object["issues"]) + extraIssues(for: definition.id, evidence: object)
            let statusMatches = status == definition.expectedStatus
            let passed = statusMatches && evidenceIssues.isEmpty
            return EvidenceCheck(
                id: definition.id,
                path: definition.relativePath,
                expectedStatus: definition.expectedStatus,
                actualStatus: status,
                requiredForLocalReady: definition.requiredForLocalReady,
                requiredForReleaseCandidate: definition.requiredForReleaseCandidate,
                passed: passed,
                issues: evidenceIssues
            )
        }

        let sourceCommit = gitCommit(rootURL: rootURL)
        let cleanCheckoutSourceCommit = evidenceObjects["clean-checkout"]?["sourceCommit"] as? String
        let sourceDrift = buildSourceDriftReport(
            rootURL: rootURL,
            currentCommit: sourceCommit,
            cleanCheckoutCommit: cleanCheckoutSourceCommit
        )

        let localEvidencePassed = checks
            .filter(\.requiredForLocalReady)
            .allSatisfy(\.passed)
        let localReady = localEvidencePassed && !sourceDrift.blocksLocalReady
        var releaseCandidateBlockers = checks
            .filter { $0.requiredForReleaseCandidate && !$0.passed }
            .map { "\($0.id) is \($0.actualStatus ?? "missing"); expected \($0.expectedStatus)." }
        if sourceDrift.blocksLocalReady {
            releaseCandidateBlockers.append("Clean-checkout proof is stale for app/build-critical paths.")
        }

        if let signing = evidenceObjects["signing-entitlements"] {
            if bool(signing["distributionReady"]) != true {
                releaseCandidateBlockers.append("Distribution signing is not ready.")
            }
            if bool(signing["notarizationSubmitted"]) != true {
                releaseCandidateBlockers.append("Notarization has not been submitted.")
            }
        }
        if let packaging = evidenceObjects["release-packaging"],
           bool(packaging["distributionReady"]) != true {
            releaseCandidateBlockers.append("Release packaging has no distributable signed artifact.")
        }
        if let appStoreAssets = evidenceObjects["app-store-assets"],
           bool(appStoreAssets["finalAssetsReady"]) != true
            || bool(appStoreAssets["finalMetadataApproved"]) != true
            || bool(appStoreAssets["legalApproved"]) != true
            || bool(appStoreAssets["appStoreConnectRecordCreated"]) != true {
            releaseCandidateBlockers.append("Final App Store assets, metadata, legal approval, and App Store Connect record are not complete.")
        }
        if let appStorePrivacy = evidenceObjects["app-store-privacy"],
           bool(appStorePrivacy["finalAppStoreConnectAnswersApproved"]) != true
            || bool(appStorePrivacy["privacyOwnerApproved"]) != true
            || bool(appStorePrivacy["legalApproved"]) != true
            || bool(appStorePrivacy["appStoreConnectRecordCreated"]) != true {
            releaseCandidateBlockers.append("Final App Store privacy answers, privacy owner approval, legal approval, and App Store Connect record are not complete.")
        }

        let manualApprovalBlockers = [
            "MeetingVault must be allowed in System Settings > Privacy & Security > Speech Recognition, then Apple Speech permission smoke must pass.",
            "Approved real selected-microphone and system/process capture smoke over non-private audio.",
            "Approved real-provider long-recording smoke over non-private audio.",
            "Approved playback validation over non-private real capture output, validated by real capture playback release gate.",
            "Full VoiceOver/manual OS accessibility confirmation, validated by manual accessibility release gate.",
            "Clean-machine crash-free proof after final packaging, validated by clean-machine release gate.",
            "Real macOS sleep/wake recovery proof over approved non-private audio, validated by sleep/wake release gate.",
            "Real OS Shortcuts/Siri/App Intents handoff proof with no external side effects, validated by Shortcuts release gate.",
            "Approved real OS Calendar/Reminders/Contacts handoff proof with permission recovery and redacted receipts, validated by system integration release gate.",
            "Developer ID or App Store signing identity, provisioning profile, and final notarization/upload credentials, validated by distribution release gate.",
            "Final App Store metadata, screenshots, legal/privacy review, and support/marketing URLs."
        ]
        releaseCandidateBlockers.append(contentsOf: manualApprovalBlockers)
        let operatorBlockers = headroomOperatorBlockers(
            from: headroomEvidence,
            evidenceURL: headroomEvidenceURL,
            rootURL: rootURL,
            required: headroomEvidenceRequired
        )

        let releaseCandidateReady = localReady && releaseCandidateBlockers.isEmpty
        let label: String
        if releaseCandidateReady {
            label = "release-candidate ready"
        } else if localReady {
            label = "local app ready; release candidate blocked"
        } else {
            label = "blocked before local app ready"
        }

        let allObjects = Array(evidenceObjects.values)
        let privacy = PrivacyFlags(
            privateAudioRecorded: anyTrue(allObjects, "privateAudioRecorded"),
            microphoneOpened: anyTrue(allObjects, "microphoneOpened"),
            externalNetworkRequested: anyTrue(allObjects, "externalNetworkRequested"),
            downloadRequested: anyTrue(allObjects, "downloadRequested"),
            externalUploadAttempted: anyTrue(allObjects, "externalUploadAttempted"),
            notarizationSubmitted: anyTrue(allObjects, "notarizationSubmitted")
        )
        let issues = checks.flatMap { check in
            check.issues.map { "\(check.id): \($0)" }
        }

        return ReleaseReadinessAuditReport(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            status: localReady ? "pass" : "blocked",
            label: label,
            sourceCommit: sourceCommit,
            cleanCheckoutSourceCommit: cleanCheckoutSourceCommit,
            sourceDrift: sourceDrift,
            localReady: localReady,
            releaseCandidateReady: releaseCandidateReady,
            readyForAppStoreSubmission: false,
            checks: checks,
            releaseCandidateBlockers: releaseCandidateBlockers,
            manualApprovalBlockers: manualApprovalBlockers,
            operatorBlockers: operatorBlockers,
            privacy: privacy,
            rawTranscriptStored: anyTrue(allObjects, "rawTranscriptStored") || anyTrue(allObjects, "rawTranscriptTextStoredInComponents"),
            rawAudioStored: anyTrue(allObjects, "rawAudioStored") || anyTrue(allObjects, "rawAudioStoredInComponents"),
            rawModelOutputStored: anyTrue(allObjects, "rawModelOutputStored") || anyTrue(allObjects, "rawModelOutputStoredInComponents"),
            rawLogsStored: anyTrue(allObjects, "rawLogsStored") || anyTrue(allObjects, "rawLogsStoredInComponents"),
            rawUITextStored: anyTrue(allObjects, "rawUITextStored"),
            issues: issues + sourceDrift.issues
        )
    }

    private static func defaultHeadroomEvidenceURL(rootURL: URL, evidenceDate: String) -> URL? {
        let candidate = rootURL
            .appendingPathComponent("docs/evidence", isDirectory: true)
            .appendingPathComponent("workspace-headroom-doctor-\(evidenceDate).json")
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    private static func headroomOperatorBlockers(
        from object: [String: Any]?,
        evidenceURL: URL?,
        rootURL: URL,
        required: Bool
    ) -> [String] {
        guard let object else {
            guard required else { return [] }
            return ["Workspace headroom evidence is missing or unreadable at \(evidenceURL?.path ?? "unknown")."]
        }
        let headroomStatus = string(object["headroomStatus"], fallback: "unknown")
        guard headroomStatus != "pass" else { return [] }

        let availableBytes = int64(object["volumeAvailableBytes"])
        let recommendedBytes = int64(object["recommendedVerificationBytes"])
        let cleanupCandidateBytes = int64(object["cleanupCandidateBytes"])
        let projectedAvailableBytes = int64(object["projectedAvailableBytesAfterCleanupCandidates"])
        let candidateCount = (object["cleanupCandidates"] as? [[String: Any]])?.count ?? 0
        let evidencePath = evidenceURL.map { displayPath(for: resolvedURL($0, rootURL: rootURL), rootURL: rootURL) }
            ?? "docs/evidence/workspace-headroom-doctor-<date>.json"

        let parts = [
            "Workspace headroom is \(headroomStatus) in \(evidencePath)",
            availableBytes.map { "available \(decimalGigabytes($0))" },
            recommendedBytes.map { "recommended \(decimalGigabytes($0))" },
            candidateCount > 0 ? "\(candidateCount) manual-review cleanup candidate(s)" : nil,
            cleanupCandidateBytes.map { "\(decimalGigabytes($0)) candidate bytes" },
            projectedAvailableBytes.map { "\(decimalGigabytes($0)) projected available after reviewed cleanup" }
        ].compactMap { $0 }

        return [parts.joined(separator: "; ") + "."]
    }

    private static func buildSourceDriftReport(
        rootURL: URL,
        currentCommit: String,
        cleanCheckoutCommit: String?
    ) -> SourceDriftReport {
        guard let cleanCheckoutCommit,
              cleanCheckoutCommit != "unknown",
              currentCommit != "unknown" else {
            return SourceDriftReport(
                checked: false,
                currentCommit: currentCommit,
                cleanCheckoutCommit: cleanCheckoutCommit,
                changedPathsSinceCleanCheckout: [],
                uncommittedPaths: [],
                blockingPaths: [],
                uncommittedBlockingPaths: [],
                ignoredPaths: [],
                blocksLocalReady: true,
                issues: ["Clean-checkout source commit could not be compared with current source commit."]
            )
        }

        let changedPaths = gitChangedPaths(
            rootURL: rootURL,
            from: cleanCheckoutCommit,
            to: currentCommit
        )
        let uncommittedPaths = gitUncommittedPaths(rootURL: rootURL)
        let blockingPaths = changedPaths.filter(isBuildCriticalPath)
        let uncommittedBlockingPaths = uncommittedPaths.filter(isBuildCriticalPath)
        let ignoredPaths = (changedPaths + uncommittedPaths)
            .filter { !isBuildCriticalPath($0) }
            .sorted()
        var issues: [String] = []
        if !blockingPaths.isEmpty {
            issues.append("Clean-checkout evidence is older than app/build-critical changes: \(blockingPaths.joined(separator: ", "))")
        }
        if !uncommittedBlockingPaths.isEmpty {
            issues.append("Uncommitted app/build-critical changes are not covered by clean-checkout evidence: \(uncommittedBlockingPaths.joined(separator: ", "))")
        }

        return SourceDriftReport(
            checked: true,
            currentCommit: currentCommit,
            cleanCheckoutCommit: cleanCheckoutCommit,
            changedPathsSinceCleanCheckout: changedPaths,
            uncommittedPaths: uncommittedPaths,
            blockingPaths: blockingPaths,
            uncommittedBlockingPaths: uncommittedBlockingPaths,
            ignoredPaths: ignoredPaths,
            blocksLocalReady: !blockingPaths.isEmpty || !uncommittedBlockingPaths.isEmpty,
            issues: issues
        )
    }

    private static func isBuildCriticalPath(_ path: String) -> Bool {
        if path == "Package.swift" || path == "Package.resolved" {
            return true
        }
        if path.hasPrefix("Sources/") || path.hasPrefix("Tests/") {
            return true
        }
        if path.hasPrefix("config/") || path.hasPrefix(".codex/environments/") {
            return true
        }
        if path.hasPrefix("script/") {
            return true
        }
        return false
    }

    private static func today() -> String {
        String(ISO8601DateFormatter().string(from: Date()).prefix(10))
    }

    private static func isValidEvidenceDate(_ value: String) -> Bool {
        let parts = value.split(separator: "-")
        guard parts.count == 3,
              parts[0].count == 4,
              parts[1].count == 2,
              parts[2].count == 2 else {
            return false
        }
        return parts.allSatisfy { part in
            part.allSatisfy(\.isNumber)
        }
    }

    private static func readJSONObject(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private static func stringArray(_ value: Any?) -> [String] {
        value as? [String] ?? []
    }

    private static func extraIssues(for id: String, evidence: [String: Any]) -> [String] {
        var issues = sensitiveEvidenceIssues(evidence)
        switch id {
        case "interaction-smoke", "primary-console-library-agent-route-interaction":
            issues.append(contentsOf: interactionSmokeEvidenceIssues(evidence))
        case "primary-console-top-transport-interaction", "primary-console-primary-transport-interaction":
            issues.append(contentsOf: primaryConsoleRecordingEvidenceIssues(evidence))
        case "crash-log-smoke":
            issues.append(contentsOf: crashLogEvidenceIssues(evidence))
        case "local-recording-import":
            issues.append(contentsOf: localRecordingImportEvidenceIssues(evidence))
        case "foundation-models-local-import":
            issues.append(contentsOf: foundationModelsLocalImportEvidenceIssues(evidence))
        case "foundation-models-english-import":
            issues.append(contentsOf: foundationModelsEnglishImportEvidenceIssues(evidence))
        case "relaunch-prompt-smoke":
            issues.append(contentsOf: relaunchPromptEvidenceIssues(evidence))
        case "system-keychain-relaunch-prompt-smoke":
            issues.append(contentsOf: relaunchPromptEvidenceIssues(evidence, expectedKeyProvider: "keychain"))
        default:
            break
        }
        return issues
    }

    private static func sensitiveEvidenceIssues(_ evidence: [String: Any]) -> [String] {
        [
            "privateAudioRecorded",
            "rawTranscriptStored",
            "rawTranscriptTextStoredInComponents",
            "rawAudioStored",
            "rawAudioStoredInComponents",
            "rawLogsStored",
            "rawLogsStoredInComponents",
            "rawUITextStored",
            "rawModelOutputStored",
            "rawModelOutputStoredInComponents",
            "rawCalendarDataStored",
            "rawContactDataStored",
            "rawCredentialStored",
            "rawMessagesStored",
            "rawSigningOutputStored",
            "rawNotarizationOutputStored",
            "rawPackagingOutputStored",
            "rawReminderDataStored",
            "externalUploadAttempted"
        ]
            .filter { bool(evidence[$0]) == true }
            .map { "Evidence must not record \($0)=true." }
    }

    private static func localRecordingImportEvidenceIssues(_ evidence: [String: Any]) -> [String] {
        var issues: [String] = []
        if bool(evidence["localSampleProofPassed"]) != true {
            issues.append("Local recording import smoke must pass required local sample proof.")
        }
        if bool(evidence["syntheticImportTestsPassed"]) != true {
            issues.append("Local recording import smoke must pass synthetic import tests.")
        }
        if bool(evidence["appWorkflowTestsPassed"]) != true {
            issues.append("Local recording import smoke must pass app transcript-agent workflow tests.")
        }
        if bool(evidence["longTranscriptSampleAvailable"]) != true {
            issues.append("Local recording import smoke must prove a long transcript sample is available.")
        }
        if (evidence["matchedLocalSampleCount"] as? Int ?? 0) <= 50 {
            issues.append("Local recording import smoke must prove more than 50 matched local transcript/audio samples.")
        }
        let formatCounts = evidence["matchedAudioFormatCounts"] as? [String: Any] ?? [:]
        if int(formatCounts["mp3"]) ?? 0 <= 0 {
            issues.append("Local recording import smoke must prove at least one matched MP3 recording.")
        }
        return issues
    }

    private static func foundationModelsLocalImportEvidenceIssues(_ evidence: [String: Any]) -> [String] {
        var issues: [String] = []
        if bool(evidence["usedLocalImportSampleFixture"]) != true {
            issues.append("Foundation Models local import smoke must use an imported local sample fixture.")
        }
        if string(evidence["localImportStatus"]) != "pass" {
            issues.append("Foundation Models local import smoke must import the local MP3/TXT sample successfully.")
        }
        if (int(evidence["localSampleMatchedCount"]) ?? 0) <= 50 {
            issues.append("Foundation Models local import smoke must prove more than 50 matched local transcript/audio samples.")
        }
        if string(evidence["selectedAudioExtension"]) != "mp3" {
            issues.append("Foundation Models local import smoke must select a matched MP3 recording.")
        }
        if (int(evidence["transcriptLineCount"]) ?? 0) <= 0 {
            issues.append("Foundation Models local import smoke must record a positive transcript line count.")
        }
        if (int(evidence["segmentCount"]) ?? 0) <= 0 {
            issues.append("Foundation Models local import smoke must parse transcript segments.")
        }
        if (int(evidence["importedAudioChunkCount"]) ?? 0) <= 0 {
            issues.append("Foundation Models local import smoke must persist imported audio as encrypted playback chunks.")
        }
        if bool(evidence["encryptedLibraryCreated"]) != true {
            issues.append("Foundation Models local import smoke must create an encrypted library bundle.")
        }
        if bool(evidence["temporaryWorkspaceDeleted"]) != true {
            issues.append("Foundation Models local import smoke must delete its temporary workspace.")
        }
        return issues
    }

    private static func foundationModelsEnglishImportEvidenceIssues(_ evidence: [String: Any]) -> [String] {
        var issues: [String] = []
        if bool(evidence["usedLocalImportSampleFixture"]) != true {
            issues.append("Foundation Models English import smoke must use the external import pipeline.")
        }
        if bool(evidence["usedGeneratedEnglishImportFixture"]) != true {
            issues.append("Foundation Models English import smoke must use the generated English fixture.")
        }
        if string(evidence["importFixtureKind"]) != "generated-english" {
            issues.append("Foundation Models English import smoke must identify fixture kind as generated-english.")
        }
        if string(evidence["localImportStatus"]) != "pass" {
            issues.append("Foundation Models English import smoke must import the English MP3/TXT fixture successfully.")
        }
        if string(evidence["selectedTranscriptLanguage"]) != "en-US" {
            issues.append("Foundation Models English import smoke must pin the imported transcript language to en-US.")
        }
        if string(evidence["selectedAudioExtension"]) != "mp3" {
            issues.append("Foundation Models English import smoke must import an MP3-named audio fixture.")
        }
        if (int(evidence["localSampleMatchedCount"]) ?? 0) <= 0 {
            issues.append("Foundation Models English import smoke must discover at least one matched external MP3/TXT pair.")
        }
        if (int(evidence["transcriptLineCount"]) ?? 0) <= 0 {
            issues.append("Foundation Models English import smoke must record a positive transcript line count.")
        }
        if (int(evidence["segmentCount"]) ?? 0) <= 0 {
            issues.append("Foundation Models English import smoke must parse transcript segments.")
        }
        if (int(evidence["importedAudioChunkCount"]) ?? 0) <= 0 {
            issues.append("Foundation Models English import smoke must persist imported audio as encrypted playback chunks.")
        }
        if bool(evidence["encryptedLibraryCreated"]) != true {
            issues.append("Foundation Models English import smoke must create an encrypted library bundle.")
        }
        if bool(evidence["generatedFixtureCreated"]) != true {
            issues.append("Foundation Models English import smoke must create the generated fixture.")
        }
        if bool(evidence["temporaryWorkspaceDeleted"]) != true {
            issues.append("Foundation Models English import smoke must delete its temporary workspace.")
        }
        if string(evidence["intelligenceStatus"]) != "pass" {
            issues.append("Foundation Models English import smoke must pass meeting intelligence.")
        }
        if string(evidence["transcriptQuestionAnswerStatus"]) != "pass" {
            issues.append("Foundation Models English import smoke must pass transcript Q&A.")
        }
        if bool(evidence["summaryTitleGenerated"]) != true {
            issues.append("Foundation Models English import smoke must generate a summary title.")
        }
        if (int(evidence["summaryBulletCount"]) ?? 0) <= 0 {
            issues.append("Foundation Models English import smoke must generate summary bullets.")
        }
        if (int(evidence["answerEvidenceCount"]) ?? 0) <= 0 {
            issues.append("Foundation Models English import smoke must return grounded answer evidence.")
        }
        if bool(evidence["allEvidenceQuotesFoundInTranscript"]) != true {
            issues.append("Foundation Models English import smoke must ground all evidence quotes in the transcript.")
        }
        return issues
    }

    private static func interactionSmokeEvidenceIssues(_ evidence: [String: Any]) -> [String] {
        var issues: [String] = []
        if bool(evidence["isolatedSmokeStorage"]) != true {
            issues.append("Interaction smoke must use isolated smoke storage.")
        }
        for key in [
            "rawUITextStored",
            "externalShareOpened",
            "destructiveActionExecuted"
        ] where bool(evidence[key]) != false {
            issues.append("Interaction smoke must record \(key)=false.")
        }
        guard let steps = evidence["steps"] as? [[String: Any]] else {
            issues.append("Interaction smoke must record verified steps.")
            return issues
        }

        for requiredStep in [
            "Copy visible transcript",
            "Focus Agent",
            "Agent prompt answer",
            "Agent editable response",
            "Copy agent response",
            "Select exportable meeting",
            "Export selected meeting",
            "Prepare share",
            "Release readiness prerequisite status"
        ] {
            guard let step = steps.first(where: { string($0["name"]) == requiredStep }) else {
                issues.append("Interaction smoke is missing required step: \(requiredStep).")
                continue
            }
            if !stepPassed(step) {
                issues.append("Interaction smoke required step did not pass: \(requiredStep).")
            }
        }

        if let promptStep = steps.first(where: { string($0["name"]) == "Agent prompt answer" }) {
            let detail = string(promptStep["detail"]).lowercased()
            if !detail.contains("grounded") {
                issues.append("Interaction smoke Agent prompt answer must prove a grounded answer.")
            }
            if detail.contains("raw answer") && !detail.contains("without storing raw answer") {
                issues.append("Interaction smoke Agent prompt answer must not store raw answer text.")
            }
        }
        if let editStep = steps.first(where: { string($0["name"]) == "Agent editable response" }) {
            let detail = string(editStep["detail"]).lowercased()
            if !detail.contains("editable") || !detail.contains("accepted") {
                issues.append("Interaction smoke Agent editable response must prove an accepted edit.")
            }
        }
        if let copyStep = steps.first(where: { string($0["name"]) == "Copy agent response" }) {
            let detail = string(copyStep["detail"]).lowercased()
            if !detail.contains("edited") || !detail.contains("copy") {
                issues.append("Interaction smoke Copy agent response must prove the edited response was copied.")
            }
            let metadata = copyStep["metadata"] as? [String: Any] ?? [:]
            if string(metadata["copyMatchesEditedText"]) != "true" {
                issues.append("Interaction smoke Copy agent response must prove clipboard content matched the edited response.")
            }
            if string(metadata["editedResponseSHA256"]).isEmpty || string(metadata["clipboardSHA256"]).isEmpty {
                issues.append("Interaction smoke Copy agent response must record bounded response and clipboard hashes instead of raw text.")
            }
            if string(metadata["editedResponseSHA256"]) != string(metadata["clipboardSHA256"]) {
                issues.append("Interaction smoke Copy agent response hashes must match.")
            }
            if detail.contains("external") && !detail.contains("without opening an external") {
                issues.append("Interaction smoke Copy agent response must not open an external destination.")
            }
        }
        if let exportStep = steps.first(where: { string($0["name"]) == "Export selected meeting" }) {
            let detail = string(exportStep["detail"]).lowercased()
            let metadata = exportStep["metadata"] as? [String: Any] ?? [:]
            if !detail.contains("local package") {
                issues.append("Interaction smoke Export selected meeting must prove a local package, not only an unavailable state.")
            }
            if detail.contains("unavailable") || detail.contains("failed") {
                issues.append("Interaction smoke Export selected meeting must not accept unavailable or failed export states.")
            }
            if string(metadata["localPackageCreated"]) != "true" {
                issues.append("Interaction smoke Export selected meeting must record localPackageCreated=true.")
            }
        }
        if let shareStep = steps.first(where: { string($0["name"]) == "Prepare share" }) {
            let detail = string(shareStep["detail"]).lowercased()
            let metadata = shareStep["metadata"] as? [String: Any] ?? [:]
            if !detail.contains("latest local export") {
                issues.append("Interaction smoke Prepare share must prove it used the latest local export package.")
            }
            if detail.contains("disabled") || detail.contains("until a package exists") {
                issues.append("Interaction smoke Prepare share must not pass while share preparation is disabled.")
            }
            if string(metadata["preparedFromLatestPackage"]) != "true" {
                issues.append("Interaction smoke Prepare share must record preparedFromLatestPackage=true.")
            }
        }
        if let releaseStep = steps.first(where: { string($0["name"]) == "Release readiness prerequisite status" }) {
            let detail = string(releaseStep["detail"]).lowercased()
            let metadata = releaseStep["metadata"] as? [String: Any] ?? [:]
            if !detail.contains("waiting-prerequisite") {
                issues.append("Interaction smoke Release readiness prerequisite status must prove waiting-prerequisite state.")
            }
            if string(metadata["waitingPrerequisiteStatusVisible"]) != "true" {
                issues.append("Interaction smoke Release readiness prerequisite status must prove the waiting-prerequisite row status is visible.")
            }
            if string(metadata["waitingPrerequisiteCountVisible"]) != "true" {
                issues.append("Interaction smoke Release readiness prerequisite status must prove the waiting-prerequisite count is visible.")
            }
            if string(metadata["releaseBlockerStatusVisible"]) != "true" {
                issues.append("Interaction smoke Release readiness prerequisite status must prove the release blocker status is visible.")
            }
            if string(metadata["actionCountVisible"]) != "true" {
                issues.append("Interaction smoke Release readiness prerequisite status must prove the queued action count is visible.")
            }
        }

        return issues
    }

    private static func stepPassed(_ step: [String: Any]) -> Bool {
        string(step["status"]) == "pass" || bool(step["passed"]) == true
    }

    private static func primaryConsoleRecordingEvidenceIssues(_ evidence: [String: Any]) -> [String] {
        var issues: [String] = []
        if bool(evidence["isolatedSmokeStorage"]) != true {
            issues.append("Primary console interaction smoke must use isolated smoke storage.")
        }
        for key in [
            "rawUITextStored",
            "externalShareOpened",
            "destructiveActionExecuted"
        ] where bool(evidence[key]) != false {
            issues.append("Primary console interaction smoke must record \(key)=false.")
        }
        guard let steps = evidence["steps"] as? [[String: Any]] else {
            issues.append("Primary console interaction smoke must record verified steps.")
            return issues
        }

        for requiredStep in [
            "Primary readiness check",
            "Primary recording command bar",
            "Primary transport controls",
            "Primary audio input selection",
            "Primary command signal",
            "Primary live transcript surface",
            "Primary selected transcript surface"
        ] {
            guard let step = steps.first(where: { string($0["name"]) == requiredStep }) else {
                issues.append("Primary console interaction smoke is missing required step: \(requiredStep).")
                continue
            }
            if !stepPassed(step) {
                issues.append("Primary console interaction smoke required step did not pass: \(requiredStep).")
            }
        }

        if let inputStep = steps.first(where: { string($0["name"]) == "Primary audio input selection" }) {
            let detail = string(inputStep["detail"]).lowercased()
            if !detail.contains("input") || !detail.contains("detect") {
                issues.append("Primary console input evidence must prove both selected input and Detect controls.")
            }
        }
        if let monitorStep = steps.first(where: { string($0["name"]) == "Primary command signal" }) {
            let detail = string(monitorStep["detail"]).lowercased()
            if !detail.contains("command") || !detail.contains("signal") {
                issues.append("Primary console activity evidence must prove the command-bar recording signal is visible.")
            }
        }
        if let transcriptStep = steps.first(where: { string($0["name"]) == "Primary live transcript surface" }) {
            let detail = string(transcriptStep["detail"]).lowercased()
            if !detail.contains("live transcript") {
                issues.append("Primary console transcript evidence must prove the live transcript surface is visible.")
            }
        }
        if let titleStep = steps.first(where: { string($0["name"]) == "Primary selected transcript surface" }) {
            let detail = string(titleStep["detail"]).lowercased()
            if !detail.contains("selected transcript") {
                issues.append("Primary console selected transcript evidence must prove the transcript surface is visible.")
            }
        }

        return issues
    }

    private static func relaunchPromptEvidenceIssues(
        _ evidence: [String: Any],
        expectedKeyProvider: String = "local-file"
    ) -> [String] {
        var issues: [String] = []
        if bool(evidence["isolatedSmokeStorage"]) != true {
            issues.append("Relaunch prompt smoke must use isolated smoke storage.")
        }
        if string(evidence["keyProvider"]) != expectedKeyProvider {
            issues.append("Relaunch prompt smoke must use the \(expectedKeyProvider) key provider.")
        }
        guard let launchCount = int(evidence["launchCount"]) else {
            issues.append("Relaunch prompt smoke must record launchCount.")
            return issues
        }
        if launchCount < 2 {
            issues.append("Relaunch prompt smoke must prove at least first launch and relaunch.")
        }
        for key in [
            "keychainPromptDetected",
            "permissionPromptDetected",
            "passwordPromptDetected",
            "unexpectedPromptDetected",
            "privateAudioRecorded",
            "microphoneOpened",
            "externalNetworkRequested",
            "rawTranscriptStored",
            "rawAudioStored",
            "rawLogsStored",
            "rawUITextStored"
        ] where bool(evidence[key]) != false {
            issues.append("Relaunch prompt smoke must record \(key)=false.")
        }
        guard let attempts = evidence["attempts"] as? [[String: Any]] else {
            issues.append("Relaunch prompt smoke must record launch attempts.")
            return issues
        }
        if attempts.count < 2 {
            issues.append("Relaunch prompt smoke must record at least two launch attempts.")
        }
        for attempt in attempts {
            let name = string(attempt["name"], fallback: "unnamed attempt")
            if bool(attempt["launched"]) != true {
                issues.append("Relaunch prompt smoke \(name) did not launch.")
            }
            if bool(attempt["mainWindowVisible"]) != true {
                issues.append("Relaunch prompt smoke \(name) did not show the main window.")
            }
            for key in [
                "keychainPromptDetected",
                "permissionPromptDetected",
                "passwordPromptDetected",
                "unexpectedPromptDetected"
            ] where bool(attempt[key]) != false {
                issues.append("Relaunch prompt smoke \(name) must record \(key)=false.")
            }
        }
        return issues
    }

    private static func crashLogEvidenceIssues(_ evidence: [String: Any]) -> [String] {
        guard let logReview = evidence["logReview"] as? [String: Any] else {
            return ["Crash/log smoke evidence is missing logReview."]
        }
        guard let errorOrFaultLines = int(logReview["errorOrFaultLineCount"]) else {
            return ["Crash/log smoke evidence must record errorOrFaultLineCount."]
        }
        guard errorOrFaultLines == 0 else {
            return ["Crash/log smoke found \(errorOrFaultLines) generic error/fault line(s)."]
        }
        guard let invalidConfigurationLines = int(logReview["swiftUIInvalidConfigurationLineCount"]) else {
            return ["Crash/log smoke evidence must record swiftUIInvalidConfigurationLineCount."]
        }
        guard invalidConfigurationLines == 0 else {
            return ["Crash/log smoke found \(invalidConfigurationLines) SwiftUI invalid-configuration line(s)."]
        }
        return []
    }

    private static func bool(_ value: Any?) -> Bool? {
        value as? Bool
    }

    private static func string(_ value: Any?, fallback: String = "") -> String {
        value as? String ?? fallback
    }

    private static func int64(_ value: Any?) -> Int64? {
        if let value = value as? Int64 { return value }
        if let value = value as? Int { return Int64(value) }
        if let value = value as? NSNumber { return value.int64Value }
        return nil
    }

    private static func int(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    private static func decimalGigabytes(_ bytes: Int64) -> String {
        let value = Double(bytes) / 1_000_000_000
        return String(format: "%.2f GB", value)
    }

    private static func resolvedURL(_ url: URL, rootURL: URL) -> URL {
        url.path.hasPrefix("/") ? url : rootURL.appendingPathComponent(url.path)
    }

    private static func displayPath(for url: URL, rootURL: URL) -> String {
        let rootPath = rootURL.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return path }
        return String(path.dropFirst(rootPath.count + 1))
    }

    private static func anyTrue(_ objects: [[String: Any]], _ key: String) -> Bool {
        objects.contains { bool($0[key]) == true }
    }

    private static func gitCommit(rootURL: URL) -> String {
        gitOutput(rootURL: rootURL, arguments: ["rev-parse", "HEAD"]) ?? "unknown"
    }

    private static func gitChangedPaths(rootURL: URL, from oldCommit: String, to newCommit: String) -> [String] {
        guard oldCommit != newCommit,
              let output = gitOutput(rootURL: rootURL, arguments: ["diff", "--name-only", "\(oldCommit)..\(newCommit)"]) else {
            return []
        }
        return output
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty }
            .sorted()
    }

    private static func gitUncommittedPaths(rootURL: URL) -> [String] {
        guard let output = gitOutput(
            rootURL: rootURL,
            arguments: ["status", "--porcelain"],
            trimOutput: false
        ) else {
            return []
        }
        return output
            .components(separatedBy: .newlines)
            .compactMap { line -> String? in
                let raw = line
                guard raw.count > 3 else { return nil }
                let path = String(raw.dropFirst(3))
                if let range = path.range(of: " -> ") {
                    return String(path[range.upperBound...])
                }
                return path
            }
            .filter { !$0.isEmpty }
            .sorted()
    }

    private static func gitOutput(rootURL: URL, arguments: [String]) -> String? {
        gitOutput(rootURL: rootURL, arguments: arguments, trimOutput: true)
    }

    private static func gitOutput(rootURL: URL, arguments: [String], trimOutput: Bool) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = rootURL
        process.standardOutput = pipe
        process.standardError = FileHandle.standardError
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let output = String(decoding: data, as: UTF8.self)
            return trimOutput
                ? output.trimmingCharacters(in: .whitespacesAndNewlines)
                : output
        } catch {
            return nil
        }
    }
}

ReleaseReadinessAudit.main()
