@preconcurrency import AVFoundation
import Foundation
@preconcurrency import Speech

typealias AppleSpeechFrameBackendFactory = @Sendable (
    Locale,
    Bool
) throws -> any LocalTranscriptionBackend

/// Explicit Apple Speech compatibility provider. Unlike the legacy preview
/// provider, it cannot open an input engine: it accepts only authoritative
/// capture frames from `TranscriptionSessionCoordinator`.
public final class AppleSpeechFrameTranscriptionProvider: LocalTranscriptionProviding, @unchecked Sendable {
    public let descriptor = ProviderDescriptor(
        id: "apple-speech-frame-compatibility",
        modelVersion: "system",
        supportedLocaleIdentifiers: ["pl-PL", "en-US"],
        audioInputStrategy: .authoritativeCaptureFrames,
        supportsRemoteSpeakerDiarization: false,
        maximumRemoteSpeakerCount: 1
    )

    private let privacyBoundary: TranscriptionPrivacyBoundary
    private let authorizationProvider: any SpeechRecognitionAuthorizationProviding
    private let onDeviceCapability: any AppleSpeechOnDeviceCapabilityProviding
    private let backendFactory: AppleSpeechFrameBackendFactory

    public init(
        privacyBoundary: TranscriptionPrivacyBoundary,
        authorizationProvider: any SpeechRecognitionAuthorizationProviding = SystemSpeechRecognitionAuthorizationProvider(),
        onDeviceCapability: any AppleSpeechOnDeviceCapabilityProviding = SystemAppleSpeechOnDeviceCapability()
    ) {
        self.privacyBoundary = privacyBoundary
        self.authorizationProvider = authorizationProvider
        self.onDeviceCapability = onDeviceCapability
        backendFactory = { locale, requiresOnDevice in
            try AppleSpeechFrameBackend(locale: locale, requiresOnDevice: requiresOnDevice)
        }
    }

    init(
        privacyBoundary: TranscriptionPrivacyBoundary,
        authorizationProvider: any SpeechRecognitionAuthorizationProviding = SystemSpeechRecognitionAuthorizationProvider(),
        onDeviceCapability: any AppleSpeechOnDeviceCapabilityProviding = SystemAppleSpeechOnDeviceCapability(),
        backendFactory: @escaping AppleSpeechFrameBackendFactory
    ) {
        self.privacyBoundary = privacyBoundary
        self.authorizationProvider = authorizationProvider
        self.onDeviceCapability = onDeviceCapability
        self.backendFactory = backendFactory
    }

    public func makeSession(
        _ configuration: TranscriptionSessionConfiguration
    ) async throws -> any LocalTranscriptionSession {
        let policy = try await privacyBoundary.appleSpeechPolicy()
        let locale = Locale(identifier: configuration.context.localeIdentifier ?? Locale.current.identifier)
        guard !policy.requiresOnDeviceRecognition || onDeviceCapability.supportsOnDeviceRecognition(for: locale) else {
            throw TranscriptionPrivacyBoundaryError.onDeviceRecognitionRequired
        }
        let authorization = authorizationProvider.currentAuthorizationState()
        guard authorization.canStartRecognition else {
            throw AppleSpeechLiveTranscriptionError.authorizationDenied(authorization)
        }
        return AppleSpeechFrameSession(
            backend: try backendFactory(locale, policy.requiresOnDeviceRecognition)
        )
    }
}

private final class AppleSpeechFrameSession: LocalTranscriptionSession, @unchecked Sendable {
    let events: AsyncThrowingStream<LocalTranscriptionEvent, Error>
    private let backend: any LocalTranscriptionBackend
    private let lock = NSLock()
    private var terminal = false
    init(backend: any LocalTranscriptionBackend) {
        self.backend = backend
        events = backend.events
    }
    func submit(_ frame: CapturedPCMFrame) async throws {
        guard !lock.withLock({ terminal }) else { return }
        try await backend.submit(frame)
    }
    func finish() async throws {
        guard beginTerminal() else { return }
        try await backend.finish()
    }
    func cancel() async {
        guard beginTerminal() else { return }
        await backend.cancel()
    }
    private func beginTerminal() -> Bool {
        lock.withLock {
            guard !terminal else { return false }
            terminal = true
            return true
        }
    }
}

private final class AppleSpeechFrameBackend: LocalTranscriptionBackend, @unchecked Sendable {
    let events: AsyncThrowingStream<LocalTranscriptionEvent, Error>
    private let continuation: AsyncThrowingStream<LocalTranscriptionEvent, Error>.Continuation
    private let microphone: AppleSpeechFrameTrack
    private let remote: AppleSpeechFrameTrack
    private let lock = NSLock()
    private var terminal = false

