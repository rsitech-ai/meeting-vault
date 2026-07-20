import Foundation
#if canImport(FoundationModels)
@preconcurrency import FoundationModels
#endif

public protocol TranscriptQuestionAnsweringProviding: Sendable {
    func answer(question: String, transcript: MeetingTranscript) async throws -> TranscriptQuestionAnswer
}

public enum FoundationModelsTranscriptQuestionAnsweringError: Error, Equatable, LocalizedError, Sendable {
    case modelUnavailable(String)
    case blankQuestion
    case emptyTranscript
    case invalidResponse(String)
    case unknownEvidenceSegment(String)
    case evidenceQuoteNotFound(segmentID: String, quote: String)
    case generationFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .modelUnavailable(reason):
            return "Foundation Models are unavailable: \(reason)"
        case .blankQuestion:
            return "Prompt cannot be blank."
        case .emptyTranscript:
            return "Foundation Models need transcript segments before answering."
        case let .invalidResponse(message):
            return "Foundation Models returned an invalid transcript answer: \(message)"
        case let .unknownEvidenceSegment(id):
            return "Foundation Models cited an unknown transcript segment: \(id)"
        case let .evidenceQuoteNotFound(segmentID, _):
            return "Foundation Models cited a quote that was not found in transcript segment: \(segmentID)"
        case let .generationFailed(message):
            return "Foundation Models transcript answer failed: \(message)"
        }
    }
}

public final class FoundationModelsTranscriptQuestionAnsweringProvider: TranscriptQuestionAnsweringProviding, @unchecked Sendable {
    private let availabilityProvider: any FoundationModelsAvailabilityProviding
    private let textGenerator: any FoundationModelsTextGenerating
    private let contextSelector: TranscriptQuestionAnsweringService
    private let decoder = JSONDecoder()

    public init(
        availabilityProvider: any FoundationModelsAvailabilityProviding = SystemFoundationModelsAvailabilityProvider(),
        textGenerator: any FoundationModelsTextGenerating = SystemFoundationModelsTextGenerator(),
        contextSelector: TranscriptQuestionAnsweringService = TranscriptQuestionAnsweringService()
    ) {
        self.availabilityProvider = availabilityProvider
        self.textGenerator = textGenerator
        self.contextSelector = contextSelector
    }

    public func answer(question: String, transcript: MeetingTranscript) async throws -> TranscriptQuestionAnswer {
        let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuestion.isEmpty else {
            throw FoundationModelsTranscriptQuestionAnsweringError.blankQuestion
        }

        let segments = transcript.segments.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !segments.isEmpty else {
            throw FoundationModelsTranscriptQuestionAnsweringError.emptyTranscript
        }

        let availability = availabilityProvider.currentAvailability()
        guard availability.isAvailable else {
            throw FoundationModelsTranscriptQuestionAnsweringError.modelUnavailable(
                availability.reason ?? "Apple Intelligence is not available."
            )
        }

        let selectedSegments = try contextSelector.contextSegments(
            question: trimmedQuestion,
            transcript: transcript,
            maximumCount: 12
        )
        let boundedSegments = try await boundedContextSegments(
            selectedSegments.isEmpty ? representativeSegments(from: segments, maximumCount: 12) : selectedSegments,
            question: trimmedQuestion,
            transcript: transcript
        )
        let request = FoundationModelsTextGenerationRequest(
            instructions: Self.instructions,
            prompt: Self.prompt(question: trimmedQuestion, transcript: transcript, segments: boundedSegments),
            maximumResponseTokens: 700,
            structuredResponseKind: .transcriptQuestionAnswer
        )
        let response: String
        do {
            response = try await textGenerator.generateText(request)
        } catch let error as FoundationModelsTranscriptQuestionAnsweringError {
            throw error
        } catch {
            if Self.shouldRetryAsPlainJSON(after: error) {
                do {
                    response = try await textGenerator.generateText(
                        FoundationModelsTextGenerationRequest(
                            instructions: request.instructions,
                            prompt: request.prompt,
                            maximumResponseTokens: request.maximumResponseTokens,
                            structuredResponseKind: nil
                        )
                    )
                } catch {
                    throw FoundationModelsTranscriptQuestionAnsweringError.generationFailed(error.localizedDescription)
                }
            } else {
                throw FoundationModelsTranscriptQuestionAnsweringError.generationFailed(error.localizedDescription)
            }
        }

        let parsed = try Self.parseResponse(
            response,
            decoder: decoder,
            segmentsByID: Dictionary(uniqueKeysWithValues: boundedSegments.map { ($0.id.uuidString, $0) })
        )
        let editableText = parsed.answerText.trimmingCharacters(in: .whitespacesAndNewlines)
        return TranscriptQuestionAnswer(
            meetingID: transcript.meetingID,
            transcriptVersion: transcript.transcriptVersion,
            transcriptDigest: try LocalFinalTranscriptionService.transcriptDigest(transcript),
            question: trimmedQuestion,
            answerText: editableText,
            editableText: editableText,
            evidence: parsed.evidence
        )
    }

