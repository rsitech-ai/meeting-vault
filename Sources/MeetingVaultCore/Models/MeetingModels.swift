import Foundation

public enum RecordingState: String, Codable, CaseIterable, Sendable {
    case idle
    case ready
    case recording
    case paused
    case processing
    case permissionNeeded
    case error
    case recovered
}

public enum CaptureMode: String, Codable, CaseIterable, Sendable {
    case selectedApplication
    case processGroup
    case systemAudio
    case outputDevice
    case microphone
    case screenCaptureFallback
}

public enum TrackKind: String, Codable, CaseIterable, Sendable {
    case remoteSystem
    case microphone
    case mixedPlayback
}

public enum ConsentStatus: String, Codable, CaseIterable, Sendable {
    case unknown
    case disclosed
    case consented
    case internalOnly
    case doNotRecord
}

public enum MeetingArtifactKind: String, Codable, CaseIterable, Sendable {
    case executiveSummary
    case detailedSummary
    case timeline
    case decision
    case actionItem
    case openQuestion
    case risk
    case followUp
    case transcript
}

public struct CaptureSource: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var displayName: String
    public var bundleIdentifier: String?
    public var mode: CaptureMode
    public var isRecommended: Bool
    public var level: Double

    public init(
        id: String,
        displayName: String,
        bundleIdentifier: String? = nil,
        mode: CaptureMode,
        isRecommended: Bool = false,
        level: Double = 0
    ) {
        self.id = id
        self.displayName = displayName
        self.bundleIdentifier = bundleIdentifier
        self.mode = mode
        self.isRecommended = isRecommended
        self.level = level
    }
}

public struct EvidenceRef: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var meetingID: UUID
    public var segmentID: UUID
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    public var quote: String

    public init(
        id: UUID = UUID(),
        meetingID: UUID,
        segmentID: UUID,
        startTime: TimeInterval,
        endTime: TimeInterval,
        quote: String
    ) {
        self.id = id
        self.meetingID = meetingID
        self.segmentID = segmentID
        self.startTime = startTime
        self.endTime = endTime
        self.quote = quote
    }
}

public struct ActionItem: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var ownerName: String?
    public var dueDate: Date?
    public var evidence: [EvidenceRef]
    public var confidence: Double

    public init(
        id: UUID = UUID(),
        title: String,
        ownerName: String? = nil,
        dueDate: Date? = nil,
        evidence: [EvidenceRef],
        confidence: Double
    ) {
        self.id = id
        self.title = title
        self.ownerName = ownerName
        self.dueDate = dueDate
        self.evidence = evidence
        self.confidence = confidence
    }
}

public struct Decision: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var details: String
    public var evidence: [EvidenceRef]
    public var confidence: Double

    public init(
        id: UUID = UUID(),
        title: String,
        details: String,
        evidence: [EvidenceRef],
        confidence: Double
    ) {
        self.id = id
        self.title = title
        self.details = details
        self.evidence = evidence
        self.confidence = confidence
    }
}

public struct OpenQuestion: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var question: String
    public var context: String
    public var evidence: [EvidenceRef]
    public var confidence: Double

    public init(
        id: UUID = UUID(),
        question: String,
        context: String,
        evidence: [EvidenceRef],
        confidence: Double
    ) {
        self.id = id
        self.question = question
        self.context = context
        self.evidence = evidence
        self.confidence = confidence
    }
}

public enum MeetingRiskSeverity: String, Codable, CaseIterable, Equatable, Sendable {
    case low
    case medium
    case high
    case critical
}

public struct MeetingRisk: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var details: String
    public var severity: MeetingRiskSeverity
    public var evidence: [EvidenceRef]
    public var confidence: Double

    public init(
        id: UUID = UUID(),
        title: String,
        details: String,
        severity: MeetingRiskSeverity,
        evidence: [EvidenceRef],
        confidence: Double
    ) {
        self.id = id
        self.title = title
        self.details = details
        self.severity = severity
        self.evidence = evidence
        self.confidence = confidence
    }
}

public struct MeetingSummary: Codable, Equatable, Sendable {
    public var title: String
    public var oneParagraph: String
    public var bullets: [String]
    public var decisions: [Decision]
    public var actionItems: [ActionItem]
    public var openQuestions: [OpenQuestion]
    public var risks: [MeetingRisk]

    public init(
        title: String,
        oneParagraph: String,
        bullets: [String],
        decisions: [Decision],
        actionItems: [ActionItem],
        openQuestions: [OpenQuestion] = [],
        risks: [MeetingRisk] = []
    ) {
        self.title = title
        self.oneParagraph = oneParagraph
        self.bullets = bullets
        self.decisions = decisions
        self.actionItems = actionItems
        self.openQuestions = openQuestions
        self.risks = risks
    }

    private enum CodingKeys: String, CodingKey {
        case title
        case oneParagraph
        case bullets
        case decisions
        case actionItems
        case openQuestions
        case risks
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        oneParagraph = try container.decode(String.self, forKey: .oneParagraph)
        bullets = try container.decode([String].self, forKey: .bullets)
        decisions = try container.decode([Decision].self, forKey: .decisions)
        actionItems = try container.decode([ActionItem].self, forKey: .actionItems)
        openQuestions = try container.decodeIfPresent([OpenQuestion].self, forKey: .openQuestions) ?? []
        risks = try container.decodeIfPresent([MeetingRisk].self, forKey: .risks) ?? []
    }
}

public struct MeetingRecord: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var startedAt: Date
    public var durationSeconds: TimeInterval
    public var sourceName: String
    public var state: RecordingState
    public var consentStatus: ConsentStatus
    public var summary: MeetingSummary?

    public init(
        id: UUID = UUID(),
        title: String,
        startedAt: Date,
        durationSeconds: TimeInterval,
        sourceName: String,
        state: RecordingState,
        consentStatus: ConsentStatus,
        summary: MeetingSummary? = nil
    ) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.durationSeconds = durationSeconds
        self.sourceName = sourceName
        self.state = state
        self.consentStatus = consentStatus
        self.summary = summary
    }
}
