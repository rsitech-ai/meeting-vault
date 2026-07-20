import Foundation

public enum TranscriptPlaybackWarningCode: String, Codable, Hashable, Sendable {
    case noTranscriptSegments
    case noAudioChunks
    case missingAudioForSegment
}

public struct TranscriptPlaybackWarning: Codable, Equatable, Hashable, Sendable {
    public var code: TranscriptPlaybackWarningCode
    public var segmentID: UUID?

    public init(code: TranscriptPlaybackWarningCode, segmentID: UUID? = nil) {
        self.code = code
        self.segmentID = segmentID
    }
}

public struct TranscriptPlaybackAudioFragment: Codable, Equatable, Sendable {
    public var audioRelativePath: String
    public var playbackStartOffset: TimeInterval
    public var playbackDuration: TimeInterval

    public init(
        audioRelativePath: String,
        playbackStartOffset: TimeInterval,
        playbackDuration: TimeInterval
    ) {
        self.audioRelativePath = audioRelativePath
        self.playbackStartOffset = max(0, playbackStartOffset)
        self.playbackDuration = max(0, playbackDuration)
    }
}

public struct TranscriptPlaybackCue: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID { segmentID }

    public var segmentID: UUID
    public var speakerName: String?
    public var trackKind: TrackKind
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    public var text: String
    public var audioFragments: [TranscriptPlaybackAudioFragment]

    public var audioRelativePath: String? {
        audioFragments.first?.audioRelativePath
    }

    public init(
        segmentID: UUID,
        speakerName: String?,
        trackKind: TrackKind,
        startTime: TimeInterval,
        endTime: TimeInterval,
        text: String,
        audioRelativePath: String?
    ) {
        self.segmentID = segmentID
        self.speakerName = speakerName
        self.trackKind = trackKind
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
        self.audioFragments = audioRelativePath.map {
            [
                TranscriptPlaybackAudioFragment(
                    audioRelativePath: $0,
                    playbackStartOffset: 0,
                    playbackDuration: max(0, endTime - startTime)
                )
            ]
        } ?? []
    }

    public init(
        segmentID: UUID,
        speakerName: String?,
        trackKind: TrackKind,
        startTime: TimeInterval,
        endTime: TimeInterval,
        text: String,
        audioFragments: [TranscriptPlaybackAudioFragment]
    ) {
        self.segmentID = segmentID
        self.speakerName = speakerName
        self.trackKind = trackKind
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
        self.audioFragments = audioFragments
    }

    public var isPlayable: Bool {
        !audioFragments.isEmpty
    }
}

public struct TranscriptPlaybackTimeline: Codable, Equatable, Sendable {
    public var meetingID: UUID
    public var duration: TimeInterval
    public var cues: [TranscriptPlaybackCue]
    public var warnings: [TranscriptPlaybackWarning]
    public var bookmarks: [MeetingBookmark]

    public init(
        meetingID: UUID,
        duration: TimeInterval,
        cues: [TranscriptPlaybackCue],
        warnings: [TranscriptPlaybackWarning],
        bookmarks: [MeetingBookmark] = []
    ) {
        self.meetingID = meetingID
        self.duration = duration
        self.cues = cues
        self.warnings = warnings
        self.bookmarks = bookmarks
    }

    public var isPlayable: Bool {
        cues.contains(where: \.isPlayable)
    }

    public func playbackRange(
        around bookmarkID: UUID,
        radius: TimeInterval = 5
    ) -> ClosedRange<TimeInterval>? {
        guard radius.isFinite,
              radius >= 0,
              let bookmark = bookmarks.first(where: { $0.id == bookmarkID }) else {
            return nil
        }
        return max(0, bookmark.timestamp - radius)...min(duration, bookmark.timestamp + radius)
    }
}

public enum TranscriptPlaybackTransportState: String, Codable, Equatable, Sendable {
    case idle
    case playing
    case paused
    case stopped
    case failed
}

public struct TranscriptPlaybackSessionState: Codable, Equatable, Sendable {
    public var meetingID: UUID
    public var selectedCueID: UUID?
    public var currentTime: TimeInterval
    public var transportState: TranscriptPlaybackTransportState
    public var statusMessage: String

    public init(
        meetingID: UUID,
        selectedCueID: UUID? = nil,
        currentTime: TimeInterval = 0,
        transportState: TranscriptPlaybackTransportState = .idle,
        statusMessage: String = "Playback ready"
    ) {
        self.meetingID = meetingID
        self.selectedCueID = selectedCueID
        self.currentTime = currentTime
        self.transportState = transportState
        self.statusMessage = statusMessage
    }

    public static func idle(for timeline: TranscriptPlaybackTimeline) -> TranscriptPlaybackSessionState {
        TranscriptPlaybackSessionState(
            meetingID: timeline.meetingID,
            selectedCueID: nil,
            currentTime: 0,
            transportState: timeline.isPlayable ? .idle : .failed,
            statusMessage: timeline.isPlayable ? "Playback ready" : "No playable audio cues"
        )
    }
}

public enum TranscriptPlaybackSessionError: Error, Equatable {
    case timelineNotPlayable(UUID)
    case cueNotFound(UUID)
    case cueMissingAudio(UUID)
    case audioDataUnavailable(String)
    case audioEngineFailed(String)
    case invalidRange
    case rangeHasNoTranscriptCue
    case rangeHasAudioGap
}
