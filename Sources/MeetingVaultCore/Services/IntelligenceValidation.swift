import Foundation

public enum IntelligenceValidationError: Error, Equatable {
    case actionItemMissingEvidence(String)
    case decisionMissingEvidence(String)
    case openQuestionMissingEvidence(String)
    case riskMissingEvidence(String)
    case confidenceOutOfRange(String)
    case evidenceSegmentNotFound(UUID)
    case evidenceQuoteNotFound(segmentID: UUID, quote: String)
}

public enum IntelligenceValidator {
    public static func validate(_ summary: MeetingSummary) throws {
        for action in summary.actionItems {
            try validateConfidence(action.confidence, label: action.title)
            guard !action.evidence.isEmpty else {
                throw IntelligenceValidationError.actionItemMissingEvidence(action.title)
            }
        }

        for decision in summary.decisions {
            try validateConfidence(decision.confidence, label: decision.title)
            guard !decision.evidence.isEmpty else {
                throw IntelligenceValidationError.decisionMissingEvidence(decision.title)
            }
        }

        for question in summary.openQuestions {
            try validateConfidence(question.confidence, label: question.question)
            guard !question.evidence.isEmpty else {
                throw IntelligenceValidationError.openQuestionMissingEvidence(question.question)
            }
        }

        for risk in summary.risks {
            try validateConfidence(risk.confidence, label: risk.title)
            guard !risk.evidence.isEmpty else {
                throw IntelligenceValidationError.riskMissingEvidence(risk.title)
            }
        }
    }

    private static func validateConfidence(_ confidence: Double, label: String) throws {
        guard (0...1).contains(confidence) else {
            throw IntelligenceValidationError.confidenceOutOfRange(label)
        }
    }

    public static func validate(_ summary: MeetingSummary, against transcript: MeetingTranscript) throws {
        try validate(summary)

        let segmentsByID = Dictionary(uniqueKeysWithValues: transcript.segments.map { ($0.id, $0) })
        for evidence in evidenceRefs(in: summary) {
            guard let segment = segmentsByID[evidence.segmentID] else {
                throw IntelligenceValidationError.evidenceSegmentNotFound(evidence.segmentID)
            }
            guard normalizedEvidenceText(segment.text) == normalizedEvidenceText(evidence.quote) else {
                throw IntelligenceValidationError.evidenceQuoteNotFound(
                    segmentID: evidence.segmentID,
                    quote: evidence.quote
                )
            }
        }
    }

    private static func evidenceRefs(in summary: MeetingSummary) -> [EvidenceRef] {
        summary.decisions.flatMap(\.evidence)
            + summary.actionItems.flatMap(\.evidence)
            + summary.openQuestions.flatMap(\.evidence)
            + summary.risks.flatMap(\.evidence)
    }

    private static func normalizedEvidenceText(_ value: String) -> String {
        value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
