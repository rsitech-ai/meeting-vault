import Foundation

public struct TranscriptPlaybackAudioDataFragment: Equatable, Sendable {
    public var audioData: Data
    public var playbackStartOffset: TimeInterval
    public var playbackDuration: TimeInterval

    public init(audioData: Data, playbackStartOffset: TimeInterval, playbackDuration: TimeInterval) {
        self.audioData = audioData
        self.playbackStartOffset = playbackStartOffset
        self.playbackDuration = playbackDuration
    }
}

public struct TranscriptPlaybackRange: Equatable, Sendable {
    public var meetingID: UUID
    public var trackKind: TrackKind
    public var startTime: TimeInterval
    public var endTime: TimeInterval

    public init(meetingID: UUID, trackKind: TrackKind, startTime: TimeInterval, endTime: TimeInterval) {
        self.meetingID = meetingID
        self.trackKind = trackKind
        self.startTime = startTime
        self.endTime = endTime
    }
}

public protocol TranscriptAudioEngine: AnyObject, Sendable {
    func play(audioFragments: [TranscriptPlaybackAudioDataFragment], cue: TranscriptPlaybackCue) throws
    func playRange(audioFragments: [TranscriptPlaybackAudioDataFragment], range: TranscriptPlaybackRange) throws
    func pause() throws
    func stop() throws
}

public struct TranscriptPlaybackSessionService {
    private let chunkWriter: EncryptedAudioChunkWriter
    private let audioEngine: any TranscriptAudioEngine

    public init(
        chunkWriter: EncryptedAudioChunkWriter,
        audioEngine: any TranscriptAudioEngine
    ) {
        self.chunkWriter = chunkWriter
        self.audioEngine = audioEngine
    }

    public func initialState(for timeline: TranscriptPlaybackTimeline) -> TranscriptPlaybackSessionState {
        TranscriptPlaybackSessionState.idle(for: timeline)
    }

    public func playCue(
        _ cueID: UUID,
        in timeline: TranscriptPlaybackTimeline
    ) throws -> TranscriptPlaybackSessionState {
        guard let cue = timeline.cues.first(where: { $0.segmentID == cueID }) else {
            throw TranscriptPlaybackSessionError.cueNotFound(cueID)
        }
        guard cue.isPlayable else {
            throw TranscriptPlaybackSessionError.cueMissingAudio(cueID)
        }
        guard timeline.isPlayable else {
            throw TranscriptPlaybackSessionError.timelineNotPlayable(timeline.meetingID)
        }

        let audioFragments = try cue.audioFragments.map { fragment in
            TranscriptPlaybackAudioDataFragment(
                audioData: try readAudioData(
                    meetingID: timeline.meetingID,
                    track: cue.trackKind,
                    audioRelativePath: fragment.audioRelativePath
                ),
                playbackStartOffset: fragment.playbackStartOffset,
                playbackDuration: fragment.playbackDuration
            )
        }

        do {
            try audioEngine.play(audioFragments: audioFragments, cue: cue)
        } catch {
            throw TranscriptPlaybackSessionError.audioEngineFailed(String(describing: error))
        }

        return TranscriptPlaybackSessionState(
            meetingID: timeline.meetingID,
            selectedCueID: cue.segmentID,
            currentTime: cue.startTime,
            transportState: .playing,
            statusMessage: "Playing \(Self.timeRange(cue))"
        )
    }

