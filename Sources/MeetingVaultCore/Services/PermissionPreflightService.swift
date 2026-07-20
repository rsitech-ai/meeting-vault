import AVFoundation
import CoreGraphics
import Foundation
import Speech

public enum PermissionKind: String, Codable, Equatable, Sendable {
    case systemAudio
    case microphone
    case speechRecognition
}

public enum PermissionAuthorizationStatus: String, Codable, Equatable, Sendable {
    case authorized
    case denied
    case restricted
    case notDetermined
    case unknown

    public var isAuthorized: Bool {
        self == .authorized
    }
}

public struct PermissionSnapshot: Codable, Equatable, Sendable {
    public var systemAudio: PermissionAuthorizationStatus
    public var microphone: PermissionAuthorizationStatus
    public var speechRecognition: PermissionAuthorizationStatus

    public init(
        systemAudio: PermissionAuthorizationStatus,
        microphone: PermissionAuthorizationStatus,
        speechRecognition: PermissionAuthorizationStatus
    ) {
        self.systemAudio = systemAudio
        self.microphone = microphone
        self.speechRecognition = speechRecognition
    }
}

public struct PermissionRecoveryAction: Codable, Equatable, Sendable {
    public var kind: PermissionKind
    public var title: String
    public var message: String
    public var settingsURLString: String
    public var opensExternalSettingsAutomatically: Bool

    public init(
        kind: PermissionKind,
        title: String,
        message: String,
        settingsURLString: String,
        opensExternalSettingsAutomatically: Bool = false
    ) {
        self.kind = kind
        self.title = title
        self.message = message
        self.settingsURLString = settingsURLString
        self.opensExternalSettingsAutomatically = opensExternalSettingsAutomatically
    }
}

public struct PermissionPreflightResult: Equatable, Sendable {
    public var canRecord: Bool
    public var issues: [PreflightIssue]
    public var recoveryActions: [PermissionRecoveryAction]
    public var storageEstimate: RecordingStorageCapacityEstimate?

    public init(
        canRecord: Bool,
        issues: [PreflightIssue],
        recoveryActions: [PermissionRecoveryAction],
        storageEstimate: RecordingStorageCapacityEstimate? = nil
    ) {
        self.canRecord = canRecord
        self.issues = issues
        self.recoveryActions = recoveryActions
        self.storageEstimate = storageEstimate
    }
}

public struct RecordingStorageBudget: Equatable, Sendable {
    public static let productionLongRecording = RecordingStorageBudget(
        estimatedDurationSeconds: 3 * 60 * 60,
        trackCount: 2,
        bytesPerSecondPerTrack: 96_000,
        artifactReserveBytes: 1 * 1_024 * 1_024 * 1_024,
        safetyReserveBytes: CompliancePolicy.minimumFreeDiskBytes
    )

    public var estimatedDurationSeconds: TimeInterval
    public var trackCount: Int
    public var bytesPerSecondPerTrack: Int64
    public var artifactReserveBytes: Int64
    public var safetyReserveBytes: Int64

    public init(
        estimatedDurationSeconds: TimeInterval,
        trackCount: Int,
        bytesPerSecondPerTrack: Int64,
        artifactReserveBytes: Int64,
        safetyReserveBytes: Int64
    ) {
        self.estimatedDurationSeconds = estimatedDurationSeconds
        self.trackCount = trackCount
        self.bytesPerSecondPerTrack = bytesPerSecondPerTrack
        self.artifactReserveBytes = artifactReserveBytes
        self.safetyReserveBytes = safetyReserveBytes
    }

    public var estimatedRecordingBytes: Int64 {
        let duration = max(0, Int64(estimatedDurationSeconds.rounded(.up)))
        let tracks = max(1, Int64(trackCount))
        let bytesPerSecond = max(1, bytesPerSecondPerTrack)
        return duration * tracks * bytesPerSecond
    }

    public var requiredFreeDiskBytes: Int64 {
        estimatedRecordingBytes + artifactReserveBytes + safetyReserveBytes
    }
}

public struct RecordingStorageCapacityEstimate: Equatable, Sendable {
    public var availableBytes: Int64
    public var budget: RecordingStorageBudget

    public init(availableBytes: Int64, budget: RecordingStorageBudget) {
        self.availableBytes = availableBytes
        self.budget = budget
    }

    public var requiredFreeDiskBytes: Int64 {
        budget.requiredFreeDiskBytes
    }

    public var hasRequiredCapacity: Bool {
        availableBytes >= requiredFreeDiskBytes
    }
}

