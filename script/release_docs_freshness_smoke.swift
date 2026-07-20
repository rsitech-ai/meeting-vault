#!/usr/bin/env swift
import Foundation

struct ReleaseDocsFreshnessReport: Codable {
    var timestamp: String
    var status: String
    var checklistPath: String
    var releaseReadinessPath: String
    var cleanCheckoutEvidencePath: String
    var releaseReadinessEvidencePath: String
    var providerMatrixEvidencePath: String
    var cleanCheckoutSourceCommit: String
    var readinessSourceCommit: String
    var readinessCleanCheckoutSourceCommit: String
    var readinessLabel: String
    var providerMatrixStatus: String
    var providerMatrixPassCount: Int
    var providerMatrixBlockedCount: Int
    var providerMatrixFailCount: Int
    var foundationModelsProviderStatus: String
    var checklistMentionsCleanCheckoutCommit: Bool
    var checklistMentionsReadinessCommit: Bool
    var checklistMentionsReadinessLabel: Bool
    var checklistHeaderMatchesReadinessLabel: Bool
    var checklistMentionsProviderMatrixSummary: Bool
    var checklistMentionsFoundationModelsProviderStatus: Bool
    var releaseReadinessMentionsCleanCheckoutCommit: Bool
    var releaseReadinessMentionsReadinessCommit: Bool
    var releaseReadinessMentionsReadinessLabel: Bool
    var releaseReadinessHeaderMatchesReadinessLabel: Bool
    var releaseReadinessMentionsProviderMatrixSummary: Bool
    var releaseReadinessMentionsFoundationModelsProviderStatus: Bool
    var localReady: Bool
    var releaseCandidateReady: Bool
    var externalUploadAttempted: Bool
    var rawTranscriptStored: Bool
    var rawAudioStored: Bool
    var rawLogsStored: Bool
    var rawUITextStored: Bool
    var issues: [String]
}

