@preconcurrency import AVFoundation
import Foundation
@preconcurrency import Speech

public enum SpeechRecognitionAuthorizationState: String, Equatable, Sendable {
    case authorized
    case denied
    case restricted
    case notDetermined
    case unknown

    var canStartRecognition: Bool {
        self == .authorized
    }
}

public protocol SpeechRecognitionAuthorizationProviding: Sendable {
    func currentAuthorizationState() -> SpeechRecognitionAuthorizationState
    func requestAuthorizationState() async -> SpeechRecognitionAuthorizationState
}

public protocol AppleSpeechOnDeviceCapabilityProviding: Sendable {
    func supportsOnDeviceRecognition(for locale: Locale) -> Bool
}

public struct SystemAppleSpeechOnDeviceCapability: AppleSpeechOnDeviceCapabilityProviding {
    public init() {}
    public func supportsOnDeviceRecognition(for locale: Locale) -> Bool {
        SFSpeechRecognizer(locale: locale)?.supportsOnDeviceRecognition == true
    }
}

public struct SystemSpeechRecognitionAuthorizationProvider: SpeechRecognitionAuthorizationProviding {
    public init() {}

    public func currentAuthorizationState() -> SpeechRecognitionAuthorizationState {
        Self.map(SFSpeechRecognizer.authorizationStatus())
    }

    public func requestAuthorizationState() async -> SpeechRecognitionAuthorizationState {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: Self.map(status))
            }
        }
    }

    private static func map(_ status: SFSpeechRecognizerAuthorizationStatus) -> SpeechRecognitionAuthorizationState {
        switch status {
        case .authorized:
            return .authorized
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .unknown
        }
    }
}

public enum AppleSpeechLiveTranscriptionError: Error, Equatable, LocalizedError, Sendable {
    case authorizationDenied(SpeechRecognitionAuthorizationState)
    case recognizerUnavailable(String)
    case recognizerNotReady(String)
    case invalidAudioInput
    case audioEngineStartFailed(String)
    case recognitionFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .authorizationDenied(state):
            return "Speech Recognition is \(state.rawValue). Choose Check Permissions Once, then open System Settings and allow Speech Recognition."
        case let .recognizerUnavailable(locale):
            return "Apple Speech is unavailable for locale \(locale)."
        case let .recognizerNotReady(locale):
            return "Apple Speech is not ready for locale \(locale). Try again after the recognizer becomes available."
        case .invalidAudioInput:
            return "Apple Speech could not read the current microphone input."
        case let .audioEngineStartFailed(message):
            return "Live transcription audio engine failed to start: \(message)"
        case let .recognitionFailed(message):
            return "Apple Speech recognition failed: \(message)"
        }
    }
}

public protocol SpeechLiveEventStreaming: Sendable {
    func events(for context: LiveTranscriptionContext) -> AsyncThrowingStream<LiveTranscriptionEvent, Error>
}

public final class AppleSpeechLiveTranscriptionProvider: LiveTranscriptionProviding, @unchecked Sendable {
    public let id = "apple-speech-live"

    private let authorizationProvider: any SpeechRecognitionAuthorizationProviding
    private let eventStreamerFactory: @Sendable (Locale) -> any SpeechLiveEventStreaming
    private let privacyBoundary: TranscriptionPrivacyBoundary
    private let onDeviceCapability: any AppleSpeechOnDeviceCapabilityProviding

    public init(
        privacyBoundary: TranscriptionPrivacyBoundary = TranscriptionPrivacyBoundary(mode: .appleMayUseNetwork),
        authorizationProvider: any SpeechRecognitionAuthorizationProviding = SystemSpeechRecognitionAuthorizationProvider(),
        onDeviceCapability: any AppleSpeechOnDeviceCapabilityProviding = SystemAppleSpeechOnDeviceCapability(),
        eventStreamerFactory: @escaping @Sendable (Locale) -> any SpeechLiveEventStreaming = {
            AppleSpeechAudioEngineLiveEventStreamer(locale: $0)
        }
    ) {
        self.privacyBoundary = privacyBoundary
        self.authorizationProvider = authorizationProvider
        self.onDeviceCapability = onDeviceCapability
        self.eventStreamerFactory = eventStreamerFactory
    }

    public func events(for context: LiveTranscriptionContext) -> AsyncThrowingStream<LiveTranscriptionEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let policy = try await privacyBoundary.appleSpeechPolicy()
                    let locale = Self.locale(from: context.localeIdentifier)
                    guard !policy.requiresOnDeviceRecognition || onDeviceCapability.supportsOnDeviceRecognition(for: locale) else {
                        throw TranscriptionPrivacyBoundaryError.onDeviceRecognitionRequired
                    }
                    continuation.yield(.status("Checking Speech Recognition permission"))
                    let authorizationState = resolvedAuthorizationState()
                    guard authorizationState.canStartRecognition else {
                        throw AppleSpeechLiveTranscriptionError.authorizationDenied(authorizationState)
                    }

                    continuation.yield(.status("Starting Apple Speech live transcription"))
                    let streamer = eventStreamerFactory(locale)
                    var effectiveContext = context
                    effectiveContext.appleSpeechRequiresOnDeviceRecognition = policy.requiresOnDeviceRecognition
                    for try await event in streamer.events(for: effectiveContext) {
                        guard !Task.isCancelled else { return }
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    guard !Task.isCancelled else { return }
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func resolvedAuthorizationState() -> SpeechRecognitionAuthorizationState {
        authorizationProvider.currentAuthorizationState()
    }

    private static func locale(from identifier: String?) -> Locale {
        let trimmed = identifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else {
            return Locale.current
        }
        return Locale(identifier: trimmed)
    }
}

public final class AppleSpeechAudioEngineLiveEventStreamer: SpeechLiveEventStreaming, @unchecked Sendable {
    private let locale: Locale

