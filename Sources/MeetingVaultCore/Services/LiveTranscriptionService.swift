import Foundation

public struct LiveTranscriptionContext: Equatable, Sendable {
    public var meetingID: UUID
    public var sourceID: String
    public var sourceName: String
    public var microphoneDeviceID: String?
    public var microphoneDeviceName: String?
    public var localeIdentifier: String?
    public var appleSpeechRequiresOnDeviceRecognition: Bool

    public init(
        meetingID: UUID,
        sourceID: String,
        sourceName: String,
        microphoneDeviceID: String? = nil,
        microphoneDeviceName: String? = nil,
        localeIdentifier: String? = nil,
        appleSpeechRequiresOnDeviceRecognition: Bool = false
    ) {
        self.meetingID = meetingID
        self.sourceID = sourceID
        self.sourceName = sourceName
        self.microphoneDeviceID = microphoneDeviceID
        self.microphoneDeviceName = microphoneDeviceName
        self.localeIdentifier = localeIdentifier
        self.appleSpeechRequiresOnDeviceRecognition = appleSpeechRequiresOnDeviceRecognition
    }
}

public enum LiveTranscriptionEvent: Equatable, Sendable {
    case status(String)
    case inputLevel(Double)
    case partial(TranscriptSegment)
    case final(TranscriptSegment)
}

public struct LiveTranscriptionProviderError: Error, Equatable, LocalizedError, Sendable {
    public var message: String

    public init(message: String) {
        self.message = message
    }

    public var errorDescription: String? {
        message
    }
}

public protocol LiveTranscriptionProviding: Sendable {
    var id: String { get }
    func events(for context: LiveTranscriptionContext) -> AsyncThrowingStream<LiveTranscriptionEvent, Error>
}

public struct LiveTranscriptionService: Sendable {
    private let provider: any LiveTranscriptionProviding

    public init(provider: any LiveTranscriptionProviding) {
        self.provider = provider
    }

    public var providerID: String {
        provider.id
    }

    public func events(for context: LiveTranscriptionContext) -> AsyncThrowingStream<LiveTranscriptionEvent, Error> {
        provider.events(for: context)
    }
}

public enum MockLiveTranscriptionProviderAction: Equatable, Sendable {
    case event(LiveTranscriptionEvent)
    case fail(String)
}

public final class MockLiveTranscriptionProvider: LiveTranscriptionProviding, @unchecked Sendable {
    public let id: String
    private let actions: [MockLiveTranscriptionProviderAction]
    private let lock = NSLock()
    private var _contexts: [LiveTranscriptionContext] = []

    public var contexts: [LiveTranscriptionContext] {
        lock.withLock { _contexts }
    }

    public init(
        id: String = "mock-live-transcription",
        actions: [MockLiveTranscriptionProviderAction]
    ) {
        self.id = id
        self.actions = actions
    }

    public func events(for context: LiveTranscriptionContext) -> AsyncThrowingStream<LiveTranscriptionEvent, Error> {
        lock.withLock {
            _contexts.append(context)
        }

        return AsyncThrowingStream { continuation in
            for action in actions {
                switch action {
                case let .event(event):
                    continuation.yield(event)
                case let .fail(message):
                    continuation.finish(throwing: LiveTranscriptionProviderError(message: message))
                    return
                }
            }
            continuation.finish()
        }
    }
}
