import Foundation
import XCTest
@testable import MeetingVaultCore

final class TranscriptPlaybackTimelineTests: XCTestCase {
    func testPlaybackTimelineBuildsPlayableCueAcrossContiguousEncryptedChunks() {
        let meetingID = UUID()
        let segmentID = UUID()
        let transcript = MeetingTranscript(
            meetingID: meetingID,
            localeIdentifier: "en-US",
            generatedAt: Date(timeIntervalSince1970: 1_780_007_000),
            segments: [
                TranscriptSegment(
                    id: segmentID,
                    speakerName: "Anna",
                    trackKind: .remoteSystem,
                    startTime: 1,
                    endTime: 7,
                    text: "This cue spans several encrypted recording checkpoints.",
                    confidence: 0.95,
                    isFinal: true
                )
            ]
        )
        let chunks = (0..<4).map { index in
            AudioChunkRecord(
                track: .remoteSystem,
                chunkIndex: index,
                relativePath: "audio/remoteSystem/chunk-\(index).caf.enc",
                startTime: TimeInterval(index * 2),
                duration: 2,
                byteCount: 1024,
                codec: "CAF/LPCM",
                encrypted: true
            )
        }

        let timeline = TranscriptPlaybackTimelineService().buildTimeline(
            transcript: transcript,
            audioChunks: chunks
        )

        XCTAssertEqual(timeline.warnings, [])
        XCTAssertTrue(timeline.cues[0].isPlayable)
        XCTAssertEqual(timeline.cues[0].audioFragments.map(\.audioRelativePath), [
            "audio/remoteSystem/chunk-0.caf.enc",
            "audio/remoteSystem/chunk-1.caf.enc",
            "audio/remoteSystem/chunk-2.caf.enc",
            "audio/remoteSystem/chunk-3.caf.enc"
        ])
        XCTAssertEqual(timeline.cues[0].audioFragments.map(\.playbackStartOffset), [1, 0, 0, 0])
        XCTAssertEqual(timeline.cues[0].audioFragments.map(\.playbackDuration), [1, 2, 2, 1])
    }

    func testPlaybackTimelineRejectsCueWhenEncryptedChunksContainGap() {
        let meetingID = UUID()
        let segmentID = UUID()
        let transcript = MeetingTranscript(
            meetingID: meetingID,
            localeIdentifier: "en-US",
            generatedAt: Date(timeIntervalSince1970: 1_780_007_000),
            segments: [
                TranscriptSegment(
                    id: segmentID,
                    speakerName: "Anna",
                    trackKind: .remoteSystem,
                    startTime: 1,
                    endTime: 7,
                    text: "This cue crosses a missing recording checkpoint.",
                    confidence: 0.95,
                    isFinal: true
                )
            ]
        )
        let chunks = [
            AudioChunkRecord(track: .remoteSystem, chunkIndex: 0, relativePath: "chunk-0.enc", startTime: 0, duration: 2, byteCount: 1, codec: "CAF/LPCM", encrypted: true),
            AudioChunkRecord(track: .remoteSystem, chunkIndex: 2, relativePath: "chunk-2.enc", startTime: 4, duration: 4, byteCount: 1, codec: "CAF/LPCM", encrypted: true)
        ]

        let timeline = TranscriptPlaybackTimelineService().buildTimeline(
            transcript: transcript,
            audioChunks: chunks
        )

        XCTAssertFalse(timeline.cues[0].isPlayable)
        XCTAssertEqual(timeline.cues[0].audioFragments, [])
        XCTAssertEqual(timeline.warnings, [
            TranscriptPlaybackWarning(code: .missingAudioForSegment, segmentID: segmentID)
        ])
    }

    func testPlaybackTimelineAlignsTranscriptSegmentsToAudioChunksAndFlagsMissingAudio() {
        let meetingID = UUID()
        let coveredRemoteSegmentID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let coveredMicSegmentID = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
        let missingAudioSegmentID = UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!
        let transcript = MeetingTranscript(
            meetingID: meetingID,
            localeIdentifier: "en-US",
            generatedAt: Date(timeIntervalSince1970: 1_780_007_000),
            segments: [
                TranscriptSegment(
                    id: missingAudioSegmentID,
                    speakerName: "Anna",
                    trackKind: .remoteSystem,
                    startTime: 45,
                    endTime: 50,
                    text: "This segment has transcript text but no recovered audio.",
                    confidence: 0.91,
                    isFinal: true
                ),
                TranscriptSegment(
                    id: coveredRemoteSegmentID,
                    speakerName: "Anna",
                    trackKind: .remoteSystem,
                    startTime: 4,
                    endTime: 8,
                    text: "Deployment moves after QA sign-off.",
                    confidence: 0.95,
                    isFinal: true
                ),
                TranscriptSegment(
                    id: coveredMicSegmentID,
                    speakerName: "You",
                    trackKind: .microphone,
                    startTime: 12,
                    endTime: 16,
                    text: "I will update the release notes.",
                    confidence: 0.88,
                    isFinal: true
                )
            ]
        )
        let audioChunks = [
            AudioChunkRecord(
                track: .remoteSystem,
                chunkIndex: 0,
                relativePath: "audio/remoteSystem/chunk-0000.caf.enc",
                startTime: 0,
                duration: 30,
                byteCount: 4096,
                codec: "CAF/LPCM",
                encrypted: true
            ),
            AudioChunkRecord(
                track: .microphone,
                chunkIndex: 0,
                relativePath: "audio/microphone/chunk-0000.caf.enc",
                startTime: 0,
                duration: 30,
                byteCount: 2048,
                codec: "CAF/LPCM",
                encrypted: true
            )
        ]

        let timeline = TranscriptPlaybackTimelineService().buildTimeline(
            transcript: transcript,
            audioChunks: audioChunks
        )

        XCTAssertEqual(timeline.meetingID, meetingID)
        XCTAssertEqual(timeline.duration, 50)
        XCTAssertEqual(timeline.cues.map(\.segmentID), [
            coveredRemoteSegmentID,
            coveredMicSegmentID,
            missingAudioSegmentID
        ])
        XCTAssertEqual(timeline.cues[0].audioRelativePath, "audio/remoteSystem/chunk-0000.caf.enc")
        XCTAssertEqual(timeline.cues[1].audioRelativePath, "audio/microphone/chunk-0000.caf.enc")
        XCTAssertTrue(timeline.cues[0].isPlayable)
        XCTAssertTrue(timeline.cues[1].isPlayable)
        XCTAssertFalse(timeline.cues[2].isPlayable)
        XCTAssertEqual(timeline.warnings, [
            TranscriptPlaybackWarning(
                code: .missingAudioForSegment,
                segmentID: missingAudioSegmentID
            )
        ])
    }
}
