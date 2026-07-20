import CryptoKit
import Foundation
import XCTest
@testable import MeetingVaultCore

final class RecordingProcessingTests: XCTestCase {
    func testRecordingProcessingCreatesDurableLibraryMeetingWithTranscriptAndSummary() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultProcessing-\(UUID().uuidString)", isDirectory: true)
        let databaseURL = root.appendingPathComponent("library.sqlite")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let meetingID = UUID()
        let decisionSegmentID = UUID()
        let followUpSegmentID = UUID()
        let vault = AESGCMDataVault(
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 73, count: 32))
        )
        let bundleStore = EncryptedMeetingBundleStore(rootDirectory: root, vault: vault)
        let chunkWriter = EncryptedAudioChunkWriter(bundleStore: bundleStore)
        let searchIndex = try SQLiteSearchIndex(databaseURL: databaseURL)
        let repository = MeetingLibraryRepository(bundleStore: bundleStore, searchIndex: searchIndex)

        let captureService = CaptureRecordingService(
            engine: MockCaptureRecordingEngine(
                sources: [
                    CaptureSource(
                        id: "teams",
                        displayName: "Microsoft Teams",
                        bundleIdentifier: "com.microsoft.teams2",
                        mode: .selectedApplication,
                        isRecommended: true,
                        level: 0.71
                    )
                ],
                chunks: [
                    CapturedAudioChunk(
                        track: .remoteSystem,
                        data: Data("remote audio".utf8),
                        startTime: 0,
                        duration: 30,
                        codec: "CAF/LPCM"
                    ),
                    CapturedAudioChunk(
                        track: .microphone,
                        data: Data("microphone audio".utf8),
                        startTime: 0,
                        duration: 30,
                        codec: "CAF/LPCM"
                    )
                ],
                healthReport: CaptureHealthReport(
                    remoteDropouts: 0,
                    microphoneDropouts: 0,
                    remoteClippingPercent: 0,
                    microphoneClippingPercent: 0,
                    silentPeriods: [],
                    deviceChanges: [],
                    transcriptionEngine: "mock",
                    intelligenceProvider: "mock"
                )
            ),
            chunkWriter: chunkWriter
        )
        let transcriptionService = FinalTranscriptionService(
            engine: MockTranscriptionEngine(
                responsesByAudioChunkPath: [
                    "audio/remoteSystem/chunk-000000.bin.enc": [
                        TranscriptSegment(
                            id: decisionSegmentID,
                            speakerName: "Anna",
                            trackKind: .remoteSystem,
                            startTime: 4,
                            endTime: 12,
                            text: "The beta candidate can ship after privacy review.",
                            confidence: 0.94,
                            isFinal: true
                        )
                    ],
                    "audio/microphone/chunk-000000.bin.enc": [
                        TranscriptSegment(
                            id: followUpSegmentID,
                            speakerName: "You",
                            trackKind: .microphone,
                            startTime: 13,
                            endTime: 19,
                            text: "I will prepare the notarized build checklist.",
                            confidence: 0.91,
                            isFinal: true
                        )
                    ]
                ]
            ),
            bundleStore: bundleStore,
            chunkWriter: chunkWriter,
            searchIndex: searchIndex,
            now: { Date(timeIntervalSince1970: 1_780_001_100) }
        )
        let evidence = EvidenceRef(
            meetingID: meetingID,
            segmentID: decisionSegmentID,
            startTime: 4,
            endTime: 12,
            quote: "The beta candidate can ship after privacy review."
        )
        let intelligenceService = MeetingIntelligenceService(
            provider: MockMeetingIntelligenceProvider(
                summary: MeetingSummary(
                    title: "Release readiness sync",
                    oneParagraph: "The team aligned on shipping the beta candidate after privacy review.",
                    bullets: ["Beta can ship after privacy review."],
                    decisions: [
                        Decision(
                            title: "Ship after privacy review",
                            details: "The beta candidate can ship after privacy review.",
                            evidence: [evidence],
                            confidence: 0.90
                        )
                    ],
                    actionItems: [
                        ActionItem(
                            title: "Prepare notarized build checklist",
                            ownerName: "You",
                            evidence: [evidence],
                            confidence: 0.82
                        )
                    ]
                )
            ),
            bundleStore: bundleStore,
            now: { Date(timeIntervalSince1970: 1_780_001_160) }
        )
        let service = RecordingProcessingService(
            captureService: captureService,
            transcriptionService: transcriptionService,
            intelligenceService: intelligenceService,
            repository: repository,
            bundleStore: bundleStore
        )

        let result = try await service.process(
            RecordingProcessingRequest(
                meetingID: meetingID,
                title: "Recorded Microsoft Teams meeting",
                startedAt: Date(timeIntervalSince1970: 1_780_001_000),
                sourceID: "teams",
                sourceName: "Microsoft Teams",
                includeMicrophone: true,
                localeIdentifier: "en-US",
                consentStatus: .disclosed
            )
        )

        XCTAssertEqual(result.record.id, meetingID)
        XCTAssertEqual(result.record.title, "Release readiness sync")
        XCTAssertEqual(result.searchMeeting.title, "Release readiness sync")
        XCTAssertEqual(result.record.state, .ready)
        XCTAssertEqual(result.record.durationSeconds, 30)
        XCTAssertEqual(result.transcription.indexedSegmentCount, 2)
        XCTAssertEqual(result.intelligence.summary.decisions.first?.title, "Ship after privacy review")

        let snapshot = try repository.loadSnapshot()
        XCTAssertEqual(snapshot.records.map(\.id), [meetingID])
        XCTAssertEqual(snapshot.records.first?.title, "Release readiness sync")
        XCTAssertEqual(snapshot.records.first?.summary?.title, "Release readiness sync")
        XCTAssertEqual(snapshot.searchMeetingsByID[meetingID]?.title, "Release readiness sync")
        XCTAssertEqual(snapshot.searchMeetingsByID[meetingID]?.sourceApp, "Microsoft Teams")
        XCTAssertEqual(snapshot.editSessionsByMeetingID[meetingID]?.draft.segments.map(\.id), [decisionSegmentID, followUpSegmentID])

        let searchResults = try searchIndex.search("notarized")
        XCTAssertEqual(searchResults.map(\.meetingID), [meetingID])
        XCTAssertEqual(searchResults.first?.meetingTitle, "Release readiness sync")
        XCTAssertEqual(searchResults.first?.speakerName, "You")
        XCTAssertEqual(try bundleStore.readManifest(meetingID: meetingID).title, "Release readiness sync")

        let transcriptURL = bundleStore.bundleURL(for: meetingID)
            .appendingPathComponent(MeetingTranscript.finalTranscriptRelativePath)
        let storedBytes = try Data(contentsOf: transcriptURL)
        XCTAssertFalse(String(decoding: storedBytes, as: UTF8.self).contains("beta candidate"))

        let storedArtifact = try bundleStore.readJSONArtifact(
            MeetingIntelligenceArtifact.self,
            meetingID: meetingID,
            relativePath: MeetingIntelligenceArtifact.summaryRelativePath,
            purpose: MeetingIntelligenceArtifact.summaryPurpose
        )
        XCTAssertEqual(storedArtifact.summary.decisions.first?.evidence, [evidence])
    }

    func testRecordingProcessingEmitsUserVisibleProgressStages() async throws {
        let harness = try ProcessingHarness()
        let progress = ProgressSink()

        _ = try await harness.service.process(
            RecordingProcessingRequest(
                meetingID: harness.meetingID,
                title: "Progress sync",
                startedAt: Date(timeIntervalSince1970: 1_780_003_000),
                sourceID: "teams",
                sourceName: "Microsoft Teams",
                includeMicrophone: true,
                microphoneDeviceID: "studio",
                microphoneDeviceName: "Studio Display Microphone",
                localeIdentifier: "en-US",
                consentStatus: .disclosed
            ),
            progress: { progress.append($0) }
        )

        XCTAssertEqual(
            progress.events.map(\.stage),
            [
                .preparingBundle,
                .recordingAudio,
                .transcribingAudio,
                .generatingIntelligence,
                .savingLibrary,
                .finished
            ]
        )
        XCTAssertEqual(progress.events.last?.fractionCompleted, 1)
        XCTAssertEqual(
            progress.events.first { $0.stage == .recordingAudio }?.message,
            "Writing encrypted audio chunks with Studio Display Microphone"
        )
        XCTAssertEqual(progress.events.last?.message, "Processing complete")
    }

    func testRecordingProcessingCanBeCancelledBeforeWritingAudio() async throws {
        let harness = try ProcessingHarness()
        let progress = ProgressSink()

        do {
            _ = try await harness.service.process(
                RecordingProcessingRequest(
                    meetingID: harness.meetingID,
                    title: "Cancelled sync",
                    startedAt: Date(timeIntervalSince1970: 1_780_003_200),
                    sourceID: "teams",
                    sourceName: "Microsoft Teams",
                    includeMicrophone: true,
                    localeIdentifier: "en-US",
                    consentStatus: .disclosed
                ),
                progress: { progress.append($0) },
                shouldCancel: { progress.events.contains { $0.stage == .preparingBundle } }
            )
            XCTFail("Expected processing cancellation to throw")
        } catch {
            XCTAssertEqual(
                error as? RecordingProcessingError,
                .cancelled(stage: .preparingBundle)
            )
        }

        XCTAssertEqual(progress.events.map(\.stage), [.preparingBundle])
        XCTAssertTrue(try harness.repository.loadSnapshot().records.isEmpty)
    }

    func testRecordingProcessingReportsFailedStageWithoutSavingLibraryRecord() async throws {
        let harness = try ProcessingHarness(transcriptionEngine: FailingTranscriptionEngine())
        let progress = ProgressSink()

        do {
            _ = try await harness.service.process(
                RecordingProcessingRequest(
                    meetingID: harness.meetingID,
                    title: "Failed transcript sync",
                    startedAt: Date(timeIntervalSince1970: 1_780_003_400),
                    sourceID: "teams",
                    sourceName: "Microsoft Teams",
                    includeMicrophone: true,
                    localeIdentifier: "en-US",
                    consentStatus: .disclosed
                ),
                progress: { progress.append($0) }
            )
            XCTFail("Expected transcription failure to throw")
        } catch {
            XCTAssertEqual(
                error as? RecordingProcessingError,
                .failed(stage: .transcribingAudio, message: "transcription provider unavailable")
            )
        }

        XCTAssertEqual(progress.events.map(\.stage), [.preparingBundle, .recordingAudio, .transcribingAudio])
        XCTAssertTrue(try harness.repository.loadSnapshot().records.isEmpty)
    }

    func testRecordingProcessingFailsClosedWhenGeneratedTitleIsEmpty() async throws {
        let harness = try ProcessingHarness(summaryTitle: "   ")
        let progress = ProgressSink()

        do {
            _ = try await harness.service.process(
                RecordingProcessingRequest(
                    meetingID: harness.meetingID,
                    title: "Stale placeholder title",
                    startedAt: Date(timeIntervalSince1970: 1_780_003_600),
                    sourceID: "teams",
                    sourceName: "Microsoft Teams",
                    includeMicrophone: true,
                    localeIdentifier: "en-US",
                    consentStatus: .disclosed
                ),
                progress: { progress.append($0) }
            )
            XCTFail("Expected empty generated title to fail closed")
        } catch {
            XCTAssertEqual(
                error as? RecordingProcessingError,
                .failed(
                    stage: .generatingIntelligence,
                    message: "Meeting intelligence returned an empty generated title."
                )
            )
        }

        XCTAssertEqual(
            progress.events.map(\.stage),
            [.preparingBundle, .recordingAudio, .transcribingAudio, .generatingIntelligence]
        )
        XCTAssertTrue(try harness.repository.loadSnapshot().records.isEmpty)
    }

    func testRecordingProcessingPromotesGenericMeetingSummaryTitleFromTranscript() async throws {
        let harness = try ProcessingHarness(summaryTitle: "Meeting Summary")

        let result = try await harness.service.process(
            RecordingProcessingRequest(
                meetingID: harness.meetingID,
                title: "Stale placeholder title",
                startedAt: Date(timeIntervalSince1970: 1_780_003_700),
                sourceID: "teams",
                sourceName: "Microsoft Teams",
                includeMicrophone: true,
                localeIdentifier: "en-US",
                consentStatus: .disclosed
            )
        )

        XCTAssertEqual(result.record.title, "Beta Candidate Can Ship After Privacy Review")
        XCTAssertEqual(result.intelligence.summary.title, "Beta Candidate Can Ship After Privacy Review")
        XCTAssertEqual(try harness.repository.loadSnapshot().records.first?.title, "Beta Candidate Can Ship After Privacy Review")
    }

    func testActiveRecordingProcessingCompletesFromCheckpointedChunksWhenCaptureInterrupts() async throws {
        let progress = ProgressSink()
        let harness = try ProcessingHarness(
            captureEngine: FailingAfterCheckpointProcessingCaptureEngine(
                source: CaptureSource(
                    id: "teams",
                    displayName: "Microsoft Teams",
                    bundleIdentifier: "com.microsoft.teams2",
                    mode: .selectedApplication,
                    isRecommended: true,
                    level: 0.71
                ),
                chunk: CapturedAudioChunk(
                    track: .remoteSystem,
                    data: Data("checkpointed remote audio".utf8),
                    startTime: 0,
                    duration: 18,
                    codec: "CAF/LPCM"
                )
            )
        )
        let session = try await harness.service.beginRecording(
            RecordingProcessingRequest(
                meetingID: harness.meetingID,
                title: "Interrupted active recording",
                startedAt: Date(timeIntervalSince1970: 1_780_003_800),
                sourceID: "teams",
                sourceName: "Microsoft Teams",
                includeMicrophone: true,
                localeIdentifier: "en-US",
                consentStatus: .disclosed
            )
        )

        let result = try await harness.service.finishRecording(
            session,
            progress: { progress.append($0) }
        )

        XCTAssertEqual(result.capture.records.map(\.relativePath), ["audio/remoteSystem/chunk-000000.bin.enc"])
        XCTAssertEqual(result.record.state, .ready)
        XCTAssertEqual(result.record.durationSeconds, 18)
        XCTAssertEqual(result.transcription.indexedSegmentCount, 1)
        XCTAssertEqual(progress.events.map(\.stage), [.recordingAudio, .transcribingAudio, .generatingIntelligence, .savingLibrary, .finished])
        XCTAssertEqual(try harness.repository.loadSnapshot().records.map(\.id), [harness.meetingID])
    }

    func testActiveRecordingProcessingFailsClosedWhenFinalAudioTranscriptionFails() async throws {
        let progress = ProgressSink()
        let liveSegment = TranscriptSegment(
            id: UUID(uuidString: "61616161-6161-6161-6161-616161616161")!,
            speakerName: "You",
            trackKind: .microphone,
            startTime: 0,
            endTime: 5,
            text: "The beta candidate can ship after live Apple Speech transcription.",
            confidence: 0.88,
            isFinal: false
        )
        let harness = try ProcessingHarness(
            transcriptionEngine: FailingTranscriptionEngine(),
            evidenceSegmentID: liveSegment.id
        )
        let session = try await harness.service.beginRecording(
            RecordingProcessingRequest(
                meetingID: harness.meetingID,
                title: "Live transcript recording",
                startedAt: Date(timeIntervalSince1970: 1_780_003_900),
                sourceID: "teams",
                sourceName: "Microsoft Teams",
                includeMicrophone: true,
                localeIdentifier: "en-US",
                consentStatus: .disclosed
            )
        )

        do {
            _ = try await harness.service.finishRecording(
                session,
                liveTranscriptSegments: [liveSegment],
                progress: { progress.append($0) }
            )
            XCTFail("Expected failed final audio transcription to fail closed")
        } catch {
            XCTAssertEqual(
                error as? RecordingProcessingError,
                .failed(stage: .transcribingAudio, message: "transcription provider unavailable")
            )
        }

        XCTAssertEqual(progress.events.map(\.stage), [.recordingAudio, .transcribingAudio])
        XCTAssertTrue(try harness.repository.loadSnapshot().records.isEmpty)
        XCTAssertNil(try harness.repository.loadSnapshot().editSessionsByMeetingID[harness.meetingID])
    }

    func testActiveRecordingProcessingPrefersFinalAudioTranscriptOverLivePreview() async throws {
        let liveSegment = TranscriptSegment(
            speakerName: "You",
            trackKind: .microphone,
            startTime: 0,
            endTime: 5,
            text: "Partial live preview should not become the saved final transcript.",
            confidence: 0.72,
            isFinal: false
        )
        let harness = try ProcessingHarness()
        let session = try await harness.service.beginRecording(
            RecordingProcessingRequest(
                meetingID: harness.meetingID,
                title: "Final transcript recording",
                startedAt: Date(timeIntervalSince1970: 1_780_003_925),
                sourceID: "teams",
                sourceName: "Microsoft Teams",
                includeMicrophone: true,
                localeIdentifier: "en-US",
                consentStatus: .disclosed
            )
        )

        let result = try await harness.service.finishRecording(
            session,
            liveTranscriptSegments: [liveSegment]
        )

        XCTAssertEqual(
            result.transcription.transcript.segments.map(\.text),
            ["The beta candidate can ship after privacy review."]
        )
        XCTAssertFalse(result.transcription.transcript.segments.map(\.text).contains(liveSegment.text))
        XCTAssertEqual(
            try harness.repository.loadSnapshot().editSessionsByMeetingID[harness.meetingID]?.draft.segments.map(\.editedText),
            ["The beta candidate can ship after privacy review."]
        )
    }

    func testActiveRecordingProcessingSurfacesIntelligenceSafetyBlockWithoutSyntheticSummary() async throws {
        let progress = ProgressSink()
        let harness = try ProcessingHarness(
            intelligenceProvider: SafetyBlockedMeetingIntelligenceProvider()
        )
        let session = try await harness.service.beginRecording(
            RecordingProcessingRequest(
                meetingID: harness.meetingID,
                title: "Safety blocked recording",
                startedAt: Date(timeIntervalSince1970: 1_780_003_950),
                sourceID: "teams",
                sourceName: "Microsoft Teams",
                includeMicrophone: true,
                localeIdentifier: "en-US",
                consentStatus: .disclosed
            )
        )

        do {
            _ = try await harness.service.finishRecording(
                session,
                progress: { progress.append($0) }
            )
            XCTFail("Expected the safety-blocked intelligence provider to fail explicitly")
        } catch let RecordingProcessingError.failed(stage, message) {
            XCTAssertEqual(stage, .generatingIntelligence)
            XCTAssertTrue(message.localizedCaseInsensitiveContains("safety"))
        }

        XCTAssertTrue(try harness.repository.loadSnapshot().records.isEmpty)
        let transcript = try harness.bundleStore.readJSONArtifact(
            MeetingTranscript.self,
            meetingID: harness.meetingID,
            relativePath: MeetingTranscript.finalTranscriptRelativePath,
            purpose: MeetingTranscript.finalTranscriptPurpose
        )
        XCTAssertFalse(transcript.segments.isEmpty)
    }

    func testBeginRecordingPersistsSchemaV2ContextMetadataBeforeCaptureStarts() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultContextOrdering-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let meetingID = UUID()
        let bundleStore = EncryptedMeetingBundleStore(
            rootDirectory: root,
            vault: AESGCMDataVault(
                keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 84, count: 32))
            )
        )
        let probe = MetadataOrderingCaptureEngine(bundleStore: bundleStore, meetingID: meetingID)
        let harness = try ProcessingHarness(
            meetingID: meetingID,
            root: root,
            bundleStore: bundleStore,
            captureEngine: probe
        )
        let context = MeetingContext(
            localeIdentifier: "pl_pl",
            expectedParticipantCount: 5,
            participantNames: ["  Żaneta Kowalska  "],
            vocabulary: ["  Projekt Żubr  "]
        )

        let session = try await harness.service.beginRecording(
            RecordingProcessingRequest(
                meetingID: meetingID,
                title: "Context ordering",
                startedAt: Date(timeIntervalSince1970: 1_780_010_500),
                sourceID: "teams",
                sourceName: "Microsoft Teams",
                includeMicrophone: true,
                context: context,
                consentStatus: .disclosed
            )
        )
        try await session.waitForCaptureCompletion()

        XCTAssertTrue(probe.metadataExistedWhenCaptureStarted)
        let manifest = try bundleStore.readManifest(meetingID: meetingID)
        XCTAssertEqual(manifest.schemaVersion, 2)
        XCTAssertEqual(manifest.context.localeIdentifier, "pl-PL")
        XCTAssertEqual(manifest.context.participantNames, ["Żaneta Kowalska"])
        XCTAssertEqual(manifest.sessionMetadataPath, RecordingSessionMetadata.relativePath)
        let metadata = try bundleStore.readJSONArtifact(
            RecordingSessionMetadata.self,
            meetingID: meetingID,
            relativePath: RecordingSessionMetadata.relativePath,
            purpose: RecordingSessionMetadata.purpose
        )
        XCTAssertEqual(metadata.context, manifest.context)
    }

    func testFinalizationPassesPersistedPreviewEvidenceIntoFinalTranscription() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultPreviewEvidenceProcessing-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let meetingID = UUID()
        let bundleStore = EncryptedMeetingBundleStore(
            rootDirectory: root,
            vault: AESGCMDataVault(
                keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 0x4F, count: 32))
            )
        )
        let metadataService = RecordingSessionMetadataService(bundleStore: bundleStore)
        let finalService = PreviewEvidenceFinalServiceProbe(bundleStore: bundleStore)
        let harness = try ProcessingHarness(
            meetingID: meetingID,
            root: root,
            bundleStore: bundleStore,
            finalTranscriptionService: finalService,
            recordingSessionMetadataCreator: metadataService,
            evidenceSegmentID: finalService.segmentID
        )
        let session = try await harness.service.beginRecording(
            RecordingProcessingRequest(
                meetingID: meetingID,
                title: "Preview evidence",
                startedAt: Date(timeIntervalSince1970: 1_805_100_000),
                sourceID: "teams",
                sourceName: "Teams",
                includeMicrophone: true,
                context: MeetingContext(localeIdentifier: "en-US"),
                consentStatus: .disclosed
            )
        )
        let evidence = TranscriptPreviewEvidence(
            gaps: [try TranscriptPreviewGap(track: .remoteSystem, startTime: 4.5, endTime: 5)],
            speakerIdentities: []
        )
        _ = try await metadataService.recordPreviewEvidence(meetingID: meetingID, evidence: evidence)

        _ = try await harness.service.finishRecording(session)

        XCTAssertEqual(finalService.observedPreviewEvidence, evidence)
    }

    func testProcessingRejectsMismatchedFinalizationMetadataBeforeManifestPromotion() async throws {
        let requestedMeetingID = UUID()
        let privateMeetingID = UUID()
        let manager = MismatchedFinalizationMetadataManager(privateMeetingID: privateMeetingID)
        let harness = try ProcessingHarness(
            meetingID: requestedMeetingID,
            recordingSessionMetadataCreator: manager
        )

        do {
            _ = try await harness.service.process(
                RecordingProcessingRequest(
                    meetingID: requestedMeetingID,
                    title: "Identity-safe promotion",
                    startedAt: Date(timeIntervalSince1970: 1_780_020_000),
                    sourceID: "teams",
                    sourceName: "Microsoft Teams",
                    includeMicrophone: true,
                    context: MeetingContext(),
                    consentStatus: .disclosed
                )
            )
            XCTFail("Expected mismatched finalization metadata rejection")
        } catch {
            XCTAssertEqual(error as? RecordingSessionMetadataValidationError, .metadataMeetingMismatch)
            XCTAssertFalse(error.localizedDescription.contains("Private promotion note"))
        }
        let manifest = try harness.bundleStore.readManifest(meetingID: requestedMeetingID)
        XCTAssertEqual(manifest.bookmarks, [])
        XCTAssertEqual(manifest.context, MeetingContext())
    }

    func testBeginRecordingRejectsInvalidContextBeforeCaptureAndRollsBackNewBundle() async throws {
        let probe = CaptureInvocationProbe()
        let harness = try ProcessingHarness(captureEngine: probe)
        let secret = "Private Unsupported Locale"

        do {
            _ = try await harness.service.beginRecording(
                RecordingProcessingRequest(
                    meetingID: harness.meetingID,
                    title: "Invalid context",
                    startedAt: Date(timeIntervalSince1970: 1_780_010_600),
                    sourceID: "teams",
                    sourceName: "Microsoft Teams",
                    includeMicrophone: true,
                    context: MeetingContext(
                        localeIdentifier: "de-DE",
                        participantNames: [secret]
                    ),
                    consentStatus: .disclosed
                )
            )
            XCTFail("Expected invalid meeting context to prevent capture")
        } catch {
            XCTAssertEqual(error as? RecordingSessionMetadataServiceError, .invalidMetadata)
            XCTAssertFalse(error.localizedDescription.contains(secret))
        }

        XCTAssertEqual(probe.recordCallCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.bundleStore.bundleURL(for: harness.meetingID).path))
    }

    func testBeginRecordingRejectsEncryptedMetadataWriteFailureBeforeCapture() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultMetadataWriteFailure-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = FailsAfterKeyLoadProvider(successfulLoadCount: 1)
        let bundleStore = EncryptedMeetingBundleStore(
            rootDirectory: root,
            vault: AESGCMDataVault(keyProvider: provider)
        )
        let probe = CaptureInvocationProbe()
        let harness = try ProcessingHarness(
            root: root,
            bundleStore: bundleStore,
            captureEngine: probe
        )

        do {
            _ = try await harness.service.beginRecording(
                RecordingProcessingRequest(
                    meetingID: harness.meetingID,
                    title: "Metadata failure",
                    startedAt: Date(timeIntervalSince1970: 1_780_010_700),
                    sourceID: "teams",
                    sourceName: "Microsoft Teams",
                    includeMicrophone: true,
                    context: MeetingContext(),
                    consentStatus: .disclosed
                )
            )
            XCTFail("Expected encrypted metadata write failure")
        } catch {
            XCTAssertEqual(error as? RecordingSessionMetadataServiceError, .encryptedWriteFailed)
        }

        XCTAssertEqual(probe.recordCallCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bundleStore.bundleURL(for: harness.meetingID).path))
    }

    func testBeginRecordingSurfacesMetadataAndRollbackFailureAndQuarantinesIncompleteBundle() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultRollbackFailure-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = FailsAfterKeyLoadProvider(successfulLoadCount: 1)
        let bundleStore = EncryptedMeetingBundleStore(
            rootDirectory: root,
            vault: AESGCMDataVault(keyProvider: provider)
        )
        let probe = CaptureInvocationProbe()
        let privateValue = "Project Nightingale private participant"
        let harness = try ProcessingHarness(
            root: root,
            bundleStore: bundleStore,
            captureEngine: probe,
            rollbackBundle: { _ in
                throw RollbackFixtureError.deleteFailed(path: root.path + "/private.bundle")
            }
        )

        do {
            _ = try await harness.service.beginRecording(
                RecordingProcessingRequest(
                    meetingID: harness.meetingID,
                    title: privateValue,
                    startedAt: Date(timeIntervalSince1970: 1_780_010_800),
                    sourceID: "teams",
                    sourceName: "Microsoft Teams",
                    includeMicrophone: true,
                    context: MeetingContext(participantNames: [privateValue]),
                    consentStatus: .disclosed
                )
            )
            XCTFail("Expected preparation and rollback failure")
        } catch {
            XCTAssertEqual(
                error as? RecordingPreparationError,
                .metadataPreparationAndRollbackFailed(cause: .encryptedWriteFailed)
            )
            let diagnostic = [
                String(describing: error),
                error.localizedDescription,
                String(describing: error as NSError)
            ].joined(separator: "\n")
            XCTAssertFalse(diagnostic.contains(privateValue))
            XCTAssertFalse(diagnostic.contains(root.path))
            XCTAssertFalse(diagnostic.contains("active-session.json.enc"))
        }

        XCTAssertEqual(probe.recordCallCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleStore.bundleURL(for: harness.meetingID).path))
        XCTAssertThrowsError(try bundleStore.readManifest(meetingID: harness.meetingID)) { error in
            XCTAssertEqual(error as? MeetingBundleStoreError, .bundlePreparationIncomplete)
        }
        XCTAssertFalse(try bundleStore.listMeetingBundleIDs().contains(harness.meetingID))
    }
}

