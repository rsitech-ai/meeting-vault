import Foundation

public enum TranscriptPreviewEvidenceError: Error, Equatable, Sendable {
    case invalidRange
    case emptySpeakerName
}

public struct TranscriptPreviewGap: Codable, Equatable, Hashable, Sendable {
    public var track: TrackKind
    public var startTime: TimeInterval
    public var endTime: TimeInterval

    public init(track: TrackKind, startTime: TimeInterval, endTime: TimeInterval) throws {
        guard startTime.isFinite, endTime.isFinite, startTime >= 0, endTime > startTime else {
            throw TranscriptPreviewEvidenceError.invalidRange
        }
        self.track = track
        self.startTime = startTime
        self.endTime = endTime
    }

    public func intersects(track: TrackKind, startTime: TimeInterval, endTime: TimeInterval) -> Bool {
        self.track == track && min(self.endTime, endTime) > max(self.startTime, startTime)
    }
}

public struct TranscriptPreviewSpeakerIdentity: Codable, Equatable, Hashable, Sendable {
    public var track: TrackKind
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    public var speakerName: String

    public init(
        track: TrackKind,
        startTime: TimeInterval,
        endTime: TimeInterval,
        speakerName: String
    ) throws {
        guard startTime.isFinite, endTime.isFinite, startTime >= 0, endTime > startTime else {
            throw TranscriptPreviewEvidenceError.invalidRange
        }
        let name = speakerName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw TranscriptPreviewEvidenceError.emptySpeakerName }
        self.track = track
        self.startTime = startTime
        self.endTime = endTime
        self.speakerName = name
    }

    public func intersects(track: TrackKind, startTime: TimeInterval, endTime: TimeInterval) -> Bool {
        self.track == track && min(self.endTime, endTime) > max(self.startTime, startTime)
    }
}

public struct TranscriptPreviewEvidence: Codable, Equatable, Sendable {
    public var gaps: [TranscriptPreviewGap]
    public var speakerIdentities: [TranscriptPreviewSpeakerIdentity]

    public init(
        gaps: [TranscriptPreviewGap] = [],
        speakerIdentities: [TranscriptPreviewSpeakerIdentity] = []
    ) {
        self.gaps = gaps.sorted(by: Self.gapOrder)
        self.speakerIdentities = speakerIdentities.sorted(by: Self.speakerOrder)
    }

    public static let empty = TranscriptPreviewEvidence()

    private static func gapOrder(_ lhs: TranscriptPreviewGap, _ rhs: TranscriptPreviewGap) -> Bool {
        if lhs.startTime != rhs.startTime { return lhs.startTime < rhs.startTime }
        if lhs.endTime != rhs.endTime { return lhs.endTime < rhs.endTime }
        return String(describing: lhs.track) < String(describing: rhs.track)
    }

    private static func speakerOrder(
        _ lhs: TranscriptPreviewSpeakerIdentity,
        _ rhs: TranscriptPreviewSpeakerIdentity
    ) -> Bool {
        if lhs.startTime != rhs.startTime { return lhs.startTime < rhs.startTime }
        if lhs.endTime != rhs.endTime { return lhs.endTime < rhs.endTime }
        return lhs.speakerName < rhs.speakerName
    }
}

public final class TranscriptPreviewCoverageTracker: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumItemsPerKind: Int
    private var gaps: [TranscriptPreviewGap] = []
    private var speakers: [TranscriptPreviewSpeakerIdentity] = []
    private var gapSet: Set<TranscriptPreviewGap> = []
    private var speakerSet: Set<TranscriptPreviewSpeakerIdentity> = []

    public init() {
        maximumItemsPerKind = RecordingSessionMetadata.maximumPreviewEvidenceItems
    }

    init(maximumItemsPerKind: Int) {
        self.maximumItemsPerKind = max(1, maximumItemsPerKind)
    }

    public func recordDroppedFrame(_ frame: CapturedPCMFrame) {
        let duration = Double(frame.frameCount) / frame.sampleRate
        guard let gap = try? TranscriptPreviewGap(
            track: frame.track,
            startTime: frame.meetingTime,
            endTime: frame.meetingTime + duration
        ) else { return }
        lock.withLock {
            guard gaps.count < maximumItemsPerKind, gapSet.insert(gap).inserted else { return }
            gaps.append(gap)
        }
    }

    public func recordSpeakerIdentity(_ identity: TranscriptPreviewSpeakerIdentity) {
        lock.withLock {
            guard speakers.count < maximumItemsPerKind,
                  speakerSet.insert(identity).inserted else { return }
            speakers.append(identity)
        }
    }

    public func snapshot() -> TranscriptPreviewEvidence {
        lock.withLock { TranscriptPreviewEvidence(gaps: gaps, speakerIdentities: speakers) }
    }
}
