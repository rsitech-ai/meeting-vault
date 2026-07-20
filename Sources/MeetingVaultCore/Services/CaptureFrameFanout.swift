import Foundation

public enum CaptureFrameFanoutError: Error, Equatable, Sendable {
    case durableCapacityExceeded(sequence: UInt64, track: TrackKind)
    case durableConsumerFailed(consumerID: String, reason: String)
}

public final class CaptureFrameFanout: @unchecked Sendable {
    private enum State {
        case active
        case finishing
        case cancelling
        case finished
    }

    private let lock = NSLock()
    private let previewTelemetryQueue = DispatchQueue(
        label: "com.andrzej.MeetingVault.capture-preview-telemetry"
    )
    private let previewDropHandler: (@Sendable (Int) -> Void)?
    private var state: State = .active
    private var lanes: [String: CaptureFrameLane] = [:]
    private var previewDropCount = 0
    private var previewTelemetryScheduled = false
    private var firstDurableFailure: CaptureFrameFanoutError?

    public init(_ previewDropHandler: (@Sendable (Int) -> Void)? = nil) {
        self.previewDropHandler = previewDropHandler
    }

    public var cumulativePreviewDropCount: Int {
        lock.withLock { previewDropCount }
    }

    public var isAcceptingFrames: Bool {
        lock.withLock { state == .active }
    }

    public func register(_ consumer: any CaptureFrameConsumer, capacity: Int) {
        let lane: CaptureFrameLane? = lock.withLock {
            guard state == .active,
                  lanes[consumer.id] == nil
            else { return nil }
            let lane = CaptureFrameLane(
                consumer: consumer,
                capacity: max(1, capacity),
                onDurableFailure: { [weak self] consumerID, error in
                    self?.latchDurableFailure(consumerID: consumerID, error: error)
                }
            )
            lanes[consumer.id] = lane
            return lane
        }
        lane?.start()
    }

    public func offer(_ frame: CapturedPCMFrame) -> FrameOfferResult {
        var shouldScheduleTelemetry = false
        let result: FrameOfferResult = lock.withLock {
            guard state == .active else { return .durabilityRejected }
            let currentLanes = Array(lanes.values)
            let durableLanes = currentLanes.filter { $0.deliveryPolicy == .durable }
            guard durableLanes.allSatisfy(\.canAcceptDurableFrame) else {
                latchDurableCapacityFailureLocked(frame)
                return .durabilityRejected
            }

            // Durable lane state changes are initiated only while this global
            // lock is held. Preflight plus enqueue is therefore one atomic
            // admission transaction across every durable consumer.
            durableLanes.forEach { $0.enqueuePreflightedDurable(frame) }

            var droppedThisOffer = 0
            for lane in currentLanes where lane.deliveryPolicy == .preview {
                droppedThisOffer += lane.enqueuePreview(frame)
            }
            if droppedThisOffer > 0 {
                previewDropCount += droppedThisOffer
                if previewDropHandler != nil, !previewTelemetryScheduled {
                    previewTelemetryScheduled = true
                    shouldScheduleTelemetry = true
                }
                return .previewDropped(previewDropCount)
            }
            return .accepted
        }
        if shouldScheduleTelemetry {
            previewTelemetryQueue.async { [self] in
                publishPreviewDropTelemetry()
            }
        }
        return result
    }

    public func finish() async throws {
        let currentLanes: [CaptureFrameLane] = lock.withLock {
            switch state {
            case .active:
                state = .finishing
                lanes.values.forEach { $0.beginFinish() }
            case .finishing, .finished:
                break
            case .cancelling:
                break
            }
            return Array(lanes.values)
        }
        await withTaskGroup(of: Void.self) { group in
            for lane in currentLanes {
                group.addTask { await lane.waitForTermination() }
            }
        }
        let failure = lock.withLock {
            if state == .finishing {
                state = .finished
            }
            return firstDurableFailure
        }
        if let failure { throw failure }
    }

    public func cancel() async {
        let currentLanes: [CaptureFrameLane] = lock.withLock {
            if state == .active {
                state = .cancelling
                lanes.values.forEach { $0.beginCancel() }
            }
            return Array(lanes.values)
        }
        await withTaskGroup(of: Void.self) { group in
            for lane in currentLanes {
                group.addTask { await lane.waitForTermination() }
            }
        }
        lock.withLock { state = .finished }
    }

    func finishProducerAfterFailedStop() {
        lock.withLock {
            guard state == .active else { return }
            state = .finishing
            for lane in lanes.values {
                if lane.deliveryPolicy == .durable {
                    lane.beginFinish()
                } else {
                    lane.beginCancel()
                }
            }
        }
    }

    private func latchDurableFailure(consumerID: String, error: Error) {
        lock.withLock {
            guard firstDurableFailure == nil else { return }
            firstDurableFailure = .durableConsumerFailed(
                consumerID: consumerID,
                reason: Self.failureReason(error)
            )
            guard state != .finished else { return }
            state = .finishing
            for (laneID, lane) in lanes {
                if lane.deliveryPolicy == .durable, laneID != consumerID {
                    // Frames admitted before the global failure belong to
                    // every durable lane. Drain those peer lanes before
                    // terminal failure; only the failed lane and replaceable
                    // preview work are cancelled immediately.
                    lane.beginFinish()
                } else {
                    lane.beginCancel()
                }
            }
        }
    }

