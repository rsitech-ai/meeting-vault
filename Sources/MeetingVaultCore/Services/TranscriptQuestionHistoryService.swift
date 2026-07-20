import Foundation

public struct TranscriptQuestionHistoryService {
    private let bundleStore: EncryptedMeetingBundleStore
    private let maximumTurnCount: Int

    public init(
        bundleStore: EncryptedMeetingBundleStore,
        maximumTurnCount: Int = 50
    ) {
        self.bundleStore = bundleStore
        self.maximumTurnCount = maximumTurnCount
    }

    public func load(meetingID: UUID) throws -> TranscriptQuestionHistory {
        let historyURL = bundleStore.bundleURL(for: meetingID)
            .appendingPathComponent(TranscriptQuestionHistory.relativePath)
        guard FileManager.default.fileExists(atPath: historyURL.path) else {
            return TranscriptQuestionHistory(meetingID: meetingID)
        }
        return try bundleStore.readJSONArtifact(
            TranscriptQuestionHistory.self,
            meetingID: meetingID,
            relativePath: TranscriptQuestionHistory.relativePath,
            purpose: TranscriptQuestionHistory.purpose
        )
    }

    @discardableResult
    public func save(_ history: TranscriptQuestionHistory) throws -> TranscriptQuestionHistory {
        let trimmed = TranscriptQuestionHistory(
            meetingID: history.meetingID,
            transcriptVersion: history.transcriptVersion,
            transcriptDigest: history.transcriptDigest,
            invalidatedAt: history.invalidatedAt,
            turns: Array(history.turns.prefix(maximumTurnCount))
        )
        try bundleStore.writeJSONArtifact(
            trimmed,
            meetingID: trimmed.meetingID,
            relativePath: TranscriptQuestionHistory.relativePath,
            purpose: TranscriptQuestionHistory.purpose
        )
        return trimmed
    }

    @discardableResult
    public func record(
        answer: TranscriptQuestionAnswer,
        createdAt: Date = Date()
    ) throws -> TranscriptQuestionHistory {
        var history = try load(meetingID: answer.meetingID)
        if !history.turns.isEmpty,
           (history.transcriptVersion != answer.transcriptVersion
            || (history.transcriptDigest != answer.transcriptDigest
                && history.transcriptDigest != "legacy")) {
            throw TranscriptQuestionAnsweringError.transcriptVersionMismatch
        }
        history.transcriptVersion = answer.transcriptVersion
        history.transcriptDigest = answer.transcriptDigest
        history.invalidatedAt = nil
        history.turns.insert(
            TranscriptQuestionTurn(
                createdAt: createdAt,
                question: answer.question,
                answerDraft: answer.editableText,
                evidence: answer.evidence
            ),
            at: 0
        )
        return try save(history)
    }

    @discardableResult
    public func updateLatestAnswerDraft(
        meetingID: UUID,
        answerDraft: String
    ) throws -> TranscriptQuestionHistory {
        var history = try load(meetingID: meetingID)
        guard !history.turns.isEmpty else {
            return history
        }
        history.turns[0].answerDraft = answerDraft
        return try save(history)
    }
}
