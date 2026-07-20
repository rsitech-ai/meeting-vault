import Foundation

public struct CapturedAudioChunk: Equatable, Sendable {
    public var track: TrackKind
    public var data: Data
    public var startTime: TimeInterval
    public var duration: TimeInterval
    public var codec: String

    public init(
        track: TrackKind,
        data: Data,
        startTime: TimeInterval,
        duration: TimeInterval,
        codec: String
    ) {
        self.track = track
        self.data = data
        self.startTime = startTime
        self.duration = duration
        self.codec = codec
    }
}

public final class CaptureRecordingStopSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false

    public init() {}

    public var isStopRequested: Bool {
        lock.withLock { stopped }
    }

    public func requestStop() {
        lock.withLock {
            stopped = true
        }
    }

    public func waitUntilStopped() async {
        while !isStopRequested && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
    }
}

public final class CaptureRecordingChunkSink: @unchecked Sendable {
    private let lock = NSLock()
    private let writer: (CapturedAudioChunk) throws -> AudioChunkRecord?
    private var storage: [AudioChunkRecord] = []

    public var records: [AudioChunkRecord] {
        lock.withLock { storage }
    }

    public init(writer: @escaping (CapturedAudioChunk) throws -> AudioChunkRecord?) {
        self.writer = writer
    }

    @discardableResult
    public func write(_ chunk: CapturedAudioChunk) throws -> AudioChunkRecord? {
        try lock.withLock {
            guard let record = try writer(chunk) else {
                return nil
            }
            storage.append(record)
            return record
        }
    }
}

public struct CaptureRecordingRequest: Equatable, Sendable {
    public var meetingID: UUID
    public var sourceID: String
    public var includeMicrophone: Bool
    public var microphoneDeviceID: String?
    public var microphoneDeviceName: String?
    public var maximumDuration: TimeInterval
    public var stopSignal: CaptureRecordingStopSignal?
    public var chunkSink: CaptureRecordingChunkSink?
    public var frameEmitter: CaptureFrameEmitter?
    public var frameConsumers: [any CaptureFrameConsumer]
    public var previewDropHandler: (@Sendable (Int) -> Void)?

    public init(
        meetingID: UUID,
        sourceID: String,
        includeMicrophone: Bool,
        microphoneDeviceID: String? = nil,
        microphoneDeviceName: String? = nil,
        maximumDuration: TimeInterval = 30,
        stopSignal: CaptureRecordingStopSignal? = nil,
        chunkSink: CaptureRecordingChunkSink? = nil,
        frameEmitter: CaptureFrameEmitter? = nil,
        frameConsumers: [any CaptureFrameConsumer] = [],
        previewDropHandler: (@Sendable (Int) -> Void)? = nil
    ) {
        self.meetingID = meetingID
        self.sourceID = sourceID
        self.includeMicrophone = includeMicrophone
        self.microphoneDeviceID = microphoneDeviceID
        self.microphoneDeviceName = microphoneDeviceName
        self.maximumDuration = max(0.1, maximumDuration)
        self.stopSignal = stopSignal
        self.chunkSink = chunkSink
        self.frameEmitter = frameEmitter
        self.frameConsumers = frameConsumers
        self.previewDropHandler = previewDropHandler
    }

    public static func == (lhs: CaptureRecordingRequest, rhs: CaptureRecordingRequest) -> Bool {
        lhs.meetingID == rhs.meetingID
            && lhs.sourceID == rhs.sourceID
            && lhs.includeMicrophone == rhs.includeMicrophone
            && lhs.microphoneDeviceID == rhs.microphoneDeviceID
            && lhs.microphoneDeviceName == rhs.microphoneDeviceName
            && lhs.maximumDuration == rhs.maximumDuration
    }
}

public struct CaptureRecordingEngineOutput: Equatable, Sendable {
    public var chunks: [CapturedAudioChunk]
    public var healthReport: CaptureHealthReport

    public init(chunks: [CapturedAudioChunk], healthReport: CaptureHealthReport) {
        self.chunks = chunks
        self.healthReport = healthReport
    }
}

public struct CaptureRecordingResult: Equatable, Sendable {
    public var records: [AudioChunkRecord]
    public var healthReport: CaptureHealthReport
    public var microphoneDeviceID: String?
    public var microphoneDeviceName: String?

    public init(
        records: [AudioChunkRecord],
        healthReport: CaptureHealthReport,
        microphoneDeviceID: String? = nil,
        microphoneDeviceName: String? = nil
    ) {
        self.records = records
        self.healthReport = healthReport
        self.microphoneDeviceID = microphoneDeviceID
        self.microphoneDeviceName = microphoneDeviceName
    }
}

public enum CaptureRecordingError: Error, Equatable {
    case sourceUnavailable(String)
    case microphoneUnavailable(id: String, name: String?)
    case systemAudioUnavailable(String)
    case interrupted(sourceID: String, checkpointedChunkCount: Int, reason: String)
}

extension CaptureRecordingError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .sourceUnavailable:
            return nil
        case let .microphoneUnavailable(id, name):
            let displayName = name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? name!
                : id
            return "Selected microphone \(displayName) is unavailable. Re-detect inputs before recording."
        case let .systemAudioUnavailable(reason):
            return "System audio capture is unavailable. \(reason)"
        case let .interrupted(sourceID, checkpointedChunkCount, reason):
            let chunkLabel = checkpointedChunkCount == 1 ? "checkpointed chunk" : "checkpointed chunks"
            return "Capture for \(sourceID) stopped after \(checkpointedChunkCount) \(chunkLabel): \(reason). Open Health & Recovery to review the incomplete encrypted bundle, then re-detect inputs or choose another source before retrying."
        }
    }
}
