import Foundation
import XCTest
@testable import MeetingVaultCore

final class TranscriptEditSessionTests: XCTestCase {
    func testTranscriptEditSessionLoadsDraftAndSavesThroughEncryptedStoreSearchHistoryAndAudit() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultTranscriptEditSession-\(UUID().uuidString)", isDirectory: true)
        let databaseURL = root.appendingPathComponent("search.sqlite")
        let auditURL = root.appendingPathComponent("privacy-audit.jsonl")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let vault = AESGCMDataVault(
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 91, count: 32))
        )
        let bundleStore = EncryptedMeetingBundleStore(rootDirectory: root, vault: vault)
        let searchIndex = try SQLiteSearchIndex(databaseURL: databaseURL)
        let auditWriter = PrivacyAuditLogWriter(
            logURL: auditURL,
            now: { Date(timeIntervalSince1970: 1_780_012_000) }
        )
        let meetingID = UUID()
        let firstSegmentID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let meeting = SearchMeeting(
            id: meetingID,
            title: "Persistence editor QA",
            startedAt: Date(timeIntervalSince1970: 1_780_011_000),
            sourceApp: "Zoom.us"
        )
        _ = try bundleStore.createBundle(
            MeetingBundleManifest.initialEncryptedBundle(
                meetingID: meetingID,
                title: meeting.title
            )
        )
        let transcript = MeetingTranscript(
            meetingID: meetingID,
            localeIdentifier: "en-US",
            generatedAt: Date(timeIntervalSince1970: 1_780_011_200),
            segments: [
                TranscriptSegment(
                    id: firstSegmentID,
                    speakerName: "Unknown speaker",
                    trackKind: .remoteSystem,
                    startTime: 30,
                    endTime: 37,
                    text: "Original sensitive transcript line.",
                    confidence: 0.77,
                    isFinal: true
                )
            ]
        )
        try bundleStore.writeJSONArtifact(
            transcript,
            meetingID: meetingID,
            relativePath: MeetingTranscript.finalTranscriptRelativePath,
            purpose: MeetingTranscript.finalTranscriptPurpose
        )

        let sessionService = TranscriptEditSessionService(
            bundleStore: bundleStore,
            searchIndex: searchIndex,
            auditWriter: auditWriter,
            now: { Date(timeIntervalSince1970: 1_780_012_000) }
        )

        var session = try sessionService.loadSession(meeting: meeting)
        XCTAssertEqual(session.draft.meetingID, meetingID)
        XCTAssertEqual(session.history.latestVersion, 0)
        XCTAssertFalse(session.draft.hasChanges)

        try session.draft.updateSegment(
            id: firstSegmentID,
            speakerName: " Anna ",
            text: " Corrected launch decision after QA sign-off. "
        )
        let saveResult = try sessionService.save(session: session)

        XCTAssertEqual(saveResult.result.version, 1)
        XCTAssertEqual(saveResult.session.draft.currentVersion, 1)
        XCTAssertFalse(saveResult.session.draft.hasChanges)
        XCTAssertEqual(saveResult.session.history.latestVersion, 1)
        XCTAssertEqual(saveResult.session.history.entries.first?.editedSegmentIDs, [firstSegmentID])

        let storedTranscript = try bundleStore.readJSONArtifact(
            MeetingTranscript.self,
            meetingID: meetingID,
            relativePath: MeetingTranscript.finalTranscriptRelativePath,
            purpose: MeetingTranscript.finalTranscriptPurpose
        )
        XCTAssertEqual(storedTranscript.segments.first?.speakerName, "Anna")
        XCTAssertEqual(storedTranscript.segments.first?.text, "Corrected launch decision after QA sign-off.")

        let rawTranscript = try String(
            contentsOf: bundleStore.bundleURL(for: meetingID)
                .appendingPathComponent(MeetingTranscript.finalTranscriptRelativePath),
            encoding: .utf8
        )
        XCTAssertFalse(rawTranscript.contains("Corrected launch decision"))
        XCTAssertFalse(rawTranscript.contains("Anna"))

        XCTAssertEqual(try searchIndex.search("Original").count, 0)
        let searchResults = try searchIndex.search("Corrected")
        XCTAssertEqual(searchResults.count, 1)
        XCTAssertEqual(searchResults.first?.speakerName, "Anna")

        let rawLog = try String(contentsOf: auditURL, encoding: .utf8)
        XCTAssertTrue(rawLog.contains("transcript.edit"))
        XCTAssertTrue(rawLog.contains("\"version\":\"1\""))
        XCTAssertFalse(rawLog.contains("Original sensitive transcript line"))
        XCTAssertFalse(rawLog.contains("Corrected launch decision"))
        XCTAssertFalse(rawLog.contains("Anna"))
    }
}
