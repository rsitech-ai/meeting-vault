import Foundation

/// Realtime capture callbacks may report failure through this relay, but may
/// not perform teardown themselves. The relay latches exactly one failure and
/// schedules exactly one bounded control-queue action.
final class CaptureCallbackFailureRelay: @unchecked Sendable {
    private let lock = NSLock()
    private let callbackQueue: DispatchQueue?
    private let controlQueue: DispatchQueue
    private let handler: @Sendable (Error) -> Void
    private var firstFailure: Error?
    private var terminalCommitted = false

    init(
        callbackQueue: DispatchQueue? = nil,
        controlQueue: DispatchQueue,
        handler: @escaping @Sendable (Error) -> Void
    ) {
        self.callbackQueue = callbackQueue
        self.controlQueue = controlQueue
        self.handler = handler
    }

    var hasLatchedFailure: Bool {
        lock.withLock { firstFailure != nil }
    }

    @discardableResult
    func report(_ error: Error) -> Bool {
        let shouldSchedule = lock.withLock {
            guard firstFailure == nil, !terminalCommitted else { return false }
            firstFailure = error
            return true
        }
        guard shouldSchedule else { return false }
        let scheduleControlAction: @Sendable () -> Void = { [controlQueue, handler] in
            controlQueue.async {
                handler(error)
            }
        }
        if let callbackQueue {
            // Enqueue behind the currently executing serial callback before
            // handing off to control teardown. This prevents teardown from
            // overlapping or re-entering the callback that reported failure.
            callbackQueue.async(execute: scheduleControlAction)
        } else {
            scheduleControlAction()
        }
        return true
    }

    /// Atomically reserves terminal completion against callback failure
    /// reporting. A failure latched before this call always replaces a
    /// proposed success, even when its control-queue teardown is still queued.
    func arbitrate<Success>(_ result: Result<Success, Error>) -> Result<Success, Error> {
        lock.withLock {
            guard !terminalCommitted else { return result }
            terminalCommitted = true
            if let firstFailure {
                return .failure(firstFailure)
            }
            return result
        }
    }
}

/// Resolves capture completion only after the producer has been stopped and
/// every callback already accepted by its serial queue has run. Callers defer
/// all terminal reads and finalization work to the result closure so a final
/// queued callback is reflected in the proposed result before failure
/// arbitration.
final class CaptureCallbackTerminalizer<Success>: @unchecked Sendable {
    private let callbackQueue: DispatchQueue
    private let failureRelay: CaptureCallbackFailureRelay

    init(
        callbackQueue: DispatchQueue,
        failureRelay: CaptureCallbackFailureRelay
    ) {
        self.callbackQueue = callbackQueue
        self.failureRelay = failureRelay
    }

    func resolveAfterProducerStopped(
        _ makeProposedResult: () -> Result<Success, Error>
    ) -> Result<Success, Error> {
        callbackQueue.sync {}
        return failureRelay.arbitrate(makeProposedResult())
    }
}
