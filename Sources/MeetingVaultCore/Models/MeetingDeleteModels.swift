import Foundation

public enum MeetingDeleteReason: String, Codable, Sendable {
    case userRequested
    case privacyRequest
}

public struct MeetingDeleteResult: Codable, Equatable, Sendable {
    public var meetingID: UUID
    public var reason: MeetingDeleteReason

    public init(meetingID: UUID, reason: MeetingDeleteReason) {
        self.meetingID = meetingID
        self.reason = reason
    }
}