private enum RollbackFixtureError: Error, LocalizedError {
    case deleteFailed(path: String)

    var errorDescription: String? {
        switch self {
        case let .deleteFailed(path): "Could not delete \(path)"
        }
    }
}

private enum FailingTranscriptionError: Error, LocalizedError {
    case unavailable

    var errorDescription: String? {
        "transcription provider unavailable"
    }
}

private final class FailingTranscriptionEngine: TranscriptionEngine, @unchecked Sendable {
    let id = "failing-transcription"
    let supportsRealtime = false

    func transcribe(_ request: TranscriptionRequest) async throws -> [TranscriptSegment] {
        throw FailingTranscriptionError.unavailable
    }
}

private struct SafetyBlockedIntelligenceError: Error, LocalizedError {
    var errorDescription: String? {
        "The request was blocked by the safety system."
    }
}

private final class SafetyBlockedMeetingIntelligenceProvider: MeetingIntelligenceProvider, @unchecked Sendable {
    let id = "safety-blocked-intelligence"

    func summarize(segments: [TranscriptSegment], meetingID: UUID) async throws -> MeetingSummary {
        throw SafetyBlockedIntelligenceError()
    }

    func summarize(
        segments: [TranscriptSegment],
        bookmarkEvidence: [MeetingIntelligenceBookmarkEvidence],
        meetingID: UUID
    ) async throws -> MeetingSummary {
        throw SafetyBlockedIntelligenceError()
    }
}

