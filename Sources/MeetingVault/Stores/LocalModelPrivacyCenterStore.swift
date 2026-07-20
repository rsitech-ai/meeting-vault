import Darwin
import Foundation
import MeetingVaultCore
import OSLog

struct LocalModelProductionRuntime: Sendable {
    let service: LocalModelInstallationService
    let appendAudit: @Sendable (PrivacyAuditAction, [String: String]) async throws -> Void
}

struct LocalModelPrivacyCenterClient: Sendable {
    var units: @Sendable () async -> [LocalModelInstallUnit]
    var snapshot: @Sendable () async -> [LocalModelAssetState]
    var install: @Sendable (String) async -> AsyncThrowingStream<ModelInstallEvent, Error>
    var cancel: @Sendable (String) async -> Void
    var repair: @Sendable (String) async -> AsyncThrowingStream<ModelInstallEvent, Error>
    var prewarm: @Sendable (String) async throws -> ModelSelfCheck
    var remove: @Sendable (String) async throws -> Void
    var lastSelfCheck: @Sendable (String) async throws -> ModelSelfCheck?
    var prewarmAvailable: Bool

    init(
        units: @escaping @Sendable () async -> [LocalModelInstallUnit],
        snapshot: @escaping @Sendable () async -> [LocalModelAssetState],
        install: @escaping @Sendable (String) async -> AsyncThrowingStream<ModelInstallEvent, Error>,
        cancel: @escaping @Sendable (String) async -> Void,
        repair: @escaping @Sendable (String) async -> AsyncThrowingStream<ModelInstallEvent, Error>,
        prewarm: @escaping @Sendable (String) async throws -> ModelSelfCheck,
        remove: @escaping @Sendable (String) async throws -> Void,
        lastSelfCheck: @escaping @Sendable (String) async throws -> ModelSelfCheck?,
        prewarmAvailable: Bool = true
    ) {
        self.units = units
        self.snapshot = snapshot
        self.install = install
        self.cancel = cancel
        self.repair = repair
        self.prewarm = prewarm
        self.remove = remove
        self.lastSelfCheck = lastSelfCheck
        self.prewarmAvailable = prewarmAvailable
    }

    static func live(_ service: LocalModelInstallationService) -> LocalModelPrivacyCenterClient {
        LocalModelPrivacyCenterClient(
            units: { await service.units() },
            snapshot: { await service.snapshot() },
            install: { await service.install($0) },
            cancel: { await service.cancel($0) },
            repair: { await service.repair($0) },
            prewarm: { try await service.prewarm($0) },
            remove: { try await service.remove($0) },
            lastSelfCheck: { try await service.lastSelfCheck($0) },
            prewarmAvailable: true
        )
    }
}

@MainActor
final class LocalModelPrivacyCenterStore: ObservableObject {
    @Published private(set) var units: [LocalModelInstallUnit] = []
    @Published private(set) var states: [String: LocalModelAssetState] = [:]
    @Published private(set) var lastSelfChecks: [String: ModelSelfCheck] = [:]
    @Published private(set) var privacyMode: TranscriptionPrivacyMode
    @Published private(set) var statusMessage = "Local model status has not been refreshed"
    var isPrewarmAvailable: Bool { client.prewarmAvailable }

    private let client: LocalModelPrivacyCenterClient
    private let privacyPreferences: TranscriptionPrivacyModeStore
    private let privacyTransition: TranscriptionPrivacyModeTransitionCoordinator?
    private let recordingIsActive: () -> Bool
    private let restartProvider: TranscriptionPrivacyModeTransitionCoordinator.Restart
    private let modelStateDidChange: @MainActor @Sendable () async -> Void

    init(
        client: LocalModelPrivacyCenterClient,
        privacyPreferences: TranscriptionPrivacyModeStore,
        privacyTransition: TranscriptionPrivacyModeTransitionCoordinator? = nil,
        recordingIsActive: @escaping () -> Bool = { false },
        restartProvider: @escaping TranscriptionPrivacyModeTransitionCoordinator.Restart = {},
        modelStateDidChange: @escaping @MainActor @Sendable () async -> Void = {}
    ) {
        self.client = client
        self.privacyPreferences = privacyPreferences
        self.privacyTransition = privacyTransition
        self.recordingIsActive = recordingIsActive
        self.restartProvider = restartProvider
        self.modelStateDidChange = modelStateDidChange
        privacyMode = privacyPreferences.mode
    }

