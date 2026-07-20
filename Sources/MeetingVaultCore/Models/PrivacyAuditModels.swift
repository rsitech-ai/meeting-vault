import Foundation

public enum PrivacyAuditAction: String, Codable, CaseIterable, Sendable {
    case retentionDelete = "retention.delete"
    case exportPackage = "export.package"
    case meetingDelete = "meeting.delete"
    case sharePrepare = "share.prepare"
    case systemIntegrationPrepare = "system.integration.prepare"
    case systemIntegrationConfirm = "system.integration.confirm"
    case transcriptEdit = "transcript.edit"
    case modelInstall = "modelInstall"
    case modelRepair = "modelRepair"
    case modelPrewarm = "modelPrewarm"
    case modelRemove = "modelRemove"
    case privacyModeChange = "privacyModeChange"
}

public struct PrivacyAuditEvent: Codable, Equatable, Sendable {
    public var id: UUID
    public var occurredAt: Date
    public var action: PrivacyAuditAction
    public var meetingID: UUID?
    public var metadata: [String: String]

    public init(
        id: UUID = UUID(),
        occurredAt: Date,
        action: PrivacyAuditAction,
        meetingID: UUID?,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.occurredAt = occurredAt
        self.action = action
        self.meetingID = meetingID
        self.metadata = metadata
    }
}
