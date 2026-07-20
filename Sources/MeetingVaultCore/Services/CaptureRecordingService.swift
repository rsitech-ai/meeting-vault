import AudioToolbox
import Foundation

public protocol CaptureRecordingEngine: CaptureEngine {
    func record(_ request: CaptureRecordingRequest) async throws -> CaptureRecordingEngineOutput
}

public struct CaptureRecordingService: @unchecked Sendable {
    private let engine: any CaptureRecordingEngine
    private let chunkWriter: EncryptedAudioChunkWriter
    private let audioInputDeviceProvider: (any AudioInputDeviceProviding)?

    public init(
        engine: any CaptureRecordingEngine,
        chunkWriter: EncryptedAudioChunkWriter,
        audioInputDeviceProvider: (any AudioInputDeviceProviding)? = nil
    ) {
        self.engine = engine
        self.chunkWriter = chunkWriter
        self.audioInputDeviceProvider = audioInputDeviceProvider
    }

    public func availableSources() async throws -> [CaptureSource] {
        try await engine.availableSources()
    }

    public func record(_ request: CaptureRecordingRequest) async throws -> CaptureRecordingResult {
        let sources = try await availableSources()
        guard sources.contains(where: { $0.id == request.sourceID }) else {
            throw CaptureRecordingError.sourceUnavailable(request.sourceID)
        }
        try await validateSelectedMicrophone(request)

        var indexesByTrack: [TrackKind: Int] = [:]
        let sink = CaptureRecordingChunkSink { chunk in
            guard request.includeMicrophone || chunk.track != .microphone else {
                return nil
            }
            let chunkIndex = indexesByTrack[chunk.track, default: 0]
            let record = try chunkWriter.writeChunk(
                chunk.data,
                meetingID: request.meetingID,
                track: chunk.track,
                chunkIndex: chunkIndex,
                startTime: chunk.startTime,
                duration: chunk.duration,
                codec: chunk.codec
            )
            indexesByTrack[chunk.track] = chunkIndex + 1
            return record
        }
        let fanout = CaptureFrameFanout(request.previewDropHandler)
        let durableWriter = DurableCaptureFrameWriter(sink: sink)
        fanout.register(durableWriter, capacity: 256)
        for consumer in request.frameConsumers {
            fanout.register(consumer, capacity: 8)
        }
        var engineRequest = request
        engineRequest.chunkSink = sink
        engineRequest.frameEmitter = CaptureFrameEmitter(fanout: fanout)
        let output: CaptureRecordingEngineOutput
        do {
            output = try await engine.record(engineRequest)
        } catch {
            let engineFailure = error
            do {
                try await fanout.finish()
            } catch {
                throw CaptureRecordingError.interrupted(
                    sourceID: request.sourceID,
                    checkpointedChunkCount: sink.records.count,
                    reason: Self.failureMessage(for: error)
                )
            }
            if let writerFailure = await durableWriter.failure {
                throw CaptureRecordingError.interrupted(
                    sourceID: request.sourceID,
                    checkpointedChunkCount: sink.records.count,
                    reason: Self.failureMessage(for: writerFailure)
                )
            }
            let records = sink.records
            guard !records.isEmpty else {
                throw engineFailure
            }
            throw CaptureRecordingError.interrupted(
                sourceID: request.sourceID,
                checkpointedChunkCount: records.count,
                reason: Self.failureMessage(for: engineFailure)
            )
        }

        do {
            try await fanout.finish()
        } catch {
            throw CaptureRecordingError.interrupted(
                sourceID: request.sourceID,
                checkpointedChunkCount: sink.records.count,
                reason: Self.failureMessage(for: error)
            )
        }
        if let writerFailure = await durableWriter.failure {
            throw CaptureRecordingError.interrupted(
                sourceID: request.sourceID,
                checkpointedChunkCount: sink.records.count,
                reason: Self.failureMessage(for: writerFailure)
            )
        }

        for chunk in output.chunks {
            try sink.write(chunk)
        }
        let records = sink.records

        return CaptureRecordingResult(
            records: records,
            healthReport: output.healthReport,
            microphoneDeviceID: request.includeMicrophone ? request.microphoneDeviceID : nil,
            microphoneDeviceName: request.includeMicrophone ? request.microphoneDeviceName : nil
        )
    }

    private static func failureMessage(for error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription,
           !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return description
        }
        return String(describing: error)
    }

    private func validateSelectedMicrophone(_ request: CaptureRecordingRequest) async throws {
        guard request.includeMicrophone,
              let microphoneDeviceID = request.microphoneDeviceID,
              let audioInputDeviceProvider
        else {
            return
        }

        let devices = await audioInputDeviceProvider.snapshot()
        guard devices.contains(where: { $0.id == microphoneDeviceID && $0.isConnected }) else {
            throw CaptureRecordingError.microphoneUnavailable(
                id: microphoneDeviceID,
                name: request.microphoneDeviceName
            )
        }
    }
}

