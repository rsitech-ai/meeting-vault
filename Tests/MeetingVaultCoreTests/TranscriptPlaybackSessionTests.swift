import Foundation
import XCTest
@testable import MeetingVaultCore

final class TranscriptPlaybackSessionTests: XCTestCase {
    func testPlaybackSessionReadsEncryptedCueAudioAndControlsTransport() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultPlaybackSession-\(UUID().uuidString)", isDirectory: true)
        let keyProvider = InMemorySymmetricKeyProvider(keyData: Data(repeating: 104, count: 32))
        let bundleStore = EncryptedMeetingBundleStore(
            rootDirectory: root,
            vault: AESGCMDataVault(keyProvider: keyProvider)
        )
        let chunkWriter = EncryptedAudioChunkWriter(bundleStore: bundleStore)
        let meetingID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        _ = try bundleStore.createBundle(.initialEncryptedBundle(
            meetingID: meetingID,
            title: "Playback smoke"
        ))
        let encryptedBytes = Data([0x52, 0x49, 0x46, 0x46, 0x01, 0x02, 0x03])
        let record = try chunkWriter.writeChunk(
            encryptedBytes,
            meetingID: meetingID,
            track: .remoteSystem,
            chunkIndex: 0,
            startTime: 0,
            duration: 12,
            codec: "WAV/PCM"
        )
        let segmentID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let transcript = MeetingTranscript(
            meetingID: meetingID,
            localeIdentifier: "en-US",
            generatedAt: Date(timeIntervalSince1970: 1_780_011_010),
            segments: [
                TranscriptSegment(
                    id: segmentID,
                    speakerName: "Anna",
                    trackKind: .remoteSystem,
                    startTime: 2,
                    endTime: 6,
                    text: "Playback should use decrypted chunk bytes.",
                    confidence: 0.94,
                    isFinal: true
                )
            ]
        )
        let timeline = TranscriptPlaybackTimelineService().buildTimeline(
            transcript: transcript,
            audioChunks: [record]
        )
        let engine = CapturingTranscriptAudioEngine()
        let service = TranscriptPlaybackSessionService(
            chunkWriter: chunkWriter,
            audioEngine: engine
        )

        let playing = try service.playCue(segmentID, in: timeline)

        XCTAssertEqual(playing.transportState, .playing)
        XCTAssertEqual(playing.selectedCueID, segmentID)
        XCTAssertEqual(playing.currentTime, 2)
        XCTAssertEqual(playing.statusMessage, "Playing 00:02-00:06")
        XCTAssertEqual(engine.playedAudioData, encryptedBytes)
        XCTAssertEqual(engine.playedFragmentOffsets, [2])
        XCTAssertEqual(engine.playedFragmentDurations, [4])
        XCTAssertEqual(engine.playedCueIDs, [segmentID])

        let paused = try service.pause(playing)
        XCTAssertEqual(paused.transportState, .paused)
        XCTAssertEqual(paused.statusMessage, "Playback paused")
        XCTAssertEqual(engine.pauseCount, 1)

