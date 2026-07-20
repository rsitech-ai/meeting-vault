import Foundation
import XCTest
@testable import MeetingVaultCore

final class SharePreparationTests: XCTestCase {
    func testEveryShareDestinationRequiresUserConfirmationAndWritesRedactedAuditMetadata() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultShareDestinationMatrix-\(UUID().uuidString)", isDirectory: true)
        let exportRoot = root.appendingPathComponent("exports", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: exportRoot, withIntermediateDirectories: true)
        let markdownURL = exportRoot.appendingPathComponent("Sensitive-board-review.md")
        let webVTTURL = exportRoot.appendingPathComponent("Sensitive-board-review.vtt")
        try "Private roadmap detail must stay out of audit metadata.".write(
            to: markdownURL,
            atomically: true,
            encoding: .utf8
        )
        try "WEBVTT\n\n00:00.000 --> 00:01.000\nPrivate roadmap detail.\n".write(
            to: webVTTURL,
            atomically: true,
            encoding: .utf8
        )

        let meetingID = UUID()
        let package = MeetingExportPackage(
            meetingID: meetingID,
            directory: exportRoot,
            files: [
                MeetingExportFile(format: .markdown, url: markdownURL),
                MeetingExportFile(format: .webVTT, url: webVTTURL)
            ]
        )
        let auditURL = root.appendingPathComponent("privacy-audit.jsonl")
        let service = MeetingSharePreparationService(
            auditWriter: PrivacyAuditLogWriter(
                logURL: auditURL,
                now: { Date(timeIntervalSince1970: 1_780_006_421) }
            )
        )

        for destination in MeetingShareDestination.allCases {
            let manifest = try service.prepareShare(
                meetingID: meetingID,
                package: package,
                destination: destination
            )

            XCTAssertEqual(manifest.meetingID, meetingID)
            XCTAssertEqual(manifest.destination, destination)
            XCTAssertTrue(manifest.requiresUserConfirmation)
            XCTAssertEqual(manifest.files.map(\.format), [.markdown, .webVTT])
            XCTAssertEqual(manifest.files.map(\.url), [markdownURL, webVTTURL])
        }

        let events = try PrivacyAuditLogReader(logURL: auditURL).readEvents()
        XCTAssertEqual(events.count, MeetingShareDestination.allCases.count)
        XCTAssertEqual(events.map(\.action), Array(repeating: .sharePrepare, count: MeetingShareDestination.allCases.count))
        XCTAssertEqual(events.map { $0.metadata["destination"] }, MeetingShareDestination.allCases.map(\.rawValue))
        XCTAssertEqual(Set(events.map { $0.metadata["fileCount"] }), ["2"])
        XCTAssertEqual(Set(events.map { $0.metadata["formats"] }), ["markdown,webVTT"])

        let rawLog = try String(contentsOf: auditURL, encoding: .utf8)
        XCTAssertFalse(rawLog.contains("Private roadmap"))
        XCTAssertFalse(rawLog.contains("Sensitive-board-review"))
        XCTAssertFalse(rawLog.contains(exportRoot.path))
    }

    func testSharePreparationRequiresUserConfirmationAndWritesRedactedAuditEvent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultSharePreparation-\(UUID().uuidString)", isDirectory: true)
        let exportRoot = root.appendingPathComponent("exports", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: exportRoot, withIntermediateDirectories: true)
        let markdownURL = exportRoot.appendingPathComponent("Secret-launch-review.md")
        let jsonURL = exportRoot.appendingPathComponent("Secret-launch-review.json")
        try "Secret launch detail should never appear in audit logs.".write(
            to: markdownURL,
            atomically: true,
            encoding: .utf8
        )
        try #"{"summary":"Secret launch detail should never appear in audit logs."}"#.write(
            to: jsonURL,
            atomically: true,
            encoding: .utf8
        )

        let meetingID = UUID()
        let package = MeetingExportPackage(
            meetingID: meetingID,
            directory: exportRoot,
            files: [
                MeetingExportFile(format: .markdown, url: markdownURL),
                MeetingExportFile(format: .json, url: jsonURL)
            ]
        )
        let auditURL = root.appendingPathComponent("privacy-audit.jsonl")
        let auditWriter = PrivacyAuditLogWriter(
            logURL: auditURL,
            now: { Date(timeIntervalSince1970: 1_780_006_420) }
        )
        let service = MeetingSharePreparationService(auditWriter: auditWriter)

        let manifest = try service.prepareShare(
            meetingID: meetingID,
            package: package,
            destination: .systemShareSheet
        )

        XCTAssertEqual(manifest.meetingID, meetingID)
        XCTAssertEqual(manifest.destination, .systemShareSheet)
        XCTAssertTrue(manifest.requiresUserConfirmation)
        XCTAssertEqual(manifest.files.map(\.format), [.markdown, .json])
        XCTAssertEqual(manifest.files.map(\.url), [markdownURL, jsonURL])

        let rawLog = try String(contentsOf: auditURL, encoding: .utf8)
        XCTAssertTrue(rawLog.contains("share.prepare"))
        XCTAssertTrue(rawLog.contains(meetingID.uuidString))
        XCTAssertFalse(rawLog.contains("Secret launch"))
        XCTAssertFalse(rawLog.contains("Secret-launch-review"))
        XCTAssertFalse(rawLog.contains(exportRoot.path))

        let event = try XCTUnwrap(PrivacyAuditLogReader(logURL: auditURL).readEvents().first)
        XCTAssertEqual(event.action, .sharePrepare)
        XCTAssertEqual(event.meetingID, meetingID)
        XCTAssertEqual(event.metadata["destination"], "systemShareSheet")
        XCTAssertEqual(event.metadata["fileCount"], "2")
        XCTAssertEqual(event.metadata["formats"], "markdown,json")

        let review = try PrivacyAuditReviewService(reader: PrivacyAuditLogReader(logURL: auditURL)).loadReview()
        XCTAssertEqual(review.rows.first?.metadata["destination"], "systemShareSheet")
        XCTAssertEqual(review.rows.first?.metadata["fileCount"], "2")
    }
}
