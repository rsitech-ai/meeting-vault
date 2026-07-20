import Foundation

public enum CapturedPCMFrameError: Error, Equatable, Sendable {
    case invalidMeetingTime
    case invalidSampleRate
    case invalidChannelCount
    case invalidFrameCount
    case invalidPCMByteCount(expected: Int, actual: Int)
}

public struct CapturedPCMFrame: Equatable, Sendable {
    public static let maximumFrameCount = 16_384
    public static let maximumChannelCount = 32
    public static let maximumPCMByteCount = maximumFrameCount
        * maximumChannelCount
        * MemoryLayout<Float>.size

    public let sequence: UInt64
    public let track: TrackKind
    public let meetingTime: TimeInterval
    public let sampleRate: Double
    public let channelCount: Int
    public let frameCount: Int
    public let pcm: Data

    public init(
        sequence: UInt64,
        track: TrackKind,
        meetingTime: TimeInterval,
        sampleRate: Double,
        channelCount: Int,
        frameCount: Int,
        pcm: Data
    ) throws {
        guard meetingTime.isFinite, meetingTime >= 0 else {
            throw CapturedPCMFrameError.invalidMeetingTime
        }
        guard sampleRate.isFinite, sampleRate > 0 else {
            throw CapturedPCMFrameError.invalidSampleRate
        }
        guard channelCount > 0, channelCount <= Self.maximumChannelCount else {
            throw CapturedPCMFrameError.invalidChannelCount
        }
        guard frameCount > 0, frameCount <= Self.maximumFrameCount else {
            throw CapturedPCMFrameError.invalidFrameCount
        }
        let (sampleCount, sampleCountOverflow) = frameCount.multipliedReportingOverflow(by: channelCount)
        let (expectedByteCount, byteCountOverflow) = sampleCount.multipliedReportingOverflow(by: MemoryLayout<Float>.size)
        guard !sampleCountOverflow,
              !byteCountOverflow,
              expectedByteCount <= Self.maximumPCMByteCount
        else {
            throw CapturedPCMFrameError.invalidFrameCount
        }
        guard pcm.count == expectedByteCount else {
            throw CapturedPCMFrameError.invalidPCMByteCount(expected: expectedByteCount, actual: pcm.count)
        }
        self.sequence = sequence
        self.track = track
        self.meetingTime = meetingTime
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.frameCount = frameCount
        self.pcm = pcm
    }
}

public extension CapturedPCMFrame {
    var floatSamples: [Float] {
        pcm.withUnsafeBytes { bytes in
            Array(bytes.bindMemory(to: Float.self))
        }
    }

    var rmsLevel: Double {
        let samples = floatSamples
        guard !samples.isEmpty else { return 0 }
        let meanSquare = samples.reduce(0.0) { partial, sample in
            let value = Double(sample)
            return partial + value * value
        } / Double(samples.count)
        return min(1, max(0, meanSquare.squareRoot()))
    }
}

public enum CaptureFrameDeliveryPolicy: Sendable {
    case durable
    case preview
}

public enum FrameOfferResult: Equatable, Sendable {
    case accepted
    case previewDropped(Int)
    case durabilityRejected
}

public protocol CaptureFrameConsumer: Sendable {
    var id: String { get }
    var deliveryPolicy: CaptureFrameDeliveryPolicy { get }
    func consume(_ frame: CapturedPCMFrame) async throws
    func finish() async throws
    func cancel() async
}

public protocol CapturePreviewDropObserving: Sendable {
    func recordDroppedPreviewFrame(_ frame: CapturedPCMFrame)
}

public struct RecordingLevelSnapshot: Equatable, Sendable {
    public var microphone: Double
    public var systemAudio: Double
    public var lastMicrophoneFrameAt: ContinuousClock.Instant?
    public var lastSystemFrameAt: ContinuousClock.Instant?

    public init(
        microphone: Double = 0,
        systemAudio: Double = 0,
        lastMicrophoneFrameAt: ContinuousClock.Instant? = nil,
        lastSystemFrameAt: ContinuousClock.Instant? = nil
    ) {
        self.microphone = microphone
        self.systemAudio = systemAudio
        self.lastMicrophoneFrameAt = lastMicrophoneFrameAt
        self.lastSystemFrameAt = lastSystemFrameAt
    }
}
