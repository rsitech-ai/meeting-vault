import Foundation

public struct MeetingIntelligenceArtifact: Codable, Equatable, Sendable {
    public static let summaryRelativePath = "ai/summary.json.enc"
    public static let summaryPurpose = "ai:summary"

    public var meetingID: UUID
    public var transcriptVersion: Int
    public var transcriptDigest: String
    public var providerID: String
    public var generatedAt: Date
    public var summary: MeetingSummary

    public init(
        meetingID: UUID,
        transcriptVersion: Int = 0,
        transcriptDigest: String = "legacy",
        providerID: String,
        generatedAt: Date = Date(),
        summary: MeetingSummary
    ) {
        self.meetingID = meetingID
        self.transcriptVersion = max(0, transcriptVersion)
        self.transcriptDigest = transcriptDigest
        self.providerID = providerID
        self.generatedAt = generatedAt
        self.summary = summary
    }

    private enum CodingKeys: String, CodingKey {
        case meetingID, transcriptVersion, transcriptDigest, providerID, generatedAt, summary
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            meetingID: try container.decode(UUID.self, forKey: .meetingID),
            transcriptVersion: try container.decodeIfPresent(Int.self, forKey: .transcriptVersion) ?? 0,
            transcriptDigest: try container.decodeIfPresent(String.self, forKey: .transcriptDigest) ?? "legacy",
            providerID: try container.decode(String.self, forKey: .providerID),
            generatedAt: try container.decode(Date.self, forKey: .generatedAt),
            summary: try container.decode(MeetingSummary.self, forKey: .summary)
        )
    }
}
