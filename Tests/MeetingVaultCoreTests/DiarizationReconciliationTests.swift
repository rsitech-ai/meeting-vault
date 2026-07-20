import Foundation
import XCTest
@testable import MeetingVaultCore

final class DiarizationReconciliationTests: XCTestCase {
    func testOverlapRepresentsTextExactlyOnceAsMultipleSpeakers() throws {
        let microphone = transcript(speaker: "unknown", track: .microphone, start: 0, end: 3, text: "my update")
        let remote = transcript(speaker: "unassigned", track: .remoteSystem, start: 0, end: 5, text: "shared discussion")
        let turns = [
            DiarizationTurn(speakerID: "a", startTime: 0, endTime: 1.5, confidence: 0.9),
            DiarizationTurn(speakerID: "b", startTime: 1, endTime: 2.2, confidence: 0.8),
            DiarizationTurn(speakerID: "c", startTime: 2, endTime: 3.2, confidence: 0.9),
            DiarizationTurn(speakerID: "d", startTime: 3, endTime: 4.2, confidence: 0.9),
            DiarizationTurn(speakerID: "e", startTime: 4, endTime: 5, confidence: 0.9),
        ]

        let result = try DiarizationReconciler().reconcile(
            asrSegments: [microphone, remote],
            remoteTurns: turns,
            expectedRemoteSpeakerCount: 5,
            speakerRenames: ["Speaker 2": "Marta"]
        )

        XCTAssertEqual(result.first(where: { $0.trackKind == .microphone })?.speakerName, "You")
        let remoteResult = result.filter { $0.trackKind == .remoteSystem }
        XCTAssertEqual(remoteResult.count, 1)
        XCTAssertEqual(remoteResult.first?.speakerName, "Multiple speakers")
        XCTAssertEqual(remoteResult.first?.text, "shared discussion")
        XCTAssertEqual(remoteResult.first?.startTime, 0)
        XCTAssertEqual(remoteResult.first?.endTime, 5)
    }

    func testSequentialFiveSpeakersDoNotCloneWholeASRSegments() throws {
        let remote = (0..<5).map { index in
            transcript(
                speaker: "unassigned",
                track: .remoteSystem,
                start: Double(index),
                end: Double(index + 1),
                text: "word-\(index)"
            )
        }
        let turns = (0..<5).map { index in
            DiarizationTurn(
                speakerID: "raw-\(index)",
                startTime: Double(index),
                endTime: Double(index + 1),
                confidence: 0.9
            )
        }
        let result = try DiarizationReconciler().reconcile(
            asrSegments: remote,
            remoteTurns: turns,
            expectedRemoteSpeakerCount: 5,
            speakerRenames: ["Speaker 2": "Marta"]
        )

        XCTAssertEqual(result.map(\.text), ["word-0", "word-1", "word-2", "word-3", "word-4"])
        XCTAssertEqual(result.map(\.speakerName), ["Speaker 1", "Marta", "Speaker 3", "Speaker 4", "Speaker 5"])
    }

    func testRejectsInvalidTurnsAndCapsUnexpectedSpeakers() throws {
        let remote = transcript(speaker: "raw", track: .remoteSystem, start: 0, end: 4, text: "hello")
        XCTAssertThrowsError(try DiarizationReconciler().reconcile(
            asrSegments: [remote],
            remoteTurns: [DiarizationTurn(speakerID: "x", startTime: 2, endTime: 1, confidence: 2)],
            expectedRemoteSpeakerCount: 5
        ))

        let capped = try DiarizationReconciler().reconcile(
            asrSegments: [remote],
            remoteTurns: (0..<8).map {
                DiarizationTurn(speakerID: "raw-\($0)", startTime: Double($0) / 2, endTime: Double($0) / 2 + 0.5, confidence: 0.8)
            },
            expectedRemoteSpeakerCount: 5
        )
        XCTAssertLessThanOrEqual(Set(capped.map(\.speakerName)).count, 5)
    }

