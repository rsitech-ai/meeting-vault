import CoreMedia
import Foundation
@preconcurrency import ScreenCaptureKit

public struct ScreenCaptureKitAudioCaptureRequest: Equatable, Sendable {
    public var meetingID: UUID
    public var sourceID: String
    public var maximumDuration: TimeInterval
    public var stopSignal: CaptureRecordingStopSignal?
    public var chunkSink: CaptureRecordingChunkSink?
    public var frameEmitter: CaptureFrameEmitter?

    public init(
        meetingID: UUID,
        sourceID: String,
        maximumDuration: TimeInterval,
        stopSignal: CaptureRecordingStopSignal? = nil,
        chunkSink: CaptureRecordingChunkSink? = nil,
        frameEmitter: CaptureFrameEmitter? = nil
    ) {
        self.meetingID = meetingID
        self.sourceID = sourceID
        self.maximumDuration = max(0.1, maximumDuration)
        self.stopSignal = stopSignal
        self.chunkSink = chunkSink
        self.frameEmitter = frameEmitter
    }

    public static func == (
        lhs: ScreenCaptureKitAudioCaptureRequest,
        rhs: ScreenCaptureKitAudioCaptureRequest
    ) -> Bool {
        lhs.meetingID == rhs.meetingID
            && lhs.sourceID == rhs.sourceID
            && lhs.maximumDuration == rhs.maximumDuration
    }
}

public protocol ScreenCaptureKitSystemAudioCapturing: Sendable {
    func capture(_ request: ScreenCaptureKitAudioCaptureRequest) async throws -> CapturedAudioChunk
}

public final class ScreenCaptureKitSystemAudioCaptureEngine: CaptureRecordingEngine, @unchecked Sendable {
    public let id = "screencapturekit-system-audio"
    public let mode: CaptureMode = .screenCaptureFallback

    private let source: CaptureSource
    private let capturer: any ScreenCaptureKitSystemAudioCapturing

    public init(
        source: CaptureSource = CaptureSource(
            id: "screencapturekit-system-audio",
            displayName: "System Audio",
            mode: .screenCaptureFallback,
            isRecommended: true,
            level: 0
        ),
        capturer: any ScreenCaptureKitSystemAudioCapturing = ScreenCaptureKitSystemAudioCapturer()
    ) {
        self.source = source
        self.capturer = capturer
    }

    public func availableSources() async throws -> [CaptureSource] {
        [source]
    }

    public func record(_ request: CaptureRecordingRequest) async throws -> CaptureRecordingEngineOutput {
        guard request.sourceID == source.id else {
            throw CaptureRecordingError.sourceUnavailable(request.sourceID)
        }

        let streamedRecordsBeforeCapture = request.chunkSink?.records.count ?? 0
        let chunk = try await capturer.capture(
            ScreenCaptureKitAudioCaptureRequest(
                meetingID: request.meetingID,
                sourceID: request.sourceID,
                maximumDuration: request.maximumDuration,
                stopSignal: request.stopSignal,
                chunkSink: request.chunkSink,
                frameEmitter: request.frameEmitter
            )
        )
        let streamedDuringCapture = request.frameEmitter?.hasEmittedFrames(for: .remoteSystem) == true
            || (request.chunkSink?.records.count ?? streamedRecordsBeforeCapture) > streamedRecordsBeforeCapture

        return CaptureRecordingEngineOutput(
            chunks: streamedDuringCapture ? [] : [chunk],
            healthReport: CaptureHealthReport(
                remoteDropouts: streamedDuringCapture || !chunk.data.isEmpty ? 0 : 1,
                microphoneDropouts: 0,
                remoteClippingPercent: 0,
                microphoneClippingPercent: 0,
                silentPeriods: [],
                deviceChanges: [],
                transcriptionEngine: "pending",
                intelligenceProvider: "pending"
            )
        )
    }
}

public enum ScreenCaptureKitSystemAudioCaptureError: Error, Equatable {
    case noShareableDisplay
    case emptyCapture
    case stopCaptureFailed(String)
}

extension ScreenCaptureKitSystemAudioCaptureError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .noShareableDisplay:
            return "No display is available for ScreenCaptureKit audio capture."
        case .emptyCapture:
            return "ScreenCaptureKit did not produce system audio. Check Screen Recording permission and active playback."
        case let .stopCaptureFailed(reason):
            return "ScreenCaptureKit could not stop system audio safely. \(reason)"
        }
    }
}

struct ScreenCaptureKitCaptureShutdown: @unchecked Sendable {
    private let stop: @Sendable () async throws -> Void

