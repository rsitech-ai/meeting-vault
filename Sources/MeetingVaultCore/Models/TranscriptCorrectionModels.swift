import Foundation

public enum TranscriptCorrectionPhase: String, Codable, Equatable, Sendable {
    case preparing
    case authoritativeCommitted
    case derivedArtifactsRegenerating
}

public struct TranscriptCorrectionRecoveryMarker: Codable, Equatable, Sendable {
    public static let relativePath = "transcript/correction-recovery.json.enc"
    public static let purpose = "transcript:correction-recovery"
    public static let schemaVersion = 1

    public var schemaVersion: Int
    public var meetingID: UUID
    public var targetTranscriptVersion: Int
    public var transcriptDigest: String?
    public var editedSegmentIDs: [UUID]
    public var resolvedReviewItemIDs: [UUID]
    public var phase: TranscriptCorrectionPhase
    public var startedAt: Date

    public init(
        meetingID: UUID,
        targetTranscriptVersion: Int,
        transcriptDigest: String? = nil,
        editedSegmentIDs: [UUID],
        resolvedReviewItemIDs: [UUID],
        phase: TranscriptCorrectionPhase = .preparing,
        startedAt: Date
    ) {
        self.schemaVersion = Self.schemaVersion
        self.meetingID = meetingID
        self.targetTranscriptVersion = targetTranscriptVersion
        self.transcriptDigest = transcriptDigest
        self.editedSegmentIDs = editedSegmentIDs.sorted { $0.uuidString < $1.uuidString }
        self.resolvedReviewItemIDs = resolvedReviewItemIDs.sorted { $0.uuidString < $1.uuidString }
        self.phase = phase
        self.startedAt = startedAt
    }
}

public struct TranscriptDerivedArtifactState: Codable, Equatable, Sendable {
    public static let relativePath = "transcript/derived-state.json.enc"
    public static let purpose = "transcript:derived-state"

    public var meetingID: UUID
    public var transcriptVersion: Int
    public var transcriptDigest: String
    public var intelligenceVersion: Int
    public var reviewVersion: Int
    public var playbackVersion: Int
    public var priorAgentAnswersInvalidatedAt: Date
    public var exportAndShareGeneration: Int

    public init(
        meetingID: UUID,
        transcriptVersion: Int,
        transcriptDigest: String,
        intelligenceVersion: Int,
        reviewVersion: Int,
        playbackVersion: Int,
        priorAgentAnswersInvalidatedAt: Date,
        exportAndShareGeneration: Int
    ) {
        self.meetingID = meetingID
        self.transcriptVersion = transcriptVersion
        self.transcriptDigest = transcriptDigest
        self.intelligenceVersion = intelligenceVersion
        self.reviewVersion = reviewVersion
        self.playbackVersion = playbackVersion
        self.priorAgentAnswersInvalidatedAt = priorAgentAnswersInvalidatedAt
        self.exportAndShareGeneration = exportAndShareGeneration
    }

    public var isConsistent: Bool {
        transcriptVersion == intelligenceVersion
            && transcriptVersion == reviewVersion
            && transcriptVersion == playbackVersion
    }
}

public struct TranscriptCorrectionResult: Equatable, Sendable {
    public var editResult: TranscriptEditResult
    public var reviewQueue: TranscriptReviewQueue
    public var playbackTimeline: TranscriptPlaybackTimeline
    public var intelligence: MeetingIntelligenceArtifact
    public var record: MeetingRecord
    public var derivedState: TranscriptDerivedArtifactState
}

public enum TranscriptCorrectionRecoveryResult: Equatable, Sendable {
    case noMarker
    case abandonedBeforeAuthoritativeCommit
    case regenerated(TranscriptCorrectionResult)
}

public enum TranscriptArtifactVersionError: Error, Equatable, LocalizedError, Sendable {
    case correctionInProgress
    case missingDerivedState
    case mixedVersions
    case staleExportOrShare
    case meetingMismatch

    public var errorDescription: String? {
        switch self {
        case .correctionInProgress: "A transcript correction is still being recovered."
        case .missingDerivedState: "Transcript-derived artifacts have not been regenerated yet."
        case .mixedVersions: "Transcript and intelligence versions do not match."
        case .staleExportOrShare: "This export or share was invalidated by a transcript correction."
        case .meetingMismatch: "A transcript-derived artifact belongs to a different meeting."
        }
    }
}

public enum TranscriptCorrectionError: Error, Equatable, LocalizedError, Sendable {
    case meetingMismatch
    case concurrentCorrection
    case incompleteProviderEvidence

    public var errorDescription: String? {
        switch self {
        case .meetingMismatch: "Correction inputs belong to different meetings."
        case .concurrentCorrection: "A transcript correction is already being recovered."
        case .incompleteProviderEvidence: "Provider evidence is incomplete, so the clean review state cannot be claimed."
        }
    }
}
