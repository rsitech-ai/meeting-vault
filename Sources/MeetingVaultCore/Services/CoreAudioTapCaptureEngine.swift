import AVFAudio
import CoreAudio
import Foundation

public struct CoreAudioTapCaptureRequest: Equatable, Sendable {
    public var meetingID: UUID
    public var sourceID: String
    public var bundleIdentifier: String?
    public var maximumDuration: TimeInterval
    public var stopSignal: CaptureRecordingStopSignal?
    public var chunkSink: CaptureRecordingChunkSink?
    public var frameEmitter: CaptureFrameEmitter?

    public init(
        meetingID: UUID,
        sourceID: String,
        bundleIdentifier: String? = nil,
        maximumDuration: TimeInterval,
        stopSignal: CaptureRecordingStopSignal? = nil,
        chunkSink: CaptureRecordingChunkSink? = nil,
        frameEmitter: CaptureFrameEmitter? = nil
    ) {
        self.meetingID = meetingID
        self.sourceID = sourceID
        self.bundleIdentifier = bundleIdentifier
        self.maximumDuration = max(0.1, maximumDuration)
        self.stopSignal = stopSignal
        self.chunkSink = chunkSink
        self.frameEmitter = frameEmitter
    }

    public static func == (lhs: CoreAudioTapCaptureRequest, rhs: CoreAudioTapCaptureRequest) -> Bool {
        lhs.meetingID == rhs.meetingID
            && lhs.sourceID == rhs.sourceID
            && lhs.bundleIdentifier == rhs.bundleIdentifier
            && lhs.maximumDuration == rhs.maximumDuration
    }
}

public protocol CoreAudioTapCapturing: Sendable {
    func capture(_ request: CoreAudioTapCaptureRequest) async throws -> CapturedAudioChunk
}

public final class CoreAudioTapCaptureEngine: CaptureRecordingEngine, @unchecked Sendable {
    public let id = "core-audio-process-tap"
    public let mode: CaptureMode = .systemAudio

    private let source: CaptureSource
    private let capturer: any CoreAudioTapCapturing

    public init(
        source: CaptureSource = CaptureSource(
            id: "coreaudio-system-audio",
            displayName: "Core Audio System Audio",
            mode: .systemAudio,
            isRecommended: true,
            level: 0
        ),
        capturer: any CoreAudioTapCapturing = CoreAudioProcessTapCapturer()
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
            CoreAudioTapCaptureRequest(
                meetingID: request.meetingID,
                sourceID: request.sourceID,
                bundleIdentifier: source.bundleIdentifier,
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

public enum CoreAudioTapCaptureError: Error, Equatable {
    case createTapFailed(OSStatus)
    case missingTapUID
    case createAggregateDeviceFailed(OSStatus)
    case streamFormatUnavailable(OSStatus)
    case createIOProcFailed(OSStatus)
    case startDeviceFailed(OSStatus)
    case stopDeviceFailed(OSStatus)
    case shutdownFailed(stopStatus: OSStatus, detachStatus: OSStatus)
    case emptyCapture
}

extension CoreAudioTapCaptureError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .createTapFailed(status):
            return "Core Audio could not create a process tap. OSStatus \(status)."
        case .missingTapUID:
            return "Core Audio did not return a tap identifier."
        case let .createAggregateDeviceFailed(status):
            return "Core Audio could not create a private tap device. OSStatus \(status)."
        case let .streamFormatUnavailable(status):
            return "Core Audio could not read the tap stream format. OSStatus \(status)."
        case let .createIOProcFailed(status):
            return "Core Audio could not create an audio reader. OSStatus \(status)."
        case let .startDeviceFailed(status):
            return "Core Audio could not start the tap device. OSStatus \(status)."
        case let .stopDeviceFailed(status):
            return "Core Audio could not stop the tap device safely. OSStatus \(status)."
        case let .shutdownFailed(stopStatus, detachStatus):
            return "Core Audio could not stop or detach the tap device safely. Stop OSStatus \(stopStatus); detach OSStatus \(detachStatus)."
        case .emptyCapture:
            return "Core Audio did not produce system audio. Check playback and capture permissions."
        }
    }
}

struct CoreAudioCaptureShutdown: @unchecked Sendable {
    private let stop: @Sendable () -> OSStatus
    private let detach: @Sendable () -> OSStatus

    init(
        stop: @escaping @Sendable () -> OSStatus,
        detach: @escaping @Sendable () -> OSStatus
    ) {
        self.stop = stop
        self.detach = detach
    }

