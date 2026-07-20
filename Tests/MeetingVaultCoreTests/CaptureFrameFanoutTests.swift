import Foundation
import MeetingVaultCore
import XCTest

final class CaptureFrameFanoutTests: XCTestCase {
    func testDurableConsumerReceivesFramesInOfferOrderAcrossTracks() async throws {
        let consumer = RecordingFrameConsumer(id: "durable", policy: .durable)
        let fanout = CaptureFrameFanout()
        fanout.register(consumer, capacity: 8)

        let offered = try [
            frame(sequence: 0, track: .remoteSystem, meetingTime: 0.010),
            frame(sequence: 0, track: .microphone, meetingTime: 0.012),
            frame(sequence: 1, track: .remoteSystem, meetingTime: 0.030),
            frame(sequence: 1, track: .microphone, meetingTime: 0.032),
        ]
        for frame in offered {
            XCTAssertEqual(fanout.offer(frame), .accepted)
        }

        try await fanout.finish()

        let delivered = await consumer.frames()
        XCTAssertEqual(delivered, offered)
    }

    func testSequencesAndMeetingTimesRemainMonotonicPerTrack() async throws {
        let consumer = RecordingFrameConsumer(id: "durable", policy: .durable)
        let fanout = CaptureFrameFanout()
        fanout.register(consumer, capacity: 8)

        for frame in try [
            frame(sequence: 0, track: .microphone, meetingTime: 0.005),
            frame(sequence: 0, track: .remoteSystem, meetingTime: 0.006),
            frame(sequence: 1, track: .microphone, meetingTime: 0.025),
            frame(sequence: 1, track: .remoteSystem, meetingTime: 0.026),
        ] {
            XCTAssertEqual(fanout.offer(frame), .accepted)
        }
        try await fanout.finish()

        let delivered = await consumer.frames()
        for track in [TrackKind.microphone, .remoteSystem] {
            let trackFrames = delivered.filter { $0.track == track }
            XCTAssertEqual(trackFrames.map(\.sequence), [0, 1])
            XCTAssertEqual(trackFrames.map(\.meetingTime), trackFrames.map(\.meetingTime).sorted())
        }
    }

    func testDurableSaturationRejectsNewestFrameWithoutLossOrReordering() async throws {
        let gate = AsyncTestGate()
        let consumer = RecordingFrameConsumer(id: "durable", policy: .durable, gate: gate)
        let fanout = CaptureFrameFanout()
        fanout.register(consumer, capacity: 1)

        XCTAssertEqual(fanout.offer(try frame(sequence: 0)), .accepted)
        await gate.waitUntilEntered()
        XCTAssertEqual(fanout.offer(try frame(sequence: 1)), .accepted)
        XCTAssertEqual(fanout.offer(try frame(sequence: 2)), .durabilityRejected)

        await gate.open()
        do {
            try await fanout.finish()
            XCTFail("Expected saturated durability lane to fail terminally")
        } catch {
            XCTAssertEqual(
                error as? CaptureFrameFanoutError,
                .durableCapacityExceeded(sequence: 2, track: .microphone)
            )
        }

        let deliveredSequences = await consumer.frames().map(\.sequence)
        XCTAssertEqual(deliveredSequences, [0, 1])
    }

    func testDurableSaturationSealsFirstFailureAndRejectsPostDrainOffers() async throws {
        let gate = AsyncTestGate()
        let durable = RecordingFrameConsumer(id: "durable", policy: .durable, gate: gate)
        let preview = RecordingFrameConsumer(id: "preview", policy: .preview)
        let fanout = CaptureFrameFanout()
        fanout.register(durable, capacity: 1)
        fanout.register(preview, capacity: 8)

        XCTAssertEqual(fanout.offer(try frame(sequence: 0)), .accepted)
        await gate.waitUntilEntered()
        XCTAssertEqual(fanout.offer(try frame(sequence: 1)), .accepted)
        XCTAssertEqual(fanout.offer(try frame(sequence: 2)), .durabilityRejected)
        XCTAssertFalse(fanout.isAcceptingFrames)

        await gate.open()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while await durable.frames().count < 2, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let drainedSequences = await durable.frames().map(\.sequence)
        XCTAssertEqual(drainedSequences, [0, 1])

        XCTAssertEqual(fanout.offer(try frame(sequence: 3)), .durabilityRejected)

        async let finishing: Void = fanout.finish()
        async let cancelling: Void = fanout.cancel()
        await cancelling
        do {
            try await finishing
            XCTFail("Expected the first durable capacity failure to be surfaced")
        } catch {
            XCTAssertEqual(
                error as? CaptureFrameFanoutError,
                .durableCapacityExceeded(sequence: 2, track: .microphone)
            )
        }

        let finalDurableSequences = await durable.frames().map(\.sequence)
        let durableFinishCount = await durable.finishCount()
        let durableCancelCount = await durable.cancelCount()
        let previewSequences = await preview.frames().map(\.sequence)
        let previewFinishCount = await preview.finishCount()
        let previewCancelCount = await preview.cancelCount()
        XCTAssertEqual(finalDurableSequences, [0, 1])
        XCTAssertEqual(durableFinishCount, 1)
        XCTAssertEqual(durableCancelCount, 0)
        XCTAssertFalse(previewSequences.contains(3))
        XCTAssertEqual(previewFinishCount, 0)
        XCTAssertEqual(previewCancelCount, 1)
    }

