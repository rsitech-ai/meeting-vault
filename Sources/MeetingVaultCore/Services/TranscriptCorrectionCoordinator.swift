import Foundation

public actor TranscriptCorrectionCoordinator {
    private let bundleStore: EncryptedMeetingBundleStore
    private let searchIndex: SQLiteSearchIndex
    private let intelligenceService: MeetingIntelligenceService
    private let chunkWriter: EncryptedAudioChunkWriter
    private let auditWriter: PrivacyAuditLogWriter?
    private let now: @Sendable () -> Date
    private let afterAuthoritativeCommit: @Sendable () throws -> Void
    private let beforeDerivedArtifactRegeneration: @Sendable (UUID) async throws -> Void

    public init(
        bundleStore: EncryptedMeetingBundleStore,
        searchIndex: SQLiteSearchIndex,
        intelligenceService: MeetingIntelligenceService,
        chunkWriter: EncryptedAudioChunkWriter,
        auditWriter: PrivacyAuditLogWriter? = nil,
        now: @escaping @Sendable () -> Date = Date.init,
        afterAuthoritativeCommit: @escaping @Sendable () throws -> Void = {},
        beforeDerivedArtifactRegeneration: @escaping @Sendable (UUID) async throws -> Void = { _ in }
    ) {
        self.bundleStore = bundleStore
        self.searchIndex = searchIndex
        self.intelligenceService = intelligenceService
        self.chunkWriter = chunkWriter
        self.auditWriter = auditWriter
        self.now = now
        self.afterAuthoritativeCommit = afterAuthoritativeCommit
        self.beforeDerivedArtifactRegeneration = beforeDerivedArtifactRegeneration
    }

    public func applyCorrection(
        meeting: SearchMeeting,
        edits: [TranscriptSegmentEdit],
        resolvedReviewItemIDs: [UUID] = []
    ) async throws -> TranscriptCorrectionResult {
        guard !edits.isEmpty else { throw TranscriptEditError.emptyEdits }
        guard !(try bundleStore.artifactExists(
            meetingID: meeting.id,
            relativePath: TranscriptCorrectionRecoveryMarker.relativePath
        )) else {
            throw TranscriptCorrectionError.concurrentCorrection
        }
        let history = try loadHistory(meetingID: meeting.id)
        var marker = TranscriptCorrectionRecoveryMarker(
            meetingID: meeting.id,
            targetTranscriptVersion: history.latestVersion + 1,
            editedSegmentIDs: edits.map(\.segmentID),
            resolvedReviewItemIDs: resolvedReviewItemIDs,
            startedAt: now()
        )
        try saveMarker(marker)

        let editResult = try TranscriptEditingService(
            bundleStore: bundleStore,
            searchIndex: searchIndex,
            auditWriter: auditWriter,
            now: now
        ).applyEdits(meeting: meeting, edits: edits, updateSearchIndex: false)
        guard editResult.transcript.meetingID == meeting.id,
              editResult.version == marker.targetTranscriptVersion else {
            throw TranscriptCorrectionError.meetingMismatch
        }
        marker.phase = .authoritativeCommitted
        marker.transcriptDigest = try LocalFinalTranscriptionService.transcriptDigest(editResult.transcript)
        try saveMarker(marker)
        try afterAuthoritativeCommit()
        marker.phase = .derivedArtifactsRegenerating
        try saveMarker(marker)
        try await beforeDerivedArtifactRegeneration(meeting.id)
        return try await regenerate(meeting: meeting, marker: marker, transcript: editResult.transcript)
    }

    public func recoverIfNeeded(meeting: SearchMeeting) async throws -> TranscriptCorrectionRecoveryResult {
        guard try bundleStore.artifactExists(
            meetingID: meeting.id,
            relativePath: TranscriptCorrectionRecoveryMarker.relativePath
        ) else { return .noMarker }
        let marker = try loadMarker(meetingID: meeting.id)
        guard marker.schemaVersion == TranscriptCorrectionRecoveryMarker.schemaVersion,
              marker.meetingID == meeting.id else {
            throw TranscriptCorrectionError.meetingMismatch
        }
        let transcript = try bundleStore.readJSONArtifact(
            MeetingTranscript.self,
            meetingID: meeting.id,
            relativePath: MeetingTranscript.finalTranscriptRelativePath,
            purpose: MeetingTranscript.finalTranscriptPurpose
        )
        guard transcript.meetingID == meeting.id else { throw TranscriptCorrectionError.meetingMismatch }
        guard transcript.transcriptVersion >= marker.targetTranscriptVersion else {
            try bundleStore.deleteArtifact(
                meetingID: meeting.id,
                relativePath: TranscriptCorrectionRecoveryMarker.relativePath
            )
            return .abandonedBeforeAuthoritativeCommit
        }
        var resumable = marker
        resumable.phase = .derivedArtifactsRegenerating
        resumable.transcriptDigest = try LocalFinalTranscriptionService.transcriptDigest(transcript)
        try repairHistoryIfNeeded(marker: resumable, transcript: transcript)
        try saveMarker(resumable)
        try await beforeDerivedArtifactRegeneration(meeting.id)
        return .regenerated(try await regenerate(meeting: meeting, marker: resumable, transcript: transcript))
    }

    private func regenerate(
        meeting: SearchMeeting,
        marker: TranscriptCorrectionRecoveryMarker,
        transcript: MeetingTranscript
    ) async throws -> TranscriptCorrectionResult {
        let digest = try LocalFinalTranscriptionService.transcriptDigest(transcript)
        guard transcript.meetingID == meeting.id,
              transcript.transcriptVersion == marker.targetTranscriptVersion,
              marker.transcriptDigest == digest else {
            throw TranscriptArtifactVersionError.mixedVersions
        }
        try searchIndex.replaceMeetingAndSegments(
            meeting: meeting,
            segments: LocalFinalTranscriptionService.searchSegments(transcript)
        )

        let reviewRepository = TranscriptReviewRepository(bundleStore: bundleStore)
        let previousReview = try reviewRepository.loadIfPresent(meetingID: meeting.id)
        var review = try TranscriptConfidenceReviewService(now: now).deriveQueue(
            transcript: transcript,
            evidence: transcript.segments.compactMap { $0.reviewEvidence },
            transcriptVersion: transcript.transcriptVersion,
            previous: previousReview
        )
        for itemID in marker.resolvedReviewItemIDs where review.items.contains(where: { $0.id == itemID }) {
            try review.updateStatus(itemID: itemID, status: .resolved)
        }
        try reviewRepository.save(review)

        let intelligence = try await intelligenceService.generateSummary(meetingID: meeting.id)
        guard intelligence.transcriptVersion == transcript.transcriptVersion,
              intelligence.transcriptDigest == digest else {
            throw TranscriptArtifactVersionError.mixedVersions
        }

        var record = try bundleStore.readJSONArtifact(
            MeetingRecord.self,
            meetingID: meeting.id,
            relativePath: MeetingLibraryRepository.recordRelativePath,
            purpose: MeetingLibraryRepository.recordPurpose
        )
        guard record.id == meeting.id else { throw TranscriptCorrectionError.meetingMismatch }
        record.summary = intelligence.summary
        try bundleStore.writeJSONArtifact(
            record,
            meetingID: meeting.id,
            relativePath: MeetingLibraryRepository.recordRelativePath,
            purpose: MeetingLibraryRepository.recordPurpose
        )

        let invalidatedAt = now()
        try TranscriptQuestionHistoryService(bundleStore: bundleStore).save(
            TranscriptQuestionHistory(
                meetingID: meeting.id,
                transcriptVersion: transcript.transcriptVersion,
                transcriptDigest: digest,
                invalidatedAt: invalidatedAt,
                turns: []
            )
        )
        let audioChunks = try TrackKind.allCases.flatMap {
            try chunkWriter.readCheckpoint(meetingID: meeting.id, track: $0).chunks
        }
        let playback = TranscriptPlaybackTimelineService().buildTimeline(
            transcript: transcript,
            audioChunks: audioChunks
        )
        let priorGeneration: Int
        if try bundleStore.artifactExists(meetingID: meeting.id, relativePath: TranscriptDerivedArtifactState.relativePath) {
            let prior = try bundleStore.readJSONArtifact(
                TranscriptDerivedArtifactState.self,
                meetingID: meeting.id,
                relativePath: TranscriptDerivedArtifactState.relativePath,
                purpose: TranscriptDerivedArtifactState.purpose
            )
            priorGeneration = prior.exportAndShareGeneration
        } else {
            priorGeneration = 0
        }
        let state = TranscriptDerivedArtifactState(
            meetingID: meeting.id,
            transcriptVersion: transcript.transcriptVersion,
            transcriptDigest: digest,
            intelligenceVersion: intelligence.transcriptVersion,
            reviewVersion: review.transcriptVersion,
            playbackVersion: transcript.transcriptVersion,
            priorAgentAnswersInvalidatedAt: invalidatedAt,
            exportAndShareGeneration: priorGeneration + 1
        )
        guard state.isConsistent else { throw TranscriptArtifactVersionError.mixedVersions }
        try bundleStore.writeJSONArtifact(
            state,
            meetingID: meeting.id,
            relativePath: TranscriptDerivedArtifactState.relativePath,
            purpose: TranscriptDerivedArtifactState.purpose
        )
        try bundleStore.deleteArtifact(
            meetingID: meeting.id,
            relativePath: TranscriptCorrectionRecoveryMarker.relativePath
        )
        return TranscriptCorrectionResult(
            editResult: TranscriptEditResult(
                transcript: transcript,
                editedSegmentCount: marker.editedSegmentIDs.count,
                version: transcript.transcriptVersion
            ),
            reviewQueue: review,
            playbackTimeline: playback,
            intelligence: intelligence,
            record: record,
            derivedState: state
        )
    }

    private func repairHistoryIfNeeded(
        marker: TranscriptCorrectionRecoveryMarker,
        transcript: MeetingTranscript
    ) throws {
        var history = try loadHistory(meetingID: marker.meetingID)
        guard history.latestVersion < transcript.transcriptVersion else { return }
        guard history.latestVersion + 1 == transcript.transcriptVersion else {
            throw TranscriptArtifactVersionError.mixedVersions
        }
        history.entries.append(
            TranscriptEditHistoryEntry(
                version: transcript.transcriptVersion,
                editedAt: transcript.editedAt ?? marker.startedAt,
                editedSegmentIDs: marker.editedSegmentIDs
            )
        )
        try bundleStore.writeJSONArtifact(
            history,
            meetingID: marker.meetingID,
            relativePath: TranscriptEditHistory.relativePath,
            purpose: TranscriptEditHistory.purpose
        )
    }

    private func loadHistory(meetingID: UUID) throws -> TranscriptEditHistory {
        guard try bundleStore.artifactExists(meetingID: meetingID, relativePath: TranscriptEditHistory.relativePath) else {
            return TranscriptEditHistory(meetingID: meetingID)
        }
        let history = try bundleStore.readJSONArtifact(
            TranscriptEditHistory.self,
            meetingID: meetingID,
            relativePath: TranscriptEditHistory.relativePath,
            purpose: TranscriptEditHistory.purpose
        )
        guard history.meetingID == meetingID else { throw TranscriptCorrectionError.meetingMismatch }
        return history
    }

    private func saveMarker(_ marker: TranscriptCorrectionRecoveryMarker) throws {
        try bundleStore.writeJSONArtifact(
            marker,
            meetingID: marker.meetingID,
            relativePath: TranscriptCorrectionRecoveryMarker.relativePath,
            purpose: TranscriptCorrectionRecoveryMarker.purpose
        )
    }

    private func loadMarker(meetingID: UUID) throws -> TranscriptCorrectionRecoveryMarker {
        try bundleStore.readJSONArtifact(
            TranscriptCorrectionRecoveryMarker.self,
            meetingID: meetingID,
            relativePath: TranscriptCorrectionRecoveryMarker.relativePath,
            purpose: TranscriptCorrectionRecoveryMarker.purpose
        )
    }
}