    func resolve<Success>(
        afterProducerStopped: (_ makeResult: @escaping () -> Result<Success, Error>) -> Result<Success, Error>,
        withoutProducerStopped: (Result<Success, Error>) -> Result<Success, Error>,
        cleanupAfterProducerStopped: @escaping () -> Void,
        makeProposedResult: @escaping () -> Result<Success, Error>
    ) -> Result<Success, Error> {
        let stopStatus = stop()
        let detachStatus = detach()
        guard detachStatus == noErr else {
            return withoutProducerStopped(
                .failure(
                    CoreAudioTapCaptureError.shutdownFailed(
                        stopStatus: stopStatus,
                        detachStatus: detachStatus
                    )
                )
            )
        }

        return afterProducerStopped {
            cleanupAfterProducerStopped()
            guard stopStatus == noErr else {
                return .failure(CoreAudioTapCaptureError.stopDeviceFailed(stopStatus))
            }
            return makeProposedResult()
        }
    }
}

public final class CoreAudioProcessTapCapturer: CoreAudioTapCapturing, @unchecked Sendable {
    public init() {}

    public func capture(_ request: CoreAudioTapCaptureRequest) async throws -> CapturedAudioChunk {
        try await withCheckedThrowingContinuation { continuation in
            let coordinator = CoreAudioTapCaptureCoordinator(request: request)
            coordinator.start { [coordinator] result in
                _ = coordinator
                continuation.resume(with: result)
            }
        }
    }
}

private final class CoreAudioTapCaptureCoordinator: @unchecked Sendable {
    private let request: CoreAudioTapCaptureRequest
    private let queue = DispatchQueue(label: "com.andrzej.MeetingVault.core-audio-tap")
    private let callbackQueue = DispatchQueue(
        label: "com.andrzej.MeetingVault.core-audio-tap.audio-callback",
        qos: .userInteractive
    )
    private let callbackStateLock = NSLock()
    private var completion: ((Result<CapturedAudioChunk, Error>) -> Void)?
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var deviceStarted = false
    private var capturedByteCount = 0
    private let audioAccumulator = LinearPCMAudioChunkAccumulator()
    private var audioFormat: AudioStreamBasicDescription?
    private var streamDurationOffset: TimeInterval = 0
    private var didFinish = false
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

    init(request: CoreAudioTapCaptureRequest) {
        self.request = request
    }

    func start(completion: @escaping (Result<CapturedAudioChunk, Error>) -> Void) {
        self.completion = completion
        queue.async { [weak self] in
            self?.startOnQueue()
        }
    }

    private func startOnQueue() {
        do {
            let description = makeTapDescription()
            var createdTapID = AudioObjectID(kAudioObjectUnknown)
            let tapStatus = AudioHardwareCreateProcessTap(description, &createdTapID)
            guard tapStatus == noErr else {
                throw CoreAudioTapCaptureError.createTapFailed(tapStatus)
            }
            tapID = createdTapID
            audioFormat = try readTapFormat(tapID: createdTapID)

            let tapUID = try readTapUID(tapID: createdTapID)
            var createdAggregateID = AudioObjectID(kAudioObjectUnknown)
            let aggregateStatus = AudioHardwareCreateAggregateDevice(
                makeAggregateDescription(tapUID: tapUID) as CFDictionary,
                &createdAggregateID
            )
            guard aggregateStatus == noErr else {
                throw CoreAudioTapCaptureError.createAggregateDeviceFailed(aggregateStatus)
            }
            aggregateDeviceID = createdAggregateID

            var createdIOProcID: AudioDeviceIOProcID?
            let state = self
            let ioStatus = AudioDeviceCreateIOProcIDWithBlock(
                &createdIOProcID,
                createdAggregateID,
                callbackQueue
            ) { _, inputData, _, _, _ in
                state.append(inputData: inputData)
            }
            guard ioStatus == noErr, let createdIOProcID else {
                throw CoreAudioTapCaptureError.createIOProcFailed(ioStatus)
            }
            ioProcID = createdIOProcID

            let startStatus = AudioDeviceStart(createdAggregateID, createdIOProcID)
            guard startStatus == noErr else {
                throw CoreAudioTapCaptureError.startDeviceFailed(startStatus)
            }
            deviceStarted = true

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
            finish(error: error)
        }
    }

    private func makeTapDescription() -> CATapDescription {
        let description: CATapDescription
        if let bundleIdentifier = request.bundleIdentifier, !bundleIdentifier.isEmpty {
            description = CATapDescription()
            description.bundleIDs = [bundleIdentifier]
            description.isExclusive = false
            description.isMixdown = true
            description.isProcessRestoreEnabled = true
        } else {
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        }
        description.name = "MeetingVault Core Audio Tap"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted
        return description
    }