    func testFinalPipelineReadsOneDecryptedChunkAtATimeAndAtomicallyReplacesEncryptedTranscript() async throws {
        let fixture = try FinalPipelineFixture()
        let engine = FixtureLocalFinalEngine()
        let service = LocalFinalTranscriptionService(
            engine: engine,
            bundleStore: fixture.bundleStore,
            searchIndex: fixture.searchIndex,
            decryptedChunkReader: fixture.reader,
            maximumDecryptedChunkBytes: 64,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )

        let result = try await service.transcribe(
            meeting: fixture.meeting,
            records: fixture.records,
            context: MeetingContext(localeIdentifier: "pl-PL", expectedParticipantCount: 6),
            speakerRenames: ["Speaker 1": "Ola"]
        )

        XCTAssertEqual(fixture.reader.maximumConcurrentReads, 1)
        XCTAssertEqual(fixture.reader.plaintextTemporaryFileCount, 0)
        XCTAssertFalse(fixture.reader.externalNetworkRequested)
        XCTAssertEqual(engine.tracks, [.microphone, .remoteSystem])
        XCTAssertEqual(result.transcript.segments.first(where: { $0.trackKind == .microphone })?.speakerName, "You")
        XCTAssertEqual(result.transcript.segments.first(where: { $0.trackKind == .remoteSystem })?.speakerName, "Ola")
        let persisted: MeetingTranscript = try fixture.bundleStore.readJSONArtifact(
            MeetingTranscript.self,
            meetingID: fixture.meeting.id,
            relativePath: MeetingTranscript.finalTranscriptRelativePath,
            purpose: MeetingTranscript.finalTranscriptPurpose
        )
        XCTAssertEqual(persisted, result.transcript)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("plaintext.wav").path))
    }

    func testNormalRemoteDiarizationDoesNotTreatInternalASRPlaceholderAsSpeakerRevision() async throws {
        let fixture = try FinalPipelineFixture()
        let service = LocalFinalTranscriptionService(
            engine: PlaceholderFinalEngine(),
            bundleStore: fixture.bundleStore,
            searchIndex: fixture.searchIndex,
            decryptedChunkReader: fixture.reader
        )

        let result = try await service.transcribe(
            meeting: fixture.meeting,
            records: fixture.records,
            context: MeetingContext(localeIdentifier: "en-US", expectedParticipantCount: 2)
        )

        let remote = try XCTUnwrap(result.transcript.segments.first { $0.trackKind == .remoteSystem })
        XCTAssertEqual(remote.speakerName, "Speaker 1")
        XCTAssertEqual(remote.reviewEvidence?.speakerWasRevised, false)
        XCTAssertFalse(try TranscriptReviewRepository(bundleStore: fixture.bundleStore)
            .load(meetingID: fixture.meeting.id).activeItems.contains { $0.reason == .revisedSpeaker })
    }

    func testObservedPreviewGapAndRealSpeakerIdentityChangeBecomeFinalEvidence() async throws {
        let fixture = try FinalPipelineFixture()
        let service = LocalFinalTranscriptionService(
            engine: PlaceholderFinalEngine(),
            bundleStore: fixture.bundleStore,
            searchIndex: fixture.searchIndex,
            decryptedChunkReader: fixture.reader
        )
        let previewEvidence = TranscriptPreviewEvidence(
            gaps: [try TranscriptPreviewGap(track: .remoteSystem, startTime: 0.25, endTime: 0.75)],
            speakerIdentities: [try TranscriptPreviewSpeakerIdentity(
                track: .remoteSystem,
                startTime: 0,
                endTime: 2,
                speakerName: "Speaker 2"
            )]
        )

        let result = try await service.transcribe(
            meeting: fixture.meeting,
            records: fixture.records,
            context: MeetingContext(localeIdentifier: "en-US", expectedParticipantCount: 2),
            previewEvidence: previewEvidence
        )

        let remote = try XCTUnwrap(result.transcript.segments.first { $0.trackKind == .remoteSystem })
        XCTAssertEqual(remote.reviewEvidence?.reconstructedFromPreviewGap, true)
        XCTAssertEqual(remote.reviewEvidence?.speakerWasRevised, true)
    }

    func testFinalEvidenceUsesEngineModelAndDiarizationConfigurationIdentity() async throws {
        let fixture = try FinalPipelineFixture()
        let expected = "asr@manifest-rev-a+offline-diarization@manifest-rev-b+config@digest-c"
        let service = LocalFinalTranscriptionService(
            engine: IdentifiedFinalEngine(configurationVersion: expected),
            bundleStore: fixture.bundleStore,
            searchIndex: fixture.searchIndex,
            decryptedChunkReader: fixture.reader
        )

        let result = try await service.transcribe(
            meeting: fixture.meeting,
            records: fixture.records,
            context: MeetingContext(localeIdentifier: "en-US", expectedParticipantCount: 2)
        )

        XCTAssertEqual(result.transcript.providerConfigurationVersion, expected)
        XCTAssertTrue(result.transcript.segments.allSatisfy { $0.reviewEvidence?.providerConfigurationVersion == expected })
    }

    func testIndexFailurePreservesEncryptedTranscriptAndRecoverableMarker() async throws {
        let fixture = try FinalPipelineFixture()
        let service = LocalFinalTranscriptionService(
            engine: FixtureLocalFinalEngine(),
            bundleStore: fixture.bundleStore,
            searchIndex: fixture.searchIndex,
            decryptedChunkReader: fixture.reader,
            indexTransaction: { _, _ in throw SQLiteSearchIndexError.executeFailed("fixture") }
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await service.transcribe(
                meeting: fixture.meeting,
                records: fixture.records,
                context: MeetingContext(localeIdentifier: "pl-PL", expectedParticipantCount: 6)
            )
        }

        XCTAssertTrue(try fixture.bundleStore.artifactExists(
            meetingID: fixture.meeting.id,
            relativePath: TranscriptReindexPendingMarker.relativePath
        ))
        let persisted: MeetingTranscript = try fixture.bundleStore.readJSONArtifact(
            MeetingTranscript.self,
            meetingID: fixture.meeting.id,
            relativePath: MeetingTranscript.finalTranscriptRelativePath,
            purpose: MeetingTranscript.finalTranscriptPurpose
        )
        XCTAssertFalse(persisted.segments.isEmpty)
        try fixture.persistAuthoritativeMetadata()

        let recovered = try TranscriptReindexRecoveryService(
            bundleStore: fixture.bundleStore,
            searchIndex: fixture.searchIndex
        ).recover(meeting: fixture.meeting)
        XCTAssertEqual(recovered, .rebuilt(digestMatchedMarker: true))
        XCTAssertFalse(try fixture.bundleStore.artifactExists(
            meetingID: fixture.meeting.id,
            relativePath: TranscriptReindexPendingMarker.relativePath
        ))
        XCTAssertEqual(try fixture.searchIndex.search("mówię").count, 1)
    }

    func testRecoveryPreservesMarkerAndSearchWhenTranscriptDigestDoesNotMatch() async throws {
        let fixture = try FinalPipelineFixture()
        let transcript = MeetingTranscript(
            meetingID: fixture.meeting.id,
            localeIdentifier: "en-US",
            segments: [transcript(
                speaker: "You",
                track: .microphone,
                start: 0,
                end: 1,
                text: "preserved authority"
            )]
        )
        try fixture.bundleStore.writeJSONArtifact(
            transcript,
            meetingID: fixture.meeting.id,
            relativePath: MeetingTranscript.finalTranscriptRelativePath,
            purpose: MeetingTranscript.finalTranscriptPurpose
        )
        try fixture.bundleStore.writeJSONArtifact(
            TranscriptReindexPendingMarker(meetingID: fixture.meeting.id, transcriptDigest: "0"),
            meetingID: fixture.meeting.id,
            relativePath: TranscriptReindexPendingMarker.relativePath,
            purpose: TranscriptReindexPendingMarker.purpose
        )
        try fixture.persistAuthoritativeMetadata()

        let recovered = try TranscriptReindexRecoveryService(
            bundleStore: fixture.bundleStore,
            searchIndex: fixture.searchIndex
        ).recover(meeting: fixture.meeting)

        XCTAssertEqual(recovered, .preserved(.transcriptDigestMismatch))
        XCTAssertTrue(try fixture.bundleStore.artifactExists(
            meetingID: fixture.meeting.id,
            relativePath: TranscriptReindexPendingMarker.relativePath
        ))
        XCTAssertTrue(try fixture.searchIndex.search("authority").isEmpty)
        let stillPersisted: MeetingTranscript = try fixture.bundleStore.readJSONArtifact(
            MeetingTranscript.self,
            meetingID: fixture.meeting.id,
            relativePath: MeetingTranscript.finalTranscriptRelativePath,
            purpose: MeetingTranscript.finalTranscriptPurpose
        )
        XCTAssertEqual(stillPersisted.meetingID, transcript.meetingID)
        XCTAssertEqual(stillPersisted.localeIdentifier, transcript.localeIdentifier)
        XCTAssertEqual(stillPersisted.segments, transcript.segments)
    }

    func testNativeFinalCloseFailureLeavesRecoveryMarkerAfterEncryptedAuthorityAndIndexCommit() async throws {
        let fixture = try FinalPipelineFixture()
        let service = LocalFinalTranscriptionService(
            engine: FailingClosePassEngine(),
            bundleStore: fixture.bundleStore,
            searchIndex: fixture.searchIndex,
            decryptedChunkReader: fixture.reader
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await service.transcribe(
                meeting: fixture.meeting,
                records: fixture.records,
                context: MeetingContext(localeIdentifier: "pl-PL", expectedParticipantCount: 2)
            )
        }

        XCTAssertTrue(try fixture.bundleStore.artifactExists(
            meetingID: fixture.meeting.id,
            relativePath: TranscriptReindexPendingMarker.relativePath
        ))
        XCTAssertEqual(try fixture.searchIndex.search("durable").count, 1)
        let transcript: MeetingTranscript = try fixture.bundleStore.readJSONArtifact(
            MeetingTranscript.self,
            meetingID: fixture.meeting.id,
            relativePath: MeetingTranscript.finalTranscriptRelativePath,
            purpose: MeetingTranscript.finalTranscriptPurpose
        )
        XCTAssertEqual(transcript.segments.map(\.text), ["durable final"])
    }

    func testIndexSearchFalsePersistsAwaitingCommitMarkerWithoutProvisionalSearchRows() async throws {
        let fixture = try FinalPipelineFixture()
        let service = LocalFinalTranscriptionService(
            engine: FixtureLocalFinalEngine(),
            bundleStore: fixture.bundleStore,
            searchIndex: fixture.searchIndex,
            decryptedChunkReader: fixture.reader
        )

        let result = try await service.transcribe(
            meeting: fixture.meeting,
            records: fixture.records,
            context: MeetingContext(localeIdentifier: "pl-PL", expectedParticipantCount: 2),
            speakerRenames: [:],
            indexSearch: false
        )

        XCTAssertEqual(result.indexedSegmentCount, 0)
        XCTAssertTrue(try fixture.searchIndex.search("mówię").isEmpty)
        let marker: TranscriptReindexPendingMarker = try fixture.bundleStore.readJSONArtifact(
            TranscriptReindexPendingMarker.self,
            meetingID: fixture.meeting.id,
            relativePath: TranscriptReindexPendingMarker.relativePath,
            purpose: TranscriptReindexPendingMarker.purpose
        )
        XCTAssertEqual(marker.phase, .awaitingAuthoritativeLibraryCommit)

        let beforeSave = try TranscriptReindexRecoveryService(
            bundleStore: fixture.bundleStore,
            searchIndex: fixture.searchIndex
        ).recover(meeting: fixture.meeting)
        XCTAssertEqual(beforeSave, .preserved(.authoritativeLibraryCommitMissing))
        XCTAssertTrue(try fixture.searchIndex.search("mówię").isEmpty)

        try fixture.persistAuthoritativeMetadata()
        let afterSave = try TranscriptReindexRecoveryService(
            bundleStore: fixture.bundleStore,
            searchIndex: fixture.searchIndex
        ).recover(meeting: fixture.meeting)
        XCTAssertEqual(afterSave, .rebuilt(digestMatchedMarker: true))
        XCTAssertEqual(try fixture.searchIndex.search("mówię").count, 1)
        XCTAssertFalse(try fixture.bundleStore.artifactExists(
            meetingID: fixture.meeting.id,
            relativePath: TranscriptReindexPendingMarker.relativePath
        ))
    }

    func testCrashAfterAuthoritativeSaveBeforeMarkerClearRecoversOnRestart() async throws {
        let fixture = try FinalPipelineFixture()
        let service = LocalFinalTranscriptionService(
            engine: FixtureLocalFinalEngine(),
            bundleStore: fixture.bundleStore,
            searchIndex: fixture.searchIndex,
            decryptedChunkReader: fixture.reader
        )
        let transcription = try await service.transcribe(
            meeting: fixture.meeting,
            records: fixture.records,
            context: MeetingContext(localeIdentifier: "pl-PL", expectedParticipantCount: 2),
            speakerRenames: [:],
            indexSearch: false
        )
        let crashingRepository = MeetingLibraryRepository(
            bundleStore: fixture.bundleStore,
            searchIndex: fixture.searchIndex,
            afterAtomicIndexCommit: { throw SQLiteSearchIndexError.executeFailed("simulated crash") }
        )
        let entry = fixture.libraryEntry(transcript: transcription.transcript)

        XCTAssertThrowsError(try crashingRepository.save(entry))
        XCTAssertEqual(try fixture.searchIndex.search("mówię").count, 1)
        XCTAssertTrue(try fixture.bundleStore.artifactExists(
            meetingID: fixture.meeting.id,
            relativePath: TranscriptReindexPendingMarker.relativePath
        ))

        let restarted = MeetingLibraryRepository(
            bundleStore: fixture.bundleStore,
            searchIndex: fixture.searchIndex
        )
        XCTAssertEqual(try restarted.loadSnapshot().records.map(\.id), [fixture.meeting.id])
        XCTAssertFalse(try fixture.bundleStore.artifactExists(
            meetingID: fixture.meeting.id,
            relativePath: TranscriptReindexPendingMarker.relativePath
        ))
        XCTAssertEqual(try fixture.searchIndex.search("mówię").count, 1)
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {}
}