private enum InterruptedProcessingCaptureFixtureError: Error, LocalizedError {
    case sourceDisappeared

    var errorDescription: String? {
        "System source disappeared during active capture"
    }
}

private final class FailingAfterCheckpointProcessingCaptureEngine: CaptureRecordingEngine, @unchecked Sendable {
    let id = "failing-after-checkpoint-processing-capture"
    let mode: CaptureMode = .selectedApplication

    private let source: CaptureSource
    private let chunk: CapturedAudioChunk

    init(source: CaptureSource, chunk: CapturedAudioChunk) {
        self.source = source
        self.chunk = chunk
    }

    func availableSources() async throws -> [CaptureSource] {
        [source]
    }

    func record(_ request: CaptureRecordingRequest) async throws -> CaptureRecordingEngineOutput {
        try request.chunkSink?.write(chunk)
        throw InterruptedProcessingCaptureFixtureError.sourceDisappeared
    }
}

private final class CaptureInvocationProbe: CaptureRecordingEngine, @unchecked Sendable {
    let id = "capture-invocation-probe"
    let mode: CaptureMode = .selectedApplication
    private let lock = NSLock()
    private var calls = 0

    var recordCallCount: Int {
        lock.withLock { calls }
    }

    func availableSources() async throws -> [CaptureSource] {
        [
            CaptureSource(
                id: "teams",
                displayName: "Microsoft Teams",
                mode: .selectedApplication
            )
        ]
    }

