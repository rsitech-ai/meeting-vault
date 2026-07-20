import Foundation

public enum MeetingShareDestination: String, Codable, CaseIterable, Hashable, Sendable {
    case systemShareSheet
    case finderReveal
    case manualCopy
}

public struct MeetingShareFile: Codable, Equatable, Sendable {
    public var format: MeetingExportFormat
    public var url: URL

    public init(format: MeetingExportFormat, url: URL) {
        self.format = format
        self.url = url
    }
}

public struct MeetingShareManifest: Codable, Equatable, Sendable {
    public var meetingID: UUID
    public var transcriptVersion: Int
    public var transcriptDigest: String
    public var destination: MeetingShareDestination
    public var files: [MeetingShareFile]
    public var requiresUserConfirmation: Bool

    public init(
        meetingID: UUID,
        transcriptVersion: Int = 0,
        transcriptDigest: String = "legacy",
        destination: MeetingShareDestination,
        files: [MeetingShareFile],
        requiresUserConfirmation: Bool = true
    ) {
        self.meetingID = meetingID
        self.transcriptVersion = max(0, transcriptVersion)
        self.transcriptDigest = transcriptDigest
        self.destination = destination
        self.files = files
        self.requiresUserConfirmation = requiresUserConfirmation
    }
}
