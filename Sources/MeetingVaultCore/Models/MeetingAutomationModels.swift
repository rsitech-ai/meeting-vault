import Foundation

public enum MeetingAutomationAction: String, Codable, CaseIterable, Hashable, Sendable {
    case openRecorder
    case runPreflight
    case startRecording
    case stopRecording
    case prepareShare
    case sendWebhook
}

public enum MeetingAutomationSurface: String, Codable, CaseIterable, Hashable, Sendable {
    case appIntent
    case shortcuts
    case menuBar
    case commandMenu
}

public enum MeetingAutomationApproval: String, Codable, CaseIterable, Hashable, Sendable {
    case notApproved
    case userConfirmed
    case externalApproved
}

public enum MeetingAutomationPlanStatus: String, Codable, Hashable, Sendable {
    case prepared
    case blocked
}

public enum MeetingAutomationDestination: String, Codable, Hashable, Sendable {
    case library
    case recorder
    case intelligence
    case diagnostics
    case automationReview
}

public enum MeetingAutomationSideEffect: String, Codable, Hashable, Sendable {
    case localStateChange
    case localFileWrite
    case externalNetwork
}

public enum MeetingAutomationBlocker: String, Codable, Hashable, Sendable {
    case externalApprovalRequired
    case blockedByLocalOnlyMode
    case missingMeetingID
    case missingSourceID
}

public struct MeetingAutomationRequest: Codable, Equatable, Sendable {
    public var action: MeetingAutomationAction
    public var surface: MeetingAutomationSurface
    public var meetingID: UUID?
    public var sourceID: String?
    public var localOnlyMode: Bool
    public var approval: MeetingAutomationApproval
    public var payloadPreview: String?

    public init(
        action: MeetingAutomationAction,
        surface: MeetingAutomationSurface,
        meetingID: UUID? = nil,
        sourceID: String? = nil,
        localOnlyMode: Bool,
        approval: MeetingAutomationApproval,
        payloadPreview: String? = nil
    ) {
        self.action = action
        self.surface = surface
        self.meetingID = meetingID
        self.sourceID = sourceID
        self.localOnlyMode = localOnlyMode
        self.approval = approval
        self.payloadPreview = payloadPreview
    }
}

public struct MeetingAutomationPlan: Codable, Equatable, Sendable {
    public var status: MeetingAutomationPlanStatus
    public var action: MeetingAutomationAction
    public var surface: MeetingAutomationSurface
    public var destination: MeetingAutomationDestination
    public var requiresPreflight: Bool
    public var requiresExternalApproval: Bool
    public var allowedSideEffects: [MeetingAutomationSideEffect]
    public var blockers: [MeetingAutomationBlocker]
    public var auditMetadata: [String: String]
    public var reviewSummary: String

    public init(
        status: MeetingAutomationPlanStatus,
        action: MeetingAutomationAction,
        surface: MeetingAutomationSurface,
        destination: MeetingAutomationDestination,
        requiresPreflight: Bool,
        requiresExternalApproval: Bool,
        allowedSideEffects: [MeetingAutomationSideEffect],
        blockers: [MeetingAutomationBlocker],
        auditMetadata: [String: String],
        reviewSummary: String
    ) {
        self.status = status
        self.action = action
        self.surface = surface
        self.destination = destination
        self.requiresPreflight = requiresPreflight
        self.requiresExternalApproval = requiresExternalApproval
        self.allowedSideEffects = allowedSideEffects
        self.blockers = blockers
        self.auditMetadata = auditMetadata
        self.reviewSummary = reviewSummary
    }
}

public struct MeetingAutomationShortcut: Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var systemImageName: String
    public var action: MeetingAutomationAction
    public var surface: MeetingAutomationSurface
    public var requiresMeetingSelection: Bool
    public var requiresSourceSelection: Bool
    public var phraseTemplates: [String]

    public init(
        id: String,
        title: String,
        systemImageName: String,
        action: MeetingAutomationAction,
        surface: MeetingAutomationSurface,
        requiresMeetingSelection: Bool,
        requiresSourceSelection: Bool,
        phraseTemplates: [String]
    ) {
        self.id = id
        self.title = title
        self.systemImageName = systemImageName
        self.action = action
        self.surface = surface
        self.requiresMeetingSelection = requiresMeetingSelection
        self.requiresSourceSelection = requiresSourceSelection
        self.phraseTemplates = phraseTemplates
    }

    public func request(
        meetingID: UUID? = nil,
        sourceID: String? = nil,
        localOnlyMode: Bool = true,
        approval: MeetingAutomationApproval = .userConfirmed
    ) -> MeetingAutomationRequest {
        MeetingAutomationRequest(
            action: action,
            surface: surface,
            meetingID: meetingID,
            sourceID: sourceID,
            localOnlyMode: localOnlyMode,
            approval: approval
        )
    }
}

public enum MeetingAutomationShortcutCatalog {
    public static let shortcuts: [MeetingAutomationShortcut] = [
        MeetingAutomationShortcut(
            id: "open-recorder",
            title: "Open Recorder",
            systemImageName: "waveform.circle",
            action: .openRecorder,
            surface: .appIntent,
            requiresMeetingSelection: false,
            requiresSourceSelection: false,
            phraseTemplates: [
                "Open Recorder in MeetingVault",
                "Show MeetingVault Recorder"
            ]
        ),
        MeetingAutomationShortcut(
            id: "run-preflight",
            title: "Check Recording Readiness",
            systemImageName: "checkmark.shield",
            action: .runPreflight,
            surface: .appIntent,
            requiresMeetingSelection: false,
            requiresSourceSelection: false,
            phraseTemplates: [
                "Check MeetingVault readiness",
                "Run MeetingVault preflight"
            ]
        ),
        MeetingAutomationShortcut(
            id: "start-recording",
            title: "Start Recording",
            systemImageName: "record.circle",
            action: .startRecording,
            surface: .appIntent,
            requiresMeetingSelection: false,
            requiresSourceSelection: true,
            phraseTemplates: [
                "Start recording in MeetingVault",
                "Begin MeetingVault recording"
            ]
        ),
        MeetingAutomationShortcut(
            id: "stop-recording",
            title: "Stop Recording",
            systemImageName: "stop.circle",
            action: .stopRecording,
            surface: .appIntent,
            requiresMeetingSelection: false,
            requiresSourceSelection: false,
            phraseTemplates: [
                "Stop recording in MeetingVault",
                "Finish MeetingVault recording"
            ]
        ),
        MeetingAutomationShortcut(
            id: "prepare-share",
            title: "Prepare Local Share",
            systemImageName: "square.and.arrow.up",
            action: .prepareShare,
            surface: .appIntent,
            requiresMeetingSelection: true,
            requiresSourceSelection: false,
            phraseTemplates: [
                "Prepare MeetingVault share",
                "Prepare local share in MeetingVault"
            ]
        )
    ]
}
