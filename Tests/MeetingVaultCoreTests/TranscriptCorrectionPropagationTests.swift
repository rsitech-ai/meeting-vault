import Foundation
import XCTest
@testable import MeetingVaultCore

final class TranscriptCorrectionPropagationTests: XCTestCase {
    func testCorrectionPropagatesOneVersionAcrossEncryptedArtifactsSearchPlaybackExportAndAgentHistory() async throws {
        let fixture = try makeFixture()
        let coordinator = TranscriptCorrectionCoordinator(
            bundleStore: fixture.bundleStore,
            searchIndex: fixture.searchIndex,
            intelligenceService: MeetingIntelligenceService(
                provider: EchoCorrectionIntelligenceProvider(),
                bundleStore: fixture.bundleStore,
                now: { Date(timeIntervalSince1970: 1_780_200_100) }
            ),
            chunkWriter: fixture.chunkWriter,
            now: { Date(timeIntervalSince1970: 1_780_200_100) }
        )

        let result = try await coordinator.applyCorrection(
            meeting: fixture.searchMeeting,
            edits: [TranscriptSegmentEdit(segmentID: fixture.segmentID, replacementText: "Ship Thursday after QA sign-off.", replacementSpeakerName: "Anna")],
            resolvedReviewItemIDs: [fixture.reviewItemID]
        )

        XCTAssertEqual(result.editResult.version, 1)
        XCTAssertEqual(result.editResult.transcript.transcriptVersion, 1)
        XCTAssertEqual(result.editResult.transcript.segments.first?.text, "Ship Thursday after QA sign-off.")
        XCTAssertEqual(result.editResult.transcript.segments.first?.speakerName, "Anna")
        XCTAssertEqual(result.reviewQueue.transcriptVersion, 1)
        XCTAssertEqual(result.reviewQueue.items.first(where: { $0.id == fixture.reviewItemID })?.status, .resolved)
        XCTAssertEqual(result.intelligence.transcriptVersion, 1)
        XCTAssertEqual(result.intelligence.transcriptDigest, result.derivedState.transcriptDigest)
        XCTAssertEqual(result.playbackTimeline.cues.first?.text, "Ship Thursday after QA sign-off.")
        XCTAssertTrue(result.derivedState.isConsistent)
        XCTAssertEqual(result.record.summary?.oneParagraph, "Ship Thursday after QA sign-off.")
        XCTAssertEqual(try fixture.searchIndex.search("Thursday").first?.speakerName, "Anna")
        XCTAssertTrue(try fixture.searchIndex.search("incorrect").isEmpty)

        let history = try TranscriptQuestionHistoryService(bundleStore: fixture.bundleStore).load(meetingID: fixture.meetingID)
        XCTAssertEqual(history.transcriptVersion, 1)
        XCTAssertEqual(history.transcriptDigest, result.derivedState.transcriptDigest)
        XCTAssertNotNil(history.invalidatedAt)
        XCTAssertTrue(history.turns.isEmpty)
        XCTAssertFalse(try fixture.bundleStore.artifactExists(meetingID: fixture.meetingID, relativePath: TranscriptCorrectionRecoveryMarker.relativePath))

        let export = try MeetingExportService(bundleStore: fixture.bundleStore).exportPackage(
            meeting: fixture.searchMeeting,
            to: fixture.root.appendingPathComponent("Exports"),
            formats: [.json]
        )
        XCTAssertEqual(export.transcriptVersion, 1)
        XCTAssertEqual(export.transcriptDigest, result.derivedState.transcriptDigest)
        let share = try MeetingSharePreparationService(
            versionGate: TranscriptArtifactVersionGate(bundleStore: fixture.bundleStore)
        ).prepareShare(meetingID: fixture.meetingID, package: export, destination: .manualCopy)
        XCTAssertEqual(share.transcriptVersion, 1)
    }