        let stopped = try service.stop(paused)
        XCTAssertEqual(stopped.transportState, .stopped)
        XCTAssertNil(stopped.selectedCueID)
        XCTAssertEqual(stopped.currentTime, 0)
        XCTAssertEqual(stopped.statusMessage, "Playback stopped")
        XCTAssertEqual(engine.stopCount, 1)
    }

    func testPlaybackSessionDecryptsEveryFragmentForCueSpanningChunks() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultPlaybackFragments-\(UUID().uuidString)", isDirectory: true)
        let bundleStore = EncryptedMeetingBundleStore(
            rootDirectory: root,
            vault: AESGCMDataVault(keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 109, count: 32)))
        )
        let chunkWriter = EncryptedAudioChunkWriter(bundleStore: bundleStore)
        let meetingID = UUID()
        _ = try bundleStore.createBundle(.initialEncryptedBundle(meetingID: meetingID, title: "Fragment playback"))
        let first = try chunkWriter.writeChunk(Data([1, 2]), meetingID: meetingID, track: .remoteSystem, chunkIndex: 0, startTime: 0, duration: 2, codec: "CAF/LPCM")
        let second = try chunkWriter.writeChunk(Data([3, 4]), meetingID: meetingID, track: .remoteSystem, chunkIndex: 1, startTime: 2, duration: 2, codec: "CAF/LPCM")
        let segmentID = UUID()
        let cue = TranscriptPlaybackCue(
            segmentID: segmentID,
            speakerName: "Anna",
            trackKind: .remoteSystem,
            startTime: 1,
            endTime: 3,
            text: "Cross-checkpoint cue",
            audioFragments: [
                TranscriptPlaybackAudioFragment(audioRelativePath: first.relativePath, playbackStartOffset: 1, playbackDuration: 1),
                TranscriptPlaybackAudioFragment(audioRelativePath: second.relativePath, playbackStartOffset: 0, playbackDuration: 1)
            ]
        )
        let timeline = TranscriptPlaybackTimeline(meetingID: meetingID, duration: 4, cues: [cue], warnings: [])
        let engine = CapturingTranscriptAudioEngine()
        let service = TranscriptPlaybackSessionService(chunkWriter: chunkWriter, audioEngine: engine)

        _ = try service.playCue(segmentID, in: timeline)

        XCTAssertEqual(engine.playedAudioDataFragments, [Data([1, 2]), Data([3, 4])])
        XCTAssertEqual(engine.playedFragmentOffsets, [1, 0])
        XCTAssertEqual(engine.playedFragmentDurations, [1, 1])
    }

    func testPlaybackSessionFailsClosedForCueWithoutAudio() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultPlaybackMissing-\(UUID().uuidString)", isDirectory: true)
        let bundleStore = EncryptedMeetingBundleStore(
            rootDirectory: root,
            vault: AESGCMDataVault(keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 105, count: 32)))
        )
        let chunkWriter = EncryptedAudioChunkWriter(bundleStore: bundleStore)
        let cueID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let timeline = TranscriptPlaybackTimeline(
            meetingID: UUID(),
            duration: 10,
            cues: [
                TranscriptPlaybackCue(
                    segmentID: cueID,
                    speakerName: "Anna",
                    trackKind: .remoteSystem,
                    startTime: 1,
                    endTime: 4,
                    text: "Transcript exists but audio is unavailable.",
                    audioRelativePath: nil
                )
            ],
            warnings: [TranscriptPlaybackWarning(code: .missingAudioForSegment, segmentID: cueID)]
        )
        let engine = CapturingTranscriptAudioEngine()
        let service = TranscriptPlaybackSessionService(
            chunkWriter: chunkWriter,
            audioEngine: engine
        )

        XCTAssertThrowsError(try service.playCue(cueID, in: timeline)) { error in
            XCTAssertEqual(error as? TranscriptPlaybackSessionError, .cueMissingAudio(cueID))
        }
        XCTAssertNil(engine.playedAudioData)
    }

    func testPlaybackSessionScrubsLongRecordingTimelineAndClampsBounds() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultLongPlayback-\(UUID().uuidString)", isDirectory: true)
        let bundleStore = EncryptedMeetingBundleStore(
            rootDirectory: root,
            vault: AESGCMDataVault(keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 108, count: 32)))
        )
        let chunkWriter = EncryptedAudioChunkWriter(bundleStore: bundleStore)
        let service = TranscriptPlaybackSessionService(
            chunkWriter: chunkWriter,
            audioEngine: CapturingTranscriptAudioEngine()
        )
        let meetingID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let cueCount = 14_400
        let timeline = TranscriptPlaybackTimeline(
            meetingID: meetingID,
            duration: TimeInterval(cueCount),
            cues: (0..<cueCount).map { index in
                TranscriptPlaybackCue(
                    segmentID: UUID(uuidString: String(format: "55555555-5555-5555-5555-%012d", index))!,
                    speakerName: index.isMultiple(of: 2) ? "Remote" : "You",
                    trackKind: index.isMultiple(of: 2) ? .remoteSystem : .microphone,
                    startTime: TimeInterval(index),
                    endTime: TimeInterval(index + 1),
                    text: "Long recording cue \(index)",
                    audioRelativePath: "audio/\(index.isMultiple(of: 2) ? TrackKind.remoteSystem.rawValue : TrackKind.microphone.rawValue)/chunk-\(String(format: "%06d", index)).bin.enc"
                )
            },
            warnings: []
        )
        let initialState = TranscriptPlaybackSessionState(
            meetingID: meetingID,
            transportState: .playing,
            statusMessage: "Playing long recording"
        )

        let middle = service.seek(to: 7_201.4, in: timeline, state: initialState)
        XCTAssertEqual(middle.currentTime, 7_201.4, accuracy: 0.0001)
        XCTAssertEqual(middle.selectedCueID, timeline.cues[7_201].segmentID)
        XCTAssertEqual(middle.transportState, .playing)
        XCTAssertEqual(middle.statusMessage, "Playback position 120:01")

        let start = service.seek(to: -42, in: timeline, state: middle)
        XCTAssertEqual(start.currentTime, 0)
        XCTAssertEqual(start.selectedCueID, timeline.cues[0].segmentID)
        XCTAssertEqual(start.transportState, .playing)

        let end = service.seek(to: 14_399.7, in: timeline, state: start)
        XCTAssertEqual(end.currentTime, 14_399.7, accuracy: 0.0001)
        XCTAssertEqual(end.selectedCueID, timeline.cues[14_399].segmentID)

        let overflow = service.seek(to: 16_000, in: timeline, state: end)
        XCTAssertEqual(overflow.currentTime, 14_400)
        XCTAssertEqual(overflow.selectedCueID, timeline.cues[14_399].segmentID)
        XCTAssertEqual(overflow.transportState, .playing)
    }

    func testPlayRangeReadsExactEncryptedTrackRangeAcrossChunksWithoutSyntheticIdentity() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultExactRange-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleStore = EncryptedMeetingBundleStore(
            rootDirectory: root,
            vault: AESGCMDataVault(keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 111, count: 32)))
        )
        let chunkWriter = EncryptedAudioChunkWriter(bundleStore: bundleStore)
        let meetingID = UUID()
        _ = try bundleStore.createBundle(.initialEncryptedBundle(meetingID: meetingID, title: "Exact range"))
        _ = try chunkWriter.writeChunk(Data([1, 2]), meetingID: meetingID, track: .remoteSystem, chunkIndex: 0, startTime: 0, duration: 5, codec: "CAF/LPCM")
        _ = try chunkWriter.writeChunk(Data([3, 4]), meetingID: meetingID, track: .remoteSystem, chunkIndex: 1, startTime: 5, duration: 5, codec: "CAF/LPCM")
        let realSegmentID = UUID()
        let timeline = TranscriptPlaybackTimeline(
            meetingID: meetingID,
            duration: 10,
            cues: [TranscriptPlaybackCue(segmentID: realSegmentID, speakerName: "Speaker 1", trackKind: .remoteSystem, startTime: 3, endTime: 8, text: "Exact", audioRelativePath: nil)],
            warnings: []
        )
        let engine = CapturingTranscriptAudioEngine()
        let service = TranscriptPlaybackSessionService(chunkWriter: chunkWriter, audioEngine: engine)

        let state = try service.playRange(startTime: 3, endTime: 8, track: .remoteSystem, in: timeline)

        XCTAssertNil(state.selectedCueID)
        XCTAssertEqual(state.currentTime, 3)
        XCTAssertEqual(engine.playedRanges, [TranscriptPlaybackRange(meetingID: meetingID, trackKind: .remoteSystem, startTime: 3, endTime: 8)])
        XCTAssertEqual(engine.playedAudioDataFragments, [Data([1, 2]), Data([3, 4])])
        XCTAssertEqual(engine.playedFragmentOffsets, [3, 0])
        XCTAssertEqual(engine.playedFragmentDurations, [2, 3])
    }

    func testPlayRangeRejectsNonFiniteOutOfBoundsWrongTrackAndAudioGaps() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultExactRangeInvalid-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleStore = EncryptedMeetingBundleStore(
            rootDirectory: root,
            vault: AESGCMDataVault(keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 112, count: 32)))
        )
        let chunkWriter = EncryptedAudioChunkWriter(bundleStore: bundleStore)
        let meetingID = UUID()
        _ = try bundleStore.createBundle(.initialEncryptedBundle(meetingID: meetingID, title: "Invalid range"))
        _ = try chunkWriter.writeChunk(Data([1]), meetingID: meetingID, track: .remoteSystem, chunkIndex: 0, startTime: 0, duration: 2, codec: "CAF/LPCM")
        _ = try chunkWriter.writeChunk(Data([2]), meetingID: meetingID, track: .remoteSystem, chunkIndex: 1, startTime: 3, duration: 2, codec: "CAF/LPCM")
        let cueID = UUID()
        let timeline = TranscriptPlaybackTimeline(
            meetingID: meetingID,
            duration: 5,
            cues: [TranscriptPlaybackCue(segmentID: cueID, speakerName: "Speaker", trackKind: .remoteSystem, startTime: 0, endTime: 5, text: "Gap", audioRelativePath: nil)],
            warnings: []
        )
        let service = TranscriptPlaybackSessionService(chunkWriter: chunkWriter, audioEngine: CapturingTranscriptAudioEngine())

        XCTAssertThrowsError(try service.playRange(startTime: .nan, endTime: 1, track: .remoteSystem, in: timeline)) {
            XCTAssertEqual($0 as? TranscriptPlaybackSessionError, .invalidRange)
        }
        XCTAssertThrowsError(try service.playRange(startTime: -1, endTime: 1, track: .remoteSystem, in: timeline)) {
            XCTAssertEqual($0 as? TranscriptPlaybackSessionError, .invalidRange)
        }
        XCTAssertThrowsError(try service.playRange(startTime: 0, endTime: 1, track: .microphone, in: timeline)) {
            XCTAssertEqual($0 as? TranscriptPlaybackSessionError, .rangeHasNoTranscriptCue)
        }
        XCTAssertThrowsError(try service.playRange(startTime: 1, endTime: 4, track: .remoteSystem, in: timeline)) {
            XCTAssertEqual($0 as? TranscriptPlaybackSessionError, .rangeHasAudioGap)
        }
    }
}

