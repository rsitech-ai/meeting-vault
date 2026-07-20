import Foundation

public enum TranscriptQuestionAnsweringError: Error, Equatable {
    case blankQuestion
    case transcriptVersionMismatch
}

public struct TranscriptQuestionEvidence: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var segmentID: UUID
    public var speakerName: String
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    public var quote: String

    public init(
        id: UUID = UUID(),
        segmentID: UUID,
        speakerName: String,
        startTime: TimeInterval,
        endTime: TimeInterval,
        quote: String
    ) {
        self.id = id
        self.segmentID = segmentID
        self.speakerName = speakerName
        self.startTime = startTime
        self.endTime = endTime
        self.quote = quote
    }
}

public struct TranscriptQuestionAnswer: Equatable, Sendable {
    public var meetingID: UUID
    public var transcriptVersion: Int
    public var transcriptDigest: String
    public var question: String
    public var answerText: String
    public var editableText: String
    public var evidence: [TranscriptQuestionEvidence]

    public init(
        meetingID: UUID,
        transcriptVersion: Int = 0,
        transcriptDigest: String = "legacy",
        question: String,
        answerText: String,
        editableText: String,
        evidence: [TranscriptQuestionEvidence]
    ) {
        self.meetingID = meetingID
        self.transcriptVersion = max(0, transcriptVersion)
        self.transcriptDigest = transcriptDigest
        self.question = question
        self.answerText = answerText
        self.editableText = editableText
        self.evidence = evidence
    }
}

public struct TranscriptQuestionAnsweringService: Sendable {
    private let stopWords: Set<String>

    public init(stopWords: Set<String>? = nil) {
        self.stopWords = stopWords ?? Self.defaultStopWords
    }

    public func answer(
        question: String,
        transcript: MeetingTranscript
    ) throws -> TranscriptQuestionAnswer {
        let selectedSegments = try contextSegments(
            question: question,
            transcript: transcript,
            maximumCount: 3
        )
        let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selectedSegments.isEmpty else {
            let answer = "I could not find transcript evidence for \"\(trimmedQuestion)\". Try a narrower question or review the visible transcript."
            return TranscriptQuestionAnswer(
                meetingID: transcript.meetingID,
                transcriptVersion: transcript.transcriptVersion,
                transcriptDigest: try LocalFinalTranscriptionService.transcriptDigest(transcript),
                question: trimmedQuestion,
                answerText: answer,
                editableText: answer,
                evidence: []
            )
        }

        let evidence = selectedSegments.map { segment in
            TranscriptQuestionEvidence(
                segmentID: segment.id,
                speakerName: segment.speakerName,
                startTime: segment.startTime,
                endTime: segment.endTime,
                quote: segment.text
            )
        }
        let answer = selectedSegments
            .map { "\($0.speakerName) at \(Self.timestamp($0.startTime)): \($0.text)" }
            .joined(separator: "\n")

        return TranscriptQuestionAnswer(
            meetingID: transcript.meetingID,
            transcriptVersion: transcript.transcriptVersion,
            transcriptDigest: try LocalFinalTranscriptionService.transcriptDigest(transcript),
            question: trimmedQuestion,
            answerText: answer,
            editableText: answer,
            evidence: evidence
        )
    }

    public func contextSegments(
        question: String,
        transcript: MeetingTranscript,
        maximumCount: Int
    ) throws -> [TranscriptSegment] {
        let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuestion.isEmpty else {
            throw TranscriptQuestionAnsweringError.blankQuestion
        }
        guard maximumCount > 0 else { return [] }

        let queryTokens = expandedQueryTokens(for: trimmedQuestion)
        let scoredSegments = transcript.segments
            .compactMap { segment -> ScoredSegment? in
                let segmentTokens = Set(tokens(in: "\(segment.speakerName) \(segment.text)"))
                let overlap = queryTokens.intersection(segmentTokens)
                guard !overlap.isEmpty else { return nil }
                return ScoredSegment(segment: segment, score: overlap.count)
            }
            .sorted {
                if $0.score == $1.score {
                    return $0.segment.startTime < $1.segment.startTime
                }
                return $0.score > $1.score
            }

        if !scoredSegments.isEmpty {
            return Array(scoredSegments.prefix(maximumCount).map(\.segment))
        }
        guard isBroadTranscriptPrompt(queryTokens: queryTokens) else {
            return []
        }
        return representativeSegments(from: transcript.segments, maximumCount: maximumCount)
    }

