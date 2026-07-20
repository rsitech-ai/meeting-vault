import Foundation

#if canImport(FoundationModels)
@preconcurrency import FoundationModels
#endif

public struct FoundationModelsAvailabilityStatus: Equatable, Sendable {
    public var isAvailable: Bool
    public var reason: String?

    public init(isAvailable: Bool, reason: String? = nil) {
        self.isAvailable = isAvailable
        self.reason = reason
    }
}

public protocol FoundationModelsAvailabilityProviding: Sendable {
    func currentAvailability() -> FoundationModelsAvailabilityStatus
}

public struct SystemFoundationModelsAvailabilityProvider: FoundationModelsAvailabilityProviding {
    public init() {}

    public func currentAvailability() -> FoundationModelsAvailabilityStatus {
        #if canImport(FoundationModels)
        switch SystemLanguageModel.default.availability {
        case .available:
            return FoundationModelsAvailabilityStatus(isAvailable: true)
        case let .unavailable(reason):
            return FoundationModelsAvailabilityStatus(
                isAvailable: false,
                reason: Self.message(for: reason)
            )
        @unknown default:
            return FoundationModelsAvailabilityStatus(
                isAvailable: false,
                reason: "Foundation Models are unavailable."
            )
        }
        #else
        return FoundationModelsAvailabilityStatus(
            isAvailable: false,
            reason: "Foundation Models framework is not available in this SDK."
        )
        #endif
    }

    #if canImport(FoundationModels)
    private static func message(for reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible:
            return "This device does not support Apple Intelligence."
        case .appleIntelligenceNotEnabled:
            return "Apple Intelligence is not enabled."
        case .modelNotReady:
            return "The model is still downloading or preparing."
        @unknown default:
            return "Foundation Models are unavailable."
        }
    }
    #endif
}

public struct FoundationModelsTextGenerationRequest: Equatable, Sendable {
    public enum StructuredResponseKind: Equatable, Sendable {
        case meetingSummary
        case transcriptQuestionAnswer
    }

    public var instructions: String
    public var prompt: String
    public var maximumResponseTokens: Int
    public var structuredResponseKind: StructuredResponseKind?

    public init(
        instructions: String,
        prompt: String,
        maximumResponseTokens: Int = 1_200,
        structuredResponseKind: StructuredResponseKind? = nil
    ) {
        self.instructions = instructions
        self.prompt = prompt
        self.maximumResponseTokens = maximumResponseTokens
        self.structuredResponseKind = structuredResponseKind
    }
}

public protocol FoundationModelsTextGenerating: Sendable {
    var contextSize: Int { get }
    func tokenCount(for request: FoundationModelsTextGenerationRequest) async throws -> Int
    func generateText(_ request: FoundationModelsTextGenerationRequest) async throws -> String
}

public enum FoundationModelsMeetingIntelligenceError: Error, Equatable, LocalizedError, Sendable {
    case modelUnavailable(String)
    case emptyTranscript
    case invalidBookmarkEvidence
    case contextLimitExceeded
    case invalidResponse(String)
    case unknownEvidenceSegment(String)
    case generationFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .modelUnavailable(reason):
            return "Foundation Models are unavailable: \(reason)"
        case .emptyTranscript:
            return "Foundation Models need transcript segments before generating meeting intelligence."
        case .invalidBookmarkEvidence:
            return "The marked-moment evidence is invalid for this meeting."
        case .contextLimitExceeded:
            return "A transcript segment is too long for the local model context."
        case let .invalidResponse(message):
            return "Foundation Models returned an invalid meeting summary: \(message)"
        case let .unknownEvidenceSegment(id):
            return "Foundation Models cited an unknown transcript segment: \(id)"
        case let .generationFailed(message):
            return "Foundation Models generation failed: \(message)"
        }
    }
}

public final class FoundationModelsMeetingIntelligenceProvider: MeetingIntelligenceProvider, @unchecked Sendable {
    public let id = "foundation-models-meeting-intelligence"
    public static let maximumBookmarkEvidenceCount = 24
    public static let bookmarkEvidenceUTF8ByteBudget = 6_144

    private let availabilityProvider: any FoundationModelsAvailabilityProviding
    private let textGenerator: any FoundationModelsTextGenerating
    private let decoder: JSONDecoder

