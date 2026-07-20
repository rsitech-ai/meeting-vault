import Foundation

public struct MeetingDeleteService {
    private let bundleStore: EncryptedMeetingBundleStore
    private let auditWriter: PrivacyAuditLogWriter
    private let searchIndex: SQLiteSearchIndex?

    public init(
        bundleStore: EncryptedMeetingBundleStore,
        auditWriter: PrivacyAuditLogWriter,
        searchIndex: SQLiteSearchIndex? = nil
    ) {
        self.bundleStore = bundleStore
        self.auditWriter = auditWriter
        self.searchIndex = searchIndex
    }

    public func deleteMeeting(
        meetingID: UUID,
        reason: MeetingDeleteReason
    ) throws -> MeetingDeleteResult {
        _ = try bundleStore.readManifest(meetingID: meetingID)
        try auditWriter.append(
            action: .meetingDelete,
            meetingID: meetingID,
            metadata: ["reason": reason.rawValue]
        )
        try searchIndex?.deleteMeeting(id: meetingID)
        try bundleStore.deleteBundle(meetingID: meetingID)
        return MeetingDeleteResult(meetingID: meetingID, reason: reason)
    }
}
