import Foundation
import XCTest
@testable import MeetingVaultCore

final class FrameFedFinalTranscriptionEngineTests: XCTestCase {
    func testFinalPassFeedsAuthoritativeWAVFramesAndNormalizesBothSideSpeakers() async throws {
        let session = FixtureFinalFrameSession(events: [
            .final(TranscriptSegment(
                speakerName: "raw-you", trackKind: .microphone,
                startTime: 0, endTime: 0.1, text: "Dzien dobry", confidence: 0.92, isFinal: true
            )),
            .final(TranscriptSegment(
                speakerName: "lseend-4", trackKind: .remoteSystem,
                startTime: 0, endTime: 0.1, text: "Good morning", confidence: 0.88, isFinal: true
            )),
        ])
        let provider = FixtureFinalFrameProvider(session: session)
        let engine = FrameFedFinalTranscriptionEngine(provider: provider)

        let result = try await engine.transcribe(TranscriptionRequest(
            meetingID: UUID(),
            audioChunkPath: "audio/chunk.wav.enc",
            audioData: float32WAV(samples: [0.2, -0.2, 0.1, -0.1], channels: 1, sampleRate: 16_000),
            audioCodec: "WAV/PCM-Float32",
            trackKind: .microphone,
            startTime: 12,
            duration: 0.1,
            localeIdentifier: "pl-PL"
        ))

        XCTAssertEqual(session.frames.flatMap(\.floatSamples), [0.2, -0.2, 0.1, -0.1])
        XCTAssertEqual(provider.configurations.map(\.context.localeIdentifier), ["pl-PL"])
        XCTAssertEqual(result.map(\.speakerName), ["You", "Speaker 1"])
        XCTAssertEqual(result.map(\.startTime), [12, 12])
        XCTAssertTrue(result.allSatisfy(\.isFinal))
        XCTAssertEqual(session.finishCount, 1)
    }

    func testRejectsMalformedOrUnsupportedAudioWithoutStartingProvider() async {
        let provider = FixtureFinalFrameProvider(session: FixtureFinalFrameSession(events: []))
        let engine = FrameFedFinalTranscriptionEngine(provider: provider)
        do {
            _ = try await engine.transcribe(TranscriptionRequest(
                meetingID: UUID(), audioChunkPath: "bad.wav", audioData: Data("bad".utf8),
                audioCodec: "WAV/PCM", trackKind: .remoteSystem
            ))
            XCTFail("Expected malformed audio to fail")
        } catch {
            XCTAssertEqual(error as? FrameFedFinalTranscriptionError, .invalidWAV)
        }
        XCTAssertTrue(provider.configurations.isEmpty)
    }
}

private final class FixtureFinalFrameProvider: LocalTranscriptionProviding, @unchecked Sendable {
    let descriptor = ProviderDescriptor(
        id: "fixture-final", modelVersion: "1", supportedLocaleIdentifiers: ["pl-PL", "en-US"]
    )
    let session: FixtureFinalFrameSession
    private let lock = NSLock()
    private var storedConfigurations: [TranscriptionSessionConfiguration] = []
    var configurations: [TranscriptionSessionConfiguration] { lock.withLock { storedConfigurations } }
    init(session: FixtureFinalFrameSession) { self.session = session }
    func makeSession(_ configuration: TranscriptionSessionConfiguration) async throws -> any LocalTranscriptionSession {
        lock.withLock { storedConfigurations.append(configuration) }
        return session
    }
}

private final class FixtureFinalFrameSession: LocalTranscriptionSession, @unchecked Sendable {
    let events: AsyncThrowingStream<LocalTranscriptionEvent, Error>
    private let continuation: AsyncThrowingStream<LocalTranscriptionEvent, Error>.Continuation
    private let scriptedEvents: [LocalTranscriptionEvent]
    private let lock = NSLock()
    private var storedFrames: [CapturedPCMFrame] = []
    private var storedFinishCount = 0
    var frames: [CapturedPCMFrame] { lock.withLock { storedFrames } }
    var finishCount: Int { lock.withLock { storedFinishCount } }
    init(events: [LocalTranscriptionEvent]) {
        let pair = AsyncThrowingStream<LocalTranscriptionEvent, Error>.makeStream(bufferingPolicy: .bufferingNewest(32))
        self.events = pair.stream
        continuation = pair.continuation
        scriptedEvents = events
    }
    func submit(_ frame: CapturedPCMFrame) async throws { lock.withLock { storedFrames.append(frame) } }
    func finish() async throws {
        lock.withLock { storedFinishCount += 1 }
        scriptedEvents.forEach { continuation.yield($0) }
        continuation.finish()
    }
    func cancel() async { continuation.finish() }
}

private func float32WAV(samples: [Float], channels: UInt16, sampleRate: UInt32) -> Data {
    let pcm = samples.withUnsafeBytes { Data($0) }
    let blockAlign = channels * 4
    var data = Data()
    func appendASCII(_ value: String) { data.append(contentsOf: value.utf8) }
    func appendLE<T: FixedWidthInteger>(_ value: T) {
        var value = value.littleEndian
        Swift.withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }
    appendASCII("RIFF"); appendLE(UInt32(36 + pcm.count)); appendASCII("WAVE")
    appendASCII("fmt "); appendLE(UInt32(16)); appendLE(UInt16(3)); appendLE(channels)
    appendLE(sampleRate); appendLE(sampleRate * UInt32(blockAlign)); appendLE(blockAlign); appendLE(UInt16(32))
    appendASCII("data"); appendLE(UInt32(pcm.count)); data.append(pcm)
    return data
}
