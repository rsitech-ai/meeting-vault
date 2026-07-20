import Foundation
@preconcurrency import Speech

public enum AppleSpeechFinalTranscriptionError: Error, Equatable, LocalizedError, Sendable {
    case authorizationDenied(SpeechRecognitionAuthorizationState)
    case missingAudioData(String)
    case temporaryFileWriteFailed(String)
    case recognizerUnavailable(String)
    case recognizerNotReady(String)
    case recognitionFailed(String)
    case recognitionTimedOut
    case recognitionCancelled
    case noRecognitionResult(String)

    public var errorDescription: String? {
        switch self {
        case let .authorizationDenied(state):
            return "Speech Recognition is \(state.rawValue). Choose Check Permissions Once, then open System Settings and allow Speech Recognition."
        case let .missingAudioData(path):
            return "Final transcription could not read decrypted audio for \(path)."
        case let .temporaryFileWriteFailed(message):
            return "Final transcription could not prepare a temporary local audio file: \(message)"
        case let .recognizerUnavailable(locale):
            return "Apple Speech is unavailable for locale \(locale)."
        case let .recognizerNotReady(locale):
            return "Apple Speech is not ready for locale \(locale). Try again after the recognizer becomes available."
        case let .recognitionFailed(message):
            return "Apple Speech final transcription failed: \(message)"
        case .recognitionTimedOut:
            return "Apple Speech final transcription timed out. The encrypted recording remains available for retry."
        case .recognitionCancelled:
            return "Apple Speech final transcription was cancelled."
        case let .noRecognitionResult(locale):
            return "Apple Speech returned no final transcript for locale \(locale)."
        }
    }
}

public protocol SpeechFileTranscribing: Sendable {
    func transcribeAudioFile(
        at url: URL,
        locale: Locale,
        request: TranscriptionRequest
    ) async throws -> [TranscriptSegment]
}

public final class AppleSpeechFinalTranscriptionEngine: TranscriptionEngine, @unchecked Sendable {
    public let id = "apple-speech-final"
    public let supportsRealtime = false

    private let authorizationProvider: any SpeechRecognitionAuthorizationProviding
    private let fileTranscriber: any SpeechFileTranscribing
    private let temporaryDirectory: URL
    private let fileManager: FileManager
    private let privacyBoundary: TranscriptionPrivacyBoundary
    private let onDeviceCapability: any AppleSpeechOnDeviceCapabilityProviding

    public init(
        privacyBoundary: TranscriptionPrivacyBoundary = TranscriptionPrivacyBoundary(mode: .appleMayUseNetwork),
        authorizationProvider: any SpeechRecognitionAuthorizationProviding = SystemSpeechRecognitionAuthorizationProvider(),
        onDeviceCapability: any AppleSpeechOnDeviceCapabilityProviding = SystemAppleSpeechOnDeviceCapability(),
        fileTranscriber: any SpeechFileTranscribing = AppleSpeechURLFileTranscriber(),
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        fileManager: FileManager = .default
    ) {
        self.privacyBoundary = privacyBoundary
        self.authorizationProvider = authorizationProvider
        self.onDeviceCapability = onDeviceCapability
        self.fileTranscriber = fileTranscriber
        self.temporaryDirectory = temporaryDirectory
        self.fileManager = fileManager
    }

    public func transcribe(_ request: TranscriptionRequest) async throws -> [TranscriptSegment] {
        let policy = try await privacyBoundary.appleSpeechPolicy()
        let locale = Self.locale(from: request.localeIdentifier)
        guard !policy.requiresOnDeviceRecognition || onDeviceCapability.supportsOnDeviceRecognition(for: locale) else {
            throw TranscriptionPrivacyBoundaryError.onDeviceRecognitionRequired
        }
        let authorizationState = resolvedAuthorizationState()
        guard authorizationState.canStartRecognition else {
            throw AppleSpeechFinalTranscriptionError.authorizationDenied(authorizationState)
        }
        guard let audioData = request.audioData, !audioData.isEmpty else {
            throw AppleSpeechFinalTranscriptionError.missingAudioData(request.audioChunkPath)
        }

        let scratchDirectory = temporaryDirectory
            .appendingPathComponent("MeetingVaultFinalTranscription", isDirectory: true)
        do {
            try fileManager.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
        } catch {
            throw AppleSpeechFinalTranscriptionError.temporaryFileWriteFailed(error.localizedDescription)
        }

        let scratchURL = scratchDirectory
            .appendingPathComponent("\(request.meetingID.uuidString)-\(UUID().uuidString)")
            .appendingPathExtension(Self.fileExtension(for: request.audioCodec))
        do {
            try audioData.write(to: scratchURL, options: [.atomic])
        } catch {
            throw AppleSpeechFinalTranscriptionError.temporaryFileWriteFailed(error.localizedDescription)
        }
        defer {
            try? fileManager.removeItem(at: scratchURL)
        }

        var effectiveRequest = request
        effectiveRequest.appleSpeechRequiresOnDeviceRecognition = policy.requiresOnDeviceRecognition
        return try await fileTranscriber.transcribeAudioFile(
            at: scratchURL,
            locale: locale,
            request: effectiveRequest
        )
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

    private static func fileExtension(for codec: String?) -> String {
        let normalized = codec?.lowercased() ?? ""
        if normalized.contains("wav") {
            return "wav"
        }
        if normalized.contains("aiff") || normalized.contains("aifc") {
            return "aiff"
        }
        if normalized.contains("mp3") {
            return "mp3"
        }
        if normalized.contains("m4a") || normalized.contains("aac") {
            return "m4a"
        }
        return "caf"
    }
}

public final class AppleSpeechURLFileTranscriber: SpeechFileTranscribing, @unchecked Sendable {
    public init() {}