enum ReleaseDocsFreshnessSmoke {
    static func main() {
        let rootURL = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let date = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
        var evidenceDate = date
        var checklistURL = rootURL.appendingPathComponent("docs/app-store-release-checklist.md")
        var releaseReadinessURL = rootURL.appendingPathComponent("docs/release-readiness.md")
        var outputURL = rootURL
            .appendingPathComponent("docs", isDirectory: true)
            .appendingPathComponent("evidence", isDirectory: true)
            .appendingPathComponent("release-docs-freshness-smoke-\(date).json")

        var iterator = CommandLine.arguments.dropFirst().makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--evidence-date":
                guard let value = iterator.next(), isValidEvidenceDate(value) else {
                    fputs("--evidence-date requires YYYY-MM-DD\n", stderr)
                    exit(2)
                }
                evidenceDate = value
            case "--checklist":
                guard let value = iterator.next() else {
                    fputs("--checklist requires a path\n", stderr)
                    exit(2)
                }
                checklistURL = URL(fileURLWithPath: value)
            case "--release-readiness":
                guard let value = iterator.next() else {
                    fputs("--release-readiness requires a path\n", stderr)
                    exit(2)
                }
                releaseReadinessURL = URL(fileURLWithPath: value)
            case "--output":
                guard let value = iterator.next() else {
                    fputs("--output requires a path\n", stderr)
                    exit(2)
                }
                outputURL = URL(fileURLWithPath: value)
            case "--help", "-h":
                print("""
                usage: script/release_docs_freshness_smoke.swift [--evidence-date YYYY-MM-DD] [--output PATH]

                Verifies release-facing Markdown docs mention the current bounded
                clean-checkout and release-readiness evidence commit/label. This
                script reads existing docs/evidence JSON only; it does not build,
                launch, record audio, upload externally, or store raw transcript,
                audio, log, or UI text.
                """)
                exit(0)
            default:
                fputs("unknown argument: \(argument)\n", stderr)
                exit(2)
            }
        }

        let cleanCheckoutURL = rootURL
            .appendingPathComponent("docs", isDirectory: true)
            .appendingPathComponent("evidence", isDirectory: true)
            .appendingPathComponent("clean-checkout-smoke-\(evidenceDate).json")
        let readinessEvidenceURL = rootURL
            .appendingPathComponent("docs", isDirectory: true)
            .appendingPathComponent("evidence", isDirectory: true)
            .appendingPathComponent("release-readiness-audit-\(evidenceDate).json")
        let providerMatrixURL = rootURL
            .appendingPathComponent("docs", isDirectory: true)
            .appendingPathComponent("evidence", isDirectory: true)
            .appendingPathComponent("provider-smoke-matrix-\(evidenceDate).json")

        let report = buildReport(
            rootURL: rootURL,
            checklistURL: checklistURL,
            releaseReadinessURL: releaseReadinessURL,
            cleanCheckoutURL: cleanCheckoutURL,
            readinessEvidenceURL: readinessEvidenceURL,
            providerMatrixURL: providerMatrixURL
        )

        do {
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: outputURL, options: .atomic)
        } catch {
            fputs("failed to write release docs freshness report: \(error.localizedDescription)\n", stderr)
            exit(1)
        }

        print("Wrote \(outputURL.path)")
        print("status=\(report.status) label=\(report.readinessLabel) sourceCommit=\(report.readinessSourceCommit)")
        exit(report.status == "pass" ? 0 : 1)
    }

    private static func buildReport(
        rootURL: URL,
        checklistURL: URL,
        releaseReadinessURL: URL,
        cleanCheckoutURL: URL,
        readinessEvidenceURL: URL,
        providerMatrixURL: URL
    ) -> ReleaseDocsFreshnessReport {
        var issues: [String] = []
        let checklist = (try? String(contentsOf: checklistURL, encoding: .utf8)) ?? ""
        let releaseReadiness = (try? String(contentsOf: releaseReadinessURL, encoding: .utf8)) ?? ""
        if checklist.isEmpty {
            issues.append("Release checklist is missing or unreadable.")
        }
        if releaseReadiness.isEmpty {
            issues.append("Release readiness document is missing or unreadable.")
        }

        let cleanCheckoutJSON = readJSONObject(at: cleanCheckoutURL)
        let readinessJSON = readJSONObject(at: readinessEvidenceURL)
        let providerMatrixJSON = readJSONObject(at: providerMatrixURL)
        let cleanCheckoutCommit = stringValue(cleanCheckoutJSON?["sourceCommit"])
        let readinessCommit = stringValue(readinessJSON?["sourceCommit"])
        let readinessCleanCommit = stringValue(readinessJSON?["cleanCheckoutSourceCommit"])
        let readinessLabel = stringValue(readinessJSON?["label"])
        let selfReferentialFreshnessBlock = isSelfReferentialFreshnessBlock(
            readinessJSON: readinessJSON,
            readinessLabel: readinessLabel,
            cleanCheckoutCommit: cleanCheckoutCommit,
            readinessCleanCommit: readinessCleanCommit
        )
        let effectiveReadinessLabel = selfReferentialFreshnessBlock
            ? "local app ready; release candidate blocked"
            : readinessLabel
        let providerMatrixStatus = stringValue(providerMatrixJSON?["status"])
        let providerMatrixPassCount = intValue(providerMatrixJSON?["passCount"])
        let providerMatrixBlockedCount = intValue(providerMatrixJSON?["blockedCount"])
        let providerMatrixFailCount = intValue(providerMatrixJSON?["failCount"])
        let foundationModelsProviderStatus = providerStatus(
            in: providerMatrixJSON,
            id: "foundation-models-intelligence-qa"
        )
        let localReady = bool(readinessJSON?["localReady"]) || selfReferentialFreshnessBlock
        let releaseCandidateReady = bool(readinessJSON?["releaseCandidateReady"])
        let privacy = readinessJSON?["privacy"] as? [String: Any]
        let externalUploadAttempted = bool(privacy?["externalUploadAttempted"])
        let rawTranscriptStored = bool(readinessJSON?["rawTranscriptStored"])
        let rawAudioStored = bool(readinessJSON?["rawAudioStored"])
        let rawLogsStored = bool(readinessJSON?["rawLogsStored"])
        let rawUITextStored = bool(readinessJSON?["rawUITextStored"])

        if cleanCheckoutCommit.isEmpty {
            issues.append("Clean-checkout evidence sourceCommit is missing.")
        }
        if readinessCommit.isEmpty {
            issues.append("Release-readiness evidence sourceCommit is missing.")
        }
        if readinessCleanCommit.isEmpty {
            issues.append("Release-readiness evidence cleanCheckoutSourceCommit is missing.")
        }
        if readinessLabel.isEmpty {
            issues.append("Release-readiness evidence label is missing.")
        }
        if providerMatrixStatus.isEmpty {
            issues.append("Provider smoke matrix evidence status is missing.")
        }
        if foundationModelsProviderStatus.isEmpty {
            issues.append("Provider smoke matrix is missing Foundation Models intelligence/Q&A status.")
        }
        if !cleanCheckoutCommit.isEmpty, !readinessCleanCommit.isEmpty, cleanCheckoutCommit != readinessCleanCommit {
            issues.append("Clean-checkout sourceCommit and readiness cleanCheckoutSourceCommit differ.")
        }
        if externalUploadAttempted || rawTranscriptStored || rawAudioStored || rawLogsStored || rawUITextStored {
            issues.append("Freshness evidence must stay local and redacted.")
        }

        let checklistMentionsClean = !cleanCheckoutCommit.isEmpty && checklist.contains(cleanCheckoutCommit)
        let checklistMentionsReady = !readinessCommit.isEmpty && checklist.contains(readinessCommit)
        let checklistMentionsLabel = !effectiveReadinessLabel.isEmpty && checklist.contains(effectiveReadinessLabel)
        let checklistHeaderMatchesLabel = !effectiveReadinessLabel.isEmpty
            && checklist.contains("Current readiness label: \(effectiveReadinessLabel).")
        let providerMatrixSummaryFragments = [
            "status=\(providerMatrixStatus)",
            "passCount=\(providerMatrixPassCount)",
            "blockedCount=\(providerMatrixBlockedCount)",
            "failCount=\(providerMatrixFailCount)"
        ]
        let foundationModelsStatusFragment = "Foundation Models fixture evidence is `status=\(foundationModelsProviderStatus)`"
        let checklistMentionsProviderSummary = providerMatrixSummaryFragments.allSatisfy { checklist.contains($0) }
        let checklistMentionsFoundationModelsStatus = !foundationModelsProviderStatus.isEmpty
            && checklist.contains(foundationModelsStatusFragment)
        let readinessMentionsClean = !cleanCheckoutCommit.isEmpty && releaseReadiness.contains(cleanCheckoutCommit)
        let readinessMentionsReady = !readinessCommit.isEmpty && releaseReadiness.contains(readinessCommit)
        let readinessMentionsLabel = !effectiveReadinessLabel.isEmpty && releaseReadiness.contains(effectiveReadinessLabel)
        let readinessHeaderMatchesLabel = !effectiveReadinessLabel.isEmpty
            && releaseReadiness.contains("Current label: \(effectiveReadinessLabel).")
        let readinessMentionsProviderSummary = providerMatrixSummaryFragments.allSatisfy { releaseReadiness.contains($0) }
        let readinessMentionsFoundationModelsStatus = !foundationModelsProviderStatus.isEmpty
            && releaseReadiness.contains(foundationModelsStatusFragment)

        if !checklistMentionsClean {
            issues.append("Release checklist does not mention current clean-checkout sourceCommit.")
        }
        if !checklistMentionsReady {
            issues.append("Release checklist does not mention current release-readiness sourceCommit.")
        }
        if !checklistMentionsLabel {
            issues.append("Release checklist does not mention current readiness label.")
        }
        if !checklistHeaderMatchesLabel {
            issues.append("Release checklist header does not match current readiness label.")
        }
        if !checklistMentionsProviderSummary {
            issues.append("Release checklist does not mention current provider matrix status/pass/block/fail counts.")
        }
        if !checklistMentionsFoundationModelsStatus {
            issues.append("Release checklist does not mention current Foundation Models provider status.")
        }
        if !readinessMentionsClean {
            issues.append("Release readiness doc does not mention current clean-checkout sourceCommit.")
        }
        if !readinessMentionsReady {
            issues.append("Release readiness doc does not mention current release-readiness sourceCommit.")
        }
        if !readinessMentionsLabel {
            issues.append("Release readiness doc does not mention current readiness label.")
        }
        if !readinessHeaderMatchesLabel {
            issues.append("Release readiness header does not match current readiness label.")
        }
        if !readinessMentionsProviderSummary {
            issues.append("Release readiness doc does not mention current provider matrix status/pass/block/fail counts.")
        }
        if !readinessMentionsFoundationModelsStatus {
            issues.append("Release readiness doc does not mention current Foundation Models provider status.")
        }

        return ReleaseDocsFreshnessReport(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            status: issues.isEmpty ? "pass" : "fail",
            checklistPath: relativePath(checklistURL, rootURL: rootURL),
            releaseReadinessPath: relativePath(releaseReadinessURL, rootURL: rootURL),
            cleanCheckoutEvidencePath: relativePath(cleanCheckoutURL, rootURL: rootURL),
            releaseReadinessEvidencePath: relativePath(readinessEvidenceURL, rootURL: rootURL),
            providerMatrixEvidencePath: relativePath(providerMatrixURL, rootURL: rootURL),
            cleanCheckoutSourceCommit: cleanCheckoutCommit,
            readinessSourceCommit: readinessCommit,
            readinessCleanCheckoutSourceCommit: readinessCleanCommit,
            readinessLabel: effectiveReadinessLabel,
            providerMatrixStatus: providerMatrixStatus,
            providerMatrixPassCount: providerMatrixPassCount,
            providerMatrixBlockedCount: providerMatrixBlockedCount,
            providerMatrixFailCount: providerMatrixFailCount,
            foundationModelsProviderStatus: foundationModelsProviderStatus,
            checklistMentionsCleanCheckoutCommit: checklistMentionsClean,
            checklistMentionsReadinessCommit: checklistMentionsReady,
            checklistMentionsReadinessLabel: checklistMentionsLabel,
            checklistHeaderMatchesReadinessLabel: checklistHeaderMatchesLabel,
            checklistMentionsProviderMatrixSummary: checklistMentionsProviderSummary,
            checklistMentionsFoundationModelsProviderStatus: checklistMentionsFoundationModelsStatus,
            releaseReadinessMentionsCleanCheckoutCommit: readinessMentionsClean,
            releaseReadinessMentionsReadinessCommit: readinessMentionsReady,
            releaseReadinessMentionsReadinessLabel: readinessMentionsLabel,
            releaseReadinessHeaderMatchesReadinessLabel: readinessHeaderMatchesLabel,
            releaseReadinessMentionsProviderMatrixSummary: readinessMentionsProviderSummary,
            releaseReadinessMentionsFoundationModelsProviderStatus: readinessMentionsFoundationModelsStatus,
            localReady: localReady,
            releaseCandidateReady: releaseCandidateReady,
            externalUploadAttempted: externalUploadAttempted,
            rawTranscriptStored: rawTranscriptStored,
            rawAudioStored: rawAudioStored,
            rawLogsStored: rawLogsStored,
            rawUITextStored: rawUITextStored,
            issues: issues
        )
    }

    private static func readJSONObject(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private static func stringValue(_ value: Any?) -> String {
        value as? String ?? ""
    }

    private static func bool(_ value: Any?) -> Bool {
        if let value = value as? Bool {
            return value
        }
        return false
    }

    private static func intValue(_ value: Any?) -> Int {
        if let value = value as? Int {
            return value
        }
        return 0
    }

    private static func isSelfReferentialFreshnessBlock(
        readinessJSON: [String: Any]?,
        readinessLabel: String,
        cleanCheckoutCommit: String,
        readinessCleanCommit: String
    ) -> Bool {
        guard readinessLabel == "blocked before local app ready",
              !cleanCheckoutCommit.isEmpty,
              cleanCheckoutCommit == readinessCleanCommit,
              let checks = readinessJSON?["checks"] as? [[String: Any]] else {
            return false
        }
        let failedLocalChecks = checks.filter {
            bool($0["requiredForLocalReady"]) && !bool($0["passed"])
        }
        return failedLocalChecks.count == 1
            && stringValue(failedLocalChecks.first?["id"]) == "release-docs-freshness"
    }

    private static func providerStatus(in object: [String: Any]?, id: String) -> String {
        guard let providers = object?["providers"] as? [[String: Any]] else {
            return ""
        }
        return providers.first { $0["id"] as? String == id }?["status"] as? String ?? ""
    }

    private static func relativePath(_ url: URL, rootURL: URL) -> String {
        let root = rootURL.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(root + "/") else { return path }
        return String(path.dropFirst(root.count + 1))
    }

    private static func isValidEvidenceDate(_ value: String) -> Bool {
        let parts = value.split(separator: "-")
        guard parts.count == 3,
              parts[0].count == 4,
              parts[1].count == 2,
              parts[2].count == 2 else {
            return false
        }
        return parts.allSatisfy { $0.allSatisfy(\.isNumber) }
    }
}

ReleaseDocsFreshnessSmoke.main()
