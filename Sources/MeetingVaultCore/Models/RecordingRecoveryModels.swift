import Foundation

public enum RecordingRecoveryWarning: String, Codable, Hashable, Sendable {
    case noAudioChunks
    case finalTranscriptMissing
    case summaryMissing
    case sessionMetadataMissing
    case sessionMetadataCorrupt
}

public struct RecoveredTrackReport: Codable, Equatable, Sendable {
    public var track: TrackKind
    public var chunkCount: Int
    public var totalDuration: TimeInterval
    public var firstStartTime: TimeInterval?
    public var lastEndTime: TimeInterval?

    public init(
        track: TrackKind,
        chunkCount: Int,
        totalDuration: TimeInterval,
        firstStartTime: TimeInterval?,
        lastEndTime: TimeInterval?
    ) {
        self.track = track
        self.chunkCount = chunkCount
        self.totalDuration = totalDuration
        self.firstStartTime = firstStartTime
        self.lastEndTime = lastEndTime
    }
}

public struct RecoveredRecordingReport: Codable, Equatable, Sendable {
    public var meetingID: UUID
    public var title: String
    public var createdAt: Date
    public var trackReports: [RecoveredTrackReport]
    public var hasFinalTranscript: Bool
    public var hasSummary: Bool
    public var warnings: Set<RecordingRecoveryWarning>
    public var bookmarks: [MeetingBookmark]

    public init(
        meetingID: UUID,
        title: String,
        createdAt: Date,
        trackReports: [RecoveredTrackReport],
        hasFinalTranscript: Bool,
        hasSummary: Bool,
        warnings: Set<RecordingRecoveryWarning>,
        bookmarks: [MeetingBookmark] = []
    ) {
        self.meetingID = meetingID
        self.title = title
        self.createdAt = createdAt
        self.trackReports = trackReports
        self.hasFinalTranscript = hasFinalTranscript
        self.hasSummary = hasSummary
        self.warnings = warnings
        self.bookmarks = bookmarks
    }

    public var totalRecordedDuration: TimeInterval {
        trackReports
            .compactMap(\.lastEndTime)
            .max() ?? 0
    }

    public var severity: DiagnosticSeverity {
        warnings.isEmpty ? .healthy : .warning
    }
}
