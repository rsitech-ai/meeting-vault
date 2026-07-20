import Foundation

public struct SearchMeeting: Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var startedAt: Date
    public var sourceApp: String

    public init(id: UUID, title: String, startedAt: Date, sourceApp: String) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.sourceApp = sourceApp
    }
}

public struct SearchTranscriptSegment: Codable, Equatable, Sendable {
    public var id: UUID
    public var meetingID: UUID
    public var speakerName: String
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    public var text: String
    public var confidence: Double
    public var isFinal: Bool

    public init(
        id: UUID,
        meetingID: UUID,
        speakerName: String,
        startTime: TimeInterval,
        endTime: TimeInterval,
        text: String,
        confidence: Double,
        isFinal: Bool
    ) {
        self.id = id
        self.meetingID = meetingID
        self.speakerName = speakerName
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
        self.confidence = confidence
        self.isFinal = isFinal
    }
}

public struct TranscriptSearchResult: Codable, Equatable, Sendable {
    public var segmentID: UUID
    public var meetingID: UUID
    public var meetingTitle: String
    public var speakerName: String
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    public var text: String

    public init(
        segmentID: UUID,
        meetingID: UUID,
        meetingTitle: String,
        speakerName: String,
        startTime: TimeInterval,
        endTime: TimeInterval,
        text: String
    ) {
        self.segmentID = segmentID
        self.meetingID = meetingID
        self.meetingTitle = meetingTitle
        self.speakerName = speakerName
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
    }
}
