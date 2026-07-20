import Foundation
import XCTest
@testable import MeetingVaultCore

final class TranscriptEditingTests: XCTestCase {
    func testTranscriptEditingPersistsEncryptedTranscriptReindexesSearchAndWritesRedactedAudit() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultTranscriptEditing-\(UUID().uuidString)", isDirectory: true)
        let databaseURL = root.appendingPathComponent("search.sqlite")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let vault = AESGCMDataVault(
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 73, count: 32))
        )
        let bundleStore = EncryptedMeetingBundleStore(rootDirectory: root, vault: vault)
        let searchIndex = try SQLiteSearchIndex(databaseURL: databaseURL)
        let auditURL = root.appendingPathComponent("privacy-audit.jsonl")
        let auditWriter = PrivacyAuditLogWriter(
            logURL: auditURL,
            now: { Date(timeIntervalSince1970: 1_780_008_000) }
        )
        let meetingID = UUID()
        let segmentID = UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")!
        let meeting = SearchMeeting(
            id: meetingID,
            title: "Transcript QA",
            startedAt: Date(timeIntervalSince1970: 1_780_007_900),
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
            generatedAt: Date(timeIntervalSince1970: 1_780_007_930),
            segments: [
                TranscriptSegment(
                    id: segmentID,
                    speakerName: "Unknown speaker",
                    trackKind: .remoteSystem,
                    startTime: 12,
                    endTime: 18,
                    text: "Wrong private customer detail should be corrected.",
                    confidence: 0.62,
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
        try searchIndex.upsertMeeting(meeting)
        try searchIndex.upsertSegments(
            transcript.segments.map {
                SearchTranscriptSegment(
                    id: $0.id,
                    meetingID: transcript.meetingID,
                    speakerName: $0.speakerName,
                    startTime: $0.startTime,
                    endTime: $0.endTime,
                    text: $0.text,
                    confidence: $0.confidence,
                    isFinal: $0.isFinal
                )
            }
        )

        let service = TranscriptEditingService(
            bundleStore: bundleStore,
            searchIndex: searchIndex,
            auditWriter: auditWriter,
            now: { Date(timeIntervalSince1970: 1_780_008_000) }
        )

        let result = try service.applyEdits(
            meeting: meeting,
            edits: [
                TranscriptSegmentEdit(
                    segmentID: segmentID,
                    replacementText: "Deployment moves to Thursday after QA sign-off.",
                    replacementSpeakerName: "Anna"
                )
            ]
        )

        XCTAssertEqual(result.editedSegmentCount, 1)
        XCTAssertEqual(result.transcript.segments.first?.text, "Deployment moves to Thursday after QA sign-off.")
        XCTAssertEqual(result.transcript.segments.first?.speakerName, "Anna")
        XCTAssertEqual(result.transcript.editedAt, Date(timeIntervalSince1970: 1_780_008_000))

        let stored = try bundleStore.readJSONArtifact(
            MeetingTranscript.self,
            meetingID: meetingID,
            relativePath: MeetingTranscript.finalTranscriptRelativePath,
            purpose: MeetingTranscript.finalTranscriptPurpose
        )
        XCTAssertEqual(stored, result.transcript)

        let storedBytes = try Data(
            contentsOf: bundleStore.bundleURL(for: meetingID)
                .appendingPathComponent(MeetingTranscript.finalTranscriptRelativePath)
        )
        XCTAssertFalse(String(decoding: storedBytes, as: UTF8.self).contains("Deployment moves"))

        XCTAssertEqual(try searchIndex.search("Wrong").count, 0)
        let updatedSearch = try searchIndex.search("Thursday")
        XCTAssertEqual(updatedSearch.count, 1)
        XCTAssertEqual(updatedSearch.first?.speakerName, "Anna")

        let rawLog = try String(contentsOf: auditURL, encoding: .utf8)
        XCTAssertTrue(rawLog.contains("transcript.edit"))
        XCTAssertTrue(rawLog.contains(meetingID.uuidString))
        XCTAssertFalse(rawLog.contains("Wrong private customer detail"))
        XCTAssertFalse(rawLog.contains("Deployment moves to Thursday"))
        XCTAssertFalse(rawLog.contains("Anna"))

        let event = try XCTUnwrap(PrivacyAuditLogReader(logURL: auditURL).readEvents().first)
        XCTAssertEqual(event.action, .transcriptEdit)
        XCTAssertEqual(event.meetingID, meetingID)
        XCTAssertEqual(event.metadata["editedSegmentCount"], "1")
    }

    func testTranscriptEditingAppendsEncryptedNonContentVersionHistory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultTranscriptEditHistory-\(UUID().uuidString)", isDirectory: true)
        let databaseURL = root.appendingPathComponent("search.sqlite")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let vault = AESGCMDataVault(
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 83, count: 32))
        )
        let bundleStore = EncryptedMeetingBundleStore(rootDirectory: root, vault: vault)
        let searchIndex = try SQLiteSearchIndex(databaseURL: databaseURL)
        let auditURL = root.appendingPathComponent("privacy-audit.jsonl")
        let auditWriter = PrivacyAuditLogWriter(
            logURL: auditURL,
            now: { Date(timeIntervalSince1970: 1_780_009_000) }
        )
        let meetingID = UUID()
        let firstSegmentID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let secondSegmentID = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
        let meeting = SearchMeeting(
            id: meetingID,
            title: "Transcript history QA",
            startedAt: Date(timeIntervalSince1970: 1_780_008_700),
            sourceApp: "Teams"
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
            generatedAt: Date(timeIntervalSince1970: 1_780_008_730),
            segments: [
                TranscriptSegment(
                    id: firstSegmentID,
                    speakerName: "Confidential Speaker",
                    trackKind: .remoteSystem,
                    startTime: 4,
                    endTime: 9,
                    text: "Original private roadmap detail.",
                    confidence: 0.70,
                    isFinal: true
                ),
                TranscriptSegment(
                    id: secondSegmentID,
                    speakerName: "Another Speaker",
                    trackKind: .microphone,
                    startTime: 12,
                    endTime: 16,
                    text: "Second private customer detail.",
                    confidence: 0.71,
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

        let editDateProvider = LockedDateProvider(dates: [
            Date(timeIntervalSince1970: 1_780_009_000),
            Date(timeIntervalSince1970: 1_780_009_060)
        ])
        let service = TranscriptEditingService(
            bundleStore: bundleStore,
            searchIndex: searchIndex,
            auditWriter: auditWriter,
            now: { editDateProvider.next() }
        )

        let firstResult = try service.applyEdits(
            meeting: meeting,
            edits: [
                TranscriptSegmentEdit(
                    segmentID: firstSegmentID,
                    replacementText: "Corrected deployment note.",
                    replacementSpeakerName: "Anna"
                )
            ]
        )
        let secondResult = try service.applyEdits(
            meeting: meeting,
            edits: [
                TranscriptSegmentEdit(
                    segmentID: secondSegmentID,
                    replacementText: "Corrected customer-safe note.",
                    replacementSpeakerName: "You"
                )
            ]
        )

        XCTAssertEqual(firstResult.version, 1)
        XCTAssertEqual(secondResult.version, 2)

        let history = try bundleStore.readJSONArtifact(
            TranscriptEditHistory.self,
            meetingID: meetingID,
            relativePath: TranscriptEditHistory.relativePath,
            purpose: TranscriptEditHistory.purpose
        )
        XCTAssertEqual(history.meetingID, meetingID)
        XCTAssertEqual(history.latestVersion, 2)
        XCTAssertEqual(history.entries.map(\.version), [1, 2])
        XCTAssertEqual(history.entries.map(\.editedSegmentIDs), [[firstSegmentID], [secondSegmentID]])
        XCTAssertEqual(history.entries.map(\.editedSegmentCount), [1, 1])
        XCTAssertEqual(history.entries.first?.editedAt, Date(timeIntervalSince1970: 1_780_009_000))
        XCTAssertEqual(history.entries.last?.editedAt, Date(timeIntervalSince1970: 1_780_009_060))

        let rawHistory = try String(
            contentsOf: bundleStore.bundleURL(for: meetingID)
                .appendingPathComponent(TranscriptEditHistory.relativePath),
            encoding: .utf8
        )
        XCTAssertFalse(rawHistory.contains("Original private roadmap detail"))
        XCTAssertFalse(rawHistory.contains("Corrected deployment note"))
        XCTAssertFalse(rawHistory.contains("Confidential Speaker"))
        XCTAssertFalse(rawHistory.contains("Anna"))
        XCTAssertFalse(rawHistory.contains("Corrected customer-safe note"))
        XCTAssertFalse(rawHistory.contains("You"))

        let rawLog = try String(contentsOf: auditURL, encoding: .utf8)
        XCTAssertTrue(rawLog.contains("\"version\":\"1\""))
        XCTAssertTrue(rawLog.contains("\"version\":\"2\""))
        XCTAssertFalse(rawLog.contains("Original private roadmap detail"))
        XCTAssertFalse(rawLog.contains("Corrected deployment note"))
        XCTAssertFalse(rawLog.contains("Confidential Speaker"))
        XCTAssertFalse(rawLog.contains("Anna"))
        XCTAssertFalse(rawLog.contains("Corrected customer-safe note"))
        XCTAssertFalse(rawLog.contains("You"))
    }
}

private final class LockedDateProvider: @unchecked Sendable {
    private let lock = NSLock()
    private var dates: [Date]

    init(dates: [Date]) {
        self.dates = dates
    }

    func next() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return dates.removeFirst()
    }
}
