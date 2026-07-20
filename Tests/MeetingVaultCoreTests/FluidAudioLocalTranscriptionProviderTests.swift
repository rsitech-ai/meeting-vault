import Foundation
import XCTest
@testable import MeetingVaultCore

final class FluidAudioLocalTranscriptionProviderTests: XCTestCase {
    func testHoldsExactVerifiedRuntimeUnitsForSessionAndNeverRequestsNetwork() async throws {
        let runtime = FixtureRuntimeSessionProvider()
        let backend = FixtureLocalBackend()
        let provider = FluidAudioLocalTranscriptionProvider(
            runtime: runtime,
            backendFactory: { _, _ in backend }
        )
        let session = try await provider.makeSession(TranscriptionSessionConfiguration(
            meetingID: UUID(),
            context: MeetingContext(localeIdentifier: "pl-PL", expectedParticipantCount: 6)
        ))

        XCTAssertEqual(runtime.requestedUnits, [
            Set(["automatic-speech-recognition", "streaming-speaker-diarization"]),
        ])
        XCTAssertTrue(runtime.leaseIsActive)
        try await session.submit(try fixtureFrame(track: .microphone))
        try await session.submit(try fixtureFrame(sequence: 2, track: .remoteSystem))
        try await session.finish()

        XCTAssertEqual(backend.frames.map(\.track), [.microphone, .remoteSystem])
        XCTAssertFalse(runtime.leaseIsActive)
        XCTAssertFalse(runtime.externalNetworkRequested)
    }

    func testCancellationReleasesRuntimeAndIsExactlyOnce() async throws {
        let runtime = FixtureRuntimeSessionProvider()
        let backend = FixtureLocalBackend()
        let provider = FluidAudioLocalTranscriptionProvider(runtime: runtime, backendFactory: { _, _ in backend })
        let session = try await provider.makeSession(TranscriptionSessionConfiguration(
            meetingID: UUID(), context: MeetingContext(localeIdentifier: "en-US")
        ))
        await session.cancel()
        await session.cancel()
        XCTAssertEqual(backend.cancelCount, 1)
        XCTAssertFalse(runtime.leaseIsActive)
    }

    func testDescriptorIsLocalFrameOnlyAndSupportsPolishEnglishAutomatic() {
        let provider = FluidAudioLocalTranscriptionProvider(runtime: FixtureRuntimeSessionProvider())
        XCTAssertEqual(provider.descriptor.supportedLocaleIdentifiers, ["pl-PL", "en-US"])
        XCTAssertEqual(provider.descriptor.audioInputStrategy, .authoritativeCaptureFrames)
        XCTAssertTrue(provider.descriptor.supportsRemoteSpeakerDiarization)
        XCTAssertGreaterThanOrEqual(provider.descriptor.maximumRemoteSpeakerCount, 5)
    }

    func testRuntimeFailureBeforeLeaseClosureReturnsPromptlyWithoutStartingBackend() async {
        let runtime = FailingBeforeOperationRuntime()
        let backendStarts = LockedCounter()
        let provider = FluidAudioLocalTranscriptionProvider(
            runtime: runtime,
            backendFactory: { _, _ in
                backendStarts.increment()
                return FixtureLocalBackend()
            }
        )
        let finished = expectation(description: "makeSession returns")
        let observed = LockedError()

        let task = Task {
            do {
                _ = try await provider.makeSession(TranscriptionSessionConfiguration(
                    meetingID: UUID(), context: MeetingContext(localeIdentifier: "pl-PL")
                ))
            } catch {
                observed.set(error)
            }
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 0.25)
        task.cancel()

        XCTAssertEqual(observed.error as? LocalModelInstallationError, .unitNotReady)
        XCTAssertEqual(backendStarts.value, 0)
        XCTAssertEqual(runtime.operationInvocationCount, 0)
    }

