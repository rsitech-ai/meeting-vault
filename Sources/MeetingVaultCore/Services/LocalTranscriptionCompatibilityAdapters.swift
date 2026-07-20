import Foundation

public struct UnavailableLocalTranscriptionProvider: LocalTranscriptionProviding {
    public let descriptor = ProviderDescriptor(
        id: "local-models-unavailable",
        modelVersion: "unavailable",
        supportedLocaleIdentifiers: ["pl-PL", "en-US"]
    )
    private let reason: String
    public init(reason: String) { self.reason = reason }
    public func makeSession(
        _ configuration: TranscriptionSessionConfiguration
    ) async throws -> any LocalTranscriptionSession {
        throw LocalTranscriptionError.providerUnavailable(reason)
    }
}

/// Compatibility bridge for deterministic fixtures and injected tests. It is
/// never selected for local or Apple production modes.
public struct LegacyLiveTranscriptionLocalAdapter: LocalTranscriptionProviding {
    public let descriptor = ProviderDescriptor(
        id: "legacy-live-fixture-adapter",
        modelVersion: "fixture",
        supportedLocaleIdentifiers: ["pl-PL", "en-US"]
    )
    private let provider: any LiveTranscriptionProviding
    public init(provider: any LiveTranscriptionProviding) { self.provider = provider }
    public func makeSession(
        _ configuration: TranscriptionSessionConfiguration
    ) async throws -> any LocalTranscriptionSession {
        LegacyLiveTranscriptionSession(
            provider: provider,
            context: LiveTranscriptionContext(
                meetingID: configuration.meetingID,
                sourceID: configuration.sourceID ?? "fixture",
                sourceName: configuration.sourceID ?? "Fixture",
                microphoneDeviceID: configuration.microphoneDeviceID,
                microphoneDeviceName: configuration.microphoneDeviceName,
                localeIdentifier: configuration.context.localeIdentifier
            )
        )
    }
}

private final class LegacyLiveTranscriptionSession: LocalTranscriptionSession, @unchecked Sendable {
    let events: AsyncThrowingStream<LocalTranscriptionEvent, Error>
    private let continuation: AsyncThrowingStream<LocalTranscriptionEvent, Error>.Continuation
    private let task: Task<Void, Never>
    private let lock = NSLock()
    private var terminal = false

    init(provider: any LiveTranscriptionProviding, context: LiveTranscriptionContext) {
        let pair = AsyncThrowingStream<LocalTranscriptionEvent, Error>.makeStream(
            bufferingPolicy: .bufferingNewest(64)
        )
        events = pair.stream
        continuation = pair.continuation
        task = Task {
            do {
                for try await event in provider.events(for: context) {
                    switch event {
                    case let .status(message): pair.continuation.yield(.status(message))
                    case .inputLevel:
                        // Legacy provider meters may come from another device;
                        // capture-frame levels remain authoritative.
                        break
                    case let .partial(segment): pair.continuation.yield(.partial(segment))
                    case let .final(segment): pair.continuation.yield(.final(segment))
                    }
                }
                pair.continuation.finish()
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                pair.continuation.yield(.degraded("Live transcription unavailable: \(message)"))
                pair.continuation.finish()
            }
        }
    }

    func submit(_ frame: CapturedPCMFrame) async throws {}
    func finish() async throws {
        guard beginTerminal() else { return }
        await task.value
        continuation.finish()
    }
    func cancel() async {
        guard beginTerminal() else { return }
        task.cancel()
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