    public func transcribeAudioFile(
        at url: URL,
        locale: Locale,
        request: TranscriptionRequest
    ) async throws -> [TranscriptSegment] {
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            throw AppleSpeechFinalTranscriptionError.recognizerUnavailable(locale.identifier)
        }
        guard recognizer.isAvailable else {
            throw AppleSpeechFinalTranscriptionError.recognizerNotReady(locale.identifier)
        }

        let recognitionRequest = SFSpeechURLRecognitionRequest(url: url)
        recognitionRequest.shouldReportPartialResults = false
        recognitionRequest.requiresOnDeviceRecognition = request.appleSpeechRequiresOnDeviceRecognition

        let segment = try await recognize(
            recognizer: recognizer,
            request: recognitionRequest,
            transcriptionRequest: request
        )
        return [segment]
    }

    private func recognize(
        recognizer: SFSpeechRecognizer,
        request: SFSpeechURLRecognitionRequest,
        transcriptionRequest: TranscriptionRequest
    ) async throws -> TranscriptSegment {
        let cancellation = RecognitionCancellationBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let state = RecognitionContinuationState(continuation: continuation)
                cancellation.install(state)
                if Task.isCancelled {
                    state.resume(.failure(AppleSpeechFinalTranscriptionError.recognitionCancelled))
                    return
                }
                let task = recognizer.recognitionTask(with: request) { result, error in
                    if let result, result.isFinal {
                        state.resume(.success(Self.segment(from: result, request: transcriptionRequest)))
                        return
                    }
                    if let error {
                        state.resume(
                            .failure(
                                AppleSpeechFinalTranscriptionError.recognitionFailed(error.localizedDescription)
                            )
                        )
                    }
                }
                state.setTask(task)
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private static func segment(
        from result: SFSpeechRecognitionResult,
        request: TranscriptionRequest
    ) -> TranscriptSegment {
        let transcription = result.bestTranscription
        let speechSegments = transcription.segments
        let offset = request.startTime ?? 0
        let relativeEnd = speechSegments.last.map {
            TimeInterval($0.timestamp + $0.duration)
        } ?? request.duration ?? 0.1
        let confidences = speechSegments.map(\.confidence)
        let confidence = confidences.isEmpty
            ? 0
            : Double(confidences.reduce(0, +) / Float(confidences.count))

        return TranscriptSegment(
            speakerName: speakerName(for: request.trackKind),
            trackKind: request.trackKind ?? .mixedPlayback,
            startTime: offset,
            endTime: max(offset + 0.1, offset + relativeEnd),
            text: transcription.formattedString,
            confidence: confidence,
            isFinal: true
        )
    }

    private static func speakerName(for track: TrackKind?) -> String {
        switch track {
        case .microphone:
            return "You"
        case .remoteSystem:
            return "Meeting audio"
        case .mixedPlayback:
            return "Playback mix"
        case nil:
            return "Meeting audio"
        }
    }
}

private final class RecognitionContinuationState: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<TranscriptSegment, Error>?
    private var task: SFSpeechRecognitionTask?
    private var timeoutTask: Task<Void, Never>?

    init(continuation: CheckedContinuation<TranscriptSegment, Error>) {
        self.continuation = continuation
    }

    func setTask(_ task: SFSpeechRecognitionTask) {
        let isActive = lock.withLock {
            guard continuation != nil else { return false }
            self.task = task
            return true
        }
        guard isActive else {
            task.cancel()
            return
        }
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000_000)
            guard !Task.isCancelled else { return }
            self?.resume(.failure(AppleSpeechFinalTranscriptionError.recognitionTimedOut))
        }
        let keepTimeout = lock.withLock {
            guard continuation != nil else { return false }
            self.timeoutTask = timeoutTask
            return true
        }
        if !keepTimeout {
            timeoutTask.cancel()
        }
    }

    func resume(_ result: Result<TranscriptSegment, Error>) {
        let continuation = lock.withLock {
            let continuation = self.continuation
            self.continuation = nil
            task?.cancel()
            task = nil
            timeoutTask?.cancel()
            timeoutTask = nil
            return continuation
        }
        guard let continuation else { return }
        continuation.resume(with: result)
    }
}

private final class RecognitionCancellationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var state: RecognitionContinuationState?
    private var cancelled = false

    func install(_ state: RecognitionContinuationState) {
        let shouldCancel = lock.withLock {
            self.state = state
            return cancelled
        }
        if shouldCancel {
            state.resume(.failure(AppleSpeechFinalTranscriptionError.recognitionCancelled))
        }
    }

    func cancel() {
        let state = lock.withLock {
            cancelled = true
            return self.state
        }
        state?.resume(.failure(AppleSpeechFinalTranscriptionError.recognitionCancelled))
    }
}