    func testCrashAfterAuthoritativeCommitFailsClosedThenRecoveryRegeneratesIdempotently() async throws {
        let fixture = try makeFixture()
        let crashing = TranscriptCorrectionCoordinator(
            bundleStore: fixture.bundleStore,
            searchIndex: fixture.searchIndex,
            intelligenceService: MeetingIntelligenceService(provider: EchoCorrectionIntelligenceProvider(), bundleStore: fixture.bundleStore),
            chunkWriter: fixture.chunkWriter,
            afterAuthoritativeCommit: { throw CorrectionFixtureError.injectedCrash }
        )
        do {
            _ = try await crashing.applyCorrection(
                meeting: fixture.searchMeeting,
                edits: [TranscriptSegmentEdit(segmentID: fixture.segmentID, replacementText: "Recovered correction", replacementSpeakerName: "You")],
                resolvedReviewItemIDs: [fixture.reviewItemID]
            )
            XCTFail("Expected injected crash")
        } catch CorrectionFixtureError.injectedCrash {}

        // The authoritative encrypted transcript can be ahead while the
        // recovery marker is present, but search must remain the previous
        // complete projection. Readers must never observe a partial edit.
        XCTAssertEqual(try fixture.searchIndex.search("incorrect").map(\.text), ["incorrect phrase"])
        XCTAssertTrue(try fixture.searchIndex.search("Recovered").isEmpty)

        XCTAssertThrowsError(try MeetingExportService(bundleStore: fixture.bundleStore).exportPackage(
            meeting: fixture.searchMeeting,
            to: fixture.root.appendingPathComponent("BlockedExport"),
            formats: [.json]
        )) { error in
            XCTAssertEqual(error as? TranscriptArtifactVersionError, .correctionInProgress)
        }

        let recovery = TranscriptCorrectionCoordinator(
            bundleStore: fixture.bundleStore,
            searchIndex: fixture.searchIndex,
            intelligenceService: MeetingIntelligenceService(provider: EchoCorrectionIntelligenceProvider(), bundleStore: fixture.bundleStore),
            chunkWriter: fixture.chunkWriter
        )
        let first = try await recovery.recoverIfNeeded(meeting: fixture.searchMeeting)
        guard case let .regenerated(result) = first else { return XCTFail("Expected regeneration") }
        XCTAssertEqual(result.editResult.transcript.segments.first?.text, "Recovered correction")
        XCTAssertEqual(result.derivedState.transcriptVersion, 1)
        let second = try await recovery.recoverIfNeeded(meeting: fixture.searchMeeting)
        XCTAssertEqual(second, .noMarker)
    }

    func testExportAndShareRejectMixedOrStaleVersions() async throws {
        let fixture = try makeFixture()
        let oldPackage = try MeetingExportService(bundleStore: fixture.bundleStore).exportPackage(
            meeting: fixture.searchMeeting,
            to: fixture.root.appendingPathComponent("OldExport"),
            formats: [.json]
        )
        let coordinator = TranscriptCorrectionCoordinator(
            bundleStore: fixture.bundleStore,
            searchIndex: fixture.searchIndex,
            intelligenceService: MeetingIntelligenceService(provider: EchoCorrectionIntelligenceProvider(), bundleStore: fixture.bundleStore),
            chunkWriter: fixture.chunkWriter
        )
        _ = try await coordinator.applyCorrection(
            meeting: fixture.searchMeeting,
            edits: [TranscriptSegmentEdit(segmentID: fixture.segmentID, replacementText: "New version")]
        )

        XCTAssertThrowsError(try MeetingSharePreparationService(
            versionGate: TranscriptArtifactVersionGate(bundleStore: fixture.bundleStore)
        ).prepareShare(meetingID: fixture.meetingID, package: oldPackage, destination: .manualCopy)) { error in
            XCTAssertEqual(error as? TranscriptArtifactVersionError, .staleExportOrShare)
        }

        var intelligence = try fixture.bundleStore.readJSONArtifact(
            MeetingIntelligenceArtifact.self,
            meetingID: fixture.meetingID,
            relativePath: MeetingIntelligenceArtifact.summaryRelativePath,
            purpose: MeetingIntelligenceArtifact.summaryPurpose
        )
        intelligence.transcriptVersion = 99
        try fixture.bundleStore.writeJSONArtifact(intelligence, meetingID: fixture.meetingID, relativePath: MeetingIntelligenceArtifact.summaryRelativePath, purpose: MeetingIntelligenceArtifact.summaryPurpose)
        XCTAssertThrowsError(try MeetingExportService(bundleStore: fixture.bundleStore).exportPackage(
            meeting: fixture.searchMeeting,
            to: fixture.root.appendingPathComponent("Mixed"),
            formats: [.json]
        )) { error in
            XCTAssertEqual(error as? TranscriptArtifactVersionError, .mixedVersions)
        }
    }

