import Foundation
import XCTest
@testable import MeetingVaultCore

final class ManualDeleteTests: XCTestCase {
    func testManualDeleteRemovesBundleAndWritesRedactedAuditEvent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultManualDelete-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let vault = AESGCMDataVault(
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 81, count: 32))
        )
        let bundleStore = EncryptedMeetingBundleStore(rootDirectory: root, vault: vault)
        let now = Date(timeIntervalSince1970: 1_780_005_000)
        let meetingID = UUID()
        var manifest = MeetingBundleManifest.initialEncryptedBundle(
            meetingID: meetingID,
            title: "Sensitive customer cancellation transcript"
        )
        manifest.createdAt = now.addingTimeInterval(-3_600)
        _ = try bundleStore.createBundle(manifest)

        let auditURL = root.appendingPathComponent("privacy-audit.jsonl")
        let auditWriter = PrivacyAuditLogWriter(logURL: auditURL, now: { now })
        let searchIndex = try SQLiteSearchIndex(databaseURL: root.appendingPathComponent("library.sqlite"))
        try searchIndex.upsertMeeting(
            SearchMeeting(
                id: meetingID,
                title: "Sensitive customer cancellation transcript",
                startedAt: now,
                sourceApp: "Teams"
            )
        )
        try searchIndex.upsertSegments([
            SearchTranscriptSegment(
                id: UUID(),
                meetingID: meetingID,
                speakerName: "Speaker",
                startTime: 0,
                endTime: 5,
                text: "customer cancellation transcript",
                confidence: 0.94,
                isFinal: true
            )
        ])
        XCTAssertEqual(try searchIndex.search("customer").count, 1)

        let service = MeetingDeleteService(
            bundleStore: bundleStore,
            auditWriter: auditWriter,
            searchIndex: searchIndex
        )

        let result = try service.deleteMeeting(meetingID: meetingID, reason: .userRequested)

        XCTAssertEqual(result.meetingID, meetingID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bundleStore.bundleURL(for: meetingID).path))
        XCTAssertEqual(try searchIndex.search("customer"), [])

        let rawLog = try String(contentsOf: auditURL, encoding: .utf8)
        XCTAssertTrue(rawLog.contains("meeting.delete"))
        XCTAssertTrue(rawLog.contains(meetingID.uuidString))
        XCTAssertFalse(rawLog.contains("Sensitive customer"))
        XCTAssertFalse(rawLog.contains("transcript"))

        let event = try XCTUnwrap(PrivacyAuditLogReader(logURL: auditURL).readEvents().first)
        XCTAssertEqual(event.action, .meetingDelete)
        XCTAssertEqual(event.meetingID, meetingID)
        XCTAssertEqual(event.metadata["reason"], "userRequested")
    }
}