private final class FinalPipelineFixture: @unchecked Sendable {
    let root: URL
    let bundleStore: EncryptedMeetingBundleStore
    let searchIndex: SQLiteSearchIndex
    let meeting: SearchMeeting
    let records: [AudioChunkRecord]
    let reader = FixtureChunkReader()

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let vault = AESGCMDataVault(keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 7, count: 32)))
        bundleStore = EncryptedMeetingBundleStore(rootDirectory: root, vault: vault)
        searchIndex = try SQLiteSearchIndex(databaseURL: root.appendingPathComponent("search.sqlite"))
        meeting = SearchMeeting(id: UUID(), title: "Fixture", startedAt: Date(), sourceApp: "Fixture")
        _ = try bundleStore.createBundle(.initialEncryptedBundle(meetingID: meeting.id, title: meeting.title))
        records = [
            AudioChunkRecord(track: .microphone, chunkIndex: 0, relativePath: "a", startTime: 0, duration: 2, byteCount: 32, codec: "PCM", encrypted: true),
            AudioChunkRecord(track: .remoteSystem, chunkIndex: 0, relativePath: "b", startTime: 0, duration: 2, byteCount: 32, codec: "PCM", encrypted: true),
        ]
        reader.payloads = ["a": Data(repeating: 1, count: 32), "b": Data(repeating: 2, count: 32)]
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func persistAuthoritativeMetadata() throws {
        try bundleStore.writeJSONArtifact(
            MeetingRecord(
                id: meeting.id,
                title: meeting.title,
                startedAt: meeting.startedAt,
                durationSeconds: 2,
                sourceName: meeting.sourceApp,
                state: .ready,
                consentStatus: .disclosed,
                summary: nil
            ),
            meetingID: meeting.id,
            relativePath: MeetingLibraryRepository.recordRelativePath,
            purpose: MeetingLibraryRepository.recordPurpose
        )
        try bundleStore.writeJSONArtifact(
            meeting,
            meetingID: meeting.id,
            relativePath: MeetingLibraryRepository.searchMeetingRelativePath,
            purpose: MeetingLibraryRepository.searchMeetingPurpose
        )
    }

    func libraryEntry(transcript: MeetingTranscript) -> MeetingLibraryEntry {
        MeetingLibraryEntry(
            record: MeetingRecord(
                id: meeting.id,
                title: meeting.title,
                startedAt: meeting.startedAt,
                durationSeconds: 2,
                sourceName: meeting.sourceApp,
                state: .ready,
                consentStatus: .disclosed,
                summary: nil
            ),
            searchMeeting: meeting,
            transcript: transcript,
            editHistory: TranscriptEditHistory(meetingID: meeting.id)
        )
    }
}