    func testFinishFailureStillReleasesRuntimeLease() async throws {
        let runtime = FixtureRuntimeSessionProvider()
        let backend = FixtureLocalBackend(finishError: LiveTranscriptionProviderError(message: "ASR finish failed"))
        let provider = FluidAudioLocalTranscriptionProvider(runtime: runtime, backendFactory: { _, _ in backend })
        let session = try await provider.makeSession(TranscriptionSessionConfiguration(
            meetingID: UUID(), context: MeetingContext(localeIdentifier: "en-US")
        ))

        do {
            try await session.finish()
            XCTFail("Expected finish failure")
        } catch {
            XCTAssertEqual((error as? LiveTranscriptionProviderError)?.message, "ASR finish failed")
        }
        XCTAssertFalse(runtime.leaseIsActive)
    }

    func testLiveOverlapResolverEmitsOneUncertainSpeakerIdentity() {
        XCTAssertEqual(FluidAudioLiveSpeakerResolver.name(for: []), "remote-unassigned")
        XCTAssertEqual(FluidAudioLiveSpeakerResolver.name(for: [2]), "lseend-2")
        XCTAssertEqual(FluidAudioLiveSpeakerResolver.name(for: [2, 1, 2]), "Multiple speakers")
    }
}

private final class FailingBeforeOperationRuntime: LocalModelRuntimeSessionProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var storedOperationInvocationCount = 0
    var operationInvocationCount: Int { lock.withLock { storedOperationInvocationCount } }

    func withRuntimeSession(
        _ ids: Set<String>,
        _ operation: @Sendable (LocalModelRuntimeAccess) async throws -> Void
    ) async throws {
        throw LocalModelInstallationError.unitNotReady
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = 0
    var value: Int { lock.withLock { storedValue } }
    func increment() { lock.withLock { storedValue += 1 } }
}

private final class LockedError: @unchecked Sendable {
    private let lock = NSLock()
    private var storedError: Error?
    var error: Error? { lock.withLock { storedError } }
    func set(_ error: Error) { lock.withLock { storedError = error } }
}

private final class FixtureRuntimeSessionProvider: LocalModelRuntimeSessionProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var storedUnits: [Set<String>] = []
    private var active = false
    var requestedUnits: [Set<String>] { lock.withLock { storedUnits } }
    var leaseIsActive: Bool { lock.withLock { active } }
    let externalNetworkRequested = false

    func withRuntimeSession(
        _ ids: Set<String>,
        _ operation: @Sendable (LocalModelRuntimeAccess) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        lock.withLock { storedUnits.append(ids); active = true }
        defer { lock.withLock { active = false } }
        let access = LocalModelRuntimeAccess(
            assetIDs: ids,
            roots: Dictionary(uniqueKeysWithValues: ids.map { ($0, root) })
        )
        try await operation(access)
        await access.invalidateAndWait()
    }
}

private final class FixtureLocalBackend: LocalTranscriptionBackend, @unchecked Sendable {
    private let pair = AsyncThrowingStream<LocalTranscriptionEvent, Error>.makeStream(bufferingPolicy: .bufferingNewest(16))
    private let lock = NSLock()
    private var storedFrames: [CapturedPCMFrame] = []
    private var storedCancelCount = 0
    private let finishError: Error?
    var events: AsyncThrowingStream<LocalTranscriptionEvent, Error> { pair.stream }
    var frames: [CapturedPCMFrame] { lock.withLock { storedFrames } }
    var cancelCount: Int { lock.withLock { storedCancelCount } }
    init(finishError: Error? = nil) { self.finishError = finishError }
    func submit(_ frame: CapturedPCMFrame) async throws { lock.withLock { storedFrames.append(frame) } }
    func finish() async throws {
        if let finishError { throw finishError }
        pair.continuation.finish()
    }
    func cancel() async { lock.withLock { storedCancelCount += 1 }; pair.continuation.finish() }
}

private func fixtureFrame(sequence: UInt64 = 1, track: TrackKind) throws -> CapturedPCMFrame {
    let samples = [Float](repeating: 0.2, count: 160)
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