    static func production(
        libraryRoot suppliedLibraryRoot: URL? = nil,
        modelsRoot suppliedModelsRoot: URL? = nil,
        privacyPreferences suppliedPreferences: TranscriptionPrivacyModeStore = TranscriptionPrivacyModeStore(),
        privacyBoundary suppliedBoundary: TranscriptionPrivacyBoundary? = nil,
        activityGate: TranscriptionRuntimeActivityGate? = nil,
        recordingIsActive: @escaping () -> Bool = { false },
        restartProvider: @escaping TranscriptionPrivacyModeTransitionCoordinator.Restart = {},
        modelStateDidChange: @escaping @MainActor @Sendable () async -> Void = {}
    ) -> LocalModelPrivacyCenterStore {
        do {
            let runtime = try makeProductionRuntime(
                libraryRoot: suppliedLibraryRoot,
                modelsRoot: suppliedModelsRoot
            )
            return production(
                runtime: runtime,
                privacyPreferences: suppliedPreferences,
                privacyBoundary: suppliedBoundary,
                activityGate: activityGate,
                recordingIsActive: recordingIsActive,
                restartProvider: restartProvider,
                modelStateDidChange: modelStateDidChange
            )
        } catch {
            return unavailableProductionStore(
                privacyPreferences: suppliedPreferences,
                privacyBoundary: suppliedBoundary,
                activityGate: activityGate,
                recordingIsActive: recordingIsActive,
                restartProvider: restartProvider,
                modelStateDidChange: modelStateDidChange
            )
        }
    }

    static func makeProductionRuntime(
        libraryRoot suppliedLibraryRoot: URL? = nil,
        modelsRoot suppliedModelsRoot: URL? = nil
    ) throws -> LocalModelProductionRuntime {
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        let meetingVaultRoot = appSupport.appendingPathComponent("MeetingVault", isDirectory: true)
        let libraryRoot = (suppliedLibraryRoot
            ?? meetingVaultRoot.appendingPathComponent("Library", isDirectory: true)).standardizedFileURL
        let modelsRoot = (suppliedModelsRoot
            ?? meetingVaultRoot.appendingPathComponent("Models", isDirectory: true)).standardizedFileURL
        let audit = LocalModelPrivacyAuditActor(
            logURL: libraryRoot.appendingPathComponent("privacy-audit.jsonl")
        )
        let manifest = try LocalModelManifest.loadBundled()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60 * 60
        let service = try LocalModelInstallationService(
                manifest: manifest,
                modelsRoot: modelsRoot,
                sessionConfiguration: configuration,
                approvedHosts: [
                    "huggingface.co",
                    "cdn-lfs.hf.co",
                    "cdn-lfs-us-1.hf.co",
                    "cas-bridge.xethub.hf.co",
                ],
                availableCapacity: { url in
                    let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                    guard let capacity = values.volumeAvailableCapacityForImportantUsage else {
                        throw LocalModelInstallationError.insufficientDisk
                    }
                    return capacity
                },
                now: Date.init,
                selfCheck: { _, _ in
                    // The in-process callback remains fail-closed. Production
                    // prewarm is routed only through the killable helper below.
                    throw LocalModelInstallationError.selfCheckFailed
                },
                terminatingSelfCheckExecutor: { id, root, timeout in
                    try await LocalModelSelfCheckProcessExecutor.run(
                        assetID: id,
                        root: root,
                        timeout: timeout
                    )
                },
                audit: { action, metadata in
                    await audit.record(action, metadata: metadata)
                }
            )
        return LocalModelProductionRuntime(
            service: service,
            appendAudit: { action, metadata in
                try await audit.append(action, metadata: metadata)
            }
        )
    }