    func testMultipleDurableLanesRejectAdmissionAtomicallyWhenAnyLaneIsFull() async throws {
        let gate = AsyncTestGate()
        let constrained = RecordingFrameConsumer(id: "constrained", policy: .durable, gate: gate)
        let peer = RecordingFrameConsumer(id: "peer", policy: .durable)
        let fanout = CaptureFrameFanout()
        fanout.register(constrained, capacity: 1)
        fanout.register(peer, capacity: 8)

        XCTAssertEqual(fanout.offer(try frame(sequence: 0)), .accepted)
        await gate.waitUntilEntered()
        XCTAssertEqual(fanout.offer(try frame(sequence: 1)), .accepted)
        XCTAssertEqual(fanout.offer(try frame(sequence: 2)), .durabilityRejected)

        await gate.open()
        do {
            try await fanout.finish()
            XCTFail("Expected atomic durable admission failure to fail terminally")
        } catch {
            XCTAssertEqual(
                error as? CaptureFrameFanoutError,
                .durableCapacityExceeded(sequence: 2, track: .microphone)
            )
        }

        let constrainedSequences = await constrained.frames().map(\.sequence)
        let peerSequences = await peer.frames().map(\.sequence)
        XCTAssertEqual(constrainedSequences, [0, 1])
        XCTAssertEqual(peerSequences, [0, 1])
    }

    func testPreviewOverflowKeepsNewestFrameAndReportsCumulativeDropCount() async throws {
        let gate = AsyncTestGate()
        let consumer = RecordingFrameConsumer(id: "meter", policy: .preview, gate: gate)
        let fanout = CaptureFrameFanout()
        fanout.register(consumer, capacity: 1)

        XCTAssertEqual(fanout.offer(try frame(sequence: 0)), .accepted)
        await gate.waitUntilEntered()
        XCTAssertEqual(fanout.offer(try frame(sequence: 1)), .accepted)
        XCTAssertEqual(fanout.offer(try frame(sequence: 2)), .previewDropped(1))
        XCTAssertEqual(fanout.offer(try frame(sequence: 3)), .previewDropped(2))

        await gate.open()
        try await fanout.finish()

        let deliveredSequences = await consumer.frames().map(\.sequence)
        XCTAssertEqual(deliveredSequences, [0, 3])
    }

    func testPreviewDropsPublishCumulativeTelemetryOffTheOfferThreadWithoutFailingCapture() async throws {
        let gate = AsyncTestGate()
        let consumer = RecordingFrameConsumer(id: "meter", policy: .preview, gate: gate)
        let recorder = PreviewDropRecorder()
        let offerQueue = OfferQueueDetector()
        let fanout = CaptureFrameFanout { count in
            recorder.append(
                count,
                wasOnOfferThread: offerQueue.isOnOfferQueue
            )
        }
        fanout.register(consumer, capacity: 1)

        XCTAssertEqual(fanout.offer(try frame(sequence: 0)), .accepted)
        await gate.waitUntilEntered()
        XCTAssertEqual(fanout.offer(try frame(sequence: 1)), .accepted)
        let frame2 = try frame(sequence: 2)
        let frame3 = try frame(sequence: 3)
        let droppedResults = offerQueue.perform {
            (
                fanout.offer(frame2),
                fanout.offer(frame3)
            )
        }

        XCTAssertEqual(droppedResults.0, .previewDropped(1))
        XCTAssertEqual(droppedResults.1, .previewDropped(2))
        XCTAssertEqual(fanout.cumulativePreviewDropCount, 2)
        try await waitUntil("cumulative preview drop telemetry is published") {
            recorder.counts.contains(2)
        }
        XCTAssertFalse(recorder.wasPublishedOnOfferThread)

        await gate.open()
        try await fanout.finish()
        let deliveredSequences = await consumer.frames().map(\.sequence)
        XCTAssertEqual(deliveredSequences, [0, 3])
    }