private final class FixtureChunkReader: LocalDecryptedAudioChunkReading, @unchecked Sendable {
    private let lock = NSLock()
    var payloads: [String: Data] = [:]
    private var concurrent = 0
    private(set) var maximumConcurrentReads = 0
    let plaintextTemporaryFileCount = 0
    let externalNetworkRequested = false
    func withDecryptedChunk<T: Sendable>(
        _ record: AudioChunkRecord,
        _ body: @Sendable (Data) async throws -> T
    ) async throws -> T {
        let data = lock.withLock { () -> Data in
            concurrent += 1
            maximumConcurrentReads = max(maximumConcurrentReads, concurrent)
            return payloads[record.relativePath]!
        }
        defer { lock.withLock { concurrent -= 1 } }
        return try await body(data)
    }
}

private final class FixtureLocalFinalEngine: LocalFinalTranscriptionEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var storedTracks: [TrackKind] = []
    var tracks: [TrackKind] { lock.withLock { storedTracks } }
    func transcribeChunk(_ request: LocalFinalChunkRequest) async throws -> [TranscriptSegment] {
        lock.withLock { storedTracks.append(request.track) }
        return [transcript(
            speaker: "raw",
            track: request.track,
            start: request.startTime,
            end: request.startTime + request.duration,
            text: request.track == .microphone ? "mówię" : "cześć"
        )]
    }
    func diarizeRemoteChunk(_ request: LocalFinalChunkRequest) async throws -> [DiarizationTurn] {
        [DiarizationTurn(speakerID: "remote-a", startTime: request.startTime, endTime: request.startTime + request.duration, confidence: 0.9)]
    }
}

