import Foundation

public struct AudioChunkRecord: Codable, Equatable, Sendable {
    public var track: TrackKind
    public var chunkIndex: Int
    public var relativePath: String
    public var startTime: TimeInterval
    public var duration: TimeInterval
    public var byteCount: Int
    public var codec: String
    public var encrypted: Bool

    public init(
        track: TrackKind,
        chunkIndex: Int,
        relativePath: String,
        startTime: TimeInterval,
        duration: TimeInterval,
        byteCount: Int,
        codec: String,
        encrypted: Bool
    ) {
        self.track = track
        self.chunkIndex = chunkIndex
        self.relativePath = relativePath
        self.startTime = startTime
        self.duration = duration
        self.byteCount = byteCount
        self.codec = codec
        self.encrypted = encrypted
    }
}

public struct AudioChunkCheckpoint: Codable, Equatable, Sendable {
    public var meetingID: UUID
    public var track: TrackKind
    public var chunks: [AudioChunkRecord]

    public init(meetingID: UUID, track: TrackKind, chunks: [AudioChunkRecord] = []) {
        self.meetingID = meetingID
        self.track = track
        self.chunks = chunks.sorted { $0.chunkIndex < $1.chunkIndex }
    }

    public var totalDuration: TimeInterval {
        chunks.reduce(0) { $0 + $1.duration }
    }

    public func replacing(_ record: AudioChunkRecord) -> AudioChunkCheckpoint {
        let filtered = chunks.filter { $0.chunkIndex != record.chunkIndex }
        return AudioChunkCheckpoint(meetingID: meetingID, track: track, chunks: filtered + [record])
    }
}