    func testFinishDrainsQueuedFramesAndFinishesConsumerExactlyOnce() async throws {
        let consumer = RecordingFrameConsumer(id: "durable", policy: .durable)
        let fanout = CaptureFrameFanout()
        fanout.register(consumer, capacity: 2)
        XCTAssertEqual(fanout.offer(try frame(sequence: 0)), .accepted)

        async let firstFinish: Void = fanout.finish()
        async let secondFinish: Void = fanout.finish()
        _ = try await (firstFinish, secondFinish)
        try await fanout.finish()

        let deliveredSequences = await consumer.frames().map(\.sequence)
        let finishCount = await consumer.finishCount()
        let cancelCount = await consumer.cancelCount()
        XCTAssertEqual(deliveredSequences, [0])
        XCTAssertEqual(finishCount, 1)
        XCTAssertEqual(cancelCount, 0)
        XCTAssertEqual(fanout.offer(try frame(sequence: 1)), .durabilityRejected)
        try await Task.sleep(for: .milliseconds(30))
        let sequencesAfterTerminalOffer = await consumer.frames().map(\.sequence)
        XCTAssertEqual(sequencesAfterTerminalOffer, [0])
    }

    func testFirstDurableConsumeFailureIsReportedByFinishAndRejectsFurtherOffersGlobally() async throws {
        let failing = FailingFrameConsumer(
            id: "failing-durable",
            policy: .durable,
            failure: TestConsumerError.consumeFailed
        )
        let peer = RecordingFrameConsumer(id: "durable-peer", policy: .durable)
        let fanout = CaptureFrameFanout()
        fanout.register(failing, capacity: 2)
        fanout.register(peer, capacity: 2)

        XCTAssertEqual(fanout.offer(try frame(sequence: 0)), .accepted)
        await failing.waitUntilConsumeFailed()
        XCTAssertEqual(fanout.offer(try frame(sequence: 1)), .durabilityRejected)

        do {
            try await fanout.finish()
            XCTFail("Expected the first durable consumer failure to be surfaced")
        } catch {
            XCTAssertEqual(
                error as? CaptureFrameFanoutError,
                .durableConsumerFailed(
                    consumerID: "failing-durable",
                    reason: "consumeFailed"
                )
            )
        }
        let peerSequences = await peer.frames().map(\.sequence)
        XCTAssertEqual(peerSequences, [0])
    }

    func testDurableFinishFailureFromFinalFrameIsReported() async throws {
        let consumer = FailingFinishFrameConsumer(id: "final-frame-writer")
        let fanout = CaptureFrameFanout()
        fanout.register(consumer, capacity: 1)
        XCTAssertEqual(fanout.offer(try frame(sequence: 0)), .accepted)

        do {
            try await fanout.finish()
            XCTFail("Expected the durable finalization failure to be surfaced")
        } catch {
            XCTAssertEqual(
                error as? CaptureFrameFanoutError,
                .durableConsumerFailed(
                    consumerID: "final-frame-writer",
                    reason: "finishFailed"
                )
            )
        }
        let consumedSequences = await consumer.consumedSequences()
        let finishCount = await consumer.finishCount()
        let cancelCount = await consumer.cancelCount()
        XCTAssertEqual(consumedSequences, [0])
        XCTAssertEqual(finishCount, 1)
        XCTAssertEqual(cancelCount, 0)
    }