    public init(
        availabilityProvider: any FoundationModelsAvailabilityProviding = SystemFoundationModelsAvailabilityProvider(),
        textGenerator: any FoundationModelsTextGenerating = SystemFoundationModelsTextGenerator()
    ) {
        self.availabilityProvider = availabilityProvider
        self.textGenerator = textGenerator
        self.decoder = JSONDecoder()
    }

    public func summarize(segments: [TranscriptSegment], meetingID: UUID) async throws -> MeetingSummary {
        try await summarize(segments: segments, bookmarkEvidence: [], meetingID: meetingID)
    }

    public func summarize(
        segments: [TranscriptSegment],
        bookmarkEvidence: [MeetingIntelligenceBookmarkEvidence],
        meetingID: UUID
    ) async throws -> MeetingSummary {
        let finalSegments = segments.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !finalSegments.isEmpty else {
            throw FoundationModelsMeetingIntelligenceError.emptyTranscript
        }

        let availability = availabilityProvider.currentAvailability()
        guard availability.isAvailable else {
            throw FoundationModelsMeetingIntelligenceError.modelUnavailable(
                availability.reason ?? "Apple Intelligence is not available."
            )
        }

        let bookmarks = try validatedBookmarkEvidence(bookmarkEvidence, meetingID: meetingID)
        let chunks = try await boundedChunks(
            segments: finalSegments,
            bookmarkEvidence: bookmarks,
            meetingID: meetingID
        )
        var summaries: [MeetingSummary] = []
        for (chunk, request) in chunks {
            let response: String
            do {
                response = try await textGenerator.generateText(request)
            } catch let error as FoundationModelsMeetingIntelligenceError {
                throw error
            } catch {
                throw FoundationModelsMeetingIntelligenceError.generationFailed(error.localizedDescription)
            }
            summaries.append(
                try Self.parseSummary(
                    response,
                    meetingID: meetingID,
                    segmentsByID: Dictionary(uniqueKeysWithValues: chunk.map { ($0.id.uuidString, $0) }),
                    decoder: decoder
                )
            )
        }
        return Self.mergedSummary(summaries)
    }

    private func boundedChunks(
        segments: [TranscriptSegment],
        bookmarkEvidence: [MeetingIntelligenceBookmarkEvidence],
        meetingID: UUID
    ) async throws -> [([TranscriptSegment], FoundationModelsTextGenerationRequest)] {
        var chunks: [([TranscriptSegment], FoundationModelsTextGenerationRequest)] = []
        var current: [TranscriptSegment] = []
        var currentRequest: FoundationModelsTextGenerationRequest?

        for segment in segments {
            let candidate = current + [segment]
            if let request = try await boundedRequest(
                meetingID: meetingID,
                segments: candidate,
                bookmarkEvidence: bookmarkEvidence
            ) {
                current = candidate
                currentRequest = request
                continue
            }
            guard !current.isEmpty else {
                throw FoundationModelsMeetingIntelligenceError.contextLimitExceeded
            }
            guard let completedRequest = currentRequest else {
                throw FoundationModelsMeetingIntelligenceError.contextLimitExceeded
            }
            chunks.append((current, completedRequest))
            current = [segment]
            guard let request = try await boundedRequest(
                meetingID: meetingID,
                segments: current,
                bookmarkEvidence: bookmarkEvidence
            ) else {
                throw FoundationModelsMeetingIntelligenceError.contextLimitExceeded
            }
            currentRequest = request
        }
        if !current.isEmpty, let currentRequest {
            chunks.append((current, currentRequest))
        }
        return chunks
    }

    private func boundedRequest(
        meetingID: UUID,
        segments: [TranscriptSegment],
        bookmarkEvidence: [MeetingIntelligenceBookmarkEvidence]
    ) async throws -> FoundationModelsTextGenerationRequest? {
        var ranked = Self.relevantBookmarkEvidence(bookmarkEvidence, to: segments)
        while true {
            let request = Self.request(
                meetingID: meetingID,
                segments: segments,
                bookmarkEvidence: ranked.sorted(by: Self.bookmarkEvidenceSort)
            )
            if try await requestFitsContext(request) {
                return request
            }
            guard !ranked.isEmpty else { return nil }
            ranked.removeLast()
        }
    }

    private func requestFitsContext(_ request: FoundationModelsTextGenerationRequest) async throws -> Bool {
        try await textGenerator.tokenCount(for: request) + Self.contextSafetyTokenCount <= textGenerator.contextSize
    }

    private static let contextSafetyTokenCount = 128

