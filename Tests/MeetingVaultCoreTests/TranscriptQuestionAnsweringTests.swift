import XCTest
@testable import MeetingVaultCore

final class TranscriptQuestionAnsweringTests: XCTestCase {
    func testTranscriptQuestionAnsweringReturnsEditableGroundedAnswerWithEvidence() throws {
        let meetingID = UUID()
        let deploymentSegmentID = UUID()
        let transcript = MeetingTranscript(
            meetingID: meetingID,
            localeIdentifier: "en-US",
            segments: [
                TranscriptSegment(
                    id: deploymentSegmentID,
                    speakerName: "Anna",
                    trackKind: .remoteSystem,
                    startTime: 44,
                    endTime: 51,
                    text: "Deployment moves to Thursday after QA signs off.",
                    confidence: 0.94,
                    isFinal: true
                ),
                TranscriptSegment(
                    speakerName: "You",
                    trackKind: .microphone,
                    startTime: 60,
                    endTime: 68,
                    text: "Release notes need owner review before the handoff.",
                    confidence: 0.90,
                    isFinal: true
                )
            ]
        )
        let service = TranscriptQuestionAnsweringService()

        let answer = try service.answer(
            question: "What did we decide about deployment?",
            transcript: transcript
        )

        XCTAssertEqual(answer.meetingID, meetingID)
        XCTAssertTrue(answer.answerText.contains("Deployment moves to Thursday"))
        XCTAssertEqual(answer.evidence.map(\.segmentID), [deploymentSegmentID])
        XCTAssertEqual(answer.evidence.first?.speakerName, "Anna")
        XCTAssertEqual(answer.editableText, answer.answerText)
    }

    func testTranscriptQuestionAnsweringFailsClosedForBlankPromptAndMissingContext() throws {
        let transcript = MeetingTranscript(
            meetingID: UUID(),
            localeIdentifier: "en-US",
            segments: [
                TranscriptSegment(
                    speakerName: "Sam",
                    trackKind: .remoteSystem,
                    startTime: 10,
                    endTime: 15,
                    text: "The team discussed onboarding copy.",
                    confidence: 0.88,
                    isFinal: true
                )
            ]
        )
        let service = TranscriptQuestionAnsweringService()

        XCTAssertThrowsError(try service.answer(question: "   ", transcript: transcript)) { error in
            XCTAssertEqual(error as? TranscriptQuestionAnsweringError, .blankQuestion)
        }

        let answer = try service.answer(
            question: "What did we decide about database migration?",
            transcript: transcript
        )

        XCTAssertTrue(answer.answerText.contains("I could not find transcript evidence"))
        XCTAssertTrue(answer.evidence.isEmpty)
    }

    func testTranscriptQuestionAnsweringUsesRepresentativeEvidenceForBroadExplainPrompt() throws {
        let firstID = UUID()
        let middleID = UUID()
        let lastID = UUID()
        let transcript = MeetingTranscript(
            meetingID: UUID(),
            localeIdentifier: "en-US",
            segments: [
                TranscriptSegment(
                    id: firstID,
                    speakerName: "Anna",
                    trackKind: .remoteSystem,
                    startTime: 4,
                    endTime: 10,
                    text: "The team reviewed a promotion scenario workflow for imported sales data.",
                    confidence: 0.91,
                    isFinal: true
                ),
                TranscriptSegment(
                    id: middleID,
                    speakerName: "Marek",
                    trackKind: .remoteSystem,
                    startTime: 30,
                    endTime: 38,
                    text: "The current spreadsheet process needs many manual edits before scoring.",
                    confidence: 0.90,
                    isFinal: true
                ),
                TranscriptSegment(
                    id: lastID,
                    speakerName: "You",
                    trackKind: .microphone,
                    startTime: 60,
                    endTime: 68,
                    text: "Follow up tasks will be added after everyone checks the repository links.",
                    confidence: 0.88,
                    isFinal: true
                )
            ]
        )
        let service = TranscriptQuestionAnsweringService()

        let answer = try service.answer(question: "ok please explain", transcript: transcript)

        XCTAssertEqual(answer.evidence.map(\.segmentID), [firstID, middleID, lastID])
        XCTAssertTrue(answer.answerText.contains("promotion scenario workflow"))
        XCTAssertTrue(answer.answerText.contains("manual edits before scoring"))
        XCTAssertTrue(answer.answerText.contains("repository links"))
        XCTAssertEqual(answer.editableText, answer.answerText)
    }