    private func latchDurableCapacityFailureLocked(_ frame: CapturedPCMFrame) {
        guard firstDurableFailure == nil else { return }
        firstDurableFailure = .durableCapacityExceeded(
            sequence: frame.sequence,
            track: frame.track
        )
        state = .finishing
        for lane in lanes.values {
            if lane.deliveryPolicy == .durable {
                lane.beginFinish()
            } else {
                lane.beginCancel()
            }
        }
    }

    private func publishPreviewDropTelemetry() {
        let count = lock.withLock {
            previewTelemetryScheduled = false
            return previewDropCount
        }
        previewDropHandler?(count)
    }

    private static func failureReason(_ error: Error) -> String {
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription,
           !description.isEmpty {
            return description
        }
        return String(describing: error)
    }
}

private final class CaptureFrameLane: @unchecked Sendable {
    private enum State {
        case active
        case finishing
        case cancelling
        case terminating
        case terminated
    }

    private enum Action {
        case consume(CapturedPCMFrame)
        case finish
        case cancel
    }

    let deliveryPolicy: CaptureFrameDeliveryPolicy

    private let consumer: any CaptureFrameConsumer
    private let onDurableFailure: @Sendable (String, Error) -> Void
    private let capacity: Int
    private let lock = NSLock()
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private var worker: Task<Void, Never>?
    private var state: State = .active
    private var queue: [CapturedPCMFrame] = []
    private var terminationWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        consumer: any CaptureFrameConsumer,
        capacity: Int,
        onDurableFailure: @escaping @Sendable (String, Error) -> Void
    ) {
        self.consumer = consumer
        self.onDurableFailure = onDurableFailure
        deliveryPolicy = consumer.deliveryPolicy
        self.capacity = capacity
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        stream = pair.stream
        continuation = pair.continuation
        queue.reserveCapacity(capacity)
    }

    func start() {
        lock.withLock {
            guard worker == nil else { return }
            worker = Task { [weak self] in
                await self?.run()
            }
        }
    }

    var canAcceptDurableFrame: Bool {
        lock.withLock { state == .active && queue.count < capacity }
    }

    func enqueuePreflightedDurable(_ frame: CapturedPCMFrame) {
        let accepted = lock.withLock {
            guard state == .active, queue.count < capacity else {
                assertionFailure("Durable admission changed during global transaction")
                return false
            }
            queue.append(frame)
            return true
        }
        if accepted { continuation.yield() }
    }

    func enqueuePreview(_ frame: CapturedPCMFrame) -> Int {
        let result: (accepted: Bool, droppedFrame: CapturedPCMFrame?) = lock.withLock {
            guard state == .active else { return (false, nil) }
            let droppedFrame = queue.count == capacity ? queue.removeFirst() : nil
            queue.append(frame)
            return (true, droppedFrame)
        }
        if let droppedFrame = result.droppedFrame {
            (consumer as? any CapturePreviewDropObserving)?.recordDroppedPreviewFrame(droppedFrame)
        }
        if result.accepted { continuation.yield() }
        return result.droppedFrame == nil ? 0 : 1
    }

    func beginFinish() {
        let shouldWake = lock.withLock {
            guard state == .active else { return false }
            state = .finishing
            return true
        }
        if shouldWake { continuation.yield() }
    }

    func beginCancel() {
        let shouldWake = lock.withLock {
            switch state {
            case .active, .finishing:
                state = .cancelling
                queue.removeAll(keepingCapacity: true)
                return true
            case .cancelling, .terminating, .terminated:
                return false
            }
        }
        if shouldWake { continuation.yield() }
    }

    func waitForTermination() async {
        await withCheckedContinuation { waiter in
            let alreadyTerminated = lock.withLock {
                if state == .terminated {
                    return true
                }
                terminationWaiters.append(waiter)
                return false
            }
            if alreadyTerminated {
                waiter.resume()
            }
        }
    }

    private func run() async {
        for await _ in stream {
            while let action = nextAction() {
                switch action {
                case let .consume(frame):
                    do {
                        try await consumer.consume(frame)
                    } catch {
                        if deliveryPolicy == .durable {
                            onDurableFailure(consumer.id, error)
                        }
                    }
                case .finish:
                    do {
                        try await consumer.finish()
                    } catch {
                        if deliveryPolicy == .durable {
                            onDurableFailure(consumer.id, error)
                        }
                    }
                    terminate()
                    return
                case .cancel:
                    await consumer.cancel()
                    terminate()
                    return
                }
            }
        }
    }

    private func nextAction() -> Action? {
        lock.withLock {
            if state == .cancelling {
                state = .terminating
                return .cancel
            }
            if !queue.isEmpty {
                return .consume(queue.removeFirst())
            }
            if state == .finishing {
                state = .terminating
                return .finish
            }
            return nil
        }
    }

    private func terminate() {
        let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
            state = .terminated
            let waiters = terminationWaiters
            terminationWaiters.removeAll()
            return waiters
        }
        continuation.finish()
        waiters.forEach { $0.resume() }
    }
}
