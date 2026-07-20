import Foundation
import XCTest
@testable import MeetingVaultCore

final class ReleaseBlockerSummaryTests: XCTestCase {
    func testReleaseBlockerSummaryServiceLoadsBoundedDoctorReport() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let reportURL = root.appendingPathComponent("release-blocker-doctor.json")
        try sampleReportJSON(
            blockedGateCount: 1,
            totalActionCount: 2,
            rawTranscriptStored: false
        ).write(to: reportURL, atomically: true, encoding: .utf8)

        let summary = ReleaseBlockerSummaryService().loadReport(at: reportURL)

        XCTAssertEqual(summary.status, "pass")
        XCTAssertEqual(summary.releaseBlockerStatus, "blocked")
        XCTAssertEqual(summary.readinessLabel, "local app ready; release candidate blocked")
        XCTAssertTrue(summary.localReady)
        XCTAssertFalse(summary.releaseCandidateReady)
        XCTAssertEqual(summary.blockedGateCount, 1)
        XCTAssertEqual(summary.totalActionCount, 2)
        XCTAssertEqual(summary.blockedGates.map(\.id), ["manual-accessibility-release"])
        XCTAssertEqual(summary.blockedGates.first?.passedScenarioCount, 0)
        XCTAssertEqual(summary.blockedGates.first?.requiredScenarioCount, 7)
        XCTAssertEqual(summary.approvalQueue.first?.title, "Clear manual accessibility release gate")
        XCTAssertEqual(summary.approvalRequiredActionCount, 1)
        XCTAssertEqual(summary.localRunnableActionCount, 0)
        XCTAssertEqual(summary.prerequisiteBlockedActionCount, 2)
        XCTAssertEqual(summary.approvalQueue.first?.unmetPrerequisites, ["VoiceOver manual pass must be completed."])
        XCTAssertEqual(summary.approvalQueue.first?.displayStatusText, "Waiting on prerequisites")
        XCTAssertEqual(summary.approvalQueue.last?.unmetPrerequisites, ["Refresh evidence first."])
        XCTAssertEqual(summary.operatorBlockers, ["Workspace headroom is blocked."])
        XCTAssertEqual(summary.workspaceCleanupCandidates.first?.name, "CoreSimulator devices and runtimes")
        XCTAssertEqual(summary.workspaceCleanupCandidates.first?.pathHint, "~/Library/Developer/CoreSimulator")
        XCTAssertEqual(summary.workspaceCleanupCandidates.first?.bytes, 13_069_369_344)
        XCTAssertEqual(summary.workspaceCleanupCandidates.first?.requiresManualReview, true)
        XCTAssertEqual(summary.loadedFromPath, reportURL.path)
        XCTAssertTrue(summary.issues.isEmpty)
    }

    func testReleaseBlockerSummaryServiceMarksMissingAndUnsafeReports() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let missingURL = root.appendingPathComponent("missing.json")

        let missing = ReleaseBlockerSummaryService().loadReport(at: missingURL)
        XCTAssertEqual(missing.status, "unavailable")
        XCTAssertEqual(missing.loadedFromPath, missingURL.path)
        XCTAssertTrue(missing.issues.contains("Release blocker report is missing."))

        let leakingURL = root.appendingPathComponent("leaking.json")
        try sampleReportJSON(
            blockedGateCount: 1,
            totalActionCount: 1,
            rawTranscriptStored: true
        ).write(to: leakingURL, atomically: true, encoding: .utf8)

        let leaking = ReleaseBlockerSummaryService().loadReport(at: leakingURL)
        XCTAssertEqual(leaking.status, "pass")
        XCTAssertTrue(leaking.issues.contains { $0.contains("rawTranscriptStored") })
    }

    func testReleaseBlockerSummaryServiceFlagsInconsistentActionCounts() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let reportURL = root.appendingPathComponent("mismatched-counts.json")
        try sampleReportJSON(
            blockedGateCount: 2,
            totalActionCount: 3,
            rawTranscriptStored: false,
            approvalRequiredActionCount: 2,
            localRunnableActionCount: 1,
            prerequisiteBlockedActionCount: 1
        ).write(to: reportURL, atomically: true, encoding: .utf8)

        let summary = ReleaseBlockerSummaryService().loadReport(at: reportURL)

        XCTAssertEqual(summary.approvalRequiredActionCount, 1)
        XCTAssertEqual(summary.localRunnableActionCount, 0)
        XCTAssertEqual(summary.prerequisiteBlockedActionCount, 2)
        XCTAssertTrue(summary.issues.contains { $0.contains("blockedGateCount=2") })
        XCTAssertTrue(summary.issues.contains { $0.contains("totalActionCount=3") })
        XCTAssertTrue(summary.issues.contains { $0.contains("approvalRequiredActionCount=2") })
        XCTAssertTrue(summary.issues.contains { $0.contains("localRunnableActionCount=1") })
        XCTAssertTrue(summary.issues.contains { $0.contains("prerequisiteBlockedActionCount=1") })
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReleaseBlockerSummaryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func sampleReportJSON(
        blockedGateCount: Int,
        totalActionCount: Int,
        rawTranscriptStored: Bool,
        approvalRequiredActionCount: Int = 1,
        localRunnableActionCount: Int = 0,
        prerequisiteBlockedActionCount: Int = 2
    ) -> String {
        """
        {
          "status": "pass",
          "releaseBlockerStatus": "blocked",
          "evidenceDate": "2026-07-01",
          "readinessLabel": "local app ready; release candidate blocked",
          "localReady": true,
          "releaseCandidateReady": false,
          "sourceCommit": "abc123",
          "cleanCheckoutSourceCommit": "abc123",
          "blockedGateCount": \(blockedGateCount),
          "totalActionCount": \(totalActionCount),
          "approvalRequiredActionCount": \(approvalRequiredActionCount),
          "localRunnableActionCount": \(localRunnableActionCount),
          "prerequisiteBlockedActionCount": \(prerequisiteBlockedActionCount),
          "blockedGates": [
            {
              "id": "manual-accessibility-release",
              "title": "manual accessibility release gate",
              "path": "docs/evidence/manual-accessibility-release-gate-2026-07-01.json",
              "status": "blocked",
              "requiredForReleaseCandidate": true,
              "passedScenarioCount": 0,
              "requiredScenarioCount": 7,
              "issueCount": 1
            }
          ],
          "approvalQueue": [
            {
              "id": "clear-manual-accessibility-release",
              "title": "Clear manual accessibility release gate",
              "category": "accessibility",
              "blockedGateID": "manual-accessibility-release",
              "commands": ["script/manual_accessibility_release_gate.swift --write-template template.json"],
              "manualStep": "Complete bounded manual QA.",
              "approvalRequired": true,
              "unmetPrerequisites": ["VoiceOver manual pass must be completed."]
            },
            {
              "id": "refresh-release-docs",
              "title": "Refresh release docs",
              "category": "docs",
              "blockedGateID": null,
              "commands": ["swift script/release_docs_freshness_smoke.swift --require-pass"],
              "manualStep": "Run after evidence has been refreshed.",
              "approvalRequired": false,
              "unmetPrerequisites": ["Refresh evidence first."]
            }
          ],
          "operatorBlockers": [
            "Workspace headroom is blocked."
          ],
          "workspaceCleanupCandidates": [
            {
              "name": "CoreSimulator devices and runtimes",
              "pathHint": "~/Library/Developer/CoreSimulator",
              "bytes": 13069369344,
              "safetyClass": "simulatorData",
              "cleanupAction": "Review in Finder or Xcode Devices and Simulators; remove only unused simulator data/runtimes.",
              "requiresManualReview": true,
              "exists": true
            }
          ],
          "privateAudioRecorded": false,
          "microphoneOpened": false,
          "externalNetworkRequested": false,
          "downloadRequested": false,
          "externalUploadAttempted": false,
          "notarizationSubmitted": false,
          "rawTranscriptStored": \(rawTranscriptStored ? "true" : "false"),
          "rawAudioStored": false,
          "rawModelOutputStored": false,
          "rawLogsStored": false,
          "rawUITextStored": false,
          "rawCredentialStored": false,
          "rawSigningOutputStored": false,
          "rawNotarizationOutputStored": false,
          "issues": []
        }
        """
    }
}