    func record(_ request: CaptureRecordingRequest) async throws -> CaptureRecordingEngineOutput {
        lock.withLock { calls += 1 }
        return CaptureRecordingEngineOutput(chunks: [], healthReport: emptyProcessingHealthReport())
    }
}

private final class MetadataOrderingCaptureEngine: CaptureRecordingEngine, @unchecked Sendable {
    let id = "metadata-ordering-capture"
    let mode: CaptureMode = .selectedApplication
    private let bundleStore: EncryptedMeetingBundleStore
    private let meetingID: UUID
    private let lock = NSLock()
    private var observedMetadata = false

    init(bundleStore: EncryptedMeetingBundleStore, meetingID: UUID) {
        self.bundleStore = bundleStore
        self.meetingID = meetingID
    }

    var metadataExistedWhenCaptureStarted: Bool {
        lock.withLock { observedMetadata }
    }

    func availableSources() async throws -> [CaptureSource] {
        [
            CaptureSource(
                id: "teams",
                displayName: "Microsoft Teams",
                mode: .selectedApplication
            )
        ]
    }

    func record(_ request: CaptureRecordingRequest) async throws -> CaptureRecordingEngineOutput {
        let exists = try bundleStore.artifactExists(
            meetingID: meetingID,
            relativePath: RecordingSessionMetadata.relativePath
        )
        lock.withLock { observedMetadata = exists }
        return CaptureRecordingEngineOutput(chunks: [], healthReport: emptyProcessingHealthReport())
    }
}

