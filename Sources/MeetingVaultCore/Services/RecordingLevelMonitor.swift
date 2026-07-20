import Foundation

public final class RecordingLevelMonitor: CaptureFrameConsumer, @unchecked Sendable {
    public let id: String
    public let deliveryPolicy: CaptureFrameDeliveryPolicy = .preview

    private let lock = NSLock()
    private let clock: ContinuousClock
    private let onSnapshot: @Sendable (RecordingLevelSnapshot) async -> Void
    private var snapshot = RecordingLevelSnapshot()

    public init(
        id: String = "recording-level-monitor",
        clock: ContinuousClock = ContinuousClock(),
        onSnapshot: @escaping @Sendable (RecordingLevelSnapshot) async -> Void
    ) {
        self.id = id
        self.clock = clock
        self.onSnapshot = onSnapshot
    }

    public func consume(_ frame: CapturedPCMFrame) async throws {
        let updated = lock.withLock {
            let level = frame.rmsLevel
            switch frame.track {
            case .microphone:
                snapshot.microphone = level
                snapshot.lastMicrophoneFrameAt = clock.now
            case .remoteSystem, .mixedPlayback:
                snapshot.systemAudio = level
                snapshot.lastSystemFrameAt = clock.now
            }
            return snapshot
        }
        await onSnapshot(updated)
    }

    public func finish() async {}
    public func cancel() async {}
}