    func testTranscriptQuestionAnsweringGroundsBroadDecisionAndFollowUpPrompt() throws {
        let decisionID = UUID()
        let followUpID = UUID()
        let transcript = MeetingTranscript(
            meetingID: UUID(),
            localeIdentifier: "en-US",
            segments: [
                TranscriptSegment(
                    id: UUID(),
                    speakerName: "Ewa",
                    trackKind: .remoteSystem,
                    startTime: 4,
                    endTime: 9,
                    text: "We reviewed the transcript import demo and confirmed the audio files are matched.",
                    confidence: 0.91,
                    isFinal: true
                ),
                TranscriptSegment(
                    id: decisionID,
                    speakerName: "Alex",
                    trackKind: .remoteSystem,
                    startTime: 15,
                    endTime: 22,
                    text: "Decision is to ship the primary recording console before adding more diagnostics.",
                    confidence: 0.93,
                    isFinal: true
                ),
                TranscriptSegment(
                    id: followUpID,
                    speakerName: "You",
                    trackKind: .microphone,
                    startTime: 31,
                    endTime: 40,
                    text: "Next action is to verify local imports and ask the transcript agent broad follow up questions.",
                    confidence: 0.92,
                    isFinal: true
                )
            ]
        )
        let service = TranscriptQuestionAnsweringService()

        let answer = try service.answer(
            question: "What did we decide, and what needs follow-up?",
            transcript: transcript
        )

        XCTAssertTrue(answer.evidence.contains { $0.segmentID == decisionID })
        XCTAssertTrue(answer.evidence.contains { $0.segmentID == followUpID })
        XCTAssertTrue(answer.answerText.contains("Decision is to ship the primary recording console"))
        XCTAssertTrue(answer.answerText.contains("Next action is to verify local imports"))
        XCTAssertEqual(answer.editableText, answer.answerText)
    }

    func testFoundationModelsTranscriptQuestionAnsweringReturnsGroundedEditableAnswer() async throws {
        let meetingID = UUID(uuidString: "81818181-8181-8181-8181-818181818181")!
        let segmentID = UUID(uuidString: "82828282-8282-8282-8282-828282828282")!
        let quote = "The migration work is blocked until the source query is reviewed."
        let generator = CapturingTranscriptQATextGenerator(
            response: """
            {
              "answerText": "The migration is blocked until source query review completes.",
              "evidence": [
                {
                  "segmentID": "\(segmentID.uuidString)",
                  "quote": "\(quote)"
                }
              ]
            }
            """
        )
        let provider = FoundationModelsTranscriptQuestionAnsweringProvider(
            availabilityProvider: StubTranscriptQAAvailabilityProvider(
                status: FoundationModelsAvailabilityStatus(isAvailable: true)
            ),
            textGenerator: generator
        )
        let transcript = MeetingTranscript(
            meetingID: meetingID,
            localeIdentifier: "en-US",
            segments: [
                TranscriptSegment(
                    id: segmentID,
                    speakerName: "Marta",
                    trackKind: .remoteSystem,
                    startTime: 22,
                    endTime: 30,
                    text: quote,
                    confidence: 0.91,
                    isFinal: true
                )
            ]
        )

        let answer = try await provider.answer(
            question: "What migration work is blocked?",
            transcript: transcript
        )

        XCTAssertEqual(answer.meetingID, meetingID)
        XCTAssertEqual(answer.question, "What migration work is blocked?")
        XCTAssertEqual(answer.answerText, "The migration is blocked until source query review completes.")
        XCTAssertEqual(answer.editableText, answer.answerText)
        XCTAssertEqual(answer.evidence.map(\.segmentID), [segmentID])
        XCTAssertEqual(answer.evidence.first?.quote, quote)
        XCTAssertEqual(answer.evidence.first?.speakerName, "Marta")
        XCTAssertEqual(generator.requests.count, 1)
        let request = generator.requests[0]
        XCTAssertFalse(request.prompt.contains("Meeting ID:"))
        XCTAssertFalse(request.prompt.contains(meetingID.uuidString))
        XCTAssertEqual(request.structuredResponseKind, .transcriptQuestionAnswer)
        XCTAssertTrue(request.prompt.contains(segmentID.uuidString))
        XCTAssertTrue(request.prompt.contains("What migration work is blocked?"))
        XCTAssertTrue(request.prompt.contains("Return one JSON object"))
        XCTAssertTrue(request.prompt.contains("Include at least one evidence item"))
        XCTAssertTrue(request.prompt.contains("set quote to the full transcript segment text exactly"))
        XCTAssertTrue(request.instructions.contains("full cited segment text copied exactly"))
        XCTAssertTrue(request.instructions.contains("using only the provided transcript"))
    }

