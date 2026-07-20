import Foundation

public struct TranscriptPlaybackTimelineService {
    public init() {}

    public func buildTimeline(
        transcript: MeetingTranscript,
        audioChunks: [AudioChunkRecord],
        bookmarks: [MeetingBookmark] = []
    ) -> TranscriptPlaybackTimeline {
        let sortedChunks = audioChunks.sorted {
            if $0.startTime == $1.startTime {
                return $0.chunkIndex < $1.chunkIndex
            }
            return $0.startTime < $1.startTime
        }
        var warnings: [TranscriptPlaybackWarning] = []

        if transcript.segments.isEmpty {
            warnings.append(TranscriptPlaybackWarning(code: .noTranscriptSegments))
        }
        if sortedChunks.isEmpty {
            warnings.append(TranscriptPlaybackWarning(code: .noAudioChunks))
        }

        let cues = transcript.segments.map { segment in
            let fragments = playbackFragments(for: segment, in: sortedChunks)
            if fragments.isEmpty {
                warnings.append(
                    TranscriptPlaybackWarning(
                        code: .missingAudioForSegment,
                        segmentID: segment.id
                    )
                )
            }

            return TranscriptPlaybackCue(
                segmentID: segment.id,
                speakerName: segment.speakerName,
                trackKind: segment.trackKind,
                startTime: segment.startTime,
                endTime: segment.endTime,
                text: segment.text,
                audioFragments: fragments
            )
        }

        let transcriptDuration = transcript.segments.map(\.endTime).max() ?? 0
        let audioDuration = sortedChunks.map(\.endTime).max() ?? 0
        let sortedBookmarks = bookmarks
            .filter { $0.meetingID == transcript.meetingID && $0.timestamp.isFinite && $0.timestamp >= 0 }
            .sorted {
                if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
                if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                return $0.id.uuidString < $1.id.uuidString
            }
        let bookmarkDuration = sortedBookmarks.map(\.timestamp).max() ?? 0

        return TranscriptPlaybackTimeline(
            meetingID: transcript.meetingID,
            duration: max(transcriptDuration, audioDuration, bookmarkDuration),
            cues: cues,
            warnings: warnings,
            bookmarks: sortedBookmarks
        )
    }

    private func playbackFragments(
        for segment: TranscriptSegment,
        in sortedChunks: [AudioChunkRecord]
    ) -> [TranscriptPlaybackAudioFragment] {
        let tolerance: TimeInterval = 0.001
        let candidates = sortedChunks.filter { chunk in
            chunk.track == segment.trackKind
                && chunk.endTime > segment.startTime
                && chunk.startTime < segment.endTime
        }
        var coverageEnd = segment.startTime
        var fragments: [TranscriptPlaybackAudioFragment] = []

        for chunk in candidates {
            guard chunk.startTime <= coverageEnd + tolerance else {
                return []
            }
            let overlapStart = max(segment.startTime, chunk.startTime)
            let overlapEnd = min(segment.endTime, chunk.endTime)
            guard overlapEnd > overlapStart else { continue }
            fragments.append(
                TranscriptPlaybackAudioFragment(
                    audioRelativePath: chunk.relativePath,
                    playbackStartOffset: overlapStart - chunk.startTime,
                    playbackDuration: overlapEnd - overlapStart
                )
            )
            coverageEnd = max(coverageEnd, overlapEnd)
            if coverageEnd >= segment.endTime - tolerance {
                return fragments
            }
        }

        return []
    }
}

private extension AudioChunkRecord {
    var endTime: TimeInterval {
        startTime + duration
    }
}
