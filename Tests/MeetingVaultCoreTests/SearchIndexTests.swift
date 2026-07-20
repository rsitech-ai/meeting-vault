import Foundation
import XCTest
@testable import MeetingVaultCore

final class SearchIndexTests: XCTestCase {
    func testSQLiteSearchIndexFindsTranscriptSegmentsWithTimestampContext() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultSearch-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let index = try SQLiteSearchIndex(databaseURL: databaseURL)
        let meetingID = UUID()

        try index.upsertMeeting(
            SearchMeeting(
                id: meetingID,
                title: "Architecture review",
                startedAt: Date(timeIntervalSince1970: 1_780_000_200),
                sourceApp: "Zoom.us"
            )
        )
        try index.upsertSegments([
            SearchTranscriptSegment(
                id: UUID(),
                meetingID: meetingID,
                speakerName: "You",
                startTime: 12,
                endTime: 18,
                text: "We need the Core Audio tap fallback before beta.",
                confidence: 0.92,
                isFinal: true
            ),
            SearchTranscriptSegment(
                id: UUID(),
                meetingID: meetingID,
                speakerName: "Anna",
                startTime: 45,
                endTime: 51,
                text: "The export checklist can wait until the recorder is stable.",
                confidence: 0.88,
                isFinal: true
            )
        ])

        let results = try index.search("fallback")

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.meetingTitle, "Architecture review")
        XCTAssertEqual(results.first?.speakerName, "You")
        XCTAssertEqual(results.first?.startTime, 12)
        XCTAssertTrue(results.first?.text.contains("Core Audio tap fallback") == true)
    }

    func testConcurrentReaderCannotObserveReplacementBetweenDeleteAndInsert() throws {
        let mutationReached = DispatchSemaphore(value: 0)
        let allowReplacementToFinish = DispatchSemaphore(value: 0)
        let replacementFinished = DispatchSemaphore(value: 0)
        let readerStarted = DispatchSemaphore(value: 0)
        let readerFinished = DispatchSemaphore(value: 0)
        let reader = ConcurrentSearchProbe()
        let index = try SQLiteSearchIndex(inMemory: ()) {
            mutationReached.signal()
            _ = allowReplacementToFinish.wait(timeout: .now() + 2)
        }
        let meeting = SearchMeeting(
            id: UUID(),
            title: "Atomic projection",
            startedAt: Date(timeIntervalSince1970: 1_780_000_300),
            sourceApp: "Meeting"
        )
        let old = SearchTranscriptSegment(
            id: UUID(),
            meetingID: meeting.id,
            speakerName: "You",
            startTime: 0,
            endTime: 1,
            text: "old projection",
            confidence: 1,
            isFinal: true
        )
        let new = SearchTranscriptSegment(
            id: old.id,
            meetingID: meeting.id,
            speakerName: "You",
            startTime: 0,
            endTime: 1,
            text: "new projection",
            confidence: 1,
            isFinal: true
        )
        try index.upsertMeeting(meeting)
        try index.upsertSegments([old])

        DispatchQueue.global().async {
            defer { replacementFinished.signal() }
            do {
                try index.replaceMeetingAndSegments(meeting: meeting, segments: [new])
            } catch {
                reader.record(error: error)
            }
        }
        XCTAssertEqual(mutationReached.wait(timeout: .now() + 2), .success)

        DispatchQueue.global().async {
            readerStarted.signal()
            defer { readerFinished.signal() }
            do {
                reader.record(
                    old: try index.search("old"),
                    new: try index.search("new")
                )
            } catch {
                reader.record(error: error)
            }
        }
        XCTAssertEqual(readerStarted.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(
            readerFinished.wait(timeout: .now() + 0.1),
            .timedOut,
            "A reader must wait until the complete replacement commits"
        )

        allowReplacementToFinish.signal()
        XCTAssertEqual(replacementFinished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(readerFinished.wait(timeout: .now() + 2), .success)
        XCTAssertNil(reader.error)
        XCTAssertTrue(reader.old.isEmpty)
        XCTAssertEqual(reader.new.map(\.text), ["new projection"])
    }
}

private final class ConcurrentSearchProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storedOld: [TranscriptSearchResult] = []
    private var storedNew: [TranscriptSearchResult] = []
    private var storedError: Error?

    var old: [TranscriptSearchResult] { lock.withLock { storedOld } }
    var new: [TranscriptSearchResult] { lock.withLock { storedNew } }
    var error: Error? { lock.withLock { storedError } }

    func record(old: [TranscriptSearchResult], new: [TranscriptSearchResult]) {
        lock.withLock {
            storedOld = old
            storedNew = new
        }
    }

    func record(error: Error) {
        lock.withLock { storedError = error }
    }
}