private final class FailsAfterKeyLoadProvider: SymmetricKeyProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var remainingSuccessfulLoads: Int

    init(successfulLoadCount: Int) {
        remainingSuccessfulLoads = successfulLoadCount
    }

    func loadKey() throws -> SymmetricKey {
        try lock.withLock {
            guard remainingSuccessfulLoads > 0 else {
                throw EncryptionError.invalidKeyLength(0)
            }
            remainingSuccessfulLoads -= 1
            return SymmetricKey(data: Data(repeating: 85, count: 32))
        }
    }
}

private func emptyProcessingHealthReport() -> CaptureHealthReport {
    CaptureHealthReport(
        remoteDropouts: 0,
        microphoneDropouts: 0,
        remoteClippingPercent: 0,
        microphoneClippingPercent: 0,
        silentPeriods: [],
        deviceChanges: [],
        transcriptionEngine: "pending",
        intelligenceProvider: "pending"
    )
}

private final class ProgressSink: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [RecordingProcessingProgress] = []

    var events: [RecordingProcessingProgress] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ progress: RecordingProcessingProgress) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(progress)
    }
}

private struct ProcessingHarness {
    var meetingID: UUID
    var service: RecordingProcessingService
    var repository: MeetingLibraryRepository
    var bundleStore: EncryptedMeetingBundleStore

