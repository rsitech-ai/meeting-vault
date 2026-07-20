import Foundation

public struct PrivacyAuditReviewRow: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var occurredAt: Date
    public var action: PrivacyAuditAction
    public var meetingID: UUID?
    public var metadata: [String: String]

    public init(
        id: UUID,
        occurredAt: Date,
        action: PrivacyAuditAction,
        meetingID: UUID?,
        metadata: [String: String]
    ) {
        self.id = id
        self.occurredAt = occurredAt
        self.action = action
        self.meetingID = meetingID
        self.metadata = metadata
    }

    public var displaySummary: String {
        let meeting = meetingID?.uuidString ?? "none"
        let metadataText = metadata
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        return [action.rawValue, "meeting=\(meeting)", metadataText]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

public struct PrivacyAuditReview: Codable, Equatable, Sendable {
    public var rows: [PrivacyAuditReviewRow]
    public var counts: [PrivacyAuditAction: Int]
    public var latestOccurredAt: Date?

    public init(rows: [PrivacyAuditReviewRow], counts: [PrivacyAuditAction: Int], latestOccurredAt: Date?) {
        self.rows = rows
        self.counts = counts
        self.latestOccurredAt = latestOccurredAt
    }
}