    private static func relevantBookmarkEvidence(
        _ evidence: [MeetingIntelligenceBookmarkEvidence],
        to segments: [TranscriptSegment]
    ) -> [MeetingIntelligenceBookmarkEvidence] {
        guard let lowerBound = segments.map(\.startTime).min(),
              let upperBound = segments.map(\.endTime).max() else { return [] }
        let ranked = evidence.sorted { lhs, rhs in
            let lhsDistance = bookmarkDistance(lhs.bookmark.timestamp, lowerBound: lowerBound, upperBound: upperBound)
            let rhsDistance = bookmarkDistance(rhs.bookmark.timestamp, lowerBound: lowerBound, upperBound: upperBound)
            if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
            return bookmarkEvidenceSort(lhs, rhs)
        }
        var selected: [MeetingIntelligenceBookmarkEvidence] = []
        var byteCount = 0
        for item in ranked.prefix(maximumBookmarkEvidenceCount) {
            let lineBytes = bookmarkLine(item).utf8.count + 1
            guard byteCount + lineBytes <= bookmarkEvidenceUTF8ByteBudget else { continue }
            selected.append(item)
            byteCount += lineBytes
        }
        return selected
    }

    private static func bookmarkDistance(
        _ timestamp: TimeInterval,
        lowerBound: TimeInterval,
        upperBound: TimeInterval
    ) -> TimeInterval {
        if timestamp < lowerBound { return lowerBound - timestamp }
        if timestamp > upperBound { return timestamp - upperBound }
        return 0
    }

    private static func bookmarkEvidenceSort(
        _ lhs: MeetingIntelligenceBookmarkEvidence,
        _ rhs: MeetingIntelligenceBookmarkEvidence
    ) -> Bool {
        if lhs.bookmark.timestamp != rhs.bookmark.timestamp {
            return lhs.bookmark.timestamp < rhs.bookmark.timestamp
        }
        return lhs.bookmark.id.uuidString < rhs.bookmark.id.uuidString
    }

    private static func request(
        meetingID: UUID,
        segments: [TranscriptSegment],
        bookmarkEvidence: [MeetingIntelligenceBookmarkEvidence] = []
    ) -> FoundationModelsTextGenerationRequest {
        FoundationModelsTextGenerationRequest(
            instructions: instructions,
            prompt: prompt(
                meetingID: meetingID,
                segments: segments,
                bookmarkEvidence: bookmarkEvidence
            ),
            maximumResponseTokens: 1_200,
            structuredResponseKind: .meetingSummary
        )
    }

    private static func mergedSummary(_ summaries: [MeetingSummary]) -> MeetingSummary {
        precondition(!summaries.isEmpty)
        return MeetingSummary(
            title: summaries[0].title,
            oneParagraph: unique(summaries.map(\.oneParagraph)).joined(separator: " "),
            bullets: unique(summaries.flatMap(\.bullets)),
            decisions: summaries.flatMap(\.decisions),
            actionItems: summaries.flatMap(\.actionItems),
            openQuestions: summaries.flatMap(\.openQuestions),
            risks: summaries.flatMap(\.risks)
        )
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { value in
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return !normalized.isEmpty && seen.insert(normalized).inserted
        }
    }

    private static let instructions = """
    Generate local-first meeting intelligence from transcript segments only.
    Do not invent decisions, action items, questions, risks, owners, or facts.
    Every decision, action, open question, and risk must cite an existing transcript segment ID.
    Marked moments are emphasis/context only, never decisions or action items without transcript evidence.
    Return JSON only, with no markdown.
    """