    private func tokens(in text: String) -> [String] {
        text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { normalizedToken($0) }
            .filter { !$0.isEmpty && !stopWords.contains($0) }
    }

    private func normalizedToken(_ token: String) -> String {
        var token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        for suffix in ["ing", "ed", "es", "s"] where token.count > suffix.count + 2 && token.hasSuffix(suffix) {
            token.removeLast(suffix.count)
            break
        }
        return token
    }

    private func expandedQueryTokens(for question: String) -> Set<String> {
        let baseTokens = Set(tokens(in: question))
        var expanded = baseTokens
        for token in baseTokens {
            if let related = Self.meetingIntentTokenExpansions[token] {
                expanded.formUnion(related)
            }
        }
        return expanded
    }

    private func isBroadTranscriptPrompt(queryTokens: Set<String>) -> Bool {
        guard !queryTokens.isEmpty else { return false }
        return queryTokens.isSubset(of: Self.broadTranscriptPromptTokens)
    }

    private func representativeSegments(
        from segments: [TranscriptSegment],
        maximumCount: Int
    ) -> [TranscriptSegment] {
        let usableSegments = segments
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.startTime < $1.startTime }
        guard !usableSegments.isEmpty else { return [] }
        guard usableSegments.count > maximumCount else { return usableSegments }
        guard maximumCount > 1 else { return [usableSegments[0]] }
        return (0..<maximumCount).map { index in
            let position = index * (usableSegments.count - 1) / (maximumCount - 1)
            return usableSegments[position]
        }
    }

    private static func timestamp(_ seconds: TimeInterval) -> String {
        let totalSeconds = max(0, Int(seconds.rounded(.down)))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private struct ScoredSegment {
        var segment: TranscriptSegment
        var score: Int
    }

    private static let defaultStopWords: Set<String> = [
        "a", "about", "after", "an", "and", "are", "as", "at", "be", "by", "can",
        "did", "do", "for", "from", "have", "how", "i", "in", "is", "it", "me",
        "need", "of", "on", "or", "our", "that", "the", "this", "to", "we",
        "what", "when", "where", "who", "why", "with", "you"
    ]

    private static let meetingIntentTokenExpansions: [String: Set<String>] = [
        "decide": ["decide", "decision", "decided", "confirm", "confirmed", "choose", "chosen", "approve", "approved"],
        "decision": ["decide", "decision", "decided", "confirm", "confirmed", "choose", "chosen", "approve", "approved"],
        "follow": ["follow", "followup", "action", "actions", "next", "owner", "owners", "todo", "task", "verify", "review"],
        "followup": ["follow", "followup", "action", "actions", "next", "owner", "owners", "todo", "task", "verify", "review"],
        "action": ["follow", "followup", "action", "actions", "next", "owner", "owners", "todo", "task", "verify", "review"],
        "next": ["follow", "followup", "action", "actions", "next", "owner", "owners", "todo", "task", "verify", "review"],
        "block": ["block", "blocked", "blocker", "risk", "issue", "problem", "waiting"],
        "risk": ["block", "blocked", "blocker", "risk", "issue", "problem", "waiting"]
    ]

    private static let broadTranscriptPromptTokens: Set<String> = [
        "brief", "context", "cover", "discuss", "discussed", "explain", "explanation",
        "include", "including", "language", "matter", "overview", "plain", "please",
        "practical", "recap", "review", "step", "summarize", "summary", "tell",
        "transcript", "understand", "ok"
    ]
}
