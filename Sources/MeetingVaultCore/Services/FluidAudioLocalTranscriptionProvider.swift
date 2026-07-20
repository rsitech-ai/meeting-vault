import Foundation

public protocol LocalModelRuntimeSessionProviding: Sendable {
    func withRuntimeSession(
        _ ids: Set<String>,
        _ operation: @Sendable (LocalModelRuntimeAccess) async throws -> Void
    ) async throws
}

extension LocalModelInstallationService: LocalModelRuntimeSessionProviding {}

protocol LocalTranscriptionBackend: Sendable {
    var events: AsyncThrowingStream<LocalTranscriptionEvent, Error> { get }
    func submit(_ frame: CapturedPCMFrame) async throws
    func finish() async throws
    func cancel() async
}

typealias LocalTranscriptionBackendFactory = @Sendable (
    LocalModelRuntimeAccess,
    TranscriptionSessionConfiguration
) async throws -> any LocalTranscriptionBackend

public final class FluidAudioLocalTranscriptionProvider: LocalTranscriptionProviding, @unchecked Sendable {
    public let descriptor = ProviderDescriptor(
        id: "fluidaudio-local",
        modelVersion: "FluidAudio-0.15.5+Parakeet-v3+LS-EEND",
        supportedLocaleIdentifiers: ["pl-PL", "en-US"],
        audioInputStrategy: .authoritativeCaptureFrames,
        supportsRemoteSpeakerDiarization: true,
        maximumRemoteSpeakerCount: 10
    )

    private let runtime: any LocalModelRuntimeSessionProviding
    private let backendFactory: LocalTranscriptionBackendFactory
    private let requiredUnits: Set<String> = [
        "automatic-speech-recognition",
        "streaming-speaker-diarization",
    ]

    public init(runtime: any LocalModelRuntimeSessionProviding) {
        self.runtime = runtime
        backendFactory = { access, configuration in
            try await FluidAudioCoreMLBackend.load(
                access: access,
                configuration: configuration
            )
        }
    }

    init(
        runtime: any LocalModelRuntimeSessionProviding,
        backendFactory: @escaping LocalTranscriptionBackendFactory
    ) {
        self.runtime = runtime
        self.backendFactory = backendFactory
    }

    public func makeSession(
        _ configuration: TranscriptionSessionConfiguration
    ) async throws -> any LocalTranscriptionSession {
        let lifecycle = FluidAudioRuntimeLifecycle()
        let runtime = self.runtime
        let requiredUnits = self.requiredUnits
        let backendFactory = self.backendFactory
        let task = Task {
            do {
                try await runtime.withRuntimeSession(requiredUnits) { access in
                    do {
                        let backend = try await backendFactory(access, configuration)
                        await lifecycle.resolve(.success(backend))
                        await lifecycle.waitUntilReleased()
                    } catch {
                        await lifecycle.resolve(.failure(error))
                        throw error
                    }
                }
            } catch {
                // Lease acquisition and readiness checks can fail before the
                // runtime invokes its closure. Always resolve the waiter so a
                // missing or repairing model can never hang recording start.
                await lifecycle.resolve(.failure(error))
                throw error
            }
        }
        let backend: any LocalTranscriptionBackend
        do {
            backend = try await lifecycle.backend()
        } catch {
            _ = try? await task.value
            throw error
        }
        return FluidAudioLocalTranscriptionSession(
            backend: backend,
            lifecycle: lifecycle,
            runtimeTask: task
        )
    }
}

private actor FluidAudioRuntimeLifecycle {
    private var resolution: Result<any LocalTranscriptionBackend, Error>?
    private var backendWaiters: [CheckedContinuation<Result<any LocalTranscriptionBackend, Error>, Never>] = []
    private var released = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func resolve(_ result: Result<any LocalTranscriptionBackend, Error>) {
        guard resolution == nil else { return }
        resolution = result
        let waiters = backendWaiters
        backendWaiters.removeAll()
        waiters.forEach { $0.resume(returning: result) }
    }

    func backend() async throws -> any LocalTranscriptionBackend {
        let result: Result<any LocalTranscriptionBackend, Error>
        if let resolution {
            result = resolution
        } else {
            result = await withCheckedContinuation { backendWaiters.append($0) }
        }
        return try result.get()
    }

    func release() {
        guard !released else { return }
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func waitUntilReleased() async {
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }
}

private final class FluidAudioLocalTranscriptionSession: LocalTranscriptionSession, @unchecked Sendable {
    let events: AsyncThrowingStream<LocalTranscriptionEvent, Error>
    private let backend: any LocalTranscriptionBackend
    private let lifecycle: FluidAudioRuntimeLifecycle
    private let runtimeTask: Task<Void, Error>
    private let lock = NSLock()
    private var terminal = false

    init(
        backend: any LocalTranscriptionBackend,
        lifecycle: FluidAudioRuntimeLifecycle,
        runtimeTask: Task<Void, Error>
    ) {
        self.backend = backend
        self.lifecycle = lifecycle
        self.runtimeTask = runtimeTask
        events = backend.events
    }

    func submit(_ frame: CapturedPCMFrame) async throws {
        guard !lock.withLock({ terminal }) else { return }
        try await backend.submit(frame)
    }

    func finish() async throws {
        guard beginTerminal() else { return }
        var terminalError: Error?
        do { try await backend.finish() } catch { terminalError = error }
        await lifecycle.release()
        do { try await runtimeTask.value } catch {
            if terminalError == nil { terminalError = error }
        }
        if let terminalError { throw terminalError }
    }

    func cancel() async {
        guard beginTerminal() else { return }
        await backend.cancel()
        await lifecycle.release()
        _ = try? await runtimeTask.value
    }

    private func beginTerminal() -> Bool {
        lock.withLock {
            guard !terminal else { return false }
            terminal = true
            return true
        }
    }

    deinit {
        // A forgotten session must not pin model leases forever. Deinit cannot
        // await, so release is scheduled; normal coordinator paths always await.
        let lifecycle = lifecycle
        let backend = backend
        Task {
            await backend.cancel()
            await lifecycle.release()
        }
    }
}