private actor DurableCaptureFrameWriter: CaptureFrameConsumer {
    nonisolated let id = "encrypted-capture-frame-writer"
    nonisolated let deliveryPolicy: CaptureFrameDeliveryPolicy = .durable

    private let sink: CaptureRecordingChunkSink
    private var accumulators: [TrackKind: LinearPCMAudioChunkAccumulator] = [:]
    private var startTimes: [TrackKind: TimeInterval] = [:]
    private(set) var failure: Error?
    private let maximumChunkBytes = 4_194_304
    private let maximumChunkDuration: TimeInterval = 5

    init(sink: CaptureRecordingChunkSink) {
        self.sink = sink
    }

    func consume(_ frame: CapturedPCMFrame) async throws {
        guard failure == nil else { throw failure! }
        do {
            try append(frame)
        } catch {
            failure = error
            throw error
        }
    }

    private func append(_ frame: CapturedPCMFrame) throws {
        let accumulator = accumulators[frame.track] ?? LinearPCMAudioChunkAccumulator()
        if accumulator.isEmpty {
            accumulators[frame.track] = accumulator
            startTimes[frame.track] = frame.meetingTime
        }
        let format = AudioStreamBasicDescription(
            mSampleRate: frame.sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(frame.channelCount * MemoryLayout<Float>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(frame.channelCount * MemoryLayout<Float>.size),
            mChannelsPerFrame: UInt32(frame.channelCount),
            mBitsPerChannel: UInt32(MemoryLayout<Float>.size * 8),
            mReserved: 0
        )
        try frame.pcm.withUnsafeBytes { bytes in
            var bufferList = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: UInt32(frame.channelCount),
                    mDataByteSize: UInt32(bytes.count),
                    mData: UnsafeMutableRawPointer(mutating: bytes.baseAddress)
                )
            )
            try withUnsafePointer(to: &bufferList) {
                try accumulator.append(
                    audioBufferList: $0,
                    format: format,
                    frameCount: UInt32(frame.frameCount)
                )
            }
        }
        if accumulator.byteCount >= maximumChunkBytes || accumulator.duration >= maximumChunkDuration {
            try flush(track: frame.track)
        }
    }

    func finish() async throws {
        do {
            for track in TrackKind.allCases {
                try flush(track: track)
            }
        } catch {
            failure = error
            throw error
        }
    }

    func cancel() async {
        accumulators.removeAll()
        startTimes.removeAll()
    }

    private func flush(track: TrackKind) throws {
        guard let accumulator = accumulators[track],
              let chunk = try accumulator.finishChunk()
        else { return }
        try sink.write(
            CapturedAudioChunk(
                track: track,
                data: chunk.data,
                startTime: startTimes[track] ?? 0,
                duration: max(0.000_001, chunk.duration),
                codec: "WAV/PCM-Float32"
            )
        )
        startTimes[track] = nil
    }
}

public final class MockCaptureRecordingEngine: CaptureRecordingEngine, @unchecked Sendable {
    public let id: String
    public let mode: CaptureMode
    private let sources: [CaptureSource]
    private let chunks: [CapturedAudioChunk]
    private let healthReport: CaptureHealthReport
    private let emitsSyntheticFramesDuringActiveRecording: Bool
    private let lock = NSLock()
    private var _recordingRequests: [CaptureRecordingRequest] = []

    public var recordingRequests: [CaptureRecordingRequest] {
        lock.lock()
        defer { lock.unlock() }
        return _recordingRequests
    }

    public init(
        id: String = "mock-capture",
        mode: CaptureMode = .selectedApplication,
        sources: [CaptureSource],
        chunks: [CapturedAudioChunk],
        healthReport: CaptureHealthReport,
        emitsSyntheticFramesDuringActiveRecording: Bool = false
    ) {
        self.id = id
        self.mode = mode
        self.sources = sources
        self.chunks = chunks
        self.healthReport = healthReport
        self.emitsSyntheticFramesDuringActiveRecording = emitsSyntheticFramesDuringActiveRecording
    }

    public func availableSources() async throws -> [CaptureSource] {
        sources
    }

    public func record(_ request: CaptureRecordingRequest) async throws -> CaptureRecordingEngineOutput {
        appendRecordingRequest(request)
        if emitsSyntheticFramesDuringActiveRecording,
           let frameEmitter = request.frameEmitter,
           let stopSignal = request.stopSignal {
            var pulse = 0
            while !stopSignal.isStopRequested && !Task.isCancelled {
                let amplitude: Float = pulse.isMultiple(of: 2) ? 0.18 : 0.52
                let samples = (0..<256).map { index in index.isMultiple(of: 2) ? amplitude : -amplitude }
                _ = try frameEmitter.emitCanonicalPCM(
                    samples.withUnsafeBytes { Data($0) },
                    sampleRate: 48_000,
                    channelCount: 1,
                    frameCount: samples.count,
                    track: .microphone
                )
                pulse += 1
                try await Task.sleep(for: .milliseconds(175))
            }
        }
        return CaptureRecordingEngineOutput(chunks: chunks, healthReport: healthReport)
    }

    private func appendRecordingRequest(_ request: CaptureRecordingRequest) {
        lock.lock()
        defer { lock.unlock() }
        _recordingRequests.append(request)
    }
}
