import Foundation

public enum RetentionCleanupError: Error, Equatable {
    case invalidRetentionDays(Int)
}

public struct RetentionCleanupService {
    private let bundleStore: EncryptedMeetingBundleStore
    private let auditWriter: PrivacyAuditLogWriter?
    private let searchIndex: SQLiteSearchIndex?

    public init(
        bundleStore: EncryptedMeetingBundleStore,
        auditWriter: PrivacyAuditLogWriter? = nil,
        searchIndex: SQLiteSearchIndex? = nil
    ) {
        self.bundleStore = bundleStore
        self.auditWriter = auditWriter
        self.searchIndex = searchIndex
    }

    public func planCleanup(policy: RetentionPolicy, now: Date = Date()) throws -> RetentionCleanupPlan {
        guard policy.retentionDays > 0 else {
            throw RetentionCleanupError.invalidRetentionDays(policy.retentionDays)
        }

        let candidates = try bundleStore.listMeetingBundleIDs().compactMap { meetingID -> RetentionCleanupCandidate? in
            let manifest = try bundleStore.readManifest(meetingID: meetingID)
            let ageDays = max(0, Int(now.timeIntervalSince(manifest.createdAt) / 86_400))
            guard ageDays >= policy.retentionDays else {
                return nil
            }
            return RetentionCleanupCandidate(
                meetingID: meetingID,
                title: manifest.title,
                createdAt: manifest.createdAt,
                ageDays: ageDays
            )
        }
        .sorted {
            if $0.createdAt == $1.createdAt {
                return $0.meetingID.uuidString < $1.meetingID.uuidString
            }
            return $0.createdAt < $1.createdAt
        }

        return RetentionCleanupPlan(policy: policy, generatedAt: now, candidates: candidates)
    }

    public func apply(_ plan: RetentionCleanupPlan) throws -> RetentionCleanupResult {
        var deleted: [UUID] = []
        for candidate in plan.candidates {
            try auditWriter?.append(
                action: .retentionDelete,
                meetingID: candidate.meetingID,
                metadata: [
                    "retentionDays": "\(plan.policy.retentionDays)",
                    "ageDays": "\(candidate.ageDays)"
                ]
            )
            try searchIndex?.deleteMeeting(id: candidate.meetingID)
            try bundleStore.deleteBundle(meetingID: candidate.meetingID)
            deleted.append(candidate.meetingID)
        }
        return RetentionCleanupResult(deletedMeetingIDs: deleted)
    }
}
