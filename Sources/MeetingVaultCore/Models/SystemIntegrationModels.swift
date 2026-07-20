import Foundation

public enum MeetingSystemIntegrationKind: String, Codable, CaseIterable, Hashable, Sendable {
    case calendarEvent
    case reminder
    case contactReview

    public var displayTitle: String {
        switch self {
        case .calendarEvent:
            "Calendar"
        case .reminder:
            "Reminder"
        case .contactReview:
            "Contacts"
        }
    }

    public var systemImageName: String {
        switch self {
        case .calendarEvent:
            "calendar.badge.plus"
        case .reminder:
            "checklist"
        case .contactReview:
            "person.crop.circle.badge.questionmark"
        }
    }
}

public enum MeetingSystemIntegrationExecutionMode: String, Codable, Hashable, Sendable {
    case reviewOnly
    case readyForConfirmedWrite
}

public enum MeetingSystemIntegrationExecutionError: Error, Equatable, LocalizedError, Sendable {
    case noPreparedReview
    case confirmationRequired
    case executorUnavailable
    case calendarPermissionRequired
    case remindersPermissionRequired
    case contactsPermissionRequired
    case missingCalendarSchedule
    case missingContactName

    public var errorDescription: String? {
        switch self {
        case .noPreparedReview:
            "Prepare Calendar, Contacts, and Reminders proposals before confirming a system handoff."
        case .confirmationRequired:
            "System handoff needs explicit confirmation before writing to Calendar, Contacts, or Reminders."
        case .executorUnavailable:
            "System write adapters are unavailable in this build. Review the proposals locally or configure an approved executor."
        case .calendarPermissionRequired:
            "Allow MeetingVault to access Calendar before confirming Calendar handoff."
        case .remindersPermissionRequired:
            "Allow MeetingVault to access Reminders before confirming Reminder handoff."
        case .contactsPermissionRequired:
            "Allow MeetingVault to access Contacts before confirming Contacts handoff."
        case .missingCalendarSchedule:
            "Calendar handoff needs a scheduled date before it can be written."
        case .missingContactName:
            "Contacts handoff needs a reviewed contact name before it can be written."
        }
    }
}

public struct MeetingSystemIntegrationProposal: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var kind: MeetingSystemIntegrationKind
    public var meetingID: UUID
    public var sourceActionItemID: UUID
    public var title: String
    public var note: String
    public var ownerName: String?
    public var scheduledAt: Date?
    public var evidence: [EvidenceRef]
    public var executionMode: MeetingSystemIntegrationExecutionMode
    public var requiresUserConfirmation: Bool

    public init(
        id: UUID = UUID(),
        kind: MeetingSystemIntegrationKind,
        meetingID: UUID,
        sourceActionItemID: UUID,
        title: String,
        note: String,
        ownerName: String?,
        scheduledAt: Date?,
        evidence: [EvidenceRef],
        executionMode: MeetingSystemIntegrationExecutionMode = .reviewOnly,
        requiresUserConfirmation: Bool = true
    ) {
        self.id = id
        self.kind = kind
        self.meetingID = meetingID
        self.sourceActionItemID = sourceActionItemID
        self.title = title
        self.note = note
        self.ownerName = ownerName
        self.scheduledAt = scheduledAt
        self.evidence = evidence
        self.executionMode = executionMode
        self.requiresUserConfirmation = requiresUserConfirmation
    }
}

public struct MeetingSystemIntegrationReview: Codable, Equatable, Sendable {
    public var meetingID: UUID
    public var generatedAt: Date
    public var proposals: [MeetingSystemIntegrationProposal]
    public var externalWritePrepared: Bool
    public var auditMetadata: [String: String]
    public var reviewSummary: String

    public init(
        meetingID: UUID,
        generatedAt: Date,
        proposals: [MeetingSystemIntegrationProposal],
        externalWritePrepared: Bool,
        auditMetadata: [String: String],
        reviewSummary: String
    ) {
        self.meetingID = meetingID
        self.generatedAt = generatedAt
        self.proposals = proposals
        self.externalWritePrepared = externalWritePrepared
        self.auditMetadata = auditMetadata
        self.reviewSummary = reviewSummary
    }
}

public struct MeetingSystemIntegrationWriteReceipt: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var proposalID: UUID
    public var kind: MeetingSystemIntegrationKind
    public var executedAt: Date

    public init(
        id: UUID = UUID(),
        proposalID: UUID,
        kind: MeetingSystemIntegrationKind,
        executedAt: Date
    ) {
        self.id = id
        self.proposalID = proposalID
        self.kind = kind
        self.executedAt = executedAt
    }
}

public struct MeetingSystemIntegrationPartialWriteError: Error, LocalizedError, Sendable {
    public var meetingID: UUID
    public var failedProposalID: UUID
    public var executedAt: Date
    public var receipts: [MeetingSystemIntegrationWriteReceipt]
    public var failureMessage: String

    public init(
        meetingID: UUID,
        failedProposalID: UUID,
        executedAt: Date,
        receipts: [MeetingSystemIntegrationWriteReceipt],
        failureMessage: String
    ) {
        self.meetingID = meetingID
        self.failedProposalID = failedProposalID
        self.executedAt = executedAt
        self.receipts = receipts
        self.failureMessage = failureMessage
    }

    public var errorDescription: String? {
        "\(receipts.count) system write(s) completed before proposal \(failedProposalID.uuidString) failed: \(failureMessage)"
    }
}

public struct MeetingSystemIntegrationExecutionResult: Codable, Equatable, Sendable {
    public var meetingID: UUID
    public var executedAt: Date
    public var receipts: [MeetingSystemIntegrationWriteReceipt]
    public var externalWriteExecuted: Bool
    public var auditMetadata: [String: String]
    public var statusSummary: String

    public init(
        meetingID: UUID,
        executedAt: Date,
        receipts: [MeetingSystemIntegrationWriteReceipt],
        externalWriteExecuted: Bool,
        auditMetadata: [String: String],
        statusSummary: String
    ) {
        self.meetingID = meetingID
        self.executedAt = executedAt
        self.receipts = receipts
        self.externalWriteExecuted = externalWriteExecuted
        self.auditMetadata = auditMetadata
        self.statusSummary = statusSummary
    }
}