    func testCancelDropsQueuedFramesAndCancelsConsumerExactlyOnce() async throws {
        let gate = AsyncTestGate()
        let consumer = RecordingFrameConsumer(id: "preview", policy: .preview, gate: gate)
        let fanout = CaptureFrameFanout()
        fanout.register(consumer, capacity: 2)
        XCTAssertEqual(fanout.offer(try frame(sequence: 0)), .accepted)
        await gate.waitUntilEntered()
        XCTAssertEqual(fanout.offer(try frame(sequence: 1)), .accepted)

        async let firstCancel: Void = fanout.cancel()
        async let secondCancel: Void = fanout.cancel()
        await Task.yield()
        await gate.open()
        _ = await (firstCancel, secondCancel)
        await fanout.cancel()

        let deliveredSequences = await consumer.frames().map(\.sequence)
        let finishCount = await consumer.finishCount()
        let cancelCount = await consumer.cancelCount()
        XCTAssertEqual(deliveredSequences, [0])
        XCTAssertEqual(finishCount, 0)
        XCTAssertEqual(cancelCount, 1)
    }

    func testFinishWinsFinishVersusCancelRaceWithoutMixedTerminalCallbacks() async throws {
        let gate = AsyncTestGate()
        let consumer = RecordingFrameConsumer(id: "durable", policy: .durable, gate: gate)
        let fanout = CaptureFrameFanout()
        fanout.register(consumer, capacity: 8)
        XCTAssertEqual(fanout.offer(try frame(sequence: 0)), .accepted)
        await gate.waitUntilEntered()

        async let finishing: Void = fanout.finish()
        while fanout.isAcceptingFrames {
            await Task.yield()
        }
        async let cancelling: Void = fanout.cancel()
        await gate.open()
        try await finishing
        await cancelling

        let finishCount = await consumer.finishCount()
        let cancelCount = await consumer.cancelCount()
        XCTAssertEqual(finishCount, 1)
        XCTAssertEqual(cancelCount, 0)
    }

    func testNoConsumerReceivesFramesRegisteredOrOfferedAfterTerminalState() async throws {
        let first = RecordingFrameConsumer(id: "first", policy: .durable)
        let late = RecordingFrameConsumer(id: "late", policy: .durable)
        let fanout = CaptureFrameFanout()
        fanout.register(first, capacity: 1)
        try await fanout.finish()

        fanout.register(late, capacity: 1)
        XCTAssertEqual(fanout.offer(try frame(sequence: 0)), .durabilityRejected)
        try await Task.sleep(for: .milliseconds(30))

        let firstFrames = await first.frames()
        let firstFinishCount = await first.finishCount()
        let lateFrames = await late.frames()
        let lateFinishCount = await late.finishCount()
        let lateCancelCount = await late.cancelCount()
        XCTAssertTrue(firstFrames.isEmpty)
        XCTAssertEqual(firstFinishCount, 1)
        XCTAssertTrue(lateFrames.isEmpty)
        XCTAssertEqual(lateFinishCount, 0)
        XCTAssertEqual(lateCancelCount, 0)
    }

    func testFrameBoundaryRejectsInvalidTimingAndGeometry() throws {
        XCTAssertThrowsError(
            try CapturedPCMFrame(
                sequence: 0,
                track: .microphone,
                meetingTime: .nan,
                sampleRate: 48_000,
                channelCount: 1,
                frameCount: 1,
                pcm: floatPCM([0])
            )
        )
        XCTAssertThrowsError(
            try CapturedPCMFrame(
                sequence: 0,
                track: .microphone,
                meetingTime: -0.1,
                sampleRate: 48_000,
                channelCount: 1,
                frameCount: 1,
                pcm: floatPCM([0])
            )
        )
        XCTAssertThrowsError(
            try CapturedPCMFrame(
                sequence: 0,
                track: .microphone,
                meetingTime: 0,
                sampleRate: 0,
                channelCount: 1,
                frameCount: 1,
                pcm: floatPCM([0])
            )
        )
        XCTAssertThrowsError(
            try CapturedPCMFrame(
                sequence: 0,
                track: .microphone,
                meetingTime: 0,
                sampleRate: 48_000,
                channelCount: 2,
                frameCount: 1,
                pcm: floatPCM([0])
            )
        )
        XCTAssertThrowsError(
            try CapturedPCMFrame(
                sequence: 0,
                track: .microphone,
                meetingTime: 0,
                sampleRate: 48_000,
                channelCount: 33,
                frameCount: 1,
                pcm: floatPCM(Array(repeating: 0, count: 33))
            )
        )
    }

    private func frame(
        sequence: UInt64,
        track: TrackKind = .microphone,
        meetingTime: TimeInterval = 0
    ) throws -> CapturedPCMFrame {
        try CapturedPCMFrame(
            sequence: sequence,
            track: track,
            meetingTime: meetingTime,
            sampleRate: 48_000,
            channelCount: 1,
            frameCount: 2,
            pcm: floatPCM([0.25, -0.25])
        )
    }