    private func makeFixture() throws -> CorrectionFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Correction-\(UUID())", isDirectory: true)
        let meetingID = UUID()
        let segmentID = UUID()
        let bundleStore = EncryptedMeetingBundleStore(
            rootDirectory: root,
            vault: AESGCMDataVault(keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 91, count: 32)))
        )
        _ = try bundleStore.createBundle(.initialEncryptedBundle(meetingID: meetingID, title: "Correction"))
        let searchIndex = try SQLiteSearchIndex(inMemory: ())
        let searchMeeting = SearchMeeting(id: meetingID, title: "Correction", startedAt: Date(timeIntervalSince1970: 1_780_200_000), sourceApp: "Meeting")
        let evidence = try TranscriptSegmentEvidence(
            segmentID: segmentID,
            trackKind: .remoteSystem,
            startTime: 1,
            endTime: 4,
            confidence: 0.2,
            speakerConfidence: 0.8,
            overlapsSpeech: false,
            reconstructedFromPreviewGap: false,
            providerConfigurationVersion: "fixture-v1"
        )
        let transcript = MeetingTranscript(
            meetingID: meetingID,
            transcriptVersion: 0,
            providerConfigurationVersion: "fixture-v1",
            localeIdentifier: "en-US",
            generatedAt: Date(timeIntervalSince1970: 1_780_200_010),
            segments: [TranscriptSegment(id: segmentID, speakerName: "Unknown", trackKind: .remoteSystem, startTime: 1, endTime: 4, text: "incorrect phrase", confidence: 0.2, isFinal: true, reviewEvidence: evidence)]
        )
        let record = MeetingRecord(id: meetingID, title: "Correction", startedAt: searchMeeting.startedAt, durationSeconds: 5, sourceName: "Meeting", state: .ready, consentStatus: .consented)
        try bundleStore.writeJSONArtifact(transcript, meetingID: meetingID, relativePath: MeetingTranscript.finalTranscriptRelativePath, purpose: MeetingTranscript.finalTranscriptPurpose)
        try bundleStore.writeJSONArtifact(TranscriptEditHistory(meetingID: meetingID), meetingID: meetingID, relativePath: TranscriptEditHistory.relativePath, purpose: TranscriptEditHistory.purpose)
        try bundleStore.writeJSONArtifact(record, meetingID: meetingID, relativePath: MeetingLibraryRepository.recordRelativePath, purpose: MeetingLibraryRepository.recordPurpose)
        try bundleStore.writeJSONArtifact(searchMeeting, meetingID: meetingID, relativePath: MeetingLibraryRepository.searchMeetingRelativePath, purpose: MeetingLibraryRepository.searchMeetingPurpose)
        try searchIndex.replaceMeetingAndSegments(meeting: searchMeeting, segments: LocalFinalTranscriptionService.searchSegments(transcript))
        let queue = try TranscriptConfidenceReviewService(now: { Date(timeIntervalSince1970: 1_780_200_020) }).deriveQueue(transcript: transcript, evidence: [evidence], transcriptVersion: 0)
        try TranscriptReviewRepository(bundleStore: bundleStore).save(queue)
        let reviewItemID = try XCTUnwrap(queue.activeItems.first?.id)
        let digest = try LocalFinalTranscriptionService.transcriptDigest(transcript)
        let initialSummary = MeetingSummary(title: "Before", oneParagraph: "incorrect phrase", bullets: [], decisions: [], actionItems: [])
        try bundleStore.writeJSONArtifact(MeetingIntelligenceArtifact(meetingID: meetingID, transcriptVersion: 0, transcriptDigest: digest, providerID: "fixture", summary: initialSummary), meetingID: meetingID, relativePath: MeetingIntelligenceArtifact.summaryRelativePath, purpose: MeetingIntelligenceArtifact.summaryPurpose)
        try TranscriptQuestionHistoryService(bundleStore: bundleStore).save(TranscriptQuestionHistory(meetingID: meetingID, transcriptVersion: 0, transcriptDigest: digest, turns: [TranscriptQuestionTurn(createdAt: Date(), question: "Old?", answerDraft: "Old", evidence: [])]))
        let chunkWriter = EncryptedAudioChunkWriter(bundleStore: bundleStore)
        _ = try chunkWriter.writeChunk(Data([1, 2, 3]), meetingID: meetingID, track: .remoteSystem, chunkIndex: 0, startTime: 0, duration: 5, codec: "CAF/LPCM")
        return CorrectionFixture(root: root, meetingID: meetingID, segmentID: segmentID, reviewItemID: reviewItemID, bundleStore: bundleStore, searchIndex: searchIndex, chunkWriter: chunkWriter, searchMeeting: searchMeeting)
    }
}

private struct CorrectionFixture {
    var root: URL
    var meetingID: UUID
    var segmentID: UUID
    var reviewItemID: UUID
    var bundleStore: EncryptedMeetingBundleStore
    var searchIndex: SQLiteSearchIndex
    var chunkWriter: EncryptedAudioChunkWriter
    var searchMeeting: SearchMeeting
}

private enum CorrectionFixtureError: Error { case injectedCrash }

private struct EchoCorrectionIntelligenceProvider: MeetingIntelligenceProvider {
    let id = "echo-correction"
    func summarize(segments: [TranscriptSegment], meetingID: UUID) async throws -> MeetingSummary {
        summary(segments)
    }
    func summarize(segments: [TranscriptSegment], bookmarkEvidence: [MeetingIntelligenceBookmarkEvidence], meetingID: UUID) async throws -> MeetingSummary {
        summary(segments)
    }
    private func summary(_ segments: [TranscriptSegment]) -> MeetingSummary {
        let text = segments.first?.text ?? ""
        return MeetingSummary(title: "Corrected", oneParagraph: text, bullets: text.isEmpty ? [] : [text], decisions: [], actionItems: [])
    }
}