    init(
        meetingID providedMeetingID: UUID? = nil,
        root providedRoot: URL? = nil,
        bundleStore providedBundleStore: EncryptedMeetingBundleStore? = nil,
        captureEngine: (any CaptureRecordingEngine)? = nil,
        transcriptionEngine: (any TranscriptionEngine)? = nil,
        finalTranscriptionService: (any FinalTranscriptionServicing)? = nil,
        intelligenceProvider: (any MeetingIntelligenceProvider)? = nil,
        recordingSessionMetadataCreator: (any RecordingSessionMetadataCreating)? = nil,
        rollbackBundle: (@Sendable (UUID) throws -> Void)? = nil,
        summaryTitle: String = "Progress sync",
        evidenceSegmentID: UUID? = nil
    ) throws {
        let root = providedRoot ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultProcessingHarness-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let meetingID = providedMeetingID ?? UUID()
        let decisionSegmentID = UUID()
        let resolvedEvidenceSegmentID = evidenceSegmentID ?? decisionSegmentID
        let vault = AESGCMDataVault(
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 74, count: 32))
        )
        let bundleStore = providedBundleStore ?? EncryptedMeetingBundleStore(rootDirectory: root, vault: vault)
        let chunkWriter = EncryptedAudioChunkWriter(bundleStore: bundleStore)
        let searchIndex = try SQLiteSearchIndex(databaseURL: root.appendingPathComponent("library.sqlite"))
        let repository = MeetingLibraryRepository(bundleStore: bundleStore, searchIndex: searchIndex)
        let captureService = CaptureRecordingService(
            engine: captureEngine ?? MockCaptureRecordingEngine(
                sources: [
                    CaptureSource(
                        id: "teams",
                        displayName: "Microsoft Teams",
                        bundleIdentifier: "com.microsoft.teams2",
                        mode: .selectedApplication,
                        isRecommended: true,
                        level: 0.71
                    )
                ],
                chunks: [
                    CapturedAudioChunk(
                        track: .remoteSystem,
                        data: Data("remote audio".utf8),
                        startTime: 0,
                        duration: 30,
                        codec: "CAF/LPCM"
                    )
                ],
                healthReport: CaptureHealthReport(
                    remoteDropouts: 0,
                    microphoneDropouts: 0,
                    remoteClippingPercent: 0,
                    microphoneClippingPercent: 0,
                    silentPeriods: [],
                    deviceChanges: [],
                    transcriptionEngine: "mock",
                    intelligenceProvider: "mock"
                )
            ),
            chunkWriter: chunkWriter
        )
        let defaultTranscriptionService = FinalTranscriptionService(
            engine: transcriptionEngine ?? MockTranscriptionEngine(
                responsesByAudioChunkPath: [
                    "audio/remoteSystem/chunk-000000.bin.enc": [
                        TranscriptSegment(
                            id: decisionSegmentID,
                            speakerName: "Anna",
                            trackKind: .remoteSystem,
                            startTime: 4,
                            endTime: 12,
                            text: "The beta candidate can ship after privacy review.",
                            confidence: 0.94,
                            isFinal: true
                        )
                    ]
                ]
            ),
            bundleStore: bundleStore,
            chunkWriter: chunkWriter,
            searchIndex: searchIndex
        )
        let transcriptionService = finalTranscriptionService ?? defaultTranscriptionService
        let evidence = EvidenceRef(
            meetingID: meetingID,
            segmentID: resolvedEvidenceSegmentID,
            startTime: 4,
            endTime: 12,
            quote: "The beta candidate can ship after privacy review."
        )
        let intelligenceService = MeetingIntelligenceService(
            provider: intelligenceProvider ?? MockMeetingIntelligenceProvider(
                summary: MeetingSummary(
                    title: summaryTitle,
                    oneParagraph: "The team aligned on shipping the beta candidate after privacy review.",
                    bullets: ["Beta can ship after privacy review."],
                    decisions: [
                        Decision(
                            title: "Ship after privacy review",
                            details: "The beta candidate can ship after privacy review.",
                            evidence: [evidence],
                            confidence: 0.90
                        )
                    ],
                    actionItems: [
                        ActionItem(
                            title: "Prepare notarized build checklist",
                            ownerName: "You",
                            evidence: [evidence],
                            confidence: 0.82
                        )
                    ]
                )
            ),
            bundleStore: bundleStore
        )

        self.meetingID = meetingID
        self.bundleStore = bundleStore
        self.service = RecordingProcessingService(
            captureService: captureService,
            transcriptionService: transcriptionService,
            intelligenceService: intelligenceService,
            repository: repository,
            bundleStore: bundleStore,
            chunkWriter: chunkWriter,
            sessionMetadataService: recordingSessionMetadataCreator,
            rollbackBundle: rollbackBundle
        )
        self.repository = repository
    }
}

