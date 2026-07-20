import Foundation

public enum TranscriptionPrivacyMode: String, Codable, CaseIterable, Sendable {
    case localOnly
    case appleOnDeviceOnly
    case appleMayUseNetwork

    /// Compatibility spelling retained only for source callers from the first Task 8 cut.
    public static let appleOnDeviceCompatible = TranscriptionPrivacyMode.appleOnDeviceOnly

    public var displayTitle: String {
        switch self {
        case .localOnly: "Local only"
        case .appleOnDeviceOnly: "Apple on-device only"
        case .appleMayUseNetwork: "Apple compatibility — may use network"
        }
    }

    public var networkTruth: String {
        switch self {
        case .localOnly: "Transcription inference stays on this Mac."
        case .appleOnDeviceOnly: "Uses Apple Speech only when on-device recognition is available."
        case .appleMayUseNetwork: "Apple Speech may process audio on Apple servers when on-device recognition is unavailable."
        }
    }
}

public enum TranscriptionPrivacyBoundaryError: Error, Equatable, LocalizedError, Sendable {
    case localProviderUnavailable
    case onDeviceRecognitionRequired

    public var errorDescription: String? {
        switch self {
        case .localProviderUnavailable:
            "Local transcription is unavailable: local models and provider integration are required."
        case .onDeviceRecognitionRequired:
            "Apple Speech on-device recognition is unavailable; network fallback is disabled."
        }
    }
}

public struct AppleSpeechPrivacyPolicy: Equatable, Sendable {
    public let requiresOnDeviceRecognition: Bool

    public init(requiresOnDeviceRecognition: Bool) {
        self.requiresOnDeviceRecognition = requiresOnDeviceRecognition
    }
}

/// One runtime gate shared by all transcription entry points.  It decides before an
/// Apple request, input tap, or provider adapter is constructed.
public actor TranscriptionPrivacyBoundary {
    private var currentMode: TranscriptionPrivacyMode
    private let modeStore: TranscriptionPrivacyModeStore?

    public init(mode: TranscriptionPrivacyMode) {
        currentMode = mode
        modeStore = nil
    }

    public init(modeStore: TranscriptionPrivacyModeStore) {
        currentMode = modeStore.mode
        self.modeStore = modeStore
    }

    public func mode() -> TranscriptionPrivacyMode {
        modeStore?.mode ?? currentMode
    }

    public func appleSpeechPolicy() throws -> AppleSpeechPrivacyPolicy {
        switch modeStore?.mode ?? currentMode {
        case .localOnly:
            throw TranscriptionPrivacyBoundaryError.localProviderUnavailable
        case .appleOnDeviceOnly:
            return AppleSpeechPrivacyPolicy(requiresOnDeviceRecognition: true)
        case .appleMayUseNetwork:
            return AppleSpeechPrivacyPolicy(requiresOnDeviceRecognition: false)
        }
    }

    public func replaceMode(_ mode: TranscriptionPrivacyMode) {
        currentMode = mode
    }
}

public enum TranscriptionPrivacyModeError: Error, Equatable, Sendable {
    case networkConfirmationRequired
}

public enum TranscriptionPrivacyModeTransitionError: Error, Equatable, Sendable {
    case recordingActive
    case auditFailed
    case restartFailed
}

public actor TranscriptionRuntimeActivityGate {
    private enum TransitionPhase { case pending, committing }
    private var recordingToken: UUID?
    private var transition: (UUID, TransitionPhase)?

    public init() {}

    public func beginRecordingActivity() throws -> TranscriptionRecordingActivityLease {
        if transition?.1 == .committing || recordingToken != nil {
            throw TranscriptionPrivacyModeTransitionError.recordingActive
        }
        let token = UUID()
        recordingToken = token
        return TranscriptionRecordingActivityLease(gate: self, token: token)
    }

    func beginPrivacyTransition() throws -> UUID {
        guard recordingToken == nil, transition == nil else {
            throw TranscriptionPrivacyModeTransitionError.recordingActive
        }
        let token = UUID()
        transition = (token, .pending)
        return token
    }

    func authorizePrivacyCommit(_ token: UUID) throws {
        guard recordingToken == nil,
              transition?.0 == token,
              transition?.1 == .pending else {
            throw TranscriptionPrivacyModeTransitionError.recordingActive
        }
        transition = (token, .committing)
    }

    func finishPrivacyTransition(_ token: UUID) {
        if transition?.0 == token { transition = nil }
    }

    fileprivate func finishRecordingActivity(_ token: UUID) {
        if recordingToken == token { recordingToken = nil }
    }
}

public final class TranscriptionRecordingActivityLease: @unchecked Sendable {
    private let lock = NSLock()
    private let gate: TranscriptionRuntimeActivityGate
    private let token: UUID
    private var active = true

    fileprivate init(gate: TranscriptionRuntimeActivityGate, token: UUID) {
        self.gate = gate
        self.token = token
    }

    public func release() async {
        let shouldRelease = lock.withLock { () -> Bool in
            guard active else { return false }
            active = false
            return true
        }
        if shouldRelease { await gate.finishRecordingActivity(token) }
    }