    private static func prompt(
        meetingID: UUID,
        segments: [TranscriptSegment],
        bookmarkEvidence: [MeetingIntelligenceBookmarkEvidence]
    ) -> String {
        let segmentLines = segments.map { segment in
            "[\(segment.id.uuidString)] \(timestamp(segment.startTime))-\(timestamp(segment.endTime)) \(segment.speakerName): \(segment.text)"
        }.joined(separator: "\n")
        let bookmarkLines = bookmarkEvidence.map(bookmarkLine).joined(separator: "\n")
        return """
        Transcript segments:
        \(segmentLines)

        User-authored marked moments (emphasis/context only; do not treat categories or notes as conclusions):
        \(bookmarkLines.isEmpty ? "None" : bookmarkLines)

        Return one JSON object, not an array and not markdown.
        Include at least one bullet.
        Include exactly one decision, one action item, one open question, and one risk when those transcript lines exist.
        Use null for dueAt unless the transcript contains an explicit ISO-8601 calendar date.
        Return JSON with this shape:
        {
          "title": "short title",
          "oneParagraph": "one paragraph grounded summary",
          "bullets": ["grounded bullet"],
          "decisions": [
            {
              "title": "decision title",
              "details": "decision details",
              "segmentID": "UUID from transcript",
              "quote": "full exact segment text copied from that segment",
              "confidence": 0.0
            }
          ],
          "actionItems": [
            {
              "title": "action title",
              "ownerName": "owner or null",
              "dueAt": "ISO-8601 date or null",
              "segmentID": "UUID from transcript",
              "quote": "full exact segment text copied from that segment",
              "confidence": 0.0
            }
          ],
          "openQuestions": [
            {
              "question": "open question",
              "context": "why it matters",
              "segmentID": "UUID from transcript",
              "quote": "full exact segment text copied from that segment",
              "confidence": 0.0
            }
          ],
          "risks": [
            {
              "title": "risk title",
              "details": "risk details",
              "severity": "low|medium|high|critical",
              "segmentID": "UUID from transcript",
              "quote": "full exact segment text copied from that segment",
              "confidence": 0.0
            }
          ]
        }
        """
    }

    private func validatedBookmarkEvidence(
        _ evidence: [MeetingIntelligenceBookmarkEvidence],
        meetingID: UUID
    ) throws -> [MeetingIntelligenceBookmarkEvidence] {
        do {
            _ = try RecordingSessionMetadata(
                meetingID: meetingID,
                startedAt: Date(timeIntervalSinceReferenceDate: 0),
                context: MeetingContext(),
                bookmarks: evidence.map(\.bookmark)
            ).validated(expectedMeetingID: meetingID)
        } catch {
            throw FoundationModelsMeetingIntelligenceError.invalidBookmarkEvidence
        }
        return evidence.sorted(by: Self.bookmarkEvidenceSort)
    }

    private static func bookmarkLine(_ evidence: MeetingIntelligenceBookmarkEvidence) -> String {
        let category = evidence.bookmark.category?.rawValue ?? "uncategorized"
        let note = evidence.bookmark.note ?? ""
        return "[\(timestamp(evidence.bookmark.timestamp))] provenance=\(evidence.provenance.rawValue) category=\(category) note=\(jsonString(note))"
    }