public protocol RecordingStorageCapacityChecking: Sendable {
    func availableCapacityBytes(for directoryURL: URL) throws -> Int64
}

public struct SystemRecordingStorageCapacityChecker: RecordingStorageCapacityChecking {
    public init() {}

    public func availableCapacityBytes(for directoryURL: URL) throws -> Int64 {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let values = try directoryURL.resourceValues(
            forKeys: [
                .volumeAvailableCapacityForImportantUsageKey,
                .volumeAvailableCapacityKey
            ]
        )
        if let importantCapacity = values.volumeAvailableCapacityForImportantUsage {
            return importantCapacity
        }
        if let capacity = values.volumeAvailableCapacity {
            return Int64(capacity)
        }
        return 0
    }
}

public protocol PermissionProviding: Sendable {
    func snapshot() async -> PermissionSnapshot
}

public protocol MicrophoneAuthorizationProviding: Sendable {
    func currentAuthorizationStatus() -> PermissionAuthorizationStatus
    func requestAuthorizationStatus() async -> PermissionAuthorizationStatus
}

public protocol SystemAudioAuthorizationProviding: Sendable {
    func currentAuthorizationStatus() async -> PermissionAuthorizationStatus
}

public final class MockPermissionProvider: PermissionProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var currentSnapshot: PermissionSnapshot
    private var reads = 0

    public init(snapshot: PermissionSnapshot) {
        self.currentSnapshot = snapshot
    }

    public var snapshotReadCount: Int {
        lock.withLock { reads }
    }

    public func update(snapshot: PermissionSnapshot) {
        lock.withLock {
            currentSnapshot = snapshot
        }
    }

    public func snapshot() async -> PermissionSnapshot {
        lock.withLock {
            reads += 1
            return currentSnapshot
        }
    }
}

public struct SystemMicrophoneAuthorizationProvider: MicrophoneAuthorizationProviding {
    public init() {}

    public func currentAuthorizationStatus() -> PermissionAuthorizationStatus {
        Self.map(AVCaptureDevice.authorizationStatus(for: .audio))
    }

    public func requestAuthorizationStatus() async -> PermissionAuthorizationStatus {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                continuation.resume(returning: Self.map(AVCaptureDevice.authorizationStatus(for: .audio)))
            }
        }
    }

    private static func map(_ status: AVAuthorizationStatus) -> PermissionAuthorizationStatus {
        switch status {
        case .authorized:
            .authorized
        case .denied:
            .denied
        case .restricted:
            .restricted
        case .notDetermined:
            .notDetermined
        @unknown default:
            .unknown
        }
    }
}

public struct SystemPermissionProvider: PermissionProviding {
    private let systemAudioAuthorizationProvider: any SystemAudioAuthorizationProviding

    public init(
        systemAudioAuthorizationProvider: any SystemAudioAuthorizationProviding = ScreenCaptureKitSystemAudioAuthorizationProvider()
    ) {
        self.systemAudioAuthorizationProvider = systemAudioAuthorizationProvider
    }

    public func snapshot() async -> PermissionSnapshot {
        let systemAudioStatus = await systemAudioAuthorizationProvider.currentAuthorizationStatus()
        return PermissionSnapshot(
            systemAudio: systemAudioStatus,
            microphone: mapMicrophoneStatus(AVCaptureDevice.authorizationStatus(for: .audio)),
            speechRecognition: mapSpeechStatus(SFSpeechRecognizer.authorizationStatus())
        )
    }

    private func mapMicrophoneStatus(_ status: AVAuthorizationStatus) -> PermissionAuthorizationStatus {
        switch status {
        case .authorized:
            .authorized
        case .denied:
            .denied
        case .restricted:
            .restricted
        case .notDetermined:
            .notDetermined
        @unknown default:
            .unknown
        }
    }

    private func mapSpeechStatus(_ status: SFSpeechRecognizerAuthorizationStatus) -> PermissionAuthorizationStatus {
        switch status {
        case .authorized:
            .authorized
        case .denied:
            .denied
        case .restricted:
            .restricted
        case .notDetermined:
            .notDetermined
        @unknown default:
            .unknown
        }
    }
}

public struct ScreenCaptureKitSystemAudioAuthorizationProvider: SystemAudioAuthorizationProviding {
    private let preflightAccess: @Sendable () -> Bool

    public init(
        preflightAccess: @escaping @Sendable () -> Bool = { CGPreflightScreenCaptureAccess() }
    ) {
        self.preflightAccess = preflightAccess
    }

