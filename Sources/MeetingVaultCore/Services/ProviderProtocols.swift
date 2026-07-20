import Foundation

public struct TranscriptionRequest: Sendable {
    public var meetingID: UUID
    public var audioChunkPath: String
    public var audioData: Data?
    public var audioCodec: String?
    public var trackKind: TrackKind?
    public var startTime: TimeInterval?
    public var duration: TimeInterval?
    public var localeIdentifier: String?
    public var expectedRemoteSpeakerCount: Int?
    public var appleSpeechRequiresOnDeviceRecognition: Bool

    public init(
        meetingID: UUID,
        audioChunkPath: String,
        audioData: Data? = nil,
        audioCodec: String? = nil,
        trackKind: TrackKind? = nil,
        startTime: TimeInterval? = nil,
        duration: TimeInterval? = nil,
        localeIdentifier: String? = nil,
        expectedRemoteSpeakerCount: Int? = nil,
        appleSpeechRequiresOnDeviceRecognition: Bool = false
    ) {
        self.meetingID = meetingID
        self.audioChunkPath = audioChunkPath
        self.audioData = audioData
        self.audioCodec = audioCodec
        self.trackKind = trackKind
        self.startTime = startTime
        self.duration = duration
        self.localeIdentifier = localeIdentifier
        self.expectedRemoteSpeakerCount = expectedRemoteSpeakerCount
        self.appleSpeechRequiresOnDeviceRecognition = appleSpeechRequiresOnDeviceRecognition
    }
}

public struct TranscriptSegment: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var speakerName: String
    public var trackKind: TrackKind
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    public var text: String
    public var confidence: Double
    public var isFinal: Bool
    public var reviewEvidence: TranscriptSegmentEvidence?

    public init(
        id: UUID = UUID(),
        speakerName: String,
        trackKind: TrackKind,
        startTime: TimeInterval,
        endTime: TimeInterval,
        text: String,
        confidence: Double,
        isFinal: Bool,
        reviewEvidence: TranscriptSegmentEvidence? = nil
    ) {
        self.id = id
        self.speakerName = speakerName
        self.trackKind = trackKind
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
        self.confidence = confidence
        self.isFinal = isFinal
        self.reviewEvidence = reviewEvidence
    }
}

public protocol TranscriptionEngine: Sendable {
    var id: String { get }
    var supportsRealtime: Bool { get }
    func transcribe(_ request: TranscriptionRequest) async throws -> [TranscriptSegment]
}

public protocol MeetingIntelligenceProvider: Sendable {
    var id: String { get }
    func summarize(segments: [TranscriptSegment], meetingID: UUID) async throws -> MeetingSummary
    func summarize(
        segments: [TranscriptSegment],
        bookmarkEvidence: [MeetingIntelligenceBookmarkEvidence],
        meetingID: UUID
    ) async throws -> MeetingSummary
}

public protocol CaptureEngine: Sendable {
    var id: String { get }
    var mode: CaptureMode { get }
    func availableSources() async throws -> [CaptureSource]
}