    private func representativeSegments(
        from segments: [TranscriptSegment],
        maximumCount: Int
    ) -> [TranscriptSegment] {
        guard segments.count > maximumCount else { return segments }
        guard maximumCount > 1 else { return [segments[0]] }
        return (0..<maximumCount).map { index in
            segments[index * (segments.count - 1) / (maximumCount - 1)]
        }
    }

    private func boundedContextSegments(
        _ candidateSegments: [TranscriptSegment],
        question: String,
        transcript: MeetingTranscript
    ) async throws -> [TranscriptSegment] {
        var bounded = candidateSegments
        while !bounded.isEmpty {
            let request = FoundationModelsTextGenerationRequest(
                instructions: Self.instructions,
                prompt: Self.prompt(question: question, transcript: transcript, segments: bounded),
                maximumResponseTokens: 700,
                structuredResponseKind: .transcriptQuestionAnswer
            )
            if try await textGenerator.tokenCount(for: request) + 128 <= textGenerator.contextSize {
                return bounded
            }
            bounded.removeLast()
        }
        throw FoundationModelsTranscriptQuestionAnsweringError.generationFailed(
            "The relevant transcript segment is too long for the local model context. Split the transcript into smaller segments and retry."
        )
    }

    private static let instructions = """
    Answer meeting transcript questions using only the provided transcript context.
    If the transcript does not contain enough evidence, say what is missing.
    Cite only segment IDs from the transcript.
    Quotes must be the full cited segment text copied exactly.
    Return JSON only, with no markdown.
    """

    private static func prompt(
        question: String,
        transcript: MeetingTranscript,
        segments: [TranscriptSegment]
    ) -> String {
        let context = segments.map { segment in
            "[\(segment.id.uuidString)] \(timestamp(segment.startTime))-\(timestamp(segment.endTime)) \(segment.speakerName): \(segment.text)"
        }.joined(separator: "\n")

        return """
        Transcript:
        \(context)

        Question:
        \(question)

        Return one JSON object, not an array and not markdown.
        Include at least one evidence item when the transcript contains the answer.
        For every evidence item, set quote to the full transcript segment text exactly as shown after the speaker name.
        Preserve labels such as Decision:, Action:, Open question:, and Risk: when they appear in the segment text.
        Return JSON with this exact shape:
        {
          "answerText": "answer grounded only in the transcript",
          "evidence": [
            {
              "segmentID": "UUID from transcript",
              "quote": "exact quote copied from the segment"
            }
          ]
        }
        """
    }

    private static func parseResponse(
        _ response: String,
        decoder: JSONDecoder,
        segmentsByID: [String: TranscriptSegment]
    ) throws -> ParsedTranscriptQuestionAnswer {
        let data = Data(response.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        let output: FoundationModelsTranscriptAnswerOutput
        do {
            output = try decoder.decode(FoundationModelsTranscriptAnswerOutput.self, from: data)
        } catch {
            throw FoundationModelsTranscriptQuestionAnsweringError.invalidResponse(error.localizedDescription)
        }

        let evidence = try output.evidence.map { item in
            guard let segment = segmentsByID[item.segmentID] else {
                throw FoundationModelsTranscriptQuestionAnsweringError.unknownEvidenceSegment(item.segmentID)
            }
            let quote = item.quote.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !quote.isEmpty else {
                throw FoundationModelsTranscriptQuestionAnsweringError.invalidResponse("Evidence quote cannot be blank.")
            }
            guard normalizedEvidenceText(segment.text) == normalizedEvidenceText(quote) else {
                throw FoundationModelsTranscriptQuestionAnsweringError.evidenceQuoteNotFound(
                    segmentID: item.segmentID,
                    quote: quote
                )
            }
            return TranscriptQuestionEvidence(
                segmentID: segment.id,
                speakerName: segment.speakerName,
                startTime: segment.startTime,
                endTime: segment.endTime,
                quote: quote
            )
        }
        return ParsedTranscriptQuestionAnswer(answerText: output.answerText, evidence: evidence)
    }

    private static func normalizedEvidenceText(_ value: String) -> String {
        value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func timestamp(_ seconds: TimeInterval) -> String {
        let totalSeconds = max(0, Int(seconds.rounded(.down)))
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    private static func shouldRetryAsPlainJSON(after error: Error) -> Bool {
        let message: String
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription {
            message = description
        } else {
            message = error.localizedDescription
        }

        return message.localizedCaseInsensitiveContains("language or locale")
            || message.localizedCaseInsensitiveContains("unsupported language")
            || message.localizedCaseInsensitiveContains("unsupported guide")
    }
}

#if canImport(FoundationModels)
@Generable
#endif
struct FoundationModelsTranscriptAnswerOutput: Codable {
    var answerText: String
    var evidence: [FoundationModelsTranscriptEvidenceOutput]
}

#if canImport(FoundationModels)
@Generable
#endif
struct FoundationModelsTranscriptEvidenceOutput: Codable {
    var segmentID: String
    var quote: String
}

private struct ParsedTranscriptQuestionAnswer {
    var answerText: String
    var evidence: [TranscriptQuestionEvidence]
}
