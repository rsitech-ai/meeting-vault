import Foundation
import XCTest
@testable import MeetingVaultCore

final class PrivacyAuditReviewTests: XCTestCase {
    func testAuditReviewRowsAreLatestFirstAndOnlyExposeAllowlistedMetadata() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultAuditReview-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let logURL = root.appendingPathComponent("privacy-audit.jsonl")
        let writer = PrivacyAuditLogWriter(logURL: logURL)
        let meetingID = UUID()

        try writer.append(
            PrivacyAuditEvent(
                occurredAt: Date(timeIntervalSince1970: 1_780_006_000),
                action: .exportPackage,
                meetingID: meetingID,
                metadata: [
                    "formats": "markdown,json",
                    "fileCount": "2",
                    "title": "Secret customer launch",
                    "outputPath": "/tmp/Secret customer launch"
                ]
            )
        )
        try writer.append(
            PrivacyAuditEvent(
                occurredAt: Date(timeIntervalSince1970: 1_780_006_060),
                action: .meetingDelete,
                meetingID: meetingID,
                metadata: [
                    "reason": "userRequested",
                    "transcript": "private transcript text"
                ]
            )
        )
        try writer.append(
            PrivacyAuditEvent(
                occurredAt: Date(timeIntervalSince1970: 1_780_006_120),
                action: .transcriptEdit,
                meetingID: meetingID,
                metadata: [
                    "editedSegmentCount": "1",
                    "version": "2",
                    "speakerName": "Private Speaker",
                    "correctedText": "private transcript correction"
                ]
            )
        )

        let review = try PrivacyAuditReviewService(reader: PrivacyAuditLogReader(logURL: logURL)).loadReview()

        XCTAssertEqual(review.rows.map(\.action), [.transcriptEdit, .meetingDelete, .exportPackage])
        XCTAssertEqual(review.counts[.meetingDelete], 1)
        XCTAssertEqual(review.counts[.exportPackage], 1)
        XCTAssertEqual(review.counts[.transcriptEdit], 1)
        XCTAssertEqual(review.rows.first?.metadata, ["editedSegmentCount": "1", "version": "2"])
        XCTAssertEqual(review.rows[1].metadata, ["reason": "userRequested"])
        XCTAssertEqual(review.rows.last?.metadata, ["fileCount": "2", "formats": "markdown,json"])

        let renderedRows = review.rows.map(\.displaySummary).joined(separator: "\n")
        XCTAssertFalse(renderedRows.contains("Secret customer"))
        XCTAssertFalse(renderedRows.contains("private transcript"))
        XCTAssertFalse(renderedRows.contains("Private Speaker"))
        XCTAssertFalse(renderedRows.contains("private transcript correction"))
        XCTAssertFalse(renderedRows.contains("/tmp/"))
    }

    func testAuditReviewExportFiltersRowsAndWritesOnlyAllowlistedMetadata() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultAuditReviewExport-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let meetingID = UUID(uuidString: "4F0D5EB0-567E-4D5F-9D5E-26F7E4D7A001")!
        let review = PrivacyAuditReview(
            rows: [
                PrivacyAuditReviewRow(
                    id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
                    occurredAt: Date(timeIntervalSince1970: 1_780_010_000),
                    action: .exportPackage,
                    meetingID: meetingID,
                    metadata: [
                        "formats": "markdown,json",
                        "fileCount": "2",
                        "title": "Secret acquisition call",
                        "outputPath": root.appendingPathComponent("Secret acquisition call").path
                    ]
                ),
                PrivacyAuditReviewRow(
                    id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
                    occurredAt: Date(timeIntervalSince1970: 1_780_009_000),
                    action: .meetingDelete,
                    meetingID: meetingID,
                    metadata: [
                        "reason": "userRequested",
                        "transcript": "private transcript text"
                    ]
                )
            ],
            counts: [
                .exportPackage: 1,
                .meetingDelete: 1
            ],
            latestOccurredAt: Date(timeIntervalSince1970: 1_780_010_000)
        )

        let export = try PrivacyAuditReviewExportService().exportReview(
            review,
            to: root,
            actionFilter: .exportPackage,
            now: Date(timeIntervalSince1970: 1_780_010_060)
        )

        XCTAssertEqual(export.rowCount, 1)
        XCTAssertEqual(export.actionFilter, .exportPackage)
        XCTAssertEqual(export.files.map(\.lastPathComponent).sorted(), [
            "privacy-audit-review.csv",
            "privacy-audit-review.json"
        ])

        let exportedText = try export.files
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")

        XCTAssertTrue(exportedText.contains("export.package"))
        XCTAssertTrue(exportedText.contains("markdown,json"))
        XCTAssertTrue(exportedText.contains(meetingID.uuidString))
        XCTAssertFalse(exportedText.contains("meeting.delete"))
        XCTAssertFalse(exportedText.contains("Secret acquisition"))
        XCTAssertFalse(exportedText.contains(root.path))
        XCTAssertFalse(exportedText.contains("private transcript"))
    }
}