    private func floatPCM(_ samples: [Float]) -> Data {
        samples.withUnsafeBytes { Data($0) }
    }

    private func waitUntil(
        _ description: String,
        timeout: Duration = .seconds(1),
        condition: @escaping @Sendable () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            if clock.now >= deadline {
                XCTFail("Timed out waiting until \(description)")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private actor RecordingFrameConsumer: CaptureFrameConsumer {
    nonisolated let id: String
    nonisolated let deliveryPolicy: CaptureFrameDeliveryPolicy
    private let gate: AsyncTestGate?
    private var storage: [CapturedPCMFrame] = []
    private var finishes = 0
    private var cancellations = 0

    init(id: String, policy: CaptureFrameDeliveryPolicy, gate: AsyncTestGate? = nil) {
        self.id = id
        deliveryPolicy = policy
        self.gate = gate
    }

    func consume(_ frame: CapturedPCMFrame) async throws {
        storage.append(frame)
        if storage.count == 1 {
            await gate?.enterAndWait()
        }
    }

    func finish() async {
        finishes += 1
    }

    func cancel() async {
        cancellations += 1
    }

    func frames() -> [CapturedPCMFrame] { storage }
    func finishCount() -> Int { finishes }
    func cancelCount() -> Int { cancellations }
}

private actor AsyncTestGate {
    private var isOpen = false
    private var entered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var openWaiters: [CheckedContinuation<Void, Never>] = []

    func enterAndWait() async {
        entered = true
        entryWaiters.forEach { $0.resume() }
        entryWaiters.removeAll()
        guard !isOpen else { return }
        await withCheckedContinuation { openWaiters.append($0) }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func open() {
        isOpen = true
        openWaiters.forEach { $0.resume() }
        openWaiters.removeAll()
    }
}

private enum TestConsumerError: Error {
    case consumeFailed
    case finishFailed
}

private actor FailingFrameConsumer: CaptureFrameConsumer {
    nonisolated let id: String
    nonisolated let deliveryPolicy: CaptureFrameDeliveryPolicy
    private let failure: Error
    private var didFail = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(id: String, policy: CaptureFrameDeliveryPolicy, failure: Error) {
        self.id = id
        deliveryPolicy = policy
        self.failure = failure
    }

    func consume(_ frame: CapturedPCMFrame) async throws {
        didFail = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
        throw failure
    }

    func finish() async {}
    func cancel() async {}

    func waitUntilConsumeFailed() async {
        guard !didFail else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private actor FailingFinishFrameConsumer: CaptureFrameConsumer {
    nonisolated let id: String
    nonisolated let deliveryPolicy: CaptureFrameDeliveryPolicy = .durable
    private var sequences: [UInt64] = []
    private var finishes = 0
    private var cancellations = 0

    init(id: String) {
        self.id = id
    }

    func consume(_ frame: CapturedPCMFrame) async throws {
        sequences.append(frame.sequence)
    }

    func finish() async throws {
        finishes += 1
        throw TestConsumerError.finishFailed
    }

    func cancel() async {
        cancellations += 1
    }

    func consumedSequences() -> [UInt64] { sequences }
    func finishCount() -> Int { finishes }
    func cancelCount() -> Int { cancellations }
}

private final class PreviewDropRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Int] = []
    private var inlinePublication = false

    var counts: [Int] {
        lock.withLock { storage }
    }

    var wasPublishedOnOfferThread: Bool {
        lock.withLock { inlinePublication }
    }

    func append(_ count: Int, wasOnOfferThread: Bool) {
        lock.withLock {
            storage.append(count)
            inlinePublication = inlinePublication || wasOnOfferThread
        }
    }
}

private final class OfferQueueDetector: @unchecked Sendable {
    private let key = DispatchSpecificKey<Bool>()
    private let queue = DispatchQueue(label: "CaptureFrameFanoutTests.offer")

    init() {
        queue.setSpecific(key: key, value: true)
    }

    var isOnOfferQueue: Bool {
        DispatchQueue.getSpecific(key: key) == true
    }

    func perform<T>(_ operation: @Sendable () throws -> T) rethrows -> T {
        try queue.sync(execute: operation)
    }
}