    public func currentAuthorizationStatus() async -> PermissionAuthorizationStatus {
        preflightAccess() ? .authorized : .notDetermined
    }
}

public struct PermissionPreflightService: Sendable {
    private let permissionProvider: PermissionProviding
    private let storageCapacityChecker: any RecordingStorageCapacityChecking
    private let storageBudget: RecordingStorageBudget

    public init(
        permissionProvider: PermissionProviding,
        storageCapacityChecker: any RecordingStorageCapacityChecking = SystemRecordingStorageCapacityChecker(),
        storageBudget: RecordingStorageBudget = .productionLongRecording
    ) {
        self.permissionProvider = permissionProvider
        self.storageCapacityChecker = storageCapacityChecker
        self.storageBudget = storageBudget
    }

    public func evaluate(
        consentStatus: ConsentStatus,
        freeDiskBytes: Int64,
        requireConsentBeforeRecording: Bool,
        requireSystemAudioPermission: Bool = true,
        requireSpeechRecognitionPermission: Bool = true
    ) async -> PermissionPreflightResult {
        let snapshot = await permissionProvider.snapshot()
        let base = CompliancePolicy.evaluatePreflight(
            RecordingPreflightInput(
                consentStatus: consentStatus,
                hasAudioPermission: !requireSystemAudioPermission || snapshot.systemAudio.isAuthorized,
                hasMicrophonePermission: snapshot.microphone.isAuthorized,
                hasSpeechPermission: !requireSpeechRecognitionPermission || snapshot.speechRecognition.isAuthorized,
                freeDiskBytes: freeDiskBytes,
                requireConsentBeforeRecording: requireConsentBeforeRecording
            )
        )
        let actions = recoveryActions(for: snapshot, issues: base.issues)
        return PermissionPreflightResult(
            canRecord: base.canRecord,
            issues: base.issues,
            recoveryActions: actions
        )
    }

    public func evaluate(
        consentStatus: ConsentStatus,
        storageDirectoryURL: URL,
        requireConsentBeforeRecording: Bool,
        requireSystemAudioPermission: Bool = true,
        requireSpeechRecognitionPermission: Bool = true
    ) async -> PermissionPreflightResult {
        let freeDiskBytes = (try? storageCapacityChecker.availableCapacityBytes(for: storageDirectoryURL)) ?? 0
        let estimate = RecordingStorageCapacityEstimate(
            availableBytes: freeDiskBytes,
            budget: storageBudget
        )
        let snapshot = await permissionProvider.snapshot()
        let base = CompliancePolicy.evaluatePreflight(
            RecordingPreflightInput(
                consentStatus: consentStatus,
                hasAudioPermission: !requireSystemAudioPermission || snapshot.systemAudio.isAuthorized,
                hasMicrophonePermission: snapshot.microphone.isAuthorized,
                hasSpeechPermission: !requireSpeechRecognitionPermission || snapshot.speechRecognition.isAuthorized,
                freeDiskBytes: freeDiskBytes,
                requiredFreeDiskBytes: estimate.requiredFreeDiskBytes,
                requireConsentBeforeRecording: requireConsentBeforeRecording
            )
        )
        let actions = recoveryActions(for: snapshot, issues: base.issues)
        return PermissionPreflightResult(
            canRecord: base.canRecord,
            issues: base.issues,
            recoveryActions: actions,
            storageEstimate: estimate
        )
    }

    private func recoveryActions(
        for snapshot: PermissionSnapshot,
        issues: [PreflightIssue]
    ) -> [PermissionRecoveryAction] {
        issues.compactMap { issue in
            switch issue {
            case .audioPermissionMissing:
                PermissionRecoveryAction(
                    kind: .systemAudio,
                    title: "Allow Screen & System Audio Recording",
                    message: "Open System Settings and allow MeetingVault to record the selected screen and system audio source.",
                    settingsURLString: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
                )
            case .microphonePermissionMissing:
                PermissionRecoveryAction(
                    kind: .microphone,
                    title: "Allow Microphone",
                    message: "Open System Settings and allow MeetingVault microphone access for your separate local track.",
                    settingsURLString: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
                )
            case .speechPermissionMissing:
                PermissionRecoveryAction(
                    kind: .speechRecognition,
                    title: "Allow Speech Recognition",
                    message: "Open System Settings and allow Speech Recognition so MeetingVault can create transcripts.",
                    settingsURLString: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"
                )
            case .diskSpaceLow, .consentRequired, .doNotRecord:
                nil
            }
        }
    }
}
