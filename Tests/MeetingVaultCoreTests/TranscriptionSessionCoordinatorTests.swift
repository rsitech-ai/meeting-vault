import Foundation
import XCTest
@testable import MeetingVaultCore

final class TranscriptionSessionCoordinatorTests: XCTestCase {
    func testUsesAuthoritativeFramesAndPreservesSelectedDeviceIdentityWithoutOwningInputEngine() async throws {
        let session = TestLocalTranscriptionSession()
        let provider = TestLocalTranscriptionProvider(session: session)
        let coordinator = TranscriptionSessionCoordinator(
            provider: provider,
            configuration: configuration(locale: "en-US", microphoneDeviceID: "studio-display")
        )

        try await coordinator.start()
        try await coordinator.consume(frame(sequence: 1, track: .microphone))
        try await coordinator.finish()

        XCTAssertEqual(provider.configurations.map(\.microphoneDeviceID), ["studio-display"])
        XCTAssertEqual(session.submittedFrames.map(\.sequence), [1])
        XCTAssertEqual(provider.descriptor.audioInputStrategy, .authoritativeCaptureFrames)
    }

    func testAcceptsPolishEnglishAndAutomaticAndRejectsUnsupportedLocaleHonestly() async throws {
        for locale in ["pl-PL", "en-US", nil] {
            let provider = TestLocalTranscriptionProvider(session: TestLocalTranscriptionSession())
            let coordinator = TranscriptionSessionCoordinator(
                provider: provider,
                configuration: configuration(locale: locale)
            )
            try await coordinator.start()
            try await coordinator.finish()
        }

        let provider = TestLocalTranscriptionProvider(session: TestLocalTranscriptionSession())
        let unsupported = TranscriptionSessionCoordinator(
            provider: provider,
            configuration: configuration(locale: "de-DE")
        )
        do {
            try await unsupported.start()
            XCTFail("Expected unsupported locale")
        } catch {
            XCTAssertEqual(error as? LocalTranscriptionError, .unsupportedLocale("de-DE"))
        }
        XCTAssertTrue(provider.configurations.isEmpty)
    }

    func testForcesMicrophoneSpeakerToYouAndKeepsFiveStableRemoteSpeakersWithOverlap() async throws {
        let microphoneID = UUID()
        let remoteID = UUID()
        let session = TestLocalTranscriptionSession()
        let provider = TestLocalTranscriptionProvider(session: session)
        let coordinator = TranscriptionSessionCoordinator(
            provider: provider,
            configuration: configuration(locale: "pl-PL", expectedRemoteSpeakerCount: 5)
        )
        let collector = EventCollector(stream: coordinator.events)

        try await coordinator.start()
        session.emit(.partial(segment(id: microphoneID, speaker: "speaker-x", track: .microphone, start: 0, end: 1)))
        session.emit(.final(segment(id: remoteID, speaker: "raw-4", track: .remoteSystem, start: 0.5, end: 2)))
        session.emit(.activeSpeakers(["raw-4", "raw-2"]))
        for speaker in 0..<5 {
            session.emit(.final(segment(speaker: "raw-\(speaker)", track: .remoteSystem, start: Double(speaker), end: Double(speaker + 2))))
        }
        try await coordinator.finish()

        let events = await collector.value
        let segments = events.compactMap(\.segment)
        XCTAssertEqual(segments.first(where: { $0.id == microphoneID })?.speakerName, "You")
        let remoteNames = Set(segments.filter { $0.trackKind == .remoteSystem }.map(\.speakerName))
        XCTAssertEqual(remoteNames, Set((1...5).map { "Speaker \($0)" }))
        XCTAssertTrue(events.contains(.activeSpeakers(["Speaker 1", "Speaker 2"])))
        XCTAssertTrue(segments.contains { $0.startTime == 0.5 && $0.endTime == 2 })
    }

