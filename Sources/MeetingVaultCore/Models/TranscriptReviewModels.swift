import Foundation

public enum TranscriptReviewValidationError: Error, Equatable, LocalizedError, Sendable {
    case invalidConfidence
    case invalidTimeRange
    case emptyProviderConfigurationVersion
    case invalidTranscriptVersion
    case duplicateSegmentID
    case evidenceSegmentMismatch
    case itemNotFound(UUID)
    case invalidStatusTransition

    public var errorDescription: String? {
        switch self {
        case .invalidConfidence: "Confidence must be finite and between zero and one."
        case .invalidTimeRange: "Review evidence must have a finite, non-negative time range."
        case .emptyProviderConfigurationVersion: "Review evidence must identify its provider configuration."
        case .invalidTranscriptVersion: "Transcript review versions cannot be negative."
        case .duplicateSegmentID: "Transcript review evidence contains a duplicate segment identity."
        case .evidenceSegmentMismatch: "Transcript review evidence does not match the authoritative segment."
        case .itemNotFound: "The transcript review item no longer exists."
        case .invalidStatusTransition: "That transcript review status transition is not allowed."
        }
    }
}

public struct TranscriptSegmentEvidence: Codable, Equatable, Sendable {
    public var segmentID: UUID
    public var trackKind: TrackKind
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    public var confidence: Double?
    public var speakerConfidence: Double?
    public var overlapsSpeech: Bool
    public var reconstructedFromPreviewGap: Bool
    public var speakerWasRevised: Bool
    public var providerConfigurationVersion: String

    public init(
        segmentID: UUID,
        trackKind: TrackKind,
        startTime: TimeInterval,
        endTime: TimeInterval,
        confidence: Double?,
        speakerConfidence: Double?,
        overlapsSpeech: Bool,
        reconstructedFromPreviewGap: Bool,
        speakerWasRevised: Bool = false,
        providerConfigurationVersion: String
    ) throws {
        guard startTime.isFinite, endTime.isFinite, startTime >= 0, endTime > startTime else {
            throw TranscriptReviewValidationError.invalidTimeRange
        }
        guard Self.isValidConfidence(confidence), Self.isValidConfidence(speakerConfidence) else {
            throw TranscriptReviewValidationError.invalidConfidence
        }
        let version = providerConfigurationVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !version.isEmpty else {
            throw TranscriptReviewValidationError.emptyProviderConfigurationVersion
        }
        self.segmentID = segmentID
        self.trackKind = trackKind
        self.startTime = startTime
        self.endTime = endTime
        self.confidence = confidence
        self.speakerConfidence = speakerConfidence
        self.overlapsSpeech = overlapsSpeech
        self.reconstructedFromPreviewGap = reconstructedFromPreviewGap
        self.speakerWasRevised = speakerWasRevised
        self.providerConfigurationVersion = version
    }

    private enum CodingKeys: String, CodingKey {
        case segmentID, trackKind, startTime, endTime, confidence, speakerConfidence
        case overlapsSpeech, reconstructedFromPreviewGap, speakerWasRevised
        case providerConfigurationVersion
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            segmentID: container.decode(UUID.self, forKey: .segmentID),
            trackKind: container.decode(TrackKind.self, forKey: .trackKind),
            startTime: container.decode(TimeInterval.self, forKey: .startTime),
            endTime: container.decode(TimeInterval.self, forKey: .endTime),
            confidence: container.decodeIfPresent(Double.self, forKey: .confidence),
            speakerConfidence: container.decodeIfPresent(Double.self, forKey: .speakerConfidence),
            overlapsSpeech: container.decode(Bool.self, forKey: .overlapsSpeech),
            reconstructedFromPreviewGap: container.decode(Bool.self, forKey: .reconstructedFromPreviewGap),
            speakerWasRevised: container.decodeIfPresent(Bool.self, forKey: .speakerWasRevised) ?? false,
            providerConfigurationVersion: container.decode(String.self, forKey: .providerConfigurationVersion)
        )
    }

    private static func isValidConfidence(_ value: Double?) -> Bool {
        guard let value else { return true }
        return value.isFinite && (0...1).contains(value)
    }
}

public enum TranscriptReviewReason: String, Codable, CaseIterable, Hashable, Sendable {
    case lowConfidence
    case uncertainSpeaker
    case revisedSpeaker
    case overlap
    case reconstructedPreviewGap
}

public enum TranscriptReviewStatus: String, Codable, CaseIterable, Sendable {
    case needsReview
    case resolved
    case deferred
    case superseded
}

