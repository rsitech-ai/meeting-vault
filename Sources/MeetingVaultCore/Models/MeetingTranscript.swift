import Foundation

public struct MeetingTranscript: Codable, Equatable, Sendable {
    public static let finalTranscriptRelativePath = "transcript/final.json.enc"
    public static let finalTranscriptPurpose = "transcript:final"

    public var meetingID: UUID
    public var transcriptVersion: Int
    public var providerConfigurationVersion: String
    public var localeIdentifier: String?
    public var generatedAt: Date
    public var editedAt: Date?
    public var segments: [TranscriptSegment]

    public init(
        meetingID: UUID,
        transcriptVersion: Int = 0,
        providerConfigurationVersion: String = "legacy",
        localeIdentifier: String?,
        generatedAt: Date = Date(),
        editedAt: Date? = nil,
        segments: [TranscriptSegment]
    ) {
        self.meetingID = meetingID
        self.transcriptVersion = max(0, transcriptVersion)
        self.providerConfigurationVersion = providerConfigurationVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "legacy"
            : providerConfigurationVersion
        self.localeIdentifier = localeIdentifier
        self.generatedAt = generatedAt
        self.editedAt = editedAt
        self.segments = segments.sorted {
            if $0.startTime == $1.startTime {
                return $0.endTime < $1.endTime
            }
            return $0.startTime < $1.startTime
        }
    }

    private enum CodingKeys: String, CodingKey {
        case meetingID, transcriptVersion, providerConfigurationVersion
        case localeIdentifier, generatedAt, editedAt, segments
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            meetingID: try container.decode(UUID.self, forKey: .meetingID),
            transcriptVersion: try container.decodeIfPresent(Int.self, forKey: .transcriptVersion) ?? 0,
            providerConfigurationVersion: try container.decodeIfPresent(String.self, forKey: .providerConfigurationVersion) ?? "legacy",
            localeIdentifier: try container.decodeIfPresent(String.self, forKey: .localeIdentifier),
            generatedAt: try container.decode(Date.self, forKey: .generatedAt),
            editedAt: try container.decodeIfPresent(Date.self, forKey: .editedAt),
            segments: try container.decode([TranscriptSegment].self, forKey: .segments)
        )
    }
}

public struct FinalTranscriptionResult: Equatable, Sendable {
    public var transcript: MeetingTranscript
    public var indexedSegmentCount: Int

    public init(transcript: MeetingTranscript, indexedSegmentCount: Int) {
        self.transcript = transcript
        self.indexedSegmentCount = indexedSegmentCount
    }
}