    private static func jsonString(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value) else { return "\"\"" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func parseSummary(
        _ response: String,
        meetingID: UUID,
        segmentsByID: [String: TranscriptSegment],
        decoder: JSONDecoder
    ) throws -> MeetingSummary {
        let data = Data(response.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        let output: FoundationModelsMeetingSummaryOutput
        do {
            output = try decoder.decode(FoundationModelsMeetingSummaryOutput.self, from: data)
        } catch {
            throw FoundationModelsMeetingIntelligenceError.invalidResponse(error.localizedDescription)
        }

        let decisions = try output.decisions.map { decision in
            let evidence = try evidenceRef(
                meetingID: meetingID,
                segmentID: decision.segmentID,
                quote: decision.quote,
                segmentsByID: segmentsByID
            )
            return Decision(
                title: decision.title,
                details: decision.details,
                evidence: [evidence],
                confidence: decision.confidence.clampedProbability
            )
        }

        let actionItems = try output.actionItems.map { action in
            let evidence = try evidenceRef(
                meetingID: meetingID,
                segmentID: action.segmentID,
                quote: action.quote,
                segmentsByID: segmentsByID
            )
            return ActionItem(
                title: action.title,
                ownerName: action.ownerName,
                dueDate: action.dueAt.flatMap(Self.parseDate),
                evidence: [evidence],
                confidence: action.confidence.clampedProbability
            )
        }

        let openQuestions = try output.openQuestions.map { question in
            let evidence = try evidenceRef(
                meetingID: meetingID,
                segmentID: question.segmentID,
                quote: question.quote,
                segmentsByID: segmentsByID
            )
            return OpenQuestion(
                question: question.question,
                context: question.context,
                evidence: [evidence],
                confidence: question.confidence.clampedProbability
            )
        }

        let risks = try output.risks.map { risk in
            let evidence = try evidenceRef(
                meetingID: meetingID,
                segmentID: risk.segmentID,
                quote: risk.quote,
                segmentsByID: segmentsByID
            )
            return MeetingRisk(
                title: risk.title,
                details: risk.details,
                severity: risk.severityValue,
                evidence: [evidence],
                confidence: risk.confidence.clampedProbability
            )
        }

        return MeetingSummary(
            title: output.title,
            oneParagraph: output.oneParagraph,
            bullets: output.bullets,
            decisions: decisions,
            actionItems: actionItems,
            openQuestions: openQuestions,
            risks: risks
        )
    }

    private static func evidenceRef(
        meetingID: UUID,
        segmentID: String,
        quote: String,
        segmentsByID: [String: TranscriptSegment]
    ) throws -> EvidenceRef {
        guard let segment = segmentsByID[segmentID] else {
            throw FoundationModelsMeetingIntelligenceError.unknownEvidenceSegment(segmentID)
        }
        return EvidenceRef(
            meetingID: meetingID,
            segmentID: segment.id,
            startTime: segment.startTime,
            endTime: segment.endTime,
            quote: quote
        )
    }

    private static func parseDate(_ rawValue: String) -> Date? {
        ISO8601DateFormatter().date(from: rawValue)
    }

    private static func timestamp(_ seconds: TimeInterval) -> String {
        let totalSeconds = max(0, Int(seconds.rounded(.down)))
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}

public struct SystemFoundationModelsTextGenerator: FoundationModelsTextGenerating {
    public init() {}

    public var contextSize: Int {
        #if canImport(FoundationModels)
        SystemLanguageModel.default.contextSize
        #else
        0
        #endif
    }

    public func tokenCount(for request: FoundationModelsTextGenerationRequest) async throws -> Int {
        #if canImport(FoundationModels)
        guard #available(macOS 26.4, *) else {
            let structuredSchemaReserve = request.structuredResponseKind == nil ? 0 : 512
            let inputByteCount = request.instructions.utf8.count + request.prompt.utf8.count
            let conservativeInputEstimate = (inputByteCount + 2) / 3
            return conservativeInputEstimate
                + request.maximumResponseTokens
                + structuredSchemaReserve
        }
        let model = SystemLanguageModel.default
        var count = try await model.tokenCount(for: Instructions(request.instructions))
        count += try await model.tokenCount(for: Prompt(request.prompt))
        switch request.structuredResponseKind {
        case .meetingSummary:
            count += try await model.tokenCount(for: FoundationModelsMeetingSummaryOutput.generationSchema)
        case .transcriptQuestionAnswer:
            count += try await model.tokenCount(for: FoundationModelsTranscriptAnswerOutput.generationSchema)
        case nil:
            break
        }
        return count + request.maximumResponseTokens
        #else
        throw FoundationModelsMeetingIntelligenceError.modelUnavailable(
            "Foundation Models framework is not available in this SDK."
        )
        #endif
    }

    public func generateText(_ request: FoundationModelsTextGenerationRequest) async throws -> String {
        #if canImport(FoundationModels)
        do {
            let session = LanguageModelSession(
                instructions: Instructions(request.instructions)
            )
            if let structuredResponseKind = request.structuredResponseKind {
                return try await Self.generateStructuredText(
                    request,
                    kind: structuredResponseKind,
                    session: session
                )
            }
            let response = try await session.respond(
                to: Prompt(request.prompt),
                options: Self.generationOptions(maximumResponseTokens: request.maximumResponseTokens)
            )
            return response.content
        } catch {
            throw FoundationModelsMeetingIntelligenceError.generationFailed(Self.message(for: error))
        }
        #else
        throw FoundationModelsMeetingIntelligenceError.modelUnavailable(
            "Foundation Models framework is not available in this SDK."
        )
        #endif
    }

    #if canImport(FoundationModels)
    private static func generateStructuredText(
        _ request: FoundationModelsTextGenerationRequest,
        kind: FoundationModelsTextGenerationRequest.StructuredResponseKind,
        session: LanguageModelSession
    ) async throws -> String {
        let options = Self.generationOptions(maximumResponseTokens: request.maximumResponseTokens)
        let encoder = JSONEncoder()
        switch kind {
        case .meetingSummary:
            let response = try await session.respond(
                to: Prompt(request.prompt),
                generating: FoundationModelsMeetingSummaryOutput.self,
                options: options
            )
            return String(decoding: try encoder.encode(response.content), as: UTF8.self)
        case .transcriptQuestionAnswer:
            let response = try await session.respond(
                to: Prompt(request.prompt),
                generating: FoundationModelsTranscriptAnswerOutput.self,
                options: options
            )
            return String(decoding: try encoder.encode(response.content), as: UTF8.self)
        }
    }
    #endif

    #if canImport(FoundationModels)
    private static func generationOptions(maximumResponseTokens: Int) -> GenerationOptions {
        GenerationOptions(
            sampling: .greedy,
            temperature: 0,
            maximumResponseTokens: maximumResponseTokens
        )
    }
    #endif

    private static func message(for error: Error) -> String {
        #if canImport(FoundationModels)
        switch error {
        case LanguageModelSession.GenerationError.exceededContextWindowSize:
            return "This transcript is too long for the local model context window."
        case LanguageModelSession.GenerationError.guardrailViolation:
            return "The request was blocked by the safety system."
        case LanguageModelSession.GenerationError.assetsUnavailable:
            return "Foundation Models assets are temporarily unavailable."
        case LanguageModelSession.GenerationError.concurrentRequests:
            return "Another Foundation Models request is already running."
        case LanguageModelSession.GenerationError.rateLimited:
            return "Foundation Models is rate limited. Try again in a moment."
        case LanguageModelSession.GenerationError.unsupportedLanguageOrLocale:
            return "This transcript language or locale is not supported."
        case LanguageModelSession.GenerationError.decodingFailure:
            return "Foundation Models response could not be decoded."
        case LanguageModelSession.GenerationError.unsupportedGuide:
            return "The requested Foundation Models guide is unsupported."
        case LanguageModelSession.GenerationError.refusal:
            return "Foundation Models declined to generate meeting intelligence."
        default:
            return error.localizedDescription
        }
        #else
        return error.localizedDescription
        #endif
    }
}

#if canImport(FoundationModels)
@Generable
#endif
private struct FoundationModelsMeetingSummaryOutput: Codable {
    var title: String
    var oneParagraph: String
    var bullets: [String]
    var decisions: [FoundationModelsDecisionOutput]
    var actionItems: [FoundationModelsActionItemOutput]

    var openQuestions: [FoundationModelsOpenQuestionOutput]
    var risks: [FoundationModelsRiskOutput]

    private enum CodingKeys: String, CodingKey {
        case title
        case oneParagraph
        case bullets
        case decisions
        case actionItems
        case openQuestions
        case risks
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        oneParagraph = try container.decode(String.self, forKey: .oneParagraph)
        bullets = try container.decode([String].self, forKey: .bullets)
        decisions = try container.decode([FoundationModelsDecisionOutput].self, forKey: .decisions)
        actionItems = try container.decode([FoundationModelsActionItemOutput].self, forKey: .actionItems)
        openQuestions = try container.decodeIfPresent([FoundationModelsOpenQuestionOutput].self, forKey: .openQuestions) ?? []
        risks = try container.decodeIfPresent([FoundationModelsRiskOutput].self, forKey: .risks) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(title, forKey: .title)
        try container.encode(oneParagraph, forKey: .oneParagraph)
        try container.encode(bullets, forKey: .bullets)
        try container.encode(decisions, forKey: .decisions)
        try container.encode(actionItems, forKey: .actionItems)
        try container.encode(openQuestions, forKey: .openQuestions)
        try container.encode(risks, forKey: .risks)
    }
}

#if canImport(FoundationModels)
@Generable
#endif
private struct FoundationModelsDecisionOutput: Codable {
    var title: String
    var details: String
    var segmentID: String
    var quote: String
    var confidence: Double
}

#if canImport(FoundationModels)
@Generable
#endif
private struct FoundationModelsActionItemOutput: Codable {
    var title: String
    var ownerName: String?
    var dueAt: String?
    var segmentID: String
    var quote: String
    var confidence: Double
}

#if canImport(FoundationModels)
@Generable
#endif
private struct FoundationModelsOpenQuestionOutput: Codable {
    var question: String
    var context: String
    var segmentID: String
    var quote: String
    var confidence: Double
}

#if canImport(FoundationModels)
@Generable
#endif
private struct FoundationModelsRiskOutput: Codable {
    var title: String
    var details: String
    var severity: String
    var segmentID: String
    var quote: String
    var confidence: Double

    var severityValue: MeetingRiskSeverity {
        MeetingRiskSeverity(rawValue: severity.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) ?? .medium
    }
}

private extension Double {
    var clampedProbability: Double {
        min(1, max(0, self))
    }
}