private final class PreviewEvidenceFinalServiceProbe: FinalTranscriptionServicing, @unchecked Sendable {
    let segmentID = UUID()
    private let bundleStore: EncryptedMeetingBundleStore
    private let lock = NSLock()
    private var storedEvidence = TranscriptPreviewEvidence.empty

    init(bundleStore: EncryptedMeetingBundleStore) {
        self.bundleStore = bundleStore
    }

    var observedPreviewEvidence: TranscriptPreviewEvidence {
        lock.withLock { storedEvidence }
    }

    func transcribe(
        meeting: SearchMeeting,
        records: [AudioChunkRecord],
        context: MeetingContext,
        speakerRenames: [String: String],
        indexSearch: Bool
    ) async throws -> FinalTranscriptionResult {
        try await transcribe(
            meeting: meeting,
            records: records,
            context: context,
            speakerRenames: speakerRenames,
            indexSearch: indexSearch,
            previewEvidence: .empty
        )
    }

    func transcribe(
        meeting: SearchMeeting,
        records: [AudioChunkRecord],
        context: MeetingContext,
        speakerRenames: [String: String],
        indexSearch: Bool,
        previewEvidence: TranscriptPreviewEvidence
    ) async throws -> FinalTranscriptionResult {
        lock.withLock { storedEvidence = previewEvidence }
        let transcript = MeetingTranscript(
            meetingID: meeting.id,
            providerConfigurationVersion: "probe-v1",
            localeIdentifier: context.localeIdentifier,
            segments: [TranscriptSegment(
                id: segmentID,
                speakerName: "Speaker 1",
                trackKind: .remoteSystem,
                startTime: 4,
                endTime: 12,
                text: "The beta candidate can ship after privacy review.",
                confidence: 0.9,
                isFinal: true
            )]
        )
        try bundleStore.writeJSONArtifact(
            transcript,
            meetingID: meeting.id,
            relativePath: MeetingTranscript.finalTranscriptRelativePath,
            purpose: MeetingTranscript.finalTranscriptPurpose
        )
        return FinalTranscriptionResult(transcript: transcript, indexedSegmentCount: 0)
    }
}

