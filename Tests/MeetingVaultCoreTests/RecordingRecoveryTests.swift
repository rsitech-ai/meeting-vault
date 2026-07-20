import Foundation
import XCTest
@testable import MeetingVaultCore

final class RecordingRecoveryTests: XCTestCase {
    func testRecoveryRejectsCopiedValidMetadataIdentityWithoutExposingPrivateBookmarks() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultRecoveryIdentity-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EncryptedMeetingBundleStore(
            rootDirectory: root,
            vault: AESGCMDataVault(
                keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 70, count: 32))
            )
        )
        let requestedMeetingID = UUID()
        let privateMeetingID = UUID()
        _ = try store.createBundle(.initialEncryptedBundle(meetingID: requestedMeetingID, title: "Requested"))
        try store.writeJSONArtifact(
            RecordingSessionMetadata(
                meetingID: privateMeetingID,
                startedAt: Date(timeIntervalSince1970: 1_780_020_000),
                context: MeetingContext(participantNames: ["Private Person"]),
                bookmarks: [
                    MeetingBookmark(
                        meetingID: privateMeetingID,
                        timestamp: 2,
                        createdAt: Date(timeIntervalSince1970: 1_780_020_002),
                        note: "Private acquisition note"
                    )
                ]
            ),
            meetingID: requestedMeetingID,
            relativePath: RecordingSessionMetadata.relativePath,
            purpose: RecordingSessionMetadata.purpose
        )
        let service = RecordingRecoveryService(
            bundleStore: store,
            chunkWriter: EncryptedAudioChunkWriter(bundleStore: store)
        )

        let report = try service.recoverableReport(for: requestedMeetingID)

        XCTAssertEqual(report.bookmarks, [])
        XCTAssertTrue(report.warnings.contains(.sessionMetadataCorrupt))
        XCTAssertThrowsError(
            try service.ensureSessionMetadataForRecoveredImport(meetingID: requestedMeetingID, duration: 10)
        ) { error in
            XCTAssertEqual(error as? RecordingSessionMetadataValidationError, .metadataMeetingMismatch)
            XCTAssertFalse(error.localizedDescription.contains("acquisition"))
        }
    }

    func testRecoveryReconcilesExistingFinalizedMetadataIntoManifestIdempotently() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultRecoveryPromotion-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EncryptedMeetingBundleStore(
            rootDirectory: root,
            vault: AESGCMDataVault(
                keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 71, count: 32))
            )
        )
        let meetingID = UUID()
        _ = try store.createBundle(.initialEncryptedBundle(meetingID: meetingID, title: "Promotion"))
        let bookmark = MeetingBookmark(
            meetingID: meetingID,
            timestamp: 4,
            createdAt: Date(timeIntervalSince1970: 1_780_020_004),
            category: .important,
            note: "Preserve me"
        )
        let context = MeetingContext(participantNames: ["Anna"])
        try store.writeJSONArtifact(
            RecordingSessionMetadata(
                meetingID: meetingID,
                startedAt: Date(timeIntervalSince1970: 1_780_020_000),
                context: context,
                bookmarks: [bookmark],
                revision: 2,
                isFinalized: true
            ),
            meetingID: meetingID,
            relativePath: RecordingSessionMetadata.relativePath,
            purpose: RecordingSessionMetadata.purpose
        )
        let service = RecordingRecoveryService(
            bundleStore: store,
            chunkWriter: EncryptedAudioChunkWriter(bundleStore: store)
        )

        XCTAssertEqual(
            try service.ensureSessionMetadataForRecoveredImport(meetingID: meetingID, duration: 10).bookmarks,
            [bookmark]
        )
        XCTAssertEqual(
            try service.ensureSessionMetadataForRecoveredImport(meetingID: meetingID, duration: 10).bookmarks,
            [bookmark]
        )
        let manifest = try store.readManifest(meetingID: meetingID)
        XCTAssertEqual(manifest.schemaVersion, 2)
        XCTAssertEqual(manifest.context, context)
        XCTAssertEqual(manifest.bookmarks, [bookmark])
    }

    func testRecoveryRetriesManifestPromotionAfterFailureBetweenMetadataAndManifestWrites() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultRecoveryRetry-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EncryptedMeetingBundleStore(
            rootDirectory: root,
            vault: AESGCMDataVault(
                keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 72, count: 32))
            )
        )
        let meetingID = UUID()
        var manifest = MeetingBundleManifest.initialEncryptedBundle(meetingID: meetingID, title: "Retry")
        let bookmark = MeetingBookmark(
            meetingID: meetingID,
            timestamp: 3,
            createdAt: Date(timeIntervalSince1970: 1_780_020_003),
            note: "Retry-safe"
        )
        manifest.bookmarks = [bookmark]
        _ = try store.createBundle(manifest)
        let failing = RecordingRecoveryService(
            bundleStore: store,
            chunkWriter: EncryptedAudioChunkWriter(bundleStore: store),
            manifestWriter: { _, _ in throw PromotionWriteError.injected }
        )

        XCTAssertThrowsError(
            try failing.ensureSessionMetadataForRecoveredImport(meetingID: meetingID, duration: 10)
        )
        XCTAssertTrue(
            try store.artifactExists(meetingID: meetingID, relativePath: RecordingSessionMetadata.relativePath)
        )

        let retry = RecordingRecoveryService(
            bundleStore: store,
            chunkWriter: EncryptedAudioChunkWriter(bundleStore: store)
        )
        XCTAssertEqual(
            try retry.ensureSessionMetadataForRecoveredImport(meetingID: meetingID, duration: 10).bookmarks,
            [bookmark]
        )
        XCTAssertEqual(try store.readManifest(meetingID: meetingID).bookmarks, [bookmark])
    }

    func testRecoveryRejectsRevisionOverflowWithoutMutatingMetadataOrManifest() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultRecoveryRevisionOverflow-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EncryptedMeetingBundleStore(
            rootDirectory: root,
            vault: AESGCMDataVault(
                keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 73, count: 32))
            )
        )
        let meetingID = UUID()
        _ = try store.createBundle(.initialEncryptedBundle(meetingID: meetingID, title: "Overflow"))
        let originalManifest = try store.readManifest(meetingID: meetingID)
        let originalMetadata = RecordingSessionMetadata(
            meetingID: meetingID,
            startedAt: Date(timeIntervalSince1970: 1_780_020_000),
            context: MeetingContext(),
            bookmarks: [],
            revision: RecordingSessionMetadata.maximumRevision,
            isFinalized: false
        )
        try store.writeJSONArtifact(
            originalMetadata,
            meetingID: meetingID,
            relativePath: RecordingSessionMetadata.relativePath,
            purpose: RecordingSessionMetadata.purpose
        )
        let service = RecordingRecoveryService(
            bundleStore: store,
            chunkWriter: EncryptedAudioChunkWriter(bundleStore: store)
        )

        XCTAssertThrowsError(
            try service.ensureSessionMetadataForRecoveredImport(meetingID: meetingID, duration: 10)
        ) { error in
            XCTAssertEqual(error as? RecordingSessionMetadataServiceError, .revisionOverflow)
        }
        let persistedMetadata: RecordingSessionMetadata = try store.readJSONArtifact(
            RecordingSessionMetadata.self,
            meetingID: meetingID,
            relativePath: RecordingSessionMetadata.relativePath,
            purpose: RecordingSessionMetadata.purpose
        )
        XCTAssertEqual(persistedMetadata, originalMetadata)
        XCTAssertEqual(try store.readManifest(meetingID: meetingID), originalManifest)
    }

    func testRecoveryScannerSkipsUnreadableBundlesInsteadOfFailingRuntimeStartup() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultRecoveryUnreadable-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let oldVault = AESGCMDataVault(
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 49, count: 32))
        )
        let oldBundleStore = EncryptedMeetingBundleStore(rootDirectory: root, vault: oldVault)
        let staleMeetingID = UUID()
        _ = try oldBundleStore.createBundle(
            MeetingBundleManifest.initialEncryptedBundle(
                meetingID: staleMeetingID,
                title: "Old unreadable bundle"
            )
        )

        let currentVault = AESGCMDataVault(
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 50, count: 32))
        )
        let currentBundleStore = EncryptedMeetingBundleStore(rootDirectory: root, vault: currentVault)
        let chunkWriter = EncryptedAudioChunkWriter(bundleStore: currentBundleStore)
        let currentMeetingID = UUID()
        _ = try currentBundleStore.createBundle(
            MeetingBundleManifest.initialEncryptedBundle(
                meetingID: currentMeetingID,
                title: "Current recoverable bundle"
            )
        )

        let scanner = RecordingRecoveryService(bundleStore: currentBundleStore, chunkWriter: chunkWriter)
        let reports = try scanner.scanRecoverableBundles()

        XCTAssertEqual(reports.map(\.meetingID), [currentMeetingID])
    }

    func testRecoveryScannerReportsCheckpointedTracksMissingFinalArtifactsAndElapsedDuration() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultRecovery-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let vault = AESGCMDataVault(
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 51, count: 32))
        )
        let bundleStore = EncryptedMeetingBundleStore(rootDirectory: root, vault: vault)
        let chunkWriter = EncryptedAudioChunkWriter(bundleStore: bundleStore)
        let meetingID = UUID()
        var manifest = MeetingBundleManifest.initialEncryptedBundle(
            meetingID: meetingID,
            title: "Recovered long call"
        )
        manifest.createdAt = Date(timeIntervalSince1970: 1_780_002_000)
        _ = try bundleStore.createBundle(manifest)

        _ = try chunkWriter.writeChunk(
            Data("remote chunk 0".utf8),
            meetingID: meetingID,
            track: .remoteSystem,
            chunkIndex: 0,
            startTime: 0,
            duration: 1_800,
            codec: "CAF/LPCM"
        )
        _ = try chunkWriter.writeChunk(
            Data("remote chunk 1".utf8),
            meetingID: meetingID,
            track: .remoteSystem,
            chunkIndex: 1,
            startTime: 1_800,
            duration: 1_800,
            codec: "CAF/LPCM"
        )
        _ = try chunkWriter.writeChunk(
            Data("microphone chunk 0".utf8),
            meetingID: meetingID,
            track: .microphone,
            chunkIndex: 0,
            startTime: 0,
            duration: 3_600,
            codec: "CAF/LPCM"
        )

        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("not-a-bundle", isDirectory: true),
            withIntermediateDirectories: true
        )

        let scanner = RecordingRecoveryService(bundleStore: bundleStore, chunkWriter: chunkWriter)
        let reports = try scanner.scanRecoverableBundles()

        XCTAssertEqual(reports.count, 1)
        let report = try XCTUnwrap(reports.first)
        XCTAssertEqual(report.meetingID, meetingID)
        XCTAssertEqual(report.title, "Recovered long call")
        XCTAssertEqual(report.severity, .warning)
        XCTAssertEqual(report.totalRecordedDuration, 3_600)
        XCTAssertEqual(report.trackReports.first { $0.track == .remoteSystem }?.chunkCount, 2)
        XCTAssertEqual(report.trackReports.first { $0.track == .remoteSystem }?.totalDuration, 3_600)
        XCTAssertEqual(report.trackReports.first { $0.track == .microphone }?.chunkCount, 1)
        XCTAssertTrue(report.warnings.contains(.finalTranscriptMissing))
        XCTAssertTrue(report.warnings.contains(.summaryMissing))
    }

    func testRecoveredRecordingImportQuarantinesCorruptMetadataAndCompletesWithSafeFallback() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultRecoveredImport-\(UUID().uuidString)", isDirectory: true)
        let databaseURL = root.appendingPathComponent("library.sqlite")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let vault = AESGCMDataVault(
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 52, count: 32))
        )
        let bundleStore = EncryptedMeetingBundleStore(rootDirectory: root, vault: vault)
        let chunkWriter = EncryptedAudioChunkWriter(bundleStore: bundleStore)
        let searchIndex = try SQLiteSearchIndex(databaseURL: databaseURL)
        let repository = MeetingLibraryRepository(bundleStore: bundleStore, searchIndex: searchIndex)
        let meetingID = UUID(uuidString: "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE")!
        let decisionSegmentID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let actionSegmentID = UUID(uuidString: "66666666-7777-8888-9999-AAAAAAAAAAAA")!
        var manifest = MeetingBundleManifest.initialEncryptedBundle(
            meetingID: meetingID,
            title: "Recovered privacy review"
        )
        manifest.createdAt = Date(timeIntervalSince1970: 1_780_012_000)
        _ = try bundleStore.createBundle(manifest)
        try bundleStore.writeJSONArtifact(
            RecordingSessionMetadata(
                meetingID: meetingID,
                startedAt: manifest.createdAt,
                context: MeetingContext(participantNames: ["Private Person"]),
                bookmarks: [
                    MeetingBookmark(
                        meetingID: meetingID,
                        timestamp: 1,
                        createdAt: manifest.createdAt,
                        note: "Private corrupt note must not leak"
                    )
                ]
            ),
            meetingID: meetingID,
            relativePath: RecordingSessionMetadata.relativePath,
            purpose: RecordingSessionMetadata.purpose
        )
        let metadataURL = bundleStore.bundleURL(for: meetingID)
            .appendingPathComponent(RecordingSessionMetadata.relativePath)
        var corruptCiphertext = try Data(contentsOf: metadataURL)
        corruptCiphertext[corruptCiphertext.index(before: corruptCiphertext.endIndex)] ^= 0x01
        try corruptCiphertext.write(to: metadataURL, options: .atomic)

        _ = try chunkWriter.writeChunk(
            Data("remote checkpoint audio".utf8),
            meetingID: meetingID,
            track: .remoteSystem,
            chunkIndex: 0,
            startTime: 10,
            duration: 40,
            codec: "CAF/LPCM"
        )
        _ = try chunkWriter.writeChunk(
            Data("microphone checkpoint audio".utf8),
            meetingID: meetingID,
            track: .microphone,
            chunkIndex: 0,
            startTime: 50,
            duration: 20,
            codec: "CAF/LPCM"
        )

        let transcriptionService = FinalTranscriptionService(
            engine: MockTranscriptionEngine(
                responsesByAudioChunkPath: [
                    "audio/remoteSystem/chunk-000000.bin.enc": [
                        TranscriptSegment(
                            id: decisionSegmentID,
                            speakerName: "Anna",
                            trackKind: .remoteSystem,
                            startTime: 12,
                            endTime: 26,
                            text: "The recovered recording can ship after privacy review.",
                            confidence: 0.93,
                            isFinal: true
                        )
                    ],
                    "audio/microphone/chunk-000000.bin.enc": [
                        TranscriptSegment(
                            id: actionSegmentID,
                            speakerName: "You",
                            trackKind: .microphone,
                            startTime: 52,
                            endTime: 66,
                            text: "I will send the recovery checklist to the team.",
                            confidence: 0.89,
                            isFinal: true
                        )
                    ]
                ]
            ),
            bundleStore: bundleStore,
            chunkWriter: chunkWriter,
            searchIndex: searchIndex,
            now: { Date(timeIntervalSince1970: 1_780_012_300) }
        )
        let evidence = EvidenceRef(
            meetingID: meetingID,
            segmentID: decisionSegmentID,
            startTime: 12,
            endTime: 26,
            quote: "The recovered recording can ship after privacy review.",
        )
        let intelligenceProvider = MockMeetingIntelligenceProvider(
                summary: MeetingSummary(
                    title: "Recovered privacy review",
                    oneParagraph: "The recovered recording can ship after privacy review.",
                    bullets: ["Recovery import preserved the privacy review decision."],
                    decisions: [
                        Decision(
                            title: "Ship after privacy review",
                            details: "The recovered recording can ship after privacy review.",
                            evidence: [evidence],
                            confidence: 0.9
                        )
                    ],
                    actionItems: []
                )
            )
        let intelligenceService = MeetingIntelligenceService(
            provider: intelligenceProvider,
            bundleStore: bundleStore,
            now: { Date(timeIntervalSince1970: 1_780_012_360) }
        )
        let recoveryService = RecordingRecoveryService(bundleStore: bundleStore, chunkWriter: chunkWriter)
        let service = RecoveredRecordingImportService(
            recoveryService: recoveryService,
            transcriptionService: transcriptionService,
            intelligenceService: intelligenceService,
            repository: repository,
            chunkWriter: chunkWriter
        )

        let result = try await service.importRecoveredRecording(
            RecoveredRecordingImportRequest(
                meetingID: meetingID,
                sourceName: "Microsoft Teams",
                localeIdentifier: "en-US",
                consentStatus: .disclosed
            )
        )

        XCTAssertEqual(
            result.reportBeforeImport.warnings,
            [.finalTranscriptMissing, .summaryMissing, .sessionMetadataCorrupt]
        )
        XCTAssertEqual(result.record.id, meetingID)
        XCTAssertEqual(result.record.state, .recovered)
        XCTAssertEqual(result.record.durationSeconds, 70)
        XCTAssertEqual(result.record.summary?.title, "Recovered privacy review")
        XCTAssertEqual(result.transcription.indexedSegmentCount, 2)
        XCTAssertEqual(result.intelligence.summary.decisions.first?.evidence, [evidence])
        XCTAssertEqual(result.bookmarks, [])
        XCTAssertEqual(intelligenceProvider.requests.first?.bookmarkEvidence, [])
        let quarantineURL = bundleStore.bundleURL(for: meetingID)
            .appendingPathComponent(RecordingSessionMetadata.corruptQuarantineRelativePath)
        XCTAssertEqual(try Data(contentsOf: quarantineURL), corruptCiphertext)
        let recoveredMetadata: RecordingSessionMetadata = try bundleStore.readJSONArtifact(
            RecordingSessionMetadata.self,
            meetingID: meetingID,
            relativePath: RecordingSessionMetadata.relativePath,
            purpose: RecordingSessionMetadata.purpose
        )
        XCTAssertEqual(recoveredMetadata.meetingID, meetingID)
        XCTAssertTrue(recoveredMetadata.isFinalized)
        XCTAssertEqual(recoveredMetadata.bookmarks, [])

        let snapshot = try repository.loadSnapshot()
        XCTAssertEqual(snapshot.records.map(\.id), [meetingID])
        XCTAssertEqual(snapshot.editSessionsByMeetingID[meetingID]?.draft.segments.map(\.id), [decisionSegmentID, actionSegmentID])

        let searchResults = try searchIndex.search("recovery checklist", limit: 5)
        XCTAssertEqual(searchResults.map(\.meetingID), [meetingID])

        let afterReport = try recoveryService.recoverableReport(for: meetingID)
        XCTAssertTrue(afterReport.hasFinalTranscript)
        XCTAssertTrue(afterReport.hasSummary)
        XCTAssertEqual(afterReport.warnings, [.sessionMetadataCorrupt])
        XCTAssertEqual(
            try chunkWriter.readChunk(result.audioChunks[0], meetingID: meetingID),
            Data("remote checkpoint audio".utf8)
        )
    }

    func testRecoveredRecordingImportPassesPersistedPreviewGapIntoAuthoritativeFinalTranscription() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultRecoveredPreviewEvidence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let bundleStore = EncryptedMeetingBundleStore(
            rootDirectory: root,
            vault: AESGCMDataVault(
                keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 0x53, count: 32))
            )
        )
        let chunkWriter = EncryptedAudioChunkWriter(bundleStore: bundleStore)
        let searchIndex = try SQLiteSearchIndex(databaseURL: root.appendingPathComponent("library.sqlite"))
        let repository = MeetingLibraryRepository(bundleStore: bundleStore, searchIndex: searchIndex)
        let meetingID = UUID()
        var manifest = MeetingBundleManifest.initialEncryptedBundle(
            meetingID: meetingID,
            title: "Recovered preview gap"
        )
        manifest.createdAt = Date(timeIntervalSince1970: 1_805_200_000)
        _ = try bundleStore.createBundle(manifest)
        let previewEvidence = TranscriptPreviewEvidence(
            gaps: [try TranscriptPreviewGap(track: .remoteSystem, startTime: 1, endTime: 2)],
            speakerIdentities: []
        )
        try bundleStore.writeJSONArtifact(
            RecordingSessionMetadata(
                meetingID: meetingID,
                startedAt: manifest.createdAt,
                context: MeetingContext(localeIdentifier: "en-US"),
                previewEvidence: previewEvidence
            ),
            meetingID: meetingID,
            relativePath: RecordingSessionMetadata.relativePath,
            purpose: RecordingSessionMetadata.purpose
        )
        _ = try chunkWriter.writeChunk(
            Data("checkpointed remote audio".utf8),
            meetingID: meetingID,
            track: .remoteSystem,
            chunkIndex: 0,
            startTime: 0,
            duration: 3,
            codec: "CAF/LPCM"
        )
        let transcriptionService = LocalFinalTranscriptionService(
            engine: RecoveredPreviewGapFinalEngine(),
            bundleStore: bundleStore,
            searchIndex: searchIndex,
            decryptedChunkReader: EncryptedAudioChunkReader(writer: chunkWriter, meetingID: meetingID),
            now: { Date(timeIntervalSince1970: 1_805_200_100) }
        )
        let intelligenceService = MeetingIntelligenceService(
            provider: MockMeetingIntelligenceProvider(
                summary: MeetingSummary(
                    title: "Recovered preview gap",
                    oneParagraph: "The recovered transcript preserves preview coverage evidence.",
                    bullets: [],
                    decisions: [],
                    actionItems: []
                )
            ),
            bundleStore: bundleStore,
            now: { Date(timeIntervalSince1970: 1_805_200_200) }
        )
        let recoveryService = RecordingRecoveryService(bundleStore: bundleStore, chunkWriter: chunkWriter)
        let service = RecoveredRecordingImportService(
            recoveryService: recoveryService,
            transcriptionService: transcriptionService,
            intelligenceService: intelligenceService,
            repository: repository,
            chunkWriter: chunkWriter
        )

        let result = try await service.importRecoveredRecording(
            RecoveredRecordingImportRequest(
                meetingID: meetingID,
                sourceName: "Recovered capture",
                localeIdentifier: "en-US",
                consentStatus: .disclosed
            )
        )

        XCTAssertEqual(result.transcription.transcript.segments.count, 1)
        XCTAssertEqual(
            result.transcription.transcript.segments[0].reviewEvidence?.reconstructedFromPreviewGap,
            true
        )
        let review = try TranscriptReviewRepository(bundleStore: bundleStore).load(meetingID: meetingID)
        XCTAssertTrue(review.items.contains { $0.reason == .reconstructedPreviewGap })
        let recoveredMetadata: RecordingSessionMetadata = try bundleStore.readJSONArtifact(
            RecordingSessionMetadata.self,
            meetingID: meetingID,
            relativePath: RecordingSessionMetadata.relativePath,
            purpose: RecordingSessionMetadata.purpose
        )
        XCTAssertTrue(recoveredMetadata.isFinalized)
        XCTAssertEqual(recoveredMetadata.previewEvidence, previewEvidence)
    }
}

private enum PromotionWriteError: Error {
    case injected
}

private struct RecoveredPreviewGapFinalEngine: LocalFinalTranscriptionEngine, LocalFinalProviderConfigurationProviding {
    func providerConfigurationVersion(for _: MeetingContext) throws -> String {
        "recovery-fixture@1"
    }

    func transcribeChunk(_ request: LocalFinalChunkRequest) async throws -> [TranscriptSegment] {
        [
            TranscriptSegment(
                speakerName: "Speaker 1",
                trackKind: request.track,
                startTime: request.startTime,
                endTime: request.startTime + request.duration,
                text: "Recovered audio overlaps the persisted preview gap.",
                confidence: 0.95,
                isFinal: true
            )
        ]
    }

    func diarizeRemoteChunk(_ request: LocalFinalChunkRequest) async throws -> [DiarizationTurn] {
        [
            DiarizationTurn(
                speakerID: "speaker-1",
                startTime: request.startTime,
                endTime: request.startTime + request.duration,
                confidence: 0.95
            )
        ]
    }
}
