@preconcurrency import AVFoundation
import Foundation

public struct SelectedMicrophoneCaptureRequest: Equatable, Sendable {
    public var meetingID: UUID
    public var deviceID: String
    public var deviceName: String?
    public var maximumDuration: TimeInterval
    public var stopSignal: CaptureRecordingStopSignal?
    public var chunkSink: CaptureRecordingChunkSink?
    public var frameEmitter: CaptureFrameEmitter?

    public init(
        meetingID: UUID,
        deviceID: String,
        deviceName: String?,
        maximumDuration: TimeInterval,
        stopSignal: CaptureRecordingStopSignal? = nil,
        chunkSink: CaptureRecordingChunkSink? = nil,
        frameEmitter: CaptureFrameEmitter? = nil
    ) {
        self.meetingID = meetingID
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.maximumDuration = max(0.1, maximumDuration)
        self.stopSignal = stopSignal
        self.chunkSink = chunkSink
        self.frameEmitter = frameEmitter
    }

    public static func == (lhs: SelectedMicrophoneCaptureRequest, rhs: SelectedMicrophoneCaptureRequest) -> Bool {
        lhs.meetingID == rhs.meetingID
            && lhs.deviceID == rhs.deviceID
            && lhs.deviceName == rhs.deviceName
            && lhs.maximumDuration == rhs.maximumDuration
    }
}

public protocol SelectedMicrophoneAudioCapturing: Sendable {
    func capture(_ request: SelectedMicrophoneCaptureRequest) async throws -> CapturedAudioChunk
}

public final class AVFoundationSelectedMicrophoneCaptureEngine: CaptureRecordingEngine, @unchecked Sendable {
    public let id = "avfoundation-selected-microphone"
    public let mode: CaptureMode = .microphone

    private let source: CaptureSource
    private let capturer: any SelectedMicrophoneAudioCapturing

    public init(
        source: CaptureSource = CaptureSource(
            id: "selected-microphone",
            displayName: "Selected Microphone",
            mode: .microphone,
            isRecommended: true,
            level: 0
        ),
        capturer: any SelectedMicrophoneAudioCapturing = AVFoundationSelectedMicrophoneAudioCapturer()
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
        guard request.includeMicrophone,
              let microphoneDeviceID = request.microphoneDeviceID
        else {
            throw CaptureRecordingError.microphoneUnavailable(
                id: "selected-microphone",
                name: request.microphoneDeviceName
            )
        }

        let streamedRecordsBeforeCapture = request.chunkSink?.records.count ?? 0
        let chunk = try await capturer.capture(
            SelectedMicrophoneCaptureRequest(
                meetingID: request.meetingID,
                deviceID: microphoneDeviceID,
                deviceName: request.microphoneDeviceName,
                maximumDuration: request.maximumDuration,
                stopSignal: request.stopSignal,
                chunkSink: request.chunkSink,
                frameEmitter: request.frameEmitter
            )
        )
        let streamedDuringCapture = request.frameEmitter?.hasEmittedFrames(for: .microphone) == true
            || (request.chunkSink?.records.count ?? streamedRecordsBeforeCapture) > streamedRecordsBeforeCapture
        return CaptureRecordingEngineOutput(
            chunks: streamedDuringCapture ? [] : [chunk],
            healthReport: CaptureHealthReport(
                remoteDropouts: 0,
                microphoneDropouts: streamedDuringCapture || !chunk.data.isEmpty ? 0 : 1,
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

public enum AVFoundationSelectedMicrophoneCaptureError: Error, Equatable {
    case deviceNotFound(String)
    case cannotCreateInput(String)
    case cannotAddInput(String)
    case cannotAddOutput
    case temporaryFileUnavailable(String)
    case emptyCapture(String)
}

extension AVFoundationSelectedMicrophoneCaptureError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .deviceNotFound(id):
            return "Selected microphone \(id) is unavailable. Re-detect inputs before recording."
        case let .cannotCreateInput(name):
            return "Selected microphone \(name) could not be opened."
        case let .cannotAddInput(name):
            return "Selected microphone \(name) could not be added to the capture session."
        case .cannotAddOutput:
            return "Microphone capture output could not be added."
        case let .temporaryFileUnavailable(message):
            return "Selected microphone recording file could not be prepared: \(message)"
        case let .emptyCapture(name):
            return "Selected microphone \(name) did not produce audio. Check the input and try again."
        }
    }
}

public final class AVFoundationSelectedMicrophoneAudioCapturer: NSObject, SelectedMicrophoneAudioCapturing, @unchecked Sendable {
    public override init() {
        super.init()
    }

