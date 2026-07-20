import Foundation

public struct TranscriptQuestionHistory: Codable, Equatable, Sendable {
    public static let relativePath = "transcript/question-history.json.enc"
    public static let purpose = "transcript:question-history"

    public var meetingID: UUID
    public var transcriptVersion: Int
    public var transcriptDigest: String
    public var invalidatedAt: Date?
    public var turns: [TranscriptQuestionTurn]

    public init(
        meetingID: UUID,
        transcriptVersion: Int = 0,
        transcriptDigest: String = "legacy",
        invalidatedAt: Date? = nil,
        turns: [TranscriptQuestionTurn] = []
    ) {
        self.meetingID = meetingID
        self.transcriptVersion = max(0, transcriptVersion)
        self.transcriptDigest = transcriptDigest
        self.invalidatedAt = invalidatedAt
        self.turns = turns.sorted {
            if $0.createdAt == $1.createdAt {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.createdAt > $1.createdAt
        }
    }

    private enum CodingKeys: String, CodingKey {
        case meetingID, transcriptVersion, transcriptDigest, invalidatedAt, turns
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            meetingID: try container.decode(UUID.self, forKey: .meetingID),
            transcriptVersion: try container.decodeIfPresent(Int.self, forKey: .transcriptVersion) ?? 0,
            transcriptDigest: try container.decodeIfPresent(String.self, forKey: .transcriptDigest) ?? "legacy",
            invalidatedAt: try container.decodeIfPresent(Date.self, forKey: .invalidatedAt),
            turns: try container.decode([TranscriptQuestionTurn].self, forKey: .turns)
        )
    }
}

public struct TranscriptQuestionTurn: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var question: String
    public var answerDraft: String
    public var evidence: [TranscriptQuestionEvidence]

    public init(
        id: UUID = UUID(),
        createdAt: Date,
        question: String,
        answerDraft: String,
        evidence: [TranscriptQuestionEvidence]
    ) {
        self.id = id
        self.createdAt = createdAt
        self.question = question
        self.answerDraft = answerDraft
        self.evidence = evidence
    }
}