    static func production(
        runtime: LocalModelProductionRuntime,
        privacyPreferences: TranscriptionPrivacyModeStore,
        privacyBoundary suppliedBoundary: TranscriptionPrivacyBoundary? = nil,
        activityGate: TranscriptionRuntimeActivityGate? = nil,
        recordingIsActive: @escaping () -> Bool = { false },
        restartProvider: @escaping TranscriptionPrivacyModeTransitionCoordinator.Restart = {},
        modelStateDidChange: @escaping @MainActor @Sendable () async -> Void = {}
    ) -> LocalModelPrivacyCenterStore {
        let boundary = suppliedBoundary ?? TranscriptionPrivacyBoundary(modeStore: privacyPreferences)
        let transition = TranscriptionPrivacyModeTransitionCoordinator(
            preferences: privacyPreferences,
            boundary: boundary,
            activityGate: activityGate,
            audit: runtime.appendAudit
        )
        return LocalModelPrivacyCenterStore(
            client: .live(runtime.service),
            privacyPreferences: privacyPreferences,
            privacyTransition: transition,
            recordingIsActive: recordingIsActive,
            restartProvider: restartProvider,
            modelStateDidChange: modelStateDidChange
        )
    }

    private static func unavailableProductionStore(
        privacyPreferences: TranscriptionPrivacyModeStore,
        privacyBoundary suppliedBoundary: TranscriptionPrivacyBoundary?,
        activityGate: TranscriptionRuntimeActivityGate?,
        recordingIsActive: @escaping () -> Bool,
        restartProvider: @escaping TranscriptionPrivacyModeTransitionCoordinator.Restart,
        modelStateDidChange: @escaping @MainActor @Sendable () async -> Void
    ) -> LocalModelPrivacyCenterStore {
        let audit: TranscriptionPrivacyModeTransitionCoordinator.Audit = { _, _ in }
        let boundary = suppliedBoundary ?? TranscriptionPrivacyBoundary(modeStore: privacyPreferences)
        let transition = TranscriptionPrivacyModeTransitionCoordinator(
            preferences: privacyPreferences,
            boundary: boundary,
            activityGate: activityGate,
            audit: audit
        )
        let unavailable = LocalModelPrivacyCenterClient(
                units: { [] },
                snapshot: { [] },
                install: { _ in AsyncThrowingStream { $0.finish(throwing: LocalModelInstallationError.unitNotReady) } },
                cancel: { _ in },
                repair: { _ in AsyncThrowingStream { $0.finish(throwing: LocalModelInstallationError.unitNotReady) } },
                prewarm: { _ in throw LocalModelInstallationError.unitNotReady },
                remove: { _ in throw LocalModelInstallationError.unitNotReady },
                lastSelfCheck: { _ in nil }
            )
        let store = LocalModelPrivacyCenterStore(
            client: unavailable,
            privacyPreferences: privacyPreferences,
            privacyTransition: transition,
            recordingIsActive: recordingIsActive,
            restartProvider: restartProvider,
            modelStateDidChange: modelStateDidChange
        )
        store.statusMessage = "Local model manifest is unavailable"
        return store
    }

    func refresh() async {
        units = await client.units()
        states = Dictionary(uniqueKeysWithValues: await client.snapshot().map { ($0.id, $0) })
        for unit in units {
            if let result = try? await client.lastSelfCheck(unit.id) {
                lastSelfChecks[unit.id] = result
            }
        }
        statusMessage = units.isEmpty ? "Local model metadata is unavailable" : "Local model status is current"
        await modelStateDidChange()
    }

    func install(_ id: String) async {
        await consume(await client.install(id), for: id)
    }

    func cancel(_ id: String) async {
        await client.cancel(id)
        await refresh()
    }

    func repair(_ id: String) async {
        await consume(await client.repair(id), for: id)
    }

    func prewarm(_ id: String) async {
        guard client.prewarmAvailable else {
            statusMessage = "The terminating local provider self-check helper is unavailable"
            return
        }
        do {
            lastSelfChecks[id] = try await client.prewarm(id)
            statusMessage = "Local provider self-check passed"
        } catch {
            await refresh()
            statusMessage = "Local provider self-check failed"
        }
    }

    func remove(_ id: String) async {
        do {
            try await client.remove(id)
            lastSelfChecks.removeValue(forKey: id)
            await refresh()
        } catch {
            statusMessage = "The local model could not be removed"
        }
    }