    public func capture(_ request: SelectedMicrophoneCaptureRequest) async throws -> CapturedAudioChunk {
        try await withCheckedThrowingContinuation { continuation in
            let coordinator = AVFoundationMicrophoneCaptureCoordinator(request: request)
            coordinator.start { [coordinator] result in
                _ = coordinator
                continuation.resume(with: result)
            }
        }
    }
}

private final class AVFoundationMicrophoneCaptureCoordinator: NSObject, AVCaptureFileOutputRecordingDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let request: SelectedMicrophoneCaptureRequest
    private let queue = DispatchQueue(label: "com.andrzej.MeetingVault.microphone-capture")
    private let callbackQueue = DispatchQueue(
        label: "com.andrzej.MeetingVault.microphone-capture.audio-callback",
        qos: .userInteractive
    )
    private let callbackStateLock = NSLock()
    private var completion: ((Result<CapturedAudioChunk, Error>) -> Void)?
    private var session: AVCaptureSession?
    private var audioOutput: AVCaptureAudioFileOutput?
    private var dataOutput: AVCaptureAudioDataOutput?
    private var scratchURL: URL?
    private var outputCodec = "M4A/AAC"
    private var startedAt: Date?
    private var didFinish = false
    private var stopObserverTask: Task<Void, Never>?
    private let audioAccumulator = LinearPCMAudioChunkAccumulator()
    private var streamDurationOffset: TimeInterval = 0
    private var capturedByteCount = 0
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

    init(request: SelectedMicrophoneCaptureRequest) {
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
            let device = try resolveDevice()
            let input: AVCaptureDeviceInput
            do {
                input = try AVCaptureDeviceInput(device: device)
            } catch {
                throw AVFoundationSelectedMicrophoneCaptureError.cannotCreateInput(device.localizedName)
            }

            let session = AVCaptureSession()
            guard session.canAddInput(input) else {
                throw AVFoundationSelectedMicrophoneCaptureError.cannotAddInput(device.localizedName)
            }
            session.addInput(input)

            if request.chunkSink != nil {
                let output = AVCaptureAudioDataOutput()
                guard session.canAddOutput(output) else {
                    throw AVFoundationSelectedMicrophoneCaptureError.cannotAddOutput
                }
                session.addOutput(output)
                output.setSampleBufferDelegate(self, queue: callbackQueue)
                self.session = session
                dataOutput = output
                outputCodec = "WAV/PCM"
                session.startRunning()
                startedAt = Date()
                scheduleFinishAndStopObservation()
                return
            }

            let output = AVCaptureAudioFileOutput()
            guard session.canAddOutput(output) else {
                throw AVFoundationSelectedMicrophoneCaptureError.cannotAddOutput
            }
            session.addOutput(output)
            self.session = session
            audioOutput = output

            let outputFileType = preferredOutputFileType()
            let scratchURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("MeetingVaultSelectedMicrophone", isDirectory: true)
                .appendingPathComponent("\(request.meetingID.uuidString)-\(UUID().uuidString)")
                .appendingPathExtension(fileExtension(for: outputFileType))
            do {
                try FileManager.default.createDirectory(
                    at: scratchURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if FileManager.default.fileExists(atPath: scratchURL.path) {
                    try FileManager.default.removeItem(at: scratchURL)
                }
            } catch {
                throw AVFoundationSelectedMicrophoneCaptureError.temporaryFileUnavailable(error.localizedDescription)
            }
            self.scratchURL = scratchURL
            outputCodec = codec(for: outputFileType)

            session.startRunning()
            startedAt = Date()
            output.startRecording(
                to: scratchURL,
                outputFileType: outputFileType,
                recordingDelegate: self
            )
            scheduleFinishAndStopObservation()
        } catch {
            completeAfterProducerStopped { .failure(error) }
        }
    }

    private func scheduleFinishAndStopObservation() {
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
    }

    private func resolveDevice() throws -> AVCaptureDevice {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        guard let device = discovery.devices.first(where: { $0.uniqueID == request.deviceID }) else {
            throw AVFoundationSelectedMicrophoneCaptureError.deviceNotFound(request.deviceID)
        }
        return device
    }