    func testFinalReplacesPartialByStableSegmentIdentity() async throws {
        let id = UUID()
        let session = TestLocalTranscriptionSession()
        let coordinator = TranscriptionSessionCoordinator(
            provider: TestLocalTranscriptionProvider(session: session),
            configuration: configuration(locale: "en-US")
        )
        let collector = EventCollector(stream: coordinator.events)
        try await coordinator.start()
        session.emit(.partial(segment(id: id, speaker: "You", track: .microphone, text: "dra", final: false)))
        session.emit(.final(segment(id: id, speaker: "You", track: .microphone, text: "draft", final: true)))
        try await coordinator.finish()

        let projection = LiveTranscriptProjection(events: await collector.value)
        XCTAssertEqual(projection.segments.count, 1)
        XCTAssertEqual(projection.segments[0].text, "draft")
        XCTAssertTrue(projection.segments[0].isFinal)
    }

    func testBackpressureDropsPreviewFramesAndEmitsDegradationWithoutBlockingCapture() async throws {
        let session = TestLocalTranscriptionSession(blockSubmissions: true)
        let coordinator = TranscriptionSessionCoordinator(
            provider: TestLocalTranscriptionProvider(session: session),
            configuration: configuration(locale: "en-US"),
            queueCapacityPerTrack: 2
        )
        let collector = EventCollector(stream: coordinator.events)
        try await coordinator.start()
        for sequence in 0..<12 {
            try await coordinator.consume(frame(sequence: UInt64(sequence), track: .microphone))
        }
        await session.unblockSubmissions()
        try await coordinator.finish()

        let snapshot = await coordinator.snapshot()
        XCTAssertGreaterThan(snapshot.droppedFrameCount, 0)
        let events = await collector.value
        XCTAssertTrue(events.contains { event in
            if case .degraded = event { return true }
            return false
        })
        let evidence = await coordinator.previewEvidenceSnapshot()
        XCTAssertFalse(evidence.gaps.isEmpty)
        XCTAssertTrue(evidence.gaps.allSatisfy { $0.track == .microphone })
    }

    func testNoPreviewDropProducesNoReconstructedCoverageGap() async throws {
        let session = TestLocalTranscriptionSession()
        let coordinator = TranscriptionSessionCoordinator(
            provider: TestLocalTranscriptionProvider(session: session),
            configuration: configuration(locale: "en-US")
        )
        try await coordinator.start()
        try await coordinator.consume(frame(sequence: 1, track: .remoteSystem))
        try await coordinator.finish()

        let evidence = await coordinator.previewEvidenceSnapshot()
        XCTAssertTrue(evidence.gaps.isEmpty)
    }

    func testPreviewCoverageTrackerBoundsAndDeduplicatesPersistedEvidence() throws {
        let tracker = TranscriptPreviewCoverageTracker(maximumItemsPerKind: 1)
        let dropped = try frame(sequence: 1, track: .remoteSystem)
        let speaker = try TranscriptPreviewSpeakerIdentity(
            track: .remoteSystem,
            startTime: 0,
            endTime: 1,
            speakerName: "Speaker 1"
        )

        tracker.recordDroppedFrame(dropped)
        tracker.recordDroppedFrame(dropped)
        tracker.recordDroppedFrame(try frame(sequence: 2, track: .remoteSystem))
        tracker.recordSpeakerIdentity(speaker)
        tracker.recordSpeakerIdentity(speaker)
        tracker.recordSpeakerIdentity(try TranscriptPreviewSpeakerIdentity(
            track: .remoteSystem,
            startTime: 1,
            endTime: 2,
            speakerName: "Speaker 2"
        ))

        let evidence = tracker.snapshot()
        XCTAssertEqual(evidence.gaps.count, 1)
        XCTAssertEqual(evidence.speakerIdentities, [speaker])
    }

    func testProviderFailureIsolatedFromCaptureConsumerAndReportedOnce() async throws {
        let session = TestLocalTranscriptionSession()
        let coordinator = TranscriptionSessionCoordinator(
            provider: TestLocalTranscriptionProvider(session: session),
            configuration: configuration(locale: "en-US")
        )
        let collector = EventCollector(stream: coordinator.events)
        try await coordinator.start()
        session.fail("decoder failed")
        try await Task.sleep(for: .milliseconds(20))

        try await coordinator.consume(frame(sequence: 1, track: .microphone))
        try await coordinator.finish()

        let degraded = (await collector.value).filter {
            if case .degraded("Local transcription stopped: decoder failed") = $0 { return true }
            return false
        }
        XCTAssertEqual(degraded.count, 1)
    }