    func testFoundationModelsTranscriptQuestionAnsweringRetriesPlainJSONWhenStructuredLocaleIsRejected() async throws {
        let meetingID = UUID(uuidString: "56565656-5656-5656-5656-565656565656")!
        let segmentID = UUID(uuidString: "57575757-5757-5757-5757-575757575757")!
        let quote = "Action: Mahesh will review the Kronos repository setup and report blockers by Friday."
        let generator = CapturingTranscriptQATextGenerator(
            results: [
                .failure(
                    FoundationModelsMeetingIntelligenceError.generationFailed(
                        "This transcript language or locale is not supported."
                    )
                ),
                .success(
                    """
                    {
                      "answerText": "Mahesh owns the Kronos repository setup review by Friday.",
                      "evidence": [
                        {
                          "segmentID": "\(segmentID.uuidString)",
                          "quote": "\(quote)"
                        }
                      ]
                    }
                    """
                )
            ]
        )
        let provider = FoundationModelsTranscriptQuestionAnsweringProvider(
            availabilityProvider: StubTranscriptQAAvailabilityProvider(
                status: FoundationModelsAvailabilityStatus(isAvailable: true)
            ),
            textGenerator: generator
        )

        let answer = try await provider.answer(
            question: "What are the action items?",
            transcript: MeetingTranscript(
                meetingID: meetingID,
                localeIdentifier: "en-US",
                segments: [
                    TranscriptSegment(
                        id: segmentID,
                        speakerName: "Kanishk",
                        trackKind: .mixedPlayback,
                        startTime: 2,
                        endTime: 8,
                        text: quote,
                        confidence: 0.9,
                        isFinal: true
                    )
                ]
            )
        )

        XCTAssertEqual(answer.answerText, "Mahesh owns the Kronos repository setup review by Friday.")
        XCTAssertEqual(answer.evidence.first?.quote, quote)
        XCTAssertEqual(generator.requests.count, 2)
        XCTAssertEqual(generator.requests[0].structuredResponseKind, .transcriptQuestionAnswer)
        XCTAssertNil(generator.requests[1].structuredResponseKind)
        XCTAssertEqual(generator.requests[1].prompt, generator.requests[0].prompt)
    }

    func testFoundationModelsTranscriptQuestionAnsweringFailsClosedWhenUnavailable() async throws {
        let generator = CapturingTranscriptQATextGenerator(response: "{}")
        let provider = FoundationModelsTranscriptQuestionAnsweringProvider(
            availabilityProvider: StubTranscriptQAAvailabilityProvider(
                status: FoundationModelsAvailabilityStatus(
                    isAvailable: false,
                    reason: "Apple Intelligence is not enabled."
                )
            ),
            textGenerator: generator
        )

        do {
            _ = try await provider.answer(
                question: "What did we decide?",
                transcript: MeetingTranscript(
                    meetingID: UUID(uuidString: "83838383-8383-8383-8383-838383838383")!,
                    localeIdentifier: "en-US",
                    segments: [
                        TranscriptSegment(
                            speakerName: "Sam",
                            trackKind: .remoteSystem,
                            startTime: 1,
                            endTime: 3,
                            text: "We decided to wait for QA.",
                            confidence: 0.9,
                            isFinal: true
                        )
                    ]
                )
            )
            XCTFail("Expected unavailable Foundation Models Q&A to fail closed")
        } catch {
            XCTAssertEqual(
                error as? FoundationModelsTranscriptQuestionAnsweringError,
                .modelUnavailable("Apple Intelligence is not enabled.")
            )
        }

        XCTAssertTrue(generator.requests.isEmpty)
    }

    func testFoundationModelsTranscriptQuestionAnsweringRejectsUnknownEvidenceSegment() async throws {
        let provider = FoundationModelsTranscriptQuestionAnsweringProvider(
            availabilityProvider: StubTranscriptQAAvailabilityProvider(
                status: FoundationModelsAvailabilityStatus(isAvailable: true)
            ),
            textGenerator: CapturingTranscriptQATextGenerator(
                response: """
                {
                  "answerText": "The answer cites an unavailable segment.",
                  "evidence": [
                    {
                      "segmentID": "84848484-8484-8484-8484-848484848484",
                      "quote": "Missing quote"
                    }
                  ]
                }
                """
            )
        )

        do {
            _ = try await provider.answer(
                question: "What did we decide?",
                transcript: MeetingTranscript(
                    meetingID: UUID(uuidString: "85858585-8585-8585-8585-858585858585")!,
                    localeIdentifier: "en-US",
                    segments: [
                        TranscriptSegment(
                            id: UUID(uuidString: "86868686-8686-8686-8686-868686868686")!,
                            speakerName: "Sam",
                            trackKind: .remoteSystem,
                            startTime: 1,
                            endTime: 3,
                            text: "Only this segment exists.",
                            confidence: 0.9,
                            isFinal: true
                        )
                    ]
                )
            )
            XCTFail("Expected unknown evidence segment to fail closed")
        } catch {
            XCTAssertEqual(
                error as? FoundationModelsTranscriptQuestionAnsweringError,
                .unknownEvidenceSegment("84848484-8484-8484-8484-848484848484")
            )
        }
    }

