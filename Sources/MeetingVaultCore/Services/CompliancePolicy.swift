import Foundation

public struct RecordingPreflightInput: Equatable, Sendable {
    public var consentStatus: ConsentStatus
    public var hasAudioPermission: Bool
    public var hasMicrophonePermission: Bool
    public var hasSpeechPermission: Bool
    public var freeDiskBytes: Int64
    public var requiredFreeDiskBytes: Int64
    public var requireConsentBeforeRecording: Bool

    public init(
        consentStatus: ConsentStatus,
        hasAudioPermission: Bool,
        hasMicrophonePermission: Bool,
        hasSpeechPermission: Bool,
        freeDiskBytes: Int64,
        requiredFreeDiskBytes: Int64 = CompliancePolicy.minimumFreeDiskBytes,
        requireConsentBeforeRecording: Bool
    ) {
        self.consentStatus = consentStatus
        self.hasAudioPermission = hasAudioPermission
        self.hasMicrophonePermission = hasMicrophonePermission
        self.hasSpeechPermission = hasSpeechPermission
        self.freeDiskBytes = freeDiskBytes
        self.requiredFreeDiskBytes = requiredFreeDiskBytes
        self.requireConsentBeforeRecording = requireConsentBeforeRecording
    }
}

public enum PreflightIssue: String, Equatable, Sendable {
    case audioPermissionMissing
    case microphonePermissionMissing
    case speechPermissionMissing
    case diskSpaceLow
    case consentRequired
    case doNotRecord
}

public struct RecordingPreflightResult: Equatable, Sendable {
    public var canRecord: Bool
    public var issues: [PreflightIssue]
    public var storageEstimate: RecordingStorageCapacityEstimate?

    public init(
        canRecord: Bool,
        issues: [PreflightIssue],
        storageEstimate: RecordingStorageCapacityEstimate? = nil
    ) {
        self.canRecord = canRecord
        self.issues = issues
        self.storageEstimate = storageEstimate
    }
}

public enum CompliancePolicy {
    public static let minimumFreeDiskBytes: Int64 = 5 * 1_024 * 1_024 * 1_024

    public static func evaluatePreflight(_ input: RecordingPreflightInput) -> RecordingPreflightResult {
        var issues: [PreflightIssue] = []

        if !input.hasAudioPermission {
            issues.append(.audioPermissionMissing)
        }
        if !input.hasMicrophonePermission {
            issues.append(.microphonePermissionMissing)
        }
        if !input.hasSpeechPermission {
            issues.append(.speechPermissionMissing)
        }
        if input.freeDiskBytes < input.requiredFreeDiskBytes {
            issues.append(.diskSpaceLow)
        }
        if input.consentStatus == .doNotRecord {
            issues.append(.doNotRecord)
        } else if input.requireConsentBeforeRecording && input.consentStatus == .unknown {
            issues.append(.consentRequired)
        }

        return RecordingPreflightResult(canRecord: issues.isEmpty, issues: issues)
    }
}