    func setPrivacyMode(
        _ mode: TranscriptionPrivacyMode,
        confirmsNetworkUse: Bool = false
    ) async throws {
        if let privacyTransition {
            try await privacyTransition.apply(mode, confirmsNetworkUse: confirmsNetworkUse, recordingIsActive: recordingIsActive(), restartProvider: restartProvider)
        } else {
            try privacyPreferences.setMode(mode, confirmsNetworkUse: confirmsNetworkUse)
        }
        privacyMode = privacyPreferences.mode
    }

    func selectPrivacyMode(_ mode: TranscriptionPrivacyMode) async {
        do {
            try await setPrivacyMode(mode)
        } catch {
            statusMessage = "The transcription privacy mode was not changed"
        }
    }

    func confirmNetworkPrivacyMode() async {
        do {
            try await setPrivacyMode(.appleMayUseNetwork, confirmsNetworkUse: true)
        } catch {
            statusMessage = "The network compatibility mode was not changed"
        }
    }

    private func consume(
        _ stream: AsyncThrowingStream<ModelInstallEvent, Error>,
        for id: String
    ) async {
        do {
            for try await event in stream {
                apply(event, to: id)
                if case .status = event {
                    await modelStateDidChange()
                }
            }
            statusMessage = states[id]?.status == .ready
                ? "Local model is verified and ready"
                : "Local model operation finished"
        } catch is CancellationError {
            await refresh()
            statusMessage = "Local model download cancelled; verified partial data can resume"
        } catch {
            await refresh()
            statusMessage = "Local model operation failed integrity or safety checks"
        }
    }

    private func apply(_ event: ModelInstallEvent, to id: String) {
        guard var state = states[id] else { return }
        switch event {
        case let .progress(completedBytes, totalBytes):
            state.completedBytes = max(state.completedBytes, completedBytes)
            state.totalBytes = totalBytes
        case let .status(status):
            state.status = status
        }
        states[id] = state
    }
}

private enum LocalModelSelfCheckProcessExecutor {
    static func run(assetID: String, root: URL, timeout: Duration) async throws {
        let executable = try helperExecutable()
        let process = Process()
        process.executableURL = executable
        process.arguments = [assetID, root.standardizedFileURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw LocalModelInstallationError.selfCheckUnavailable
        }
        let timeoutSeconds = max(
            0.1,
            Double(timeout.components.seconds)
                + Double(timeout.components.attoseconds) / 1_000_000_000_000_000_000
        )
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let deadline = Date().addingTimeInterval(timeoutSeconds)
                while process.isRunning, Date() < deadline {
                    usleep(20_000)
                }
                let timedOut = process.isRunning
                if timedOut {
                    kill(process.processIdentifier, SIGTERM)
                    let terminationDeadline = Date().addingTimeInterval(0.5)
                    while process.isRunning, Date() < terminationDeadline {
                        usleep(20_000)
                    }
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
                process.waitUntilExit()
                if timedOut {
                    continuation.resume(throwing: LocalModelInstallationError.selfCheckTimedOut)
                } else if process.terminationReason == .exit, process.terminationStatus == 0 {
                    continuation.resume(returning: ())
                } else {
                    continuation.resume(throwing: LocalModelInstallationError.selfCheckFailed)
                }
            }
        }
    }

    private static func helperExecutable() throws -> URL {
        let name = "MeetingVaultLocalModelSelfCheck"
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(name)"),
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent(name),
        ].compactMap { $0 }
        for candidate in candidates {
            guard let values = try? candidate.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  FileManager.default.isExecutableFile(atPath: candidate.path)
            else { continue }
            return candidate
        }
        throw LocalModelInstallationError.selfCheckUnavailable
    }
}

private actor LocalModelPrivacyAuditActor {
    private let writer: PrivacyAuditLogWriter
    private let logger = Logger(subsystem: "com.andrzej.MeetingVault", category: "LocalModelPrivacyAudit")

    init(logURL: URL) {
        writer = PrivacyAuditLogWriter(logURL: logURL)
    }

    func record(_ action: PrivacyAuditAction, metadata: [String: String]) {
        do {
            try writer.append(action: action, meetingID: nil, metadata: metadata)
        } catch {
            logger.error("Privacy audit append failed code=model_audit_write_failed")
        }
    }

    func append(_ action: PrivacyAuditAction, metadata: [String: String]) throws {
        try writer.append(action: action, meetingID: nil, metadata: metadata)
    }
}