    public init(locale: Locale) {
        self.locale = locale
    }

    public func events(for context: LiveTranscriptionContext) -> AsyncThrowingStream<LiveTranscriptionEvent, Error> {
        AsyncThrowingStream { continuation in
            let coordinator = AppleSpeechAudioEngineLiveCoordinator(
                locale: locale,
                context: context,
                continuation: continuation
            )
            coordinator.start()
            continuation.onTermination = { _ in
                coordinator.stop()
            }
        }
    }
}

private final class AppleSpeechAudioEngineLiveCoordinator: @unchecked Sendable {
    private let locale: Locale
    private let context: LiveTranscriptionContext
    private let continuation: AsyncThrowingStream<LiveTranscriptionEvent, Error>.Continuation
    private let audioEngine = AVAudioEngine()
    private let segmentID = UUID()
    private let lock = NSLock()
    private let levelLock = NSLock()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var didFinish = false
    private var lastLevelEmissionUptime: TimeInterval = 0

    init(
        locale: Locale,
        context: LiveTranscriptionContext,
        continuation: AsyncThrowingStream<LiveTranscriptionEvent, Error>.Continuation
    ) {
        self.locale = locale
        self.context = context
        self.continuation = continuation
    }

    func start() {
        do {
            guard let recognizer = SFSpeechRecognizer(locale: locale) else {
                throw AppleSpeechLiveTranscriptionError.recognizerUnavailable(locale.identifier)
            }
            guard recognizer.isAvailable else {
                throw AppleSpeechLiveTranscriptionError.recognizerNotReady(locale.identifier)
            }

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.requiresOnDeviceRecognition = context.appleSpeechRequiresOnDeviceRecognition

            let inputNode = audioEngine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            guard format.channelCount > 0, format.sampleRate > 0 else {
                throw AppleSpeechLiveTranscriptionError.invalidAudioInput
            }

            inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, _ in
                self?.emitInputLevel(from: buffer)
                request.append(buffer)
            }

            audioEngine.prepare()
            do {
                try audioEngine.start()
            } catch {
                throw AppleSpeechLiveTranscriptionError.audioEngineStartFailed(error.localizedDescription)
            }

            recognitionRequest = request
            continuation.yield(
                .status("Apple Speech listening on \(context.microphoneDeviceName ?? "system input")")
            )
            recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                self?.handleRecognition(result: result, error: error)
            }
        } catch {
            finish(throwing: error)
        }
    }

    func stop() {
        lock.withLock {
            guard !didFinish else { return }
            didFinish = true
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
            recognitionRequest?.endAudio()
            recognitionTask?.cancel()
            recognitionRequest = nil
            recognitionTask = nil
        }
    }

    private func handleRecognition(result: SFSpeechRecognitionResult?, error: Error?) {
        if let result {
            let segment = transcriptSegment(from: result)
            continuation.yield(result.isFinal ? .final(segment) : .partial(segment))
            if result.isFinal {
                finish()
                return
            }
        }

        if let error {
            finish(throwing: AppleSpeechLiveTranscriptionError.recognitionFailed(error.localizedDescription))
        }
    }

    private func transcriptSegment(from result: SFSpeechRecognitionResult) -> TranscriptSegment {
        let transcription = result.bestTranscription
        let segments = transcription.segments
        let endTime = segments.last.map { TimeInterval($0.timestamp + $0.duration) } ?? 0.1
        let confidences = segments.map(\.confidence)
        let confidence = confidences.isEmpty
            ? 0
            : Double(confidences.reduce(0, +) / Float(confidences.count))

        return TranscriptSegment(
            id: segmentID,
            speakerName: "You",
            trackKind: .microphone,
            startTime: 0,
            endTime: max(0.1, endTime),
            text: transcription.formattedString,
            confidence: confidence,
            isFinal: result.isFinal
        )
    }

    private func emitInputLevel(from buffer: AVAudioPCMBuffer) {
        let now = ProcessInfo.processInfo.systemUptime
        let shouldEmit = levelLock.withLock { () -> Bool in
            guard now - lastLevelEmissionUptime >= 0.10 else { return false }
            lastLevelEmissionUptime = now
            return true
        }
        guard shouldEmit else { return }
        continuation.yield(.inputLevel(Self.normalizedInputLevel(from: buffer)))
    }

    private static func normalizedInputLevel(from buffer: AVAudioPCMBuffer) -> Double {
        guard let channels = buffer.floatChannelData,
              buffer.frameLength > 0,
              buffer.format.channelCount > 0 else {
            return 0
        }

        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        var sumOfSquares: Double = 0
        var sampleCount = 0
        for channelIndex in 0..<channelCount {
            let samples = channels[channelIndex]
            for frameIndex in 0..<frameCount {
                let sample = Double(samples[frameIndex])
                sumOfSquares += sample * sample
                sampleCount += 1
            }
        }
        guard sampleCount > 0 else { return 0 }

        let rms = sqrt(sumOfSquares / Double(sampleCount))
        let decibels = 20 * log10(max(rms, 0.000_01))
        return min(1, max(0, (decibels + 60) / 60))
    }

    private func finish(throwing error: Error? = nil) {
        stop()
        if let error {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
    }
}