    init(stop: @escaping @Sendable () async throws -> Void) {
        self.stop = stop
    }

    func resolve<Success>(
        afterProducerStopped: (_ makeResult: @escaping () -> Result<Success, Error>) -> Result<Success, Error>,
        withoutProducerStopped: (Result<Success, Error>) -> Result<Success, Error>,
        clearStoppedStream: () -> Void,
        retainFailedStream: () -> Void,
        rejectFurtherFrames: () -> Void,
        makeProposedResult: @escaping () -> Result<Success, Error>
    ) async -> Result<Success, Error> {
        do {
            try await stop()
            clearStoppedStream()
            return afterProducerStopped(makeProposedResult)
        } catch {
            retainFailedStream()
            rejectFurtherFrames()
            return withoutProducerStopped(
                .failure(
                    ScreenCaptureKitSystemAudioCaptureError.stopCaptureFailed(
                        Self.failureReason(error)
                    )
                )
            )
        }
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

public final class ScreenCaptureKitSystemAudioCapturer: NSObject, ScreenCaptureKitSystemAudioCapturing, @unchecked Sendable {
    public override init() {
        super.init()
    }

    public func capture(_ request: ScreenCaptureKitAudioCaptureRequest) async throws -> CapturedAudioChunk {
        try await withCheckedThrowingContinuation { continuation in
            let coordinator = ScreenCaptureKitAudioCaptureCoordinator(request: request)
            coordinator.start { [coordinator] result in
                _ = coordinator
                continuation.resume(with: result)
            }
        }
    }
}

private final class ScreenCaptureKitAudioCaptureCoordinator: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let request: ScreenCaptureKitAudioCaptureRequest
    private let queue = DispatchQueue(label: "com.andrzej.MeetingVault.screencapturekit-audio")
    private let callbackQueue = DispatchQueue(
        label: "com.andrzej.MeetingVault.screencapturekit-audio.audio-callback",
        qos: .userInteractive
    )
    private let callbackStateLock = NSLock()
    private var completion: ((Result<CapturedAudioChunk, Error>) -> Void)?
    private var stream: SCStream?
    private var capturedByteCount = 0
    private let audioAccumulator = LinearPCMAudioChunkAccumulator()
    private var streamDurationOffset: TimeInterval = 0
    private var firstPresentationTime: CMTime?
    private var lastPresentationTime: CMTime?
    private var didFinish = false
    private var rejectsCallbacksAfterFailedStop = false
    private var failedStopRetention: ScreenCaptureKitAudioCaptureCoordinator?
    private var stopObserverTask: Task<Void, Never>?
    private let maximumStreamBufferBytes = 8_388_608
    private let maximumStreamBufferDuration: TimeInterval = 15
    private lazy var callbackFailureRelay = CaptureCallbackFailureRelay(
        callbackQueue: callbackQueue,
        controlQueue: queue
    ) { [weak self] error in
        self?.finish(error: error)
    }
    private lazy var callbackTerminalizer = CaptureCallbackTerminalizer<CapturedAudioChunk>(
        callbackQueue: callbackQueue,
        failureRelay: callbackFailureRelay
    )

    init(request: ScreenCaptureKitAudioCaptureRequest) {
        self.request = request
    }

    func start(completion: @escaping (Result<CapturedAudioChunk, Error>) -> Void) {
        self.completion = completion
        Task {
            await startCapture()
        }
    }

    private func startCapture() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            guard let display = content.displays.first else {
                throw ScreenCaptureKitSystemAudioCaptureError.noShareableDisplay
            }

            let configuration = SCStreamConfiguration()
            configuration.width = 2
            configuration.height = 2
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            configuration.capturesAudio = true
            configuration.excludesCurrentProcessAudio = false

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
            self.stream = stream
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: callbackQueue)
            try await stream.startCapture()

