import Foundation
import XCTest
@testable import MeetingVaultCore

final class RecordingSessionMetadataTests: XCTestCase {
    func testPreviewCoverageEvidencePersistsEncryptedForFinalizationAndRecovery() async throws {
        let fixture = try makeFixture()
        let meetingID = try await fixture.createSession()
        let evidence = TranscriptPreviewEvidence(
            gaps: [try TranscriptPreviewGap(track: .remoteSystem, startTime: 1, endTime: 1.25)],
            speakerIdentities: [try TranscriptPreviewSpeakerIdentity(
                track: .remoteSystem,
                startTime: 0,
                endTime: 2,
                speakerName: "Speaker 2"
            )]
        )

        _ = try await fixture.service.recordPreviewEvidence(meetingID: meetingID, evidence: evidence)
        let persisted = try await fixture.service.read(meetingID: meetingID)

        XCTAssertEqual(persisted.previewEvidence, evidence)
        let raw = try Data(contentsOf: fixture.bundleStore.bundleURL(for: meetingID)
            .appendingPathComponent(RecordingSessionMetadata.relativePath))
        XCTAssertFalse(String(decoding: raw, as: UTF8.self).contains("Speaker 2"))
    }

    func testConcurrentMarksCollapseIntoOneDurableBookmark() async throws {
        let fixture = try makeFixture()
        let meetingID = try await fixture.createSession()

        let bookmarks = try await withThrowingTaskGroup(of: MeetingBookmark.self) { group in
            for _ in 0..<24 {
                group.addTask {
                    try await fixture.service.markMoment(meetingID: meetingID, timestamp: 12.25)
                }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }

        XCTAssertEqual(Set(bookmarks.map(\.id)).count, 1)
        let metadata = try await fixture.service.read(meetingID: meetingID)
        XCTAssertEqual(metadata.bookmarks.count, 1)
        XCTAssertEqual(metadata.revision, 1)
    }

    func testCollapseWindowIncludesExactFiveHundredMillisecondBoundaryAndPreservesEarliestIdentity() async throws {
        let fixture = try makeFixture()
        let meetingID = try await fixture.createSession()
        let first = try await fixture.service.markMoment(
            meetingID: meetingID,
            timestamp: 2,
            category: .important,
            note: "first"
        )
        let collapsed = try await fixture.service.markMoment(
            meetingID: meetingID,
            timestamp: 2.5,
            category: .question,
            note: nil
        )
        let separate = try await fixture.service.markMoment(meetingID: meetingID, timestamp: 3.001)

        XCTAssertEqual(collapsed.id, first.id)
        XCTAssertEqual(collapsed.timestamp, 2)
        XCTAssertEqual(collapsed.createdAt, first.createdAt)
        XCTAssertEqual(collapsed.category, .question)
        XCTAssertEqual(collapsed.note, "first", "A nil collapse field preserves the existing user-authored value")
        XCTAssertNotEqual(separate.id, first.id)
        let metadata = try await fixture.service.read(meetingID: meetingID)
        XCTAssertEqual(metadata.bookmarks.map(\.timestamp), [2, 3.001])
        XCTAssertEqual(metadata.revision, 3)
    }

    func testOutOfOrderCollapsedMarkKeepsStableIDButMovesToEarliestTimestamp() async throws {
        let fixture = try makeFixture()
        let meetingID = try await fixture.createSession()
        let first = try await fixture.service.markMoment(meetingID: meetingID, timestamp: 4.5)
        let collapsed = try await fixture.service.markMoment(meetingID: meetingID, timestamp: 4)

        XCTAssertEqual(collapsed.id, first.id)
        XCTAssertEqual(collapsed.createdAt, first.createdAt)
        XCTAssertEqual(collapsed.timestamp, 4)
        let metadata = try await fixture.service.read(meetingID: meetingID)
        XCTAssertEqual(metadata.bookmarks.map(\.timestamp), [4])
    }

    func testMarkRejectsMissingMismatchedAndFinalizedSessions() async throws {
        let fixture = try makeFixture()
        let missingID = UUID()
        await assertAsyncError(
            try await fixture.service.markMoment(meetingID: missingID, timestamp: 0),
            equals: .sessionNotActive
        )

        let meetingID = try await fixture.createSession()
        var mismatched = try await fixture.service.read(meetingID: meetingID)
        mismatched.meetingID = UUID()
        try fixture.bundleStore.writeJSONArtifact(
            mismatched,
            meetingID: meetingID,
            relativePath: RecordingSessionMetadata.relativePath,
            purpose: RecordingSessionMetadata.purpose
        )
        await assertAsyncError(
            try await fixture.service.markMoment(meetingID: meetingID, timestamp: 0),
            equals: .meetingMismatch
        )

        let finalizedID = try await fixture.createSession()
        _ = try await fixture.service.finalize(meetingID: finalizedID, duration: 4)
        await assertAsyncError(
            try await fixture.service.markMoment(meetingID: finalizedID, timestamp: 1),
            equals: .sessionNotActive
        )
    }

    func testMarkRejectsNonfiniteNegativeAndBeyondMaximumDurationWithoutLeakingNote() async throws {
        let fixture = try makeFixture()
        let meetingID = try await fixture.createSession()
        let privateNote = "private launch secret"

        for value in [Double.nan, Double.infinity, -0.001, RecordingSessionMetadata.maximumDuration + 0.001] {
            do {
                _ = try await fixture.service.markMoment(
                    meetingID: meetingID,
                    timestamp: value,
                    note: privateNote
                )
                XCTFail("Expected invalid bookmark timestamp")
            } catch {
                XCTAssertEqual(error as? RecordingSessionMetadataServiceError, .invalidBookmark)
                XCTAssertFalse(error.localizedDescription.contains(privateNote))
            }
        }
    }

    func testFinalizeRejectsBookmarkBeyondActualDurationAndLeavesMetadataActive() async throws {
        let fixture = try makeFixture()
        let meetingID = try await fixture.createSession()
        _ = try await fixture.service.markMoment(meetingID: meetingID, timestamp: 4)

        await assertAsyncError(
            try await fixture.service.finalize(meetingID: meetingID, duration: 3.999),
            equals: .bookmarkOutsideRecording
        )
        let metadata = try await fixture.service.read(meetingID: meetingID)
        XCTAssertFalse(metadata.isFinalized)
    }

    func testEditValidatesAndAtomicallyRewritesCategoryNoteAndRevision() async throws {
        let fixture = try makeFixture()
        let meetingID = try await fixture.createSession()
        let bookmark = try await fixture.service.markMoment(meetingID: meetingID, timestamp: 1)
        let privateNote = "Review <this> & preserve newlines\nsecond"

        let edited = try await fixture.service.editBookmark(
            meetingID: meetingID,
            bookmarkID: bookmark.id,
            category: .decision,
            note: privateNote
        )
        XCTAssertEqual(edited.category, .decision)
        XCTAssertEqual(edited.note, privateNote)
        let metadata = try await fixture.service.read(meetingID: meetingID)
        XCTAssertEqual(metadata.revision, 2)

        await assertAsyncError(
            try await fixture.service.editBookmark(
                meetingID: meetingID,
                bookmarkID: bookmark.id,
                category: nil,
                note: String(repeating: "x", count: RecordingSessionMetadata.maxBookmarkNoteUTF8Bytes + 1)
            ),
            equals: .invalidBookmark
        )
    }

    func testIdenticalCollapseAndIdenticalEditAreIdempotent() async throws {
        let fixture = try makeFixture()
        let meetingID = try await fixture.createSession()
        let first = try await fixture.service.markMoment(meetingID: meetingID, timestamp: 10)
        _ = try await fixture.service.markMoment(meetingID: meetingID, timestamp: 10.25)
        _ = try await fixture.service.editBookmark(
            meetingID: meetingID,
            bookmarkID: first.id,
            category: nil,
            note: nil
        )

        let metadata = try await fixture.service.read(meetingID: meetingID)
        XCTAssertEqual(metadata.revision, 1)
    }

    func testCorruptAndMissingMetadataUsePrivateSafeErrorsAndDoNotCreatePlaintext() async throws {
        let fixture = try makeFixture()
        let meetingID = try await fixture.createSession()
        let privateNote = "Board acquisition code name"
        _ = try await fixture.service.markMoment(meetingID: meetingID, timestamp: 0.25, note: privateNote)
        let artifactURL = fixture.bundleStore.bundleURL(for: meetingID)
            .appendingPathComponent(RecordingSessionMetadata.relativePath)
        let raw = try Data(contentsOf: artifactURL)
        XCTAssertFalse(String(decoding: raw, as: UTF8.self).contains(privateNote))

        try Data("corrupt".utf8).write(to: artifactURL, options: .atomic)
        do {
            _ = try await fixture.service.markMoment(meetingID: meetingID, timestamp: 1, note: privateNote)
            XCTFail("Expected corrupt metadata rejection")
        } catch {
            XCTAssertEqual(error as? RecordingSessionMetadataServiceError, .metadataUnreadable)
            XCTAssertFalse(error.localizedDescription.contains(privateNote))
        }
        let plaintextCandidates = try FileManager.default.contentsOfDirectory(
            at: artifactURL.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(plaintextCandidates.map(\.lastPathComponent), [artifactURL.lastPathComponent])
    }

    func testValidationRejectsBookmarkMeetingMismatchDuplicateIDsAndNoncanonicalNotes() throws {
        let meetingID = UUID()
        let duplicateID = UUID()
        let valid = MeetingBookmark(
            id: duplicateID,
            meetingID: meetingID,
            timestamp: 1,
            createdAt: Date(timeIntervalSince1970: 1_780_020_000),
            note: "note"
        )
        for bookmarks in [
            [MeetingBookmark(meetingID: UUID(), timestamp: 1, createdAt: valid.createdAt)],
            [valid, valid],
            [MeetingBookmark(meetingID: meetingID, timestamp: 1, createdAt: valid.createdAt, note: "   ")]
        ] {
            XCTAssertThrowsError(
                try RecordingSessionMetadata(
                    meetingID: meetingID,
                    startedAt: valid.createdAt,
                    context: MeetingContext(),
                    bookmarks: bookmarks
                ).validated()
            )
        }
    }

    func testSchemaV2ManifestCarriesSortedBookmarksAndSchemaV1DefaultsToNone() throws {
        let meetingID = UUID()
        let late = MeetingBookmark(
            meetingID: meetingID,
            timestamp: 9,
            createdAt: Date(timeIntervalSince1970: 1_780_020_009)
        )
        let early = MeetingBookmark(
            meetingID: meetingID,
            timestamp: 2,
            createdAt: Date(timeIntervalSince1970: 1_780_020_002)
        )
        let manifest = MeetingBundleManifest(
            meetingID: meetingID,
            schemaVersion: 2,
            title: "Bookmarks",
            tracks: [],
            bookmarks: [early, late]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(
            try decoder.decode(MeetingBundleManifest.self, from: encoder.encode(manifest)).bookmarks,
            [early, late]
        )

        let v1 = """
        {"meetingID":"\(meetingID.uuidString)","schemaVersion":1,"createdAt":"2026-07-17T12:00:00Z","title":"Legacy","tracks":[]}
        """
        XCTAssertEqual(try decoder.decode(MeetingBundleManifest.self, from: Data(v1.utf8)).bookmarks, [])
    }

    func testPlaybackTimelineProjectsExactSortedMarkersAndBookmarkRange() {
        let meetingID = UUID()
        let first = MeetingBookmark(
            meetingID: meetingID,
            timestamp: 1.25,
            createdAt: Date(timeIntervalSince1970: 1_780_020_000),
            category: .question,
            note: "Why now?"
        )
        let second = MeetingBookmark(
            meetingID: meetingID,
            timestamp: 8.75,
            createdAt: Date(timeIntervalSince1970: 1_780_020_001),
            category: .decision
        )
        let transcript = MeetingTranscript(meetingID: meetingID, localeIdentifier: "en-US", segments: [])

        let timeline = TranscriptPlaybackTimelineService().buildTimeline(
            transcript: transcript,
            audioChunks: [],
            bookmarks: [second, first]
        )

        XCTAssertEqual(timeline.bookmarks, [first, second])
        XCTAssertEqual(timeline.playbackRange(around: second.id, radius: 3), 5.75...8.75)
    }

    func testRecoveryReportsCorruptMetadataWithoutDroppingRecoverableAudio() async throws {
        let fixture = try makeFixture()
        let meetingID = try await fixture.createSession()
        _ = try EncryptedAudioChunkWriter(bundleStore: fixture.bundleStore).writeChunk(
            Data("recoverable encrypted audio".utf8),
            meetingID: meetingID,
            track: .microphone,
            chunkIndex: 0,
            startTime: 0,
            duration: 2,
            codec: "CAF/LPCM"
        )
        let artifactURL = fixture.bundleStore.bundleURL(for: meetingID)
            .appendingPathComponent(RecordingSessionMetadata.relativePath)
        try Data("corrupt".utf8).write(to: artifactURL, options: .atomic)

        let report = try RecordingRecoveryService(
            bundleStore: fixture.bundleStore,
            chunkWriter: EncryptedAudioChunkWriter(bundleStore: fixture.bundleStore)
        ).recoverableReport(for: meetingID)

        XCTAssertEqual(report.trackReports.first?.chunkCount, 1)
        XCTAssertEqual(report.bookmarks, [])
        XCTAssertTrue(report.warnings.contains(.sessionMetadataCorrupt))
    }

    func testIntelligenceReceivesBookmarkOnlyAsUserAuthoredEvidence() async throws {
        let fixture = try makeFixture()
        let meetingID = try await fixture.createSession()
        let bookmark = try await fixture.service.markMoment(
            meetingID: meetingID,
            timestamp: 1,
            category: .decision,
            note: "User says this moment matters"
        )
        let segment = TranscriptSegment(
            speakerName: "Anna",
            trackKind: .remoteSystem,
            startTime: 0,
            endTime: 2,
            text: "We should review the launch plan.",
            confidence: 0.9,
            isFinal: true
        )
        try fixture.bundleStore.writeJSONArtifact(
            MeetingTranscript(meetingID: meetingID, localeIdentifier: "en-US", segments: [segment]),
            meetingID: meetingID,
            relativePath: MeetingTranscript.finalTranscriptRelativePath,
            purpose: MeetingTranscript.finalTranscriptPurpose
        )
        let provider = MockMeetingIntelligenceProvider(
            summary: MeetingSummary(
                title: "Launch plan",
                oneParagraph: "The launch plan needs review.",
                bullets: [],
                decisions: [],
                actionItems: []
            )
        )
        _ = try await MeetingIntelligenceService(provider: provider, bundleStore: fixture.bundleStore)
            .generateSummary(meetingID: meetingID)

        XCTAssertEqual(provider.requests.first?.bookmarkEvidence.map(\.bookmark), [bookmark])
        XCTAssertEqual(provider.requests.first?.bookmarkEvidence.map(\.provenance), [.userAuthored])
    }

    func testExpectedMeetingValidationRejectsCopiedValidMetadataWithoutExposingAuthoredFields() throws {
        let requestedMeetingID = UUID()
        let privateMeetingID = UUID()
        let privateNote = "Acquisition code name Borealis"
        let metadata = RecordingSessionMetadata(
            meetingID: privateMeetingID,
            startedAt: Date(timeIntervalSince1970: 1_780_020_000),
            context: MeetingContext(participantNames: ["Private Person"]),
            bookmarks: [
                MeetingBookmark(
                    meetingID: privateMeetingID,
                    timestamp: 3,
                    createdAt: Date(timeIntervalSince1970: 1_780_020_003),
                    note: privateNote
                )
            ]
        )

        XCTAssertThrowsError(try metadata.validated(expectedMeetingID: requestedMeetingID)) { error in
            XCTAssertEqual(error as? RecordingSessionMetadataValidationError, .metadataMeetingMismatch)
            XCTAssertFalse(error.localizedDescription.contains(privateNote))
            XCTAssertFalse(error.localizedDescription.contains("Private Person"))
        }
    }

    func testConnectedCollapseClusterIsScheduleIndependentAndKeepsEarliestIdentity() async throws {
        let permutations: [[(TimeInterval, MeetingBookmarkCategory?, String?)]] = [
            [(0, .important, "alpha"), (0.4, .decision, "middle"), (0.8, .question, "omega")],
            [(0.8, .question, "omega"), (0.4, .decision, "middle"), (0, .important, "alpha")],
            [(0.4, .decision, "middle"), (0, .important, "alpha"), (0.8, .question, "omega")]
        ]

        for permutation in permutations {
            let fixture = try makeFixture()
            let meetingID = try await fixture.createSession()
            var firstAcceptedID: UUID?
            for (timestamp, category, note) in permutation {
                let result = try await fixture.service.markMoment(
                    meetingID: meetingID,
                    timestamp: timestamp,
                    category: category,
                    note: note
                )
                if firstAcceptedID == nil { firstAcceptedID = result.id }
            }

            let metadata = try await fixture.service.read(meetingID: meetingID)
            XCTAssertEqual(metadata.bookmarks.count, 1)
            XCTAssertEqual(metadata.bookmarks.first?.id, firstAcceptedID)
            XCTAssertEqual(metadata.bookmarks.first?.timestamp, 0)
            XCTAssertEqual(metadata.bookmarks.first?.category, .question)
            XCTAssertEqual(metadata.bookmarks.first?.note, "omega")
        }
    }

    func testEqualTimestampAuthoredFieldsUseDeterministicTieBreakInsteadOfArrivalOrder() async throws {
        for notes in [["alpha", "omega"], ["omega", "alpha"]] {
            let fixture = try makeFixture()
            let meetingID = try await fixture.createSession()
            _ = try await fixture.service.markMoment(
                meetingID: meetingID,
                timestamp: 1,
                category: .decision,
                note: notes[0]
            )
            _ = try await fixture.service.markMoment(
                meetingID: meetingID,
                timestamp: 1,
                category: .question,
                note: notes[1]
            )

            let metadata = try await fixture.service.read(meetingID: meetingID)
            let bookmark = try XCTUnwrap(metadata.bookmarks.first)
            XCTAssertEqual(bookmark.category, .question)
            XCTAssertEqual(bookmark.note, "omega")
        }
    }

    func testCollapsedClusterPersistsSequenceWatermarkForNextDistinctGesture() async throws {
        let fixture = try makeFixture()
        let meetingID = try await fixture.createSession()
        _ = try await fixture.service.markMoment(meetingID: meetingID, timestamp: 0)
        _ = try await fixture.service.markMoment(meetingID: meetingID, timestamp: 0.4)

        _ = try await fixture.service.markMoment(meetingID: meetingID, timestamp: 2)

        let metadata = try await fixture.service.read(meetingID: meetingID)
        XCTAssertEqual(metadata.bookmarks.count, 2)
        XCTAssertEqual(metadata.bookmarks[0].acceptedSequence, 1)
        XCTAssertEqual(metadata.bookmarks[0].collapsedThroughSequence, 2)
        XCTAssertEqual(metadata.bookmarks[1].acceptedSequence, 3)
    }

    func testRevisionCeilingRejectsMarkEditAndFinalizeWithTypedPrivateSafeError() async throws {
        for operation in 0..<3 {
            let fixture = try makeFixture()
            let meetingID = try await fixture.createSession()
            let bookmark = MeetingBookmark(
                meetingID: meetingID,
                timestamp: 1,
                createdAt: Date(timeIntervalSince1970: 1_780_020_001)
            )
            try fixture.bundleStore.writeJSONArtifact(
                RecordingSessionMetadata(
                    meetingID: meetingID,
                    startedAt: Date(timeIntervalSince1970: 1_780_020_000),
                    context: MeetingContext(),
                    bookmarks: operation == 1 ? [bookmark] : [],
                    revision: RecordingSessionMetadata.maximumRevision
                ),
                meetingID: meetingID,
                relativePath: RecordingSessionMetadata.relativePath,
                purpose: RecordingSessionMetadata.purpose
            )

            switch operation {
            case 0:
                await assertAsyncError(
                    try await fixture.service.markMoment(meetingID: meetingID, timestamp: 2),
                    equals: .revisionOverflow
                )
            case 1:
                await assertAsyncError(
                    try await fixture.service.editBookmark(
                        meetingID: meetingID,
                        bookmarkID: bookmark.id,
                        category: .important,
                        note: nil
                    ),
                    equals: .revisionOverflow
                )
            default:
                await assertAsyncError(
                    try await fixture.service.finalize(meetingID: meetingID, duration: 2),
                    equals: .revisionOverflow
                )
            }
        }
    }

    private func makeFixture() throws -> MetadataFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultBookmarkTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let bundleStore = EncryptedMeetingBundleStore(
            rootDirectory: root,
            vault: AESGCMDataVault(
                keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 47, count: 32))
            )
        )
        return MetadataFixture(
            bundleStore: bundleStore,
            service: RecordingSessionMetadataService(
                bundleStore: bundleStore,
                now: { Date(timeIntervalSince1970: 1_780_020_100) }
            )
        )
    }

    private func assertAsyncError<T>(
        _ expression: @autoclosure () async throws -> T,
        equals expected: RecordingSessionMetadataServiceError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await expression()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? RecordingSessionMetadataServiceError, expected, file: file, line: line)
        }
    }
}

private struct MetadataFixture {
    let bundleStore: EncryptedMeetingBundleStore
    let service: RecordingSessionMetadataService

    func createSession() async throws -> UUID {
        let meetingID = UUID()
        _ = try bundleStore.createBundle(.initialEncryptedBundle(meetingID: meetingID, title: "Bookmarks"))
        _ = try await service.create(
            meetingID: meetingID,
            startedAt: Date(timeIntervalSince1970: 1_780_020_000),
            context: MeetingContext()
        )
        return meetingID
    }
}
