import Foundation
import XCTest
@testable import MeetingVaultCore

final class MeetingLibraryRepositoryTests: XCTestCase {
    func testMeetingLibraryRepositoryPersistsEncryptedRecordsAndReloadsEditorSessions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultLibraryRepository-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let keyProvider = InMemorySymmetricKeyProvider(keyData: Data(repeating: 77, count: 32))
        let vault = AESGCMDataVault(keyProvider: keyProvider)
        let bundleStore = EncryptedMeetingBundleStore(rootDirectory: root, vault: vault)
        let searchIndex = try SQLiteSearchIndex(inMemory: ())
        let repository = MeetingLibraryRepository(bundleStore: bundleStore, searchIndex: searchIndex)

        let first = makeEntry(
            title: "Launch planning",
            sourceName: "Microsoft Teams",
            transcriptText: "We need support-ready release notes before launch.",
            state: .processing
        )
        let second = makeEntry(
            title: "Design review",
            sourceName: "Zoom.us",
            transcriptText: "The inspector hierarchy needs another visual pass.",
            state: .recovered
        )

        try repository.save(first)
        try repository.save(second)

        let reloadedSearchIndex = try SQLiteSearchIndex(inMemory: ())
        let reloadedRepository = MeetingLibraryRepository(bundleStore: bundleStore, searchIndex: reloadedSearchIndex)
        let snapshot = try reloadedRepository.loadSnapshot()

        XCTAssertEqual(snapshot.records.map(\.title), ["Launch planning", "Design review"])
        XCTAssertEqual(snapshot.searchMeetingsByID[second.record.id]?.sourceApp, "Zoom.us")

        let secondSession = try XCTUnwrap(snapshot.editSessionsByMeetingID[second.record.id])
        XCTAssertEqual(secondSession.draft.meetingID, second.record.id)
        XCTAssertEqual(secondSession.draft.segments.first?.editedText, "The inspector hierarchy needs another visual pass.")
        XCTAssertEqual(secondSession.history.meetingID, second.record.id)

        let searchResults = try reloadedSearchIndex.search("inspector hierarchy", limit: 5)
        XCTAssertEqual(searchResults.map(\.meetingID), [second.record.id])

        let rawRecord = try Data(
            contentsOf: bundleStore.bundleURL(for: second.record.id)
                .appendingPathComponent(MeetingLibraryRepository.recordRelativePath)
        )
        let rawTranscript = try Data(
            contentsOf: bundleStore.bundleURL(for: second.record.id)
                .appendingPathComponent(MeetingTranscript.finalTranscriptRelativePath)
        )
        let rawRecordText = String(data: rawRecord, encoding: .utf8) ?? ""
        let rawTranscriptText = String(data: rawTranscript, encoding: .utf8) ?? ""

        XCTAssertFalse(rawRecordText.contains("Design review"))
        XCTAssertFalse(rawTranscriptText.contains("inspector hierarchy"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("library.sqlite").path))
    }

    private func makeEntry(
        title: String,
        sourceName: String,
        transcriptText: String,
        state: RecordingState
    ) -> MeetingLibraryEntry {
        let meetingID = UUID()
        let segmentID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_780_000_000 + Double(title.count))
        let evidence = EvidenceRef(
            meetingID: meetingID,
            segmentID: segmentID,
            startTime: 12,
            endTime: 20,
            quote: transcriptText
        )
        let record = MeetingRecord(
            id: meetingID,
            title: title,
            startedAt: startedAt,
            durationSeconds: 1_240,
            sourceName: sourceName,
            state: state,
            consentStatus: .disclosed,
            summary: MeetingSummary(
                title: title,
                oneParagraph: transcriptText,
                bullets: [transcriptText],
                decisions: [
                    Decision(
                        title: "Review next step",
                        details: transcriptText,
                        evidence: [evidence],
                        confidence: 0.88
                    )
                ],
                actionItems: []
            )
        )
        let transcript = MeetingTranscript(
            meetingID: meetingID,
            localeIdentifier: "en-US",
            generatedAt: startedAt.addingTimeInterval(600),
            segments: [
                TranscriptSegment(
                    id: segmentID,
                    speakerName: "Avery",
                    trackKind: .remoteSystem,
                    startTime: 12,
                    endTime: 20,
                    text: transcriptText,
                    confidence: 0.93,
                    isFinal: true
                )
            ]
        )

        return MeetingLibraryEntry(
            record: record,
            searchMeeting: SearchMeeting(
                id: meetingID,
                title: title,
                startedAt: startedAt,
                sourceApp: sourceName
            ),
            transcript: transcript,
            editHistory: TranscriptEditHistory(meetingID: meetingID)
        )
    }
}