    func testFoundationModelsTranscriptQuestionAnsweringRejectsQuoteNotInSegment() async throws {
        let segmentID = UUID(uuidString: "87878787-8787-8787-8787-878787878787")!
        let provider = FoundationModelsTranscriptQuestionAnsweringProvider(
            availabilityProvider: StubTranscriptQAAvailabilityProvider(
                status: FoundationModelsAvailabilityStatus(isAvailable: true)
            ),
            textGenerator: CapturingTranscriptQATextGenerator(
                response: """
                {
                  "answerText": "The answer cites a phrase that was not said.",
                  "evidence": [
                    {
                      "segmentID": "\(segmentID.uuidString)",
                      "quote": "A phrase that is not in the transcript"
                    }
                  ]
                }
                """
            )
        )

        do {
            _ = try await provider.answer(
                question: "What did we decide?",
                transcript: MeetingTranscript(
                    meetingID: UUID(uuidString: "88888888-8888-8888-8888-888888888888")!,
                    localeIdentifier: "en-US",
                    segments: [
                        TranscriptSegment(
                            id: segmentID,
                            speakerName: "Sam",
                            trackKind: .remoteSystem,
                            startTime: 1,
                            endTime: 3,
                            text: "Only exact transcript quotes can be cited.",
                            confidence: 0.9,
                            isFinal: true
                        )
                    ]
                )
            )
            XCTFail("Expected non-substring evidence quote to fail closed")
        } catch {
            XCTAssertEqual(
                error as? FoundationModelsTranscriptQuestionAnsweringError,
                .evidenceQuoteNotFound(
                    segmentID: segmentID.uuidString,
                    quote: "A phrase that is not in the transcript"
                )
            )
        }
    }

    func testFoundationModelsTranscriptQuestionAnsweringBoundsLongTranscriptToRelevantSegments() async throws {
        let relevantID = UUID()
        let relevantText = "The launch blocker is the certificate renewal."
        let generator = CapturingTranscriptQATextGenerator(
            response: """
            {
              "answerText": "Certificate renewal is blocking the launch.",
              "evidence": [
                {
                  "segmentID": "\(relevantID.uuidString)",
                  "quote": "\(relevantText)"
                }
              ]
            }
            """
        )
        let routineSegments = (0..<100).map { index in
            TranscriptSegment(
                speakerName: "Speaker",
                trackKind: .remoteSystem,
                startTime: Double(index * 5),
                endTime: Double(index * 5 + 4),
                text: "Routine status note number \(index).",
                confidence: 0.9,
                isFinal: true
            )
        }
        let relevantSegment = TranscriptSegment(
            id: relevantID,
            speakerName: "Marta",
            trackKind: .remoteSystem,
            startTime: 505,
            endTime: 510,
            text: relevantText,
            confidence: 0.95,
            isFinal: true
        )
        let transcript = MeetingTranscript(
            meetingID: UUID(),
            localeIdentifier: "en-US",
            segments: routineSegments + [relevantSegment]
        )

        let answer = try await FoundationModelsTranscriptQuestionAnsweringProvider(
            availabilityProvider: StubTranscriptQAAvailabilityProvider(
                status: FoundationModelsAvailabilityStatus(isAvailable: true)
            ),
            textGenerator: generator
        ).answer(question: "What is the launch blocker?", transcript: transcript)

        let request = try XCTUnwrap(generator.requests.first)
        XCTAssertTrue(request.prompt.contains(relevantID.uuidString))
        XCTAssertFalse(request.prompt.contains(routineSegments[0].id.uuidString))
        XCTAssertEqual(answer.evidence.map(\.segmentID), [relevantID])
    }
}

private struct StubTranscriptQAAvailabilityProvider: FoundationModelsAvailabilityProviding {
    var status: FoundationModelsAvailabilityStatus

    func currentAvailability() -> FoundationModelsAvailabilityStatus {
        status
    }
}

private final class CapturingTranscriptQATextGenerator: FoundationModelsTextGenerating, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<String, Error>]
    private var _requests: [FoundationModelsTextGenerationRequest] = []

    var requests: [FoundationModelsTextGenerationRequest] {
        lock.withLock { _requests }
    }

    init(response: String) {
        results = [.success(response)]
    }

    init(results: [Result<String, Error>]) {
        self.results = results
    }

    let contextSize = 100_000

    func tokenCount(for request: FoundationModelsTextGenerationRequest) async throws -> Int {
        request.maximumResponseTokens + request.instructions.count + request.prompt.count
    }

    func generateText(_ request: FoundationModelsTextGenerationRequest) async throws -> String {
        try lock.withLock {
            _requests.append(request)
            let result = results.count > 1 ? results.removeFirst() : results[0]
            switch result {
            case let .success(response):
                return response
            case let .failure(error):
                throw error
            }
        }
    }
}