    func testFinishCancelAndSleepAreExactlyOnceAndLeaveNoTasks() async throws {
        for terminal: TranscriptionTerminalAction in [.finish, .cancel, .sleep] {
            let session = TestLocalTranscriptionSession()
            let coordinator = TranscriptionSessionCoordinator(
                provider: TestLocalTranscriptionProvider(session: session),
                configuration: configuration(locale: "en-US")
            )
            try await coordinator.start()
            try await coordinator.consume(frame(sequence: 1, track: .remoteSystem))
            switch terminal {
            case .finish:
                try await coordinator.finish()
                try await coordinator.finish()
            case .cancel:
                await coordinator.cancel()
                await coordinator.cancel()
            case .sleep:
                await coordinator.handleSystemSleep()
                await coordinator.handleSystemSleep()
            }
            let snapshot = await coordinator.snapshot()
            XCTAssertEqual(session.terminalCount, 1)
            XCTAssertEqual(snapshot.activeTaskCount, 0)
            XCTAssertTrue(snapshot.isTerminal)
        }
    }

    func testFinishErrorCancelsNonClosingProviderEventsAndReturnsBoundedly() async throws {
        let session = TestLocalTranscriptionSession(finishError: LiveTranscriptionProviderError(message: "finish failed"))
        let coordinator = TranscriptionSessionCoordinator(
            provider: TestLocalTranscriptionProvider(session: session),
            configuration: configuration(locale: "en-US")
        )
        try await coordinator.start()
        let result = LockedCounter()
        let finishTask = Task {
            try? await coordinator.finish()
            result.increment()
        }

        try await Task.sleep(for: .milliseconds(100))
        let returnedBoundedly = result.value == 1
        if !returnedBoundedly { await coordinator.cancel() }
        _ = await finishTask.result

        XCTAssertTrue(returnedBoundedly)
        let snapshot = await coordinator.snapshot()
        XCTAssertTrue(snapshot.isTerminal)
        XCTAssertEqual(snapshot.activeTaskCount, 0)
        XCTAssertTrue(snapshot.providerFailed)
    }

    func testMultipleLiveSpeakersKeepOneUncertainTextSegmentWithoutDuplicatingWords() async throws {
        let session = TestLocalTranscriptionSession()
        let coordinator = TranscriptionSessionCoordinator(
            provider: TestLocalTranscriptionProvider(session: session),
            configuration: configuration(locale: "en-US", expectedRemoteSpeakerCount: 5)
        )
        let collector = EventCollector(stream: coordinator.events)
        try await coordinator.start()
        session.emit(.activeSpeakers(["raw-1", "raw-2"]))
        session.emit(.final(segment(
            speaker: "Multiple speakers",
            track: .remoteSystem,
            text: "one shared utterance"
        )))
        try await coordinator.finish()

        let projection = LiveTranscriptProjection(events: await collector.value)
        XCTAssertEqual(projection.activeSpeakers.count, 2)
        XCTAssertEqual(projection.segments.map(\.text), ["one shared utterance"])
        XCTAssertEqual(projection.segments.map(\.speakerName), ["Multiple speakers"])
    }
}

private enum TranscriptionTerminalAction { case finish, cancel, sleep }

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = 0
    var value: Int { lock.withLock { storedValue } }
    func increment() { lock.withLock { storedValue += 1 } }
}

private final class EventCollector: @unchecked Sendable {
    private let task: Task<[LocalTranscriptionEvent], Never>
    init(stream: AsyncStream<LocalTranscriptionEvent>) {
        task = Task {
            var result: [LocalTranscriptionEvent] = []
            for await event in stream { result.append(event) }
            return result
        }
    }
    var value: [LocalTranscriptionEvent] { get async { await task.value } }
}

