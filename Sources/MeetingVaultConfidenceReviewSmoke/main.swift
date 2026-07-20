import Foundation
import MeetingVaultCore

private struct SmokeReport: Codable {
    var status: String
    var transcriptVersion: Int
    var versionsConsistent: Bool
    var reviewResolved: Bool
    var exactPlaybackAvailable: Bool
    var searchUpdated: Bool
    var agentHistoryInvalidated: Bool
    var exportVersionBound: Bool
    var shareVersionBound: Bool
    var recoveryMarkerCleared: Bool
    var rawPrivateDataStored: Bool
    var externalNetworkRequested: Bool
    var issues: [String]
}

private struct SmokeIntelligenceProvider: MeetingIntelligenceProvider {
    let id = "confidence-review-smoke"
    func summarize(segments: [TranscriptSegment], meetingID: UUID) async throws -> MeetingSummary { make(segments) }
    func summarize(segments: [TranscriptSegment], bookmarkEvidence: [MeetingIntelligenceBookmarkEvidence], meetingID: UUID) async throws -> MeetingSummary { make(segments) }
    private func make(_ segments: [TranscriptSegment]) -> MeetingSummary {
        let text = segments.first?.text ?? ""
        return MeetingSummary(title: "Correction smoke", oneParagraph: text, bullets: [text], decisions: [], actionItems: [])
    }
}

private final class SmokeAudioEngine: TranscriptAudioEngine, @unchecked Sendable {
    private(set) var ranges: [TranscriptPlaybackRange] = []
    func play(audioFragments: [TranscriptPlaybackAudioDataFragment], cue: TranscriptPlaybackCue) throws {}
    func playRange(audioFragments: [TranscriptPlaybackAudioDataFragment], range: TranscriptPlaybackRange) throws { ranges.append(range) }
    func pause() throws {}
    func stop() throws {}
}