    private func readTapUID(tapID: AudioObjectID) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var tapUID: CFString?
        var dataSize = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &tapUID) { pointer in
            AudioObjectGetPropertyData(tapID, &address, 0, nil, &dataSize, pointer)
        }
        guard status == noErr, let tapUID else {
            throw CoreAudioTapCaptureError.missingTapUID
        }
        return tapUID as String
    }

    private func makeAggregateDescription(tapUID: String) -> [String: Any] {
        [
            String(kAudioAggregateDeviceNameKey): "MeetingVault Core Audio Tap Device",
            String(kAudioAggregateDeviceUIDKey): "com.andrzej.MeetingVault.CoreAudioTap.\(UUID().uuidString)",
            String(kAudioAggregateDeviceIsPrivateKey): true,
            String(kAudioAggregateDeviceTapAutoStartKey): false,
            String(kAudioAggregateDeviceTapListKey): [
                [
                    String(kAudioSubTapUIDKey): tapUID,
                    String(kAudioSubTapDriftCompensationKey): true
                ]
            ]
        ]
    }

    private func readTapFormat(tapID: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format)
        guard status == noErr, format.mFormatID == kAudioFormatLinearPCM else {
            throw CoreAudioTapCaptureError.streamFormatUnavailable(status)
        }
        return format
    }

    private func append(inputData: UnsafePointer<AudioBufferList>?) {
        guard let inputData, let audioFormat else { return }
        do {
            let geometry = try CanonicalPCMFrameConverter.withValidatedAudioBufferListGeometry(
                audioBufferList: inputData,
                format: audioFormat
            ) { $0 }
            recordCapturedBytes(geometry.sourceByteCount)
            if let frameEmitter = request.frameEmitter {
                try frameEmitter.emit(
                    audioBufferList: inputData,
                    format: audioFormat,
                    frameCount: geometry.frameCount,
                    track: .remoteSystem
                )
                return
            }
            try audioAccumulator.append(
                audioBufferList: inputData,
                format: audioFormat,
                frameCount: UInt32(geometry.frameCount)
            )
        } catch {
            callbackFailureRelay.report(error)
        }
    }

    private var callbackCapturedByteCount: Int {
        callbackStateLock.withLock { capturedByteCount }
    }

    private func recordCapturedBytes(_ count: Int) {
        callbackStateLock.withLock {
            capturedByteCount += count
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

    private func finish(error: Error? = nil) {
        guard !didFinish else { return }
        didFinish = true
        stopObserverTask?.cancel()
        stopObserverTask = nil

        guard deviceStarted,
              let aggregateDeviceID = aggregateDeviceID.nonUnknown,
              let ioProcID
        else {
            completeAfterProducerStopped { [self] in
                if let aggregateDeviceID = aggregateDeviceID.nonUnknown, let ioProcID {
                    AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
                }
                destroyDetachedCaptureResources()
                return makeProposedResult(error: error)
            }
            return
        }

        let shutdown = CoreAudioCaptureShutdown(
            stop: {
                AudioDeviceStop(aggregateDeviceID, ioProcID)
            },
            detach: {
                AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
            }
        )
        let result = shutdown.resolve(
            afterProducerStopped: { [self] makeResult in
                callbackTerminalizer.resolveAfterProducerStopped(makeResult)
            },
            withoutProducerStopped: { [self] result in
                callbackFailureRelay.arbitrate(result)
            },
            cleanupAfterProducerStopped: { [self] in
                destroyDetachedCaptureResources()
            },
            makeProposedResult: { [self] in
                makeProposedResult(error: error)
            }
        )
        complete(result)
    }

    private func destroyDetachedCaptureResources() {
        if let aggregateDeviceID = aggregateDeviceID.nonUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
        }
        if let tapID = tapID.nonUnknown {
            AudioHardwareDestroyProcessTap(tapID)
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
        guard callbackCapturedByteCount > 0 else {
            return .failure(CoreAudioTapCaptureError.emptyCapture)
        }
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
                duration: request.maximumDuration,
                codec: "WAV/PCM"
            )
        )
    }

    private func completeAfterProducerStopped(
        _ makeProposedResult: () -> Result<CapturedAudioChunk, Error>
    ) {
        complete(callbackTerminalizer.resolveAfterProducerStopped(makeProposedResult))
    }

    private func complete(_ result: Result<CapturedAudioChunk, Error>) {
        let completion = completion
        self.completion = nil
        completion?(result)
    }
}

private extension AudioObjectID {
    var nonUnknown: AudioObjectID? {
        self == AudioObjectID(kAudioObjectUnknown) ? nil : self
    }
}