    public func playRange(
        startTime: TimeInterval,
        endTime: TimeInterval,
        track: TrackKind,
        in timeline: TranscriptPlaybackTimeline
    ) throws -> TranscriptPlaybackSessionState {
        guard startTime.isFinite, endTime.isFinite,
              startTime >= 0, endTime > startTime, endTime <= timeline.duration else {
            throw TranscriptPlaybackSessionError.invalidRange
        }
        guard timeline.cues.contains(where: {
            $0.trackKind == track && $0.startTime <= startTime && $0.endTime >= endTime
        }) else {
            throw TranscriptPlaybackSessionError.rangeHasNoTranscriptCue
        }

        let checkpoint = try chunkWriter.readCheckpoint(meetingID: timeline.meetingID, track: track)
        let overlapping = checkpoint.chunks
            .filter { record in
                record.startTime < endTime && record.startTime + record.duration > startTime
            }
            .sorted { lhs, rhs in
                if lhs.startTime == rhs.startTime { return lhs.chunkIndex < rhs.chunkIndex }
                return lhs.startTime < rhs.startTime
            }
        guard !overlapping.isEmpty else { throw TranscriptPlaybackSessionError.rangeHasAudioGap }

        var cursor = startTime
        var fragments: [TranscriptPlaybackAudioDataFragment] = []
        for record in overlapping {
            let recordEnd = record.startTime + record.duration
            let fragmentStart = max(startTime, record.startTime)
            let fragmentEnd = min(endTime, recordEnd)
            guard fragmentEnd > fragmentStart else { continue }
            guard fragmentStart <= cursor + 0.001 else {
                throw TranscriptPlaybackSessionError.rangeHasAudioGap
            }
            if fragmentEnd <= cursor { continue }
            let effectiveStart = max(fragmentStart, cursor)
            fragments.append(
                TranscriptPlaybackAudioDataFragment(
                    audioData: try readAudioData(
                        meetingID: timeline.meetingID,
                        track: track,
                        audioRelativePath: record.relativePath
                    ),
                    playbackStartOffset: effectiveStart - record.startTime,
                    playbackDuration: fragmentEnd - effectiveStart
                )
            )
            cursor = max(cursor, fragmentEnd)
        }
        guard cursor >= endTime - 0.001 else { throw TranscriptPlaybackSessionError.rangeHasAudioGap }

        let range = TranscriptPlaybackRange(
            meetingID: timeline.meetingID,
            trackKind: track,
            startTime: startTime,
            endTime: endTime
        )
        do {
            try audioEngine.playRange(audioFragments: fragments, range: range)
        } catch {
            throw TranscriptPlaybackSessionError.audioEngineFailed(String(describing: error))
        }
        return TranscriptPlaybackSessionState(
            meetingID: timeline.meetingID,
            selectedCueID: nil,
            currentTime: startTime,
            transportState: .playing,
            statusMessage: "Playing \(Self.durationText(startTime))-\(Self.durationText(endTime))"
        )
    }

    public func pause(_ state: TranscriptPlaybackSessionState) throws -> TranscriptPlaybackSessionState {
        do {
            try audioEngine.pause()
        } catch {
            throw TranscriptPlaybackSessionError.audioEngineFailed(String(describing: error))
        }

        return TranscriptPlaybackSessionState(
            meetingID: state.meetingID,
            selectedCueID: state.selectedCueID,
            currentTime: state.currentTime,
            transportState: .paused,
            statusMessage: "Playback paused"
        )
    }

    public func stop(_ state: TranscriptPlaybackSessionState) throws -> TranscriptPlaybackSessionState {
        do {
            try audioEngine.stop()
        } catch {
            throw TranscriptPlaybackSessionError.audioEngineFailed(String(describing: error))
        }

        return TranscriptPlaybackSessionState(
            meetingID: state.meetingID,
            selectedCueID: nil,
            currentTime: 0,
            transportState: .stopped,
            statusMessage: "Playback stopped"
        )
    }

    public func seek(
        to currentTime: TimeInterval,
        in timeline: TranscriptPlaybackTimeline,
        state: TranscriptPlaybackSessionState
    ) -> TranscriptPlaybackSessionState {
        let boundedTime = min(max(0, currentTime), max(0, timeline.duration))
        let selectedCue = timeline.cues.first { cue in
            cue.startTime <= boundedTime && cue.endTime >= boundedTime
        }

        return TranscriptPlaybackSessionState(
            meetingID: timeline.meetingID,
            selectedCueID: selectedCue?.segmentID ?? state.selectedCueID,
            currentTime: boundedTime,
            transportState: state.transportState,
            statusMessage: "Playback position \(Self.durationText(boundedTime))"
        )
    }

    private func readAudioData(
        meetingID: UUID,
        track: TrackKind,
        audioRelativePath: String
    ) throws -> Data {
        let checkpoint = try chunkWriter.readCheckpoint(meetingID: meetingID, track: track)
        guard let record = checkpoint.chunks.first(where: { $0.relativePath == audioRelativePath }) else {
            throw TranscriptPlaybackSessionError.audioDataUnavailable(audioRelativePath)
        }

        do {
            return try chunkWriter.readChunk(record, meetingID: meetingID)
        } catch {
            throw TranscriptPlaybackSessionError.audioDataUnavailable(audioRelativePath)
        }
    }

    private static func timeRange(_ cue: TranscriptPlaybackCue) -> String {
        "\(durationText(cue.startTime))-\(durationText(cue.endTime))"
    }

    private static func durationText(_ seconds: TimeInterval) -> String {
        let totalSeconds = max(0, Int(seconds.rounded(.down)))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