private struct PlaceholderFinalEngine: LocalFinalTranscriptionEngine, LocalFinalProviderConfigurationProviding {
    let providerConfigurationVersion = "fixture-asr@rev+fixture-diarization@rev+config@stable"
    func providerConfigurationVersion(for context: MeetingContext) throws -> String {
        providerConfigurationVersion
    }

    func transcribeChunk(_ request: LocalFinalChunkRequest) async throws -> [TranscriptSegment] {
        [transcript(
            speaker: request.track == .microphone ? "You" : "remote-unassigned",
            track: request.track,
            start: request.startTime,
            end: request.startTime + request.duration,
            text: "fixture"
        )]
    }

    func diarizeRemoteChunk(_ request: LocalFinalChunkRequest) async throws -> [DiarizationTurn] {
        [DiarizationTurn(
            speakerID: "final-speaker-a",
            startTime: request.startTime,
            endTime: request.startTime + request.duration,
            confidence: 0.9
        )]
    }
}

private struct IdentifiedFinalEngine: LocalFinalTranscriptionEngine, LocalFinalProviderConfigurationProviding {
    let providerConfigurationVersion: String
    init(configurationVersion: String) { providerConfigurationVersion = configurationVersion }
    func providerConfigurationVersion(for context: MeetingContext) throws -> String {
        providerConfigurationVersion
    }
    func transcribeChunk(_ request: LocalFinalChunkRequest) async throws -> [TranscriptSegment] {
        [transcript(speaker: "You", track: request.track, start: request.startTime, end: request.startTime + request.duration, text: "fixture")]
    }
    func diarizeRemoteChunk(_ request: LocalFinalChunkRequest) async throws -> [DiarizationTurn] { [] }
}