    private func finish(error: Error? = nil) {
        guard !didFinish else { return }
        didFinish = true
        stopObserverTask?.cancel()
        stopObserverTask = nil

        if dataOutput != nil {
            session?.stopRunning()
            dataOutput?.setSampleBufferDelegate(nil, queue: nil)
            session = nil
            dataOutput = nil
            completeAfterProducerStopped { [self] in
                if let error {
                    return .failure(error)
                }
                do {
                    try flushStreamBufferIfNeeded(force: true)
                } catch {
                    return .failure(error)
                }
                guard callbackCapturedByteCount > 0 else {
                    return .failure(
                        AVFoundationSelectedMicrophoneCaptureError.emptyCapture(
                            request.deviceName ?? request.deviceID
                        )
                    )
                }
                let duration = startedAt.map { Date().timeIntervalSince($0) } ?? request.maximumDuration
                return .success(
                    CapturedAudioChunk(
                        track: .microphone,
                        data: Data(),
                        startTime: 0,
                        duration: max(0.1, duration),
                        codec: outputCodec
                    )
                )
            }
            return
        }

        if let error {
            audioOutput?.stopRecording()
            session?.stopRunning()
            session = nil
            completeAfterProducerStopped { [self] in
                cleanupScratchFile()
                return .failure(error)
            }
            return
        }

        if audioOutput?.isRecording == true {
            audioOutput?.stopRecording()
            return
        }

        finishFromRecordedFile(error: nil)
    }

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        queue.async { [weak self] in
            self?.finishFromRecordedFile(error: error)
        }
    }

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didStartRecordingTo fileURL: URL,
        from connections: [AVCaptureConnection]
    ) {}

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        do {
            if let frameEmitter = request.frameEmitter {
                try frameEmitter.emit(sampleBuffer: sampleBuffer, track: .microphone)
                recordCapturedBytes(max(1, CMSampleBufferGetTotalSampleSize(sampleBuffer)))
                return
            }
            try audioAccumulator.append(sampleBuffer: sampleBuffer)
            recordCapturedBytes(max(1, CMSampleBufferGetTotalSampleSize(sampleBuffer)))
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
        try chunkSink.write(
            CapturedAudioChunk(
                track: .microphone,
                data: audioChunk.data,
                startTime: streamDurationOffset,
                duration: max(0.1, audioChunk.duration),
                codec: "WAV/PCM"
            )
        )
        streamDurationOffset += audioChunk.duration
    }

    private func finishFromRecordedFile(error: Error?) {
        stopObserverTask?.cancel()
        stopObserverTask = nil
        session?.stopRunning()
        session = nil
        completeAfterProducerStopped { [self] in
            if let error {
                cleanupScratchFile()
                return .failure(error)
            }

            guard let scratchURL else {
                return .failure(
                    AVFoundationSelectedMicrophoneCaptureError.temporaryFileUnavailable(
                        "Recording output URL was not prepared."
                    )
                )
            }

            let audioData: Data
            do {
                audioData = try Data(contentsOf: scratchURL)
            } catch {
                cleanupScratchFile()
                return .failure(error)
            }
            cleanupScratchFile()

            guard !audioData.isEmpty else {
                return .failure(
                    AVFoundationSelectedMicrophoneCaptureError.emptyCapture(
                        request.deviceName ?? request.deviceID
                    )
                )
            }

            let duration = startedAt.map { Date().timeIntervalSince($0) } ?? request.maximumDuration
            return .success(
                CapturedAudioChunk(
                    track: .microphone,
                    data: audioData,
                    startTime: 0,
                    duration: max(0.1, duration),
                    codec: outputCodec
                )
            )
        }
    }

    private func completeAfterProducerStopped(
        _ makeProposedResult: () -> Result<CapturedAudioChunk, Error>
    ) {
        let result = callbackTerminalizer.resolveAfterProducerStopped(makeProposedResult)
        let completion = completion
        self.completion = nil
        completion?(result)
    }

    private func preferredOutputFileType() -> AVFileType {
        if AVCaptureAudioFileOutput.availableOutputFileTypes().contains(.m4a) {
            return .m4a
        }
        return .caf
    }

    private func fileExtension(for outputFileType: AVFileType) -> String {
        switch outputFileType {
        case .m4a:
            return "m4a"
        case .caf:
            return "caf"
        default:
            return "audio"
        }
    }

    private func codec(for outputFileType: AVFileType) -> String {
        switch outputFileType {
        case .m4a:
            return "M4A/AAC"
        case .caf:
            return "CAF/AAC"
        default:
            return outputFileType.rawValue
        }
    }

    private func cleanupScratchFile() {
        guard let scratchURL else { return }
        try? FileManager.default.removeItem(at: scratchURL)
        self.scratchURL = nil
    }
}