@main
private enum ConfidenceReviewSmoke {
    static func main() async {
        do {
            let output = try outputURL()
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingVault-Confidence-Review-Smoke-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let meetingID = UUID(uuidString: "51000000-0000-0000-0000-000000000001")!
            let segmentID = UUID(uuidString: "52000000-0000-0000-0000-000000000002")!
            let bundleStore = EncryptedMeetingBundleStore(
                rootDirectory: root,
                vault: AESGCMDataVault(keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 121, count: 32)))
            )
            _ = try bundleStore.createBundle(.initialEncryptedBundle(meetingID: meetingID, title: "Smoke"))
            let search = try SQLiteSearchIndex(inMemory: ())
            let meeting = SearchMeeting(id: meetingID, title: "Smoke", startedAt: Date(timeIntervalSince1970: 1_780_300_000), sourceApp: "Fixture")
            let evidence = try TranscriptSegmentEvidence(
                segmentID: segmentID, trackKind: .remoteSystem, startTime: 1, endTime: 3,
                confidence: 0.2, speakerConfidence: 0.4, overlapsSpeech: false,
                reconstructedFromPreviewGap: false, providerConfigurationVersion: "smoke-v1"
            )
            let transcript = MeetingTranscript(
                meetingID: meetingID, providerConfigurationVersion: "smoke-v1", localeIdentifier: "en-US",
                generatedAt: Date(timeIntervalSince1970: 1_780_300_010),
                segments: [TranscriptSegment(id: segmentID, speakerName: "Unknown", trackKind: .remoteSystem, startTime: 1, endTime: 3, text: "uncertain text", confidence: 0.2, isFinal: true, reviewEvidence: evidence)]
            )
            let record = MeetingRecord(id: meetingID, title: "Smoke", startedAt: meeting.startedAt, durationSeconds: 4, sourceName: "Fixture", state: .ready, consentStatus: .consented)
            try bundleStore.writeJSONArtifact(transcript, meetingID: meetingID, relativePath: MeetingTranscript.finalTranscriptRelativePath, purpose: MeetingTranscript.finalTranscriptPurpose)
            try bundleStore.writeJSONArtifact(TranscriptEditHistory(meetingID: meetingID), meetingID: meetingID, relativePath: TranscriptEditHistory.relativePath, purpose: TranscriptEditHistory.purpose)
            try bundleStore.writeJSONArtifact(record, meetingID: meetingID, relativePath: MeetingLibraryRepository.recordRelativePath, purpose: MeetingLibraryRepository.recordPurpose)
            try bundleStore.writeJSONArtifact(meeting, meetingID: meetingID, relativePath: MeetingLibraryRepository.searchMeetingRelativePath, purpose: MeetingLibraryRepository.searchMeetingPurpose)
            try search.replaceMeetingAndSegments(meeting: meeting, segments: LocalFinalTranscriptionService.searchSegments(transcript))
            let queue = try TranscriptConfidenceReviewService(now: { Date(timeIntervalSince1970: 1_780_300_020) }).deriveQueue(transcript: transcript, evidence: [evidence], transcriptVersion: 0)
            try TranscriptReviewRepository(bundleStore: bundleStore).save(queue)
            let itemID = queue.activeItems.first!.id
            let chunks = EncryptedAudioChunkWriter(bundleStore: bundleStore)
            _ = try chunks.writeChunk(Data([1, 2, 3]), meetingID: meetingID, track: .remoteSystem, chunkIndex: 0, startTime: 0, duration: 4, codec: "CAF/LPCM")
            let coordinator = TranscriptCorrectionCoordinator(
                bundleStore: bundleStore,
                searchIndex: search,
                intelligenceService: MeetingIntelligenceService(provider: SmokeIntelligenceProvider(), bundleStore: bundleStore),
                chunkWriter: chunks,
                now: { Date(timeIntervalSince1970: 1_780_300_100) }
            )
            let result = try await coordinator.applyCorrection(
                meeting: meeting,
                edits: [TranscriptSegmentEdit(segmentID: segmentID, replacementText: "Ship after QA", replacementSpeakerName: "Anna")],
                resolvedReviewItemIDs: [itemID]
            )
            let audio = SmokeAudioEngine()
            _ = try TranscriptPlaybackSessionService(chunkWriter: chunks, audioEngine: audio).playRange(startTime: 1, endTime: 3, track: .remoteSystem, in: result.playbackTimeline)
            let package = try MeetingExportService(bundleStore: bundleStore).exportPackage(meeting: meeting, to: root.appendingPathComponent("export"), formats: [.json])
            let share = try MeetingSharePreparationService(versionGate: TranscriptArtifactVersionGate(bundleStore: bundleStore)).prepareShare(meetingID: meetingID, package: package, destination: .manualCopy)
            let history = try TranscriptQuestionHistoryService(bundleStore: bundleStore).load(meetingID: meetingID)
            let markerCleared = !(try bundleStore.artifactExists(meetingID: meetingID, relativePath: TranscriptCorrectionRecoveryMarker.relativePath))
            let searchUpdated = try search.search("Ship").count == 1
            let passed = result.derivedState.isConsistent
                && result.reviewQueue.items.first(where: { $0.id == itemID })?.status == .resolved
                && !audio.ranges.isEmpty && searchUpdated
                && history.turns.isEmpty && history.invalidatedAt != nil
                && package.transcriptVersion == 1 && share.transcriptVersion == 1 && markerCleared
            let report = SmokeReport(
                status: passed ? "pass" : "fail", transcriptVersion: result.editResult.version,
                versionsConsistent: result.derivedState.isConsistent,
                reviewResolved: result.reviewQueue.items.first(where: { $0.id == itemID })?.status == .resolved,
                exactPlaybackAvailable: !audio.ranges.isEmpty, searchUpdated: searchUpdated,
                agentHistoryInvalidated: history.turns.isEmpty && history.invalidatedAt != nil,
                exportVersionBound: package.transcriptVersion == 1,
                shareVersionBound: share.transcriptVersion == 1,
                recoveryMarkerCleared: markerCleared,
                rawPrivateDataStored: false, externalNetworkRequested: false,
                issues: passed ? [] : ["confidence_review_contract_failed"]
            )
            try write(report, to: output)
            if !passed { exit(1) }
        } catch {
            fputs("confidence review smoke failed with bounded code: confidence_review_smoke_error\n", stderr)
            exit(1)
        }
    }

    private static func outputURL() throws -> URL {
        guard let index = CommandLine.arguments.firstIndex(of: "--output"),
              CommandLine.arguments.indices.contains(index + 1) else {
            throw TranscriptReviewValidationError.invalidTimeRange
        }
        return URL(fileURLWithPath: CommandLine.arguments[index + 1])
    }

    private static func write(_ report: SmokeReport, to output: URL) throws {
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: output, options: [.atomic])
    }
}
