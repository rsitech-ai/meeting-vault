import Foundation

public struct RetentionPolicy: Codable, Equatable, Sendable {
    public var retentionDays: Int

    public init(retentionDays: Int) {
        self.retentionDays = retentionDays
    }
}

public struct RetentionCleanupCandidate: Codable, Equatable, Sendable {
    public var meetingID: UUID
    public var title: String
    public var createdAt: Date
    public var ageDays: Int

    public init(meetingID: UUID, title: String, createdAt: Date, ageDays: Int) {
        self.meetingID = meetingID
        self.title = title
        self.createdAt = createdAt
        self.ageDays = ageDays
    }
}

public struct RetentionCleanupPlan: Codable, Equatable, Sendable {
    public var policy: RetentionPolicy
    public var generatedAt: Date
    public var candidates: [RetentionCleanupCandidate]

    public init(policy: RetentionPolicy, generatedAt: Date, candidates: [RetentionCleanupCandidate]) {
        self.policy = policy
        self.generatedAt = generatedAt
        self.candidates = candidates
    }
}

public struct RetentionCleanupResult: Codable, Equatable, Sendable {
    public var deletedMeetingIDs: [UUID]

    public init(deletedMeetingIDs: [UUID]) {
        self.deletedMeetingIDs = deletedMeetingIDs
    }
}
