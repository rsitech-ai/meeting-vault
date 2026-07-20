import Foundation
import XCTest
@testable import MeetingVaultCore

final class AppleSpeechFrameTranscriptionProviderTests: XCTestCase {
    func testCompatibilityProviderConsumesAuthoritativeFramesWithoutInputEngine() async throws {
        let backend = FixtureAppleFrameBackend()
        let provider = AppleSpeechFrameTranscriptionProvider(
            privacyBoundary: TranscriptionPrivacyBoundary(mode: .appleOnDeviceOnly),
            authorizationProvider: FrameSpeechAuthorizationProvider(currentState: .authorized),
            onDeviceCapability: FrameOnDeviceCapability(supported: true),
            backendFactory: { _, requiresOnDevice in
                XCTAssertTrue(requiresOnDevice)
                return backend
            }
        )
        let session = try await provider.makeSession(TranscriptionSessionConfiguration(
            meetingID: UUID(),
            context: MeetingContext(localeIdentifier: "pl-PL"),
            microphoneDeviceID: "selected-studio"
        ))
        try await session.submit(try appleFixtureFrame(track: .microphone))
        try await session.submit(try appleFixtureFrame(sequence: 2, track: .remoteSystem))
        try await session.finish()

        XCTAssertEqual(provider.descriptor.audioInputStrategy, .authoritativeCaptureFrames)
        XCTAssertEqual(backend.frames.map(\.track), [.microphone, .remoteSystem])
    }

    func testLocalOnlyRejectsBeforeAuthorizationOrFactory() async throws {
        let authorization = FrameSpeechAuthorizationProvider(currentState: .authorized)
        let factory = AppleFrameFactoryObservation()
        let provider = AppleSpeechFrameTranscriptionProvider(
            privacyBoundary: TranscriptionPrivacyBoundary(mode: .localOnly),
            authorizationProvider: authorization,
            backendFactory: { _, _ in factory.make() }
        )
        do {
            _ = try await provider.makeSession(TranscriptionSessionConfiguration(
                meetingID: UUID(), context: MeetingContext(localeIdentifier: "en-US")
            ))
            XCTFail("Expected privacy rejection")
        } catch {
            XCTAssertEqual(error as? TranscriptionPrivacyBoundaryError, .localProviderUnavailable)
        }
        XCTAssertEqual(authorization.requestCount, 0)
        XCTAssertEqual(factory.makeCount, 0)
    }

    func testOnDeviceUnsupportedFailsBeforeFactoryAndNeverFallsBack() async throws {
        let factory = AppleFrameFactoryObservation()
        let provider = AppleSpeechFrameTranscriptionProvider(
            privacyBoundary: TranscriptionPrivacyBoundary(mode: .appleOnDeviceOnly),
            authorizationProvider: FrameSpeechAuthorizationProvider(currentState: .authorized),
            onDeviceCapability: FrameOnDeviceCapability(supported: false),
            backendFactory: { _, _ in factory.make() }
        )
        do {
            _ = try await provider.makeSession(TranscriptionSessionConfiguration(
                meetingID: UUID(), context: MeetingContext(localeIdentifier: "en-US")
            ))
            XCTFail("Expected on-device rejection")
        } catch {
            XCTAssertEqual(error as? TranscriptionPrivacyBoundaryError, .onDeviceRecognitionRequired)
        }
        XCTAssertEqual(factory.makeCount, 0)
    }
}

private final class FrameSpeechAuthorizationProvider: SpeechRecognitionAuthorizationProviding, @unchecked Sendable {
    private let lock = NSLock()
    private let state: SpeechRecognitionAuthorizationState
    private var requests = 0
    var requestCount: Int { lock.withLock { requests } }
    init(currentState: SpeechRecognitionAuthorizationState) { state = currentState }
    func currentAuthorizationState() -> SpeechRecognitionAuthorizationState { state }
    func requestAuthorizationState() async -> SpeechRecognitionAuthorizationState {
        lock.withLock { requests += 1 }
        return state
    }
}

private struct FrameOnDeviceCapability: AppleSpeechOnDeviceCapabilityProviding {
    var supported: Bool
    func supportsOnDeviceRecognition(for locale: Locale) -> Bool { supported }
}

private final class FixtureAppleFrameBackend: LocalTranscriptionBackend, @unchecked Sendable {
    private let pair = AsyncThrowingStream<LocalTranscriptionEvent, Error>.makeStream(bufferingPolicy: .bufferingNewest(16))
    private let lock = NSLock()
    private var storedFrames: [CapturedPCMFrame] = []
    var frames: [CapturedPCMFrame] { lock.withLock { storedFrames } }
    var events: AsyncThrowingStream<LocalTranscriptionEvent, Error> { pair.stream }
    func submit(_ frame: CapturedPCMFrame) async throws { lock.withLock { storedFrames.append(frame) } }
    func finish() async throws { pair.continuation.finish() }
    func cancel() async { pair.continuation.finish() }
}

private final class AppleFrameFactoryObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var makeCount: Int { lock.withLock { count } }
    func make() -> any LocalTranscriptionBackend {
        lock.withLock { count += 1 }
        return FixtureAppleFrameBackend()
    }
}

private func appleFixtureFrame(sequence: UInt64 = 1, track: TrackKind) throws -> CapturedPCMFrame {
    let samples = [Float](repeating: 0.1, count: 160)
    return try CapturedPCMFrame(
        sequence: sequence,
        track: track,
        meetingTime: Double(sequence),
        sampleRate: 16_000,
        channelCount: 1,
        frameCount: samples.count,
        pcm: samples.withUnsafeBytes { Data($0) }
    )
}