            queue.asyncAfter(deadline: .now() + request.maximumDuration) { [weak self] in
                self?.finish()
            }
            if let stopSignal = request.stopSignal {
                let coordinator = self
                stopObserverTask = Task { [coordinator] in
                    await stopSignal.waitUntilStopped()
                    coordinator.queue.async {
                        coordinator.finish()
                    }
                }
            }
        } catch {
            queue.async { [weak self] in
                self?.finish(error: error)
            }
        }
    }

    private func finish(error completionError: Error? = nil) {
        guard !didFinish else { return }
        didFinish = true
        stopObserverTask?.cancel()
        stopObserverTask = nil
        let activeStream = stream
        Task { [weak self] in
            guard let self else { return }
            let shutdown = ScreenCaptureKitCaptureShutdown {
                try await activeStream?.stopCapture()
            }
            let result: Result<CapturedAudioChunk, Error> = await shutdown.resolve(
                afterProducerStopped: { [self] makeResult in
                    callbackTerminalizer.resolveAfterProducerStopped(makeResult)
                },
                withoutProducerStopped: { [self] result in
                    callbackFailureRelay.arbitrate(result)
                },
                clearStoppedStream: { [self] in
                    stream = nil
                },
                retainFailedStream: { [self] in
                    callbackStateLock.withLock {
                        rejectsCallbacksAfterFailedStop = true
                    }
                    failedStopRetention = self
                },
                rejectFurtherFrames: { [self] in
                    request.frameEmitter?.finishProducerAfterFailedStop()
                },
                makeProposedResult: { [self] in
                    makeProposedResult(error: completionError)
                }
            )
            queue.async { [weak self, result] in
                self?.complete(result)
            }
        }
    }

    private func makeProposedResult(error: Error?) -> Result<CapturedAudioChunk, Error> {
        if let error {
            return .failure(error)
        }
        if request.frameEmitter == nil {
            do {
                try flushStreamBufferIfNeeded(force: true)
            } catch {
                return .failure(error)
            }
        }
        let callbackMetrics = callbackCaptureMetrics
        guard callbackMetrics.byteCount > 0 else {
            return .failure(ScreenCaptureKitSystemAudioCaptureError.emptyCapture)
        }
        let startTime = callbackMetrics.firstPresentationTime.map(CMTimeGetSeconds) ?? 0
        let endTime = callbackMetrics.lastPresentationTime.map(CMTimeGetSeconds) ?? request.maximumDuration
        let finalAudioData: Data
        do {
            finalAudioData = request.frameEmitter == nil && request.chunkSink == nil
                ? try audioAccumulator.finishChunk()?.data ?? Data()
                : Data()
        } catch {
            return .failure(error)
        }
        return .success(
            CapturedAudioChunk(
                track: .remoteSystem,
                data: finalAudioData,
                startTime: 0,
                duration: max(0.1, endTime - startTime),
                codec: "WAV/PCM"
            )
        )
    }

    private func complete(_ result: Result<CapturedAudioChunk, Error>) {
        let completion = completion
        self.completion = nil
        completion?(result)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { [weak self] in
            self?.finish(error: error)
        }
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .audio else { return }
        let shouldRejectCallback = callbackStateLock.withLock {
            rejectsCallbacksAfterFailedStop
        }
        guard !shouldRejectCallback else { return }
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        do {
            if let frameEmitter = request.frameEmitter {
                try frameEmitter.emit(sampleBuffer: sampleBuffer, track: .remoteSystem)
                recordCapturedSample(
                    byteCount: max(1, CMSampleBufferGetTotalSampleSize(sampleBuffer)),
                    presentationTime: presentationTime
                )
                return
            }
            try audioAccumulator.append(sampleBuffer: sampleBuffer)
            recordCapturedSample(
                byteCount: max(1, CMSampleBufferGetTotalSampleSize(sampleBuffer)),
                presentationTime: presentationTime
            )
        } catch {
            callbackFailureRelay.report(error)
        }
    }

    private var callbackCaptureMetrics: (
        byteCount: Int,
        firstPresentationTime: CMTime?,
        lastPresentationTime: CMTime?
    ) {
        callbackStateLock.withLock {
            (capturedByteCount, firstPresentationTime, lastPresentationTime)
        }
    }

    private func recordCapturedSample(byteCount: Int, presentationTime: CMTime) {
        callbackStateLock.withLock {
            if firstPresentationTime == nil {
                firstPresentationTime = presentationTime
            }
            lastPresentationTime = presentationTime
            capturedByteCount += byteCount
        }
    }

    private func flushStreamBufferIfNeeded(force: Bool) throws {
        guard let chunkSink = request.chunkSink, !audioAccumulator.isEmpty else { return }
        guard force
            || audioAccumulator.duration >= maximumStreamBufferDuration
            || audioAccumulator.byteCount >= maximumStreamBufferBytes
        else {
            return
        }
        guard let audioChunk = try audioAccumulator.finishChunk() else { return }
        let chunk = CapturedAudioChunk(
            track: .remoteSystem,
            data: audioChunk.data,
            startTime: streamDurationOffset,
            duration: max(0.1, audioChunk.duration),
            codec: "WAV/PCM"
        )
        try chunkSink.write(chunk)
        streamDurationOffset += audioChunk.duration
    }
}