private actor MismatchedFinalizationMetadataManager: RecordingSessionMetadataManaging {
    let privateMeetingID: UUID

    init(privateMeetingID: UUID) {
        self.privateMeetingID = privateMeetingID
    }

    func create(meetingID: UUID, startedAt: Date, context: MeetingContext) async throws -> RecordingSessionMetadata {
        RecordingSessionMetadata(meetingID: meetingID, startedAt: startedAt, context: context)
    }

    func markMoment(
        meetingID: UUID,
        timestamp: TimeInterval,
        category: MeetingBookmarkCategory?,
        note: String?
    ) async throws -> MeetingBookmark {
        throw RecordingSessionMetadataServiceError.sessionNotActive
    }

    func finalize(meetingID: UUID, duration: TimeInterval) async throws -> RecordingSessionMetadata {
        RecordingSessionMetadata(
            meetingID: privateMeetingID,
            startedAt: Date(timeIntervalSince1970: 1_780_020_000),
            context: MeetingContext(participantNames: ["Private Person"]),
            bookmarks: [
                MeetingBookmark(
                    meetingID: privateMeetingID,
                    timestamp: 1,
                    createdAt: Date(timeIntervalSince1970: 1_780_020_001),
                    note: "Private promotion note"
                )
            ],
            isFinalized: true
        )
    }
}