    deinit {
        let shouldRelease = lock.withLock { () -> Bool in
            guard active else { return false }
            active = false
            return true
        }
        if shouldRelease {
            let gate = gate
            let token = token
            Task { await gate.finishRecordingActivity(token) }
        }
    }
}

public actor TranscriptionPrivacyModeTransitionCoordinator {
    public typealias Audit = @Sendable (PrivacyAuditAction, [String: String]) async throws -> Void
    public typealias Restart = @Sendable () async throws -> Void

    private let preferences: TranscriptionPrivacyModeStore
    private let boundary: TranscriptionPrivacyBoundary
    private let activityGate: TranscriptionRuntimeActivityGate?
    private let audit: Audit

    public init(
        preferences: TranscriptionPrivacyModeStore,
        boundary: TranscriptionPrivacyBoundary,
        activityGate: TranscriptionRuntimeActivityGate? = nil,
        audit: @escaping Audit
    ) {
        self.preferences = preferences
        self.boundary = boundary
        self.activityGate = activityGate
        self.audit = audit
    }

    public func apply(
        _ next: TranscriptionPrivacyMode,
        confirmsNetworkUse: Bool = false,
        recordingIsActive: Bool,
        restartProvider: @escaping Restart
    ) async throws {
        guard !recordingIsActive else { throw TranscriptionPrivacyModeTransitionError.recordingActive }
        if next == .appleMayUseNetwork, !confirmsNetworkUse {
            throw TranscriptionPrivacyModeError.networkConfirmationRequired
        }
        let previous = preferences.mode
        guard previous != next else { return }
        let transitionToken = try await activityGate?.beginPrivacyTransition()
        do {
            try await applyTransition(
                next,
                previous: previous,
                transitionToken: transitionToken,
                restartProvider: restartProvider
            )
            if let transitionToken { await activityGate?.finishPrivacyTransition(transitionToken) }
        } catch {
            if let transitionToken { await activityGate?.finishPrivacyTransition(transitionToken) }
            throw error
        }
    }

    private func applyTransition(
        _ next: TranscriptionPrivacyMode,
        previous: TranscriptionPrivacyMode,
        transitionToken: UUID?,
        restartProvider: @escaping Restart
    ) async throws {
        let metadata = ["mode": next.rawValue]
        do {
            try await audit(.privacyModeChange, metadata.merging(["code": "pending"]) { $1 })
        } catch {
            throw TranscriptionPrivacyModeTransitionError.auditFailed
        }
        if let transitionToken {
            try await activityGate?.authorizePrivacyCommit(transitionToken)
        }
        preferences.persistMode(next)
        await boundary.replaceMode(next)
        do {
            try await restartProvider()
        } catch {
            preferences.persistMode(previous)
            await boundary.replaceMode(previous)
            try? await restartProvider()
            throw TranscriptionPrivacyModeTransitionError.restartFailed
        }
        do {
            try await audit(.privacyModeChange, metadata.merging(["code": "committed"]) { $1 })
        } catch {
            preferences.persistMode(previous)
            await boundary.replaceMode(previous)
            do {
                try await restartProvider()
            } catch {
                throw TranscriptionPrivacyModeTransitionError.restartFailed
            }
            throw TranscriptionPrivacyModeTransitionError.auditFailed
        }
    }
}

extension TranscriptionPrivacyModeError: LocalizedError {
    public var errorDescription: String? {
        "Confirm that Apple Speech may use the network before selecting this compatibility mode."
    }
}

public final class TranscriptionPrivacyModeStore: @unchecked Sendable {
    public static let defaultsKey = "MeetingVault.transcriptionPrivacyMode"
    public typealias Audit = @Sendable (PrivacyAuditAction, [String: String]) -> Void

    private let lock = NSLock()
    private let userDefaults: UserDefaults
    private let audit: Audit

    public init(
        userDefaults: UserDefaults = .standard,
        audit: @escaping Audit = { _, _ in }
    ) {
        self.userDefaults = userDefaults
        self.audit = audit
    }

    public var mode: TranscriptionPrivacyMode {
        lock.withLock {
            guard let raw = userDefaults.string(forKey: Self.defaultsKey),
                  let stored = TranscriptionPrivacyMode(rawValue: raw)
                    ?? (raw == "appleOnDeviceCompatible" ? .appleOnDeviceOnly : nil) else {
                return .localOnly
            }
            return stored
        }
    }

    public func setMode(
        _ mode: TranscriptionPrivacyMode,
        confirmsNetworkUse: Bool = false
    ) throws {
        if mode == .appleMayUseNetwork, !confirmsNetworkUse {
            throw TranscriptionPrivacyModeError.networkConfirmationRequired
        }
        lock.withLock {
            userDefaults.set(mode.rawValue, forKey: Self.defaultsKey)
        }
        audit(.privacyModeChange, ["mode": mode.rawValue, "code": "selected"])
    }

    func persistMode(_ mode: TranscriptionPrivacyMode) {
        lock.withLock { userDefaults.set(mode.rawValue, forKey: Self.defaultsKey) }
    }
}