public struct TranscriptReviewItem: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var segmentID: UUID?
    public var trackKind: TrackKind
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    public var reason: TranscriptReviewReason
    public var confidence: Double?
    public var status: TranscriptReviewStatus
    public var transcriptVersion: Int
    public var providerConfigurationVersion: String

    public init(
        id: UUID,
        segmentID: UUID?,
        trackKind: TrackKind,
        startTime: TimeInterval,
        endTime: TimeInterval,
        reason: TranscriptReviewReason,
        confidence: Double?,
        status: TranscriptReviewStatus,
        transcriptVersion: Int,
        providerConfigurationVersion: String
    ) throws {
        guard startTime.isFinite, endTime.isFinite, startTime >= 0, endTime > startTime else {
            throw TranscriptReviewValidationError.invalidTimeRange
        }
        guard confidence.map({ $0.isFinite && (0...1).contains($0) }) ?? true else {
            throw TranscriptReviewValidationError.invalidConfidence
        }
        guard transcriptVersion >= 0 else { throw TranscriptReviewValidationError.invalidTranscriptVersion }
        let providerVersion = providerConfigurationVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !providerVersion.isEmpty else { throw TranscriptReviewValidationError.emptyProviderConfigurationVersion }
        self.id = id
        self.segmentID = segmentID
        self.trackKind = trackKind
        self.startTime = startTime
        self.endTime = endTime
        self.reason = reason
        self.confidence = confidence
        self.status = status
        self.transcriptVersion = transcriptVersion
        self.providerConfigurationVersion = providerVersion
    }

    private enum CodingKeys: String, CodingKey {
        case id, segmentID, trackKind, startTime, endTime, reason, confidence, status
        case transcriptVersion, providerConfigurationVersion
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(UUID.self, forKey: .id),
            segmentID: container.decodeIfPresent(UUID.self, forKey: .segmentID),
            trackKind: container.decode(TrackKind.self, forKey: .trackKind),
            startTime: container.decode(TimeInterval.self, forKey: .startTime),
            endTime: container.decode(TimeInterval.self, forKey: .endTime),
            reason: container.decode(TranscriptReviewReason.self, forKey: .reason),
            confidence: container.decodeIfPresent(Double.self, forKey: .confidence),
            status: container.decode(TranscriptReviewStatus.self, forKey: .status),
            transcriptVersion: container.decode(Int.self, forKey: .transcriptVersion),
            providerConfigurationVersion: container.decode(String.self, forKey: .providerConfigurationVersion)
        )
    }
}

public struct TranscriptReviewQueue: Codable, Equatable, Sendable {
    public static let relativePath = "transcript/review.json.enc"
    public static let purpose = "transcript:review"
    public static let schemaVersion = 1

    public var schemaVersion: Int
    public var meetingID: UUID
    public var transcriptDigest: String
    public var transcriptVersion: Int
    public var evidenceComplete: Bool
    public var generatedAt: Date
    public var items: [TranscriptReviewItem]

    public init(
        meetingID: UUID,
        transcriptDigest: String,
        transcriptVersion: Int,
        evidenceComplete: Bool,
        generatedAt: Date,
        items: [TranscriptReviewItem]
    ) throws {
        guard transcriptVersion >= 0 else { throw TranscriptReviewValidationError.invalidTranscriptVersion }
        self.schemaVersion = Self.schemaVersion
        self.meetingID = meetingID
        self.transcriptDigest = transcriptDigest
        self.transcriptVersion = transcriptVersion
        self.evidenceComplete = evidenceComplete
        self.generatedAt = generatedAt
        self.items = items.sorted(by: Self.itemOrder)
    }

    public var activeItems: [TranscriptReviewItem] {
        items.filter { $0.status != .superseded }
    }

    public var pendingItems: [TranscriptReviewItem] {
        activeItems.filter { $0.status == .needsReview || $0.status == .deferred }
    }

    public mutating func updateStatus(itemID: UUID, status: TranscriptReviewStatus) throws {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else {
            throw TranscriptReviewValidationError.itemNotFound(itemID)
        }
        guard items[index].status != .superseded, status != .superseded else {
            throw TranscriptReviewValidationError.invalidStatusTransition
        }
        items[index].status = status
    }

    public func validated(expectedMeetingID: UUID) throws -> Self {
        guard schemaVersion == Self.schemaVersion, meetingID == expectedMeetingID else {
            throw TranscriptReviewRepositoryError.meetingMismatch
        }
        guard transcriptVersion >= 0 else { throw TranscriptReviewValidationError.invalidTranscriptVersion }
        return self
    }

    static func itemOrder(_ lhs: TranscriptReviewItem, _ rhs: TranscriptReviewItem) -> Bool {
        if lhs.startTime != rhs.startTime { return lhs.startTime < rhs.startTime }
        if lhs.endTime != rhs.endTime { return lhs.endTime < rhs.endTime }
        if lhs.reason.rawValue != rhs.reason.rawValue { return lhs.reason.rawValue < rhs.reason.rawValue }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

public enum TranscriptReviewRepositoryError: Error, Equatable, Sendable {
    case meetingMismatch
    case queueNotFound
}