    init(locale: Locale, requiresOnDevice: Bool) throws {
        let pair = AsyncThrowingStream<LocalTranscriptionEvent, Error>.makeStream(
            bufferingPolicy: .bufferingNewest(128)
        )
        events = pair.stream
        continuation = pair.continuation
        microphone = try AppleSpeechFrameTrack(
            locale: locale,
            track: .microphone,
            speakerName: "You",
            requiresOnDevice: requiresOnDevice,
            continuation: pair.continuation
        )
        remote = try AppleSpeechFrameTrack(
            locale: locale,
            track: .remoteSystem,
            speakerName: "Speaker 1",
            requiresOnDevice: requiresOnDevice,
            continuation: pair.continuation
        )
        continuation.yield(.status("Apple Speech compatibility mode ready from capture frames"))
    }

    func submit(_ frame: CapturedPCMFrame) async throws {
        guard !lock.withLock({ terminal }) else { return }
        switch frame.track {
        case .microphone: try microphone.append(frame)
        case .remoteSystem: try remote.append(frame)
        case .mixedPlayback: break
        }
    }

    func finish() async throws {
        guard beginTerminal() else { return }
        async let microphoneFinish: Void = microphone.finish()
        async let remoteFinish: Void = remote.finish()
        _ = await (microphoneFinish, remoteFinish)
        continuation.finish()
    }

    func cancel() async {
        guard beginTerminal() else { return }
        microphone.cancel()
        remote.cancel()
        continuation.finish()
    }

    private func beginTerminal() -> Bool {
        lock.withLock {
            guard !terminal else { return false }
            terminal = true
            return true
        }
    }
}

private final class AppleSpeechFrameTrack: @unchecked Sendable {
    private let track: TrackKind
    private let speakerName: String
    private let request: SFSpeechAudioBufferRecognitionRequest
    private let continuation: AsyncThrowingStream<LocalTranscriptionEvent, Error>.Continuation
    private let segmentID = UUID()
    private let lock = NSLock()
    private var recognitionTask: SFSpeechRecognitionTask?
    private var firstMeetingTime: TimeInterval?
    private var completed = false
    private var completionWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        locale: Locale,
        track: TrackKind,
        speakerName: String,
        requiresOnDevice: Bool,
        continuation: AsyncThrowingStream<LocalTranscriptionEvent, Error>.Continuation
    ) throws {
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw AppleSpeechLiveTranscriptionError.recognizerUnavailable(locale.identifier)
        }
        self.track = track
        self.speakerName = speakerName
        self.continuation = continuation
        request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = requiresOnDevice
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            self?.receive(result: result, error: error)
        }
    }

    func append(_ frame: CapturedPCMFrame) throws {
        guard !lock.withLock({ completed }) else { return }
        lock.withLock {
            if firstMeetingTime == nil { firstMeetingTime = frame.meetingTime }
        }
        request.append(try Self.buffer(frame))
    }

    func finish() async {
        let alreadyComplete = lock.withLock { completed }
        guard !alreadyComplete else { return }
        request.endAudio()
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            self?.cancel()
        }
        await withCheckedContinuation { waiter in
            let resumeNow = lock.withLock { () -> Bool in
                if completed { return true }
                completionWaiters.append(waiter)
                return false
            }
            if resumeNow { waiter.resume() }
        }
        timeout.cancel()
    }

    func cancel() {
        recognitionTask?.cancel()
        complete()
    }

    private func receive(result: SFSpeechRecognitionResult?, error: Error?) {
        if let result {
            let raw = result.bestTranscription
            let start = lock.withLock { firstMeetingTime ?? 0 }
            let end = start + (raw.segments.last.map { TimeInterval($0.timestamp + $0.duration) } ?? 0.1)
            let confidences = raw.segments.map(\.confidence)
            let confidence = confidences.isEmpty ? 0 : Double(confidences.reduce(0, +) / Float(confidences.count))
            let segment = TranscriptSegment(
                id: segmentID,
                speakerName: speakerName,
                trackKind: track,
                startTime: start,
                endTime: max(start + 0.1, end),
                text: raw.formattedString,
                confidence: confidence,
                isFinal: result.isFinal
            )
            continuation.yield(result.isFinal ? .final(segment) : .partial(segment))
            if result.isFinal { complete() }
        }
        if let error {
            continuation.yield(.degraded("Apple Speech \(track.rawValue) stream stopped: \(error.localizedDescription)"))
            complete()
        }
    }

    private func complete() {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            guard !completed else { return [] }
            completed = true
            recognitionTask = nil
            let waiters = completionWaiters
            completionWaiters.removeAll()
            return waiters
        }
        waiters.forEach { $0.resume() }
    }

    private static func buffer(_ frame: CapturedPCMFrame) throws -> AVAudioPCMBuffer {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: frame.sampleRate,
            channels: AVAudioChannelCount(frame.channelCount),
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frame.frameCount)
        ), let channels = buffer.floatChannelData else {
            throw AppleSpeechLiveTranscriptionError.invalidAudioInput
        }
        buffer.frameLength = AVAudioFrameCount(frame.frameCount)
        let source = frame.floatSamples
        for channel in 0..<frame.channelCount {
            for frameIndex in 0..<frame.frameCount {
                channels[channel][frameIndex] = source[frameIndex * frame.channelCount + channel]
            }
        }
        return buffer
    }
}
