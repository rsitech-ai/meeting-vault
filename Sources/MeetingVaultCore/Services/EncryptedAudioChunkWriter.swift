import Foundation

public enum AudioChunkWriterError: Error, Equatable {
    case invalidChunkIndex(Int)
    case invalidDuration(TimeInterval)
}

public struct EncryptedAudioChunkWriter: @unchecked Sendable {
    private let bundleStore: EncryptedMeetingBundleStore

    public init(bundleStore: EncryptedMeetingBundleStore) {
        self.bundleStore = bundleStore
    }

    public func writeChunk(
        _ data: Data,
        meetingID: UUID,
        track: TrackKind,
        chunkIndex: Int,
        startTime: TimeInterval,
        duration: TimeInterval,
        codec: String
    ) throws -> AudioChunkRecord {
        guard chunkIndex >= 0 else {
            throw AudioChunkWriterError.invalidChunkIndex(chunkIndex)
        }
        guard duration > 0 else {
            throw AudioChunkWriterError.invalidDuration(duration)
        }

        let record = AudioChunkRecord(
            track: track,
            chunkIndex: chunkIndex,
            relativePath: chunkRelativePath(track: track, chunkIndex: chunkIndex),
            startTime: startTime,
            duration: duration,
            byteCount: data.count,
            codec: codec,
            encrypted: true
        )

        try bundleStore.writeEncryptedData(
            data,
            meetingID: meetingID,
            relativePath: record.relativePath,
            purpose: chunkPurpose(track: track, chunkIndex: chunkIndex)
        )

        let updatedCheckpoint = try readCheckpoint(meetingID: meetingID, track: track)
            .replacing(record)
        try bundleStore.writeJSONArtifact(
            updatedCheckpoint,
            meetingID: meetingID,
            relativePath: checkpointRelativePath(track: track),
            purpose: checkpointPurpose(track: track)
        )

        return record
    }

    public func readChunk(_ record: AudioChunkRecord, meetingID: UUID) throws -> Data {
        try bundleStore.readEncryptedData(
            meetingID: meetingID,
            relativePath: record.relativePath,
            purpose: chunkPurpose(track: record.track, chunkIndex: record.chunkIndex)
        )
    }

    public func readCheckpoint(meetingID: UUID, track: TrackKind) throws -> AudioChunkCheckpoint {
        let relativePath = checkpointRelativePath(track: track)
        guard try bundleStore.artifactExists(meetingID: meetingID, relativePath: relativePath) else {
            return AudioChunkCheckpoint(meetingID: meetingID, track: track)
        }
        return try bundleStore.readJSONArtifact(
            AudioChunkCheckpoint.self,
            meetingID: meetingID,
            relativePath: relativePath,
            purpose: checkpointPurpose(track: track)
        )
    }

    private func chunkRelativePath(track: TrackKind, chunkIndex: Int) -> String {
        "audio/\(track.rawValue)/chunk-\(String(format: "%06d", chunkIndex)).bin.enc"
    }

    private func checkpointRelativePath(track: TrackKind) -> String {
        "diagnostics/\(track.rawValue)-chunks.json.enc"
    }

    private func chunkPurpose(track: TrackKind, chunkIndex: Int) -> String {
        "audio-chunk:\(track.rawValue):\(chunkIndex)"
    }

    private func checkpointPurpose(track: TrackKind) -> String {
        "audio-checkpoint:\(track.rawValue)"
    }
}