private final class CapturingTranscriptAudioEngine: TranscriptAudioEngine, @unchecked Sendable {
    private(set) var playedAudioData: Data?
    private(set) var playedAudioDataFragments: [Data] = []
    private(set) var playedFragmentOffsets: [TimeInterval] = []
    private(set) var playedFragmentDurations: [TimeInterval] = []
    private(set) var playedCueIDs: [UUID] = []
    private(set) var playedRanges: [TranscriptPlaybackRange] = []
    private(set) var pauseCount = 0
    private(set) var stopCount = 0

    func play(audioFragments: [TranscriptPlaybackAudioDataFragment], cue: TranscriptPlaybackCue) throws {
        playedAudioDataFragments = audioFragments.map(\.audioData)
        playedAudioData = audioFragments.first?.audioData
        playedFragmentOffsets = audioFragments.map(\.playbackStartOffset)
        playedFragmentDurations = audioFragments.map(\.playbackDuration)
        playedCueIDs.append(cue.segmentID)
    }

    func playRange(audioFragments: [TranscriptPlaybackAudioDataFragment], range: TranscriptPlaybackRange) throws {
        playedAudioDataFragments = audioFragments.map(\.audioData)
        playedAudioData = audioFragments.first?.audioData
        playedFragmentOffsets = audioFragments.map(\.playbackStartOffset)
        playedFragmentDurations = audioFragments.map(\.playbackDuration)
        playedRanges.append(range)
    }

    func pause() throws {
        pauseCount += 1
    }

    func stop() throws {
        stopCount += 1
    }
}