private struct FailingClosePassEngine: LocalFinalPassTranscriptionEngine {
    func transcribePass(
        meeting: SearchMeeting,
        records: [AudioChunkRecord],
        context: MeetingContext,
        decryptedChunkReader: any LocalDecryptedAudioChunkReading,
        maximumDecryptedChunkBytes: Int
    ) async throws -> LocalFinalPassOutput {
        LocalFinalPassOutput(
            asrSegments: [transcript(
                speaker: "You",
                track: .microphone,
                start: 0,
                end: 1,
                text: "durable final"
            )],
            remoteTurns: [],
            completion: FailingCloseCompletion()
        )
    }

    func transcribeChunk(_ request: LocalFinalChunkRequest) async throws -> [TranscriptSegment] { [] }
    func diarizeRemoteChunk(_ request: LocalFinalChunkRequest) async throws -> [DiarizationTurn] { [] }
}

private struct FailingCloseCompletion: LocalFinalPassCompletion {
    func close() async throws { throw SQLiteSearchIndexError.executeFailed("native close") }
    func cancel() async {}
}

private func transcript(
    speaker: String,
    track: TrackKind,
    start: TimeInterval,
    end: TimeInterval,
    text: String
) -> TranscriptSegment {
    TranscriptSegment(
        speakerName: speaker,
        trackKind: track,
        startTime: start,
        endTime: end,
        text: text,
        confidence: 0.85,
        isFinal: true
    )
}