private final class TestLocalTranscriptionProvider: LocalTranscriptionProviding, @unchecked Sendable {
    let descriptor = ProviderDescriptor(
        id: "fixture-local",
        modelVersion: "fixture-v1",
        supportedLocaleIdentifiers: ["pl-PL", "en-US"],
        audioInputStrategy: .authoritativeCaptureFrames,
        supportsRemoteSpeakerDiarization: true,
        maximumRemoteSpeakerCount: 10
    )
    private let session: TestLocalTranscriptionSession
    private let lock = NSLock()
    private var storedConfigurations: [TranscriptionSessionConfiguration] = []
    var configurations: [TranscriptionSessionConfiguration] { lock.withLock { storedConfigurations } }
    init(session: TestLocalTranscriptionSession) { self.session = session }
    func makeSession(_ configuration: TranscriptionSessionConfiguration) async throws -> any LocalTranscriptionSession {
        lock.withLock { storedConfigurations.append(configuration) }
        return session
    }
}

private final class TestLocalTranscriptionSession: LocalTranscriptionSession, @unchecked Sendable {
    private let pair = AsyncThrowingStream<LocalTranscriptionEvent, Error>.makeStream(bufferingPolicy: .bufferingNewest(64))
    private let lock = NSLock()
    private let gate: SubmissionGate
    private var frames: [CapturedPCMFrame] = []
    private var finishCount = 0
    private var cancelCount = 0
    private let finishError: Error?
    var events: AsyncThrowingStream<LocalTranscriptionEvent, Error> { pair.stream }
    var submittedFrames: [CapturedPCMFrame] { lock.withLock { frames } }
    var terminalCount: Int { lock.withLock { finishCount + cancelCount } }
    init(blockSubmissions: Bool = false, finishError: Error? = nil) {
        gate = SubmissionGate(blocked: blockSubmissions)
        self.finishError = finishError
    }
    func submit(_ frame: CapturedPCMFrame) async throws {
        await gate.waitIfBlocked()
        lock.withLock { frames.append(frame) }
    }
    func finish() async throws {
        lock.withLock { finishCount += 1 }
        if let finishError { throw finishError }
        pair.continuation.finish()
    }
    func cancel() async {
        lock.withLock { cancelCount += 1 }
        pair.continuation.finish()
    }
    func emit(_ event: LocalTranscriptionEvent) { pair.continuation.yield(event) }
    func fail(_ message: String) { pair.continuation.finish(throwing: LiveTranscriptionProviderError(message: message)) }
    func unblockSubmissions() async { await gate.unblock() }
}

private actor SubmissionGate {
    private var blocked: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(blocked: Bool) { self.blocked = blocked }
    func waitIfBlocked() async {
        guard blocked else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func unblock() {
        blocked = false
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private func configuration(
    locale: String?,
    expectedRemoteSpeakerCount: Int? = nil,
    microphoneDeviceID: String? = nil
) -> TranscriptionSessionConfiguration {
    TranscriptionSessionConfiguration(
        meetingID: UUID(),
        context: MeetingContext(localeIdentifier: locale),
        expectedRemoteSpeakerCount: expectedRemoteSpeakerCount,
        microphoneDeviceID: microphoneDeviceID
    )
}

private func frame(sequence: UInt64, track: TrackKind) throws -> CapturedPCMFrame {
    try CapturedPCMFrame(
        sequence: sequence,
        track: track,
        meetingTime: Double(sequence) * 0.02,
        sampleRate: 16_000,
        channelCount: 1,
        frameCount: 4,
        pcm: Data(bytes: [Float](repeating: 0.25, count: 4), count: 16)
    )
}

private func segment(
    id: UUID = UUID(),
    speaker: String,
    track: TrackKind,
    start: TimeInterval = 0,
    end: TimeInterval = 1,
    text: String = "fixture",
    final: Bool = true
) -> TranscriptSegment {
    TranscriptSegment(
        id: id,
        speakerName: speaker,
        trackKind: track,
        startTime: start,
        endTime: end,
        text: text,
        confidence: 0.9,
        isFinal: final
    )
}

private extension LocalTranscriptionEvent {
    var segment: TranscriptSegment? {
        switch self {
        case let .partial(segment), let .final(segment): segment
        default: nil
        }
    }
}
