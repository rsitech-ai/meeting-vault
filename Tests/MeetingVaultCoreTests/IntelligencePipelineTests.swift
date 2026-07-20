import Foundation
import XCTest
@testable import MeetingVaultCore

final class IntelligencePipelineTests: XCTestCase {
    func testIntelligenceRejectsCopiedValidSessionMetadataBeforeProviderSeesPrivateEvidence() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultIntelligenceIdentity-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EncryptedMeetingBundleStore(
            rootDirectory: root,
            vault: AESGCMDataVault(
                keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 73, count: 32))
            )
        )
        let requestedMeetingID = UUID()
        let privateMeetingID = UUID()
        _ = try store.createBundle(.initialEncryptedBundle(meetingID: requestedMeetingID, title: "Requested"))
        try store.writeJSONArtifact(
            MeetingTranscript(
                meetingID: requestedMeetingID,
                localeIdentifier: "en-US",
                segments: [
                    TranscriptSegment(
                        speakerName: "Anna",
                        trackKind: .remoteSystem,
                        startTime: 0,
                        endTime: 1,
                        text: "Safe transcript",
                        confidence: 0.9,
                        isFinal: true
                    )
                ]
            ),
            meetingID: requestedMeetingID,
            relativePath: MeetingTranscript.finalTranscriptRelativePath,
            purpose: MeetingTranscript.finalTranscriptPurpose
        )
        try store.writeJSONArtifact(
            RecordingSessionMetadata(
                meetingID: privateMeetingID,
                startedAt: Date(timeIntervalSince1970: 1_780_020_000),
                context: MeetingContext(),
                bookmarks: [
                    MeetingBookmark(
                        meetingID: privateMeetingID,
                        timestamp: 0.5,
                        createdAt: Date(timeIntervalSince1970: 1_780_020_001),
                        note: "Private board note"
                    )
                ]
            ),
            meetingID: requestedMeetingID,
            relativePath: RecordingSessionMetadata.relativePath,
            purpose: RecordingSessionMetadata.purpose
        )
        let provider = MockMeetingIntelligenceProvider(
            summary: MeetingSummary(
                title: "Unused",
                oneParagraph: "Unused",
                bullets: [],
                decisions: [],
                actionItems: []
            )
        )

        do {
            _ = try await MeetingIntelligenceService(provider: provider, bundleStore: store)
                .generateSummary(meetingID: requestedMeetingID)
            XCTFail("Expected copied metadata identity rejection")
        } catch {
            XCTAssertEqual(error as? RecordingSessionMetadataValidationError, .metadataMeetingMismatch)
            XCTAssertFalse(error.localizedDescription.contains("Private board note"))
        }
        XCTAssertTrue(provider.requests.isEmpty)
    }
    func testGroundedIntelligencePersistsEncryptedSummaryArtifact() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultIntelligence-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let vault = AESGCMDataVault(
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 31, count: 32))
        )
        let bundleStore = EncryptedMeetingBundleStore(rootDirectory: root, vault: vault)
        let meetingID = UUID()
        var manifest = MeetingBundleManifest.initialEncryptedBundle(
            meetingID: meetingID,
            title: "Launch review"
        )
        manifest.createdAt = Date(timeIntervalSince1970: 1_780_000_500)
        _ = try bundleStore.createBundle(manifest)

        let segmentID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let transcript = MeetingTranscript(
            meetingID: meetingID,
            localeIdentifier: "en-US",
            generatedAt: Date(timeIntervalSince1970: 1_780_000_560),
            segments: [
                TranscriptSegment(
                    id: segmentID,
                    speakerName: "Alex",
                    trackKind: .remoteSystem,
                    startTime: 42,
                    endTime: 49,
                    text: "QA sign-off blocks the Thursday launch.",
                    confidence: 0.94,
                    isFinal: true
                )
            ]
        )
        try bundleStore.writeJSONArtifact(
            transcript,
            meetingID: meetingID,
            relativePath: MeetingTranscript.finalTranscriptRelativePath,
            purpose: MeetingTranscript.finalTranscriptPurpose
        )

        let evidence = EvidenceRef(
            meetingID: meetingID,
            segmentID: segmentID,
            startTime: 42,
            endTime: 49,
            quote: "QA sign-off blocks the Thursday launch."
        )
        let summary = MeetingSummary(
            title: "Launch review",
            oneParagraph: "The launch remains blocked on QA sign-off.",
            bullets: ["QA sign-off is the release gate."],
            decisions: [
                Decision(
                    title: "Wait for QA",
                    details: "Do not launch until QA signs off.",
                    evidence: [evidence],
                    confidence: 0.92
                )
            ],
            actionItems: [
                ActionItem(
                    title: "Get QA sign-off",
                    ownerName: "You",
                    evidence: [evidence],
                    confidence: 0.87
                )
            ]
        )
        let provider = MockMeetingIntelligenceProvider(summary: summary)
        let service = MeetingIntelligenceService(
            provider: provider,
            bundleStore: bundleStore,
            now: { Date(timeIntervalSince1970: 1_780_000_620) }
        )

        let artifact = try await service.generateSummary(meetingID: meetingID)

        XCTAssertEqual(artifact.meetingID, meetingID)
        XCTAssertEqual(artifact.providerID, "mock-intelligence")
        XCTAssertEqual(artifact.summary, summary)
        XCTAssertEqual(provider.requests.map(\.meetingID), [meetingID])

        let stored = try bundleStore.readJSONArtifact(
            MeetingIntelligenceArtifact.self,
            meetingID: meetingID,
            relativePath: MeetingIntelligenceArtifact.summaryRelativePath,
            purpose: MeetingIntelligenceArtifact.summaryPurpose
        )
        XCTAssertEqual(stored, artifact)

        let artifactURL = bundleStore.bundleURL(for: meetingID)
            .appendingPathComponent(MeetingIntelligenceArtifact.summaryRelativePath)
        let storedBytes = try Data(contentsOf: artifactURL)
        XCTAssertFalse(String(decoding: storedBytes, as: UTF8.self).contains("QA sign-off"))
    }

    func testUngroundedIntelligenceIsRejectedBeforePersistence() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultUngroundedIntelligence-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let vault = AESGCMDataVault(
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 33, count: 32))
        )
        let bundleStore = EncryptedMeetingBundleStore(rootDirectory: root, vault: vault)
        let meetingID = UUID()
        _ = try bundleStore.createBundle(
            MeetingBundleManifest.initialEncryptedBundle(
                meetingID: meetingID,
                title: "Risk review"
            )
        )

        let segmentID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let transcript = MeetingTranscript(
            meetingID: meetingID,
            localeIdentifier: "en-US",
            generatedAt: Date(timeIntervalSince1970: 1_780_000_700),
            segments: [
                TranscriptSegment(
                    id: segmentID,
                    speakerName: "Sam",
                    trackKind: .remoteSystem,
                    startTime: 4,
                    endTime: 9,
                    text: "We need another QA pass before launch.",
                    confidence: 0.91,
                    isFinal: true
                )
            ]
        )
        try bundleStore.writeJSONArtifact(
            transcript,
            meetingID: meetingID,
            relativePath: MeetingTranscript.finalTranscriptRelativePath,
            purpose: MeetingTranscript.finalTranscriptPurpose
        )

        let evidence = EvidenceRef(
            meetingID: meetingID,
            segmentID: segmentID,
            startTime: 4,
            endTime: 9,
            quote: "Marketing approved the launch."
        )
        let provider = MockMeetingIntelligenceProvider(
            summary: MeetingSummary(
                title: "Risk review",
                oneParagraph: "The launch is approved.",
                bullets: [],
                decisions: [
                    Decision(
                        title: "Launch now",
                        details: "The provider claims approval.",
                        evidence: [evidence],
                        confidence: 0.8
                    )
                ],
                actionItems: []
            )
        )
        let service = MeetingIntelligenceService(provider: provider, bundleStore: bundleStore)

        do {
            _ = try await service.generateSummary(meetingID: meetingID)
            XCTFail("Expected ungrounded provider output to fail validation")
        } catch {
            XCTAssertEqual(
                error as? IntelligenceValidationError,
                .evidenceQuoteNotFound(segmentID: segmentID, quote: "Marketing approved the launch.")
            )
        }

        let artifactURL = bundleStore.bundleURL(for: meetingID)
            .appendingPathComponent(MeetingIntelligenceArtifact.summaryRelativePath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: artifactURL.path))
    }

    func testGroundedQuestionsAndRisksPersistAsIntelligenceArtifacts() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultQuestionRiskIntelligence-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let vault = AESGCMDataVault(
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 34, count: 32))
        )
        let bundleStore = EncryptedMeetingBundleStore(rootDirectory: root, vault: vault)
        let meetingID = UUID()
        _ = try bundleStore.createBundle(
            MeetingBundleManifest.initialEncryptedBundle(
                meetingID: meetingID,
                title: "Risk triage"
            )
        )

        let questionSegmentID = UUID(uuidString: "45454545-4545-4545-4545-454545454545")!
        let riskSegmentID = UUID(uuidString: "46464646-4646-4646-4646-464646464646")!
        let transcript = MeetingTranscript(
            meetingID: meetingID,
            localeIdentifier: "en-US",
            generatedAt: Date(timeIntervalSince1970: 1_780_000_760),
            segments: [
                TranscriptSegment(
                    id: questionSegmentID,
                    speakerName: "Sam",
                    trackKind: .remoteSystem,
                    startTime: 11,
                    endTime: 16,
                    text: "Who owns the final privacy review before release?",
                    confidence: 0.91,
                    isFinal: true
                ),
                TranscriptSegment(
                    id: riskSegmentID,
                    speakerName: "Anna",
                    trackKind: .remoteSystem,
                    startTime: 24,
                    endTime: 31,
                    text: "The biggest risk is that notarization fails on the release build.",
                    confidence: 0.93,
                    isFinal: true
                )
            ]
        )
        try bundleStore.writeJSONArtifact(
            transcript,
            meetingID: meetingID,
            relativePath: MeetingTranscript.finalTranscriptRelativePath,
            purpose: MeetingTranscript.finalTranscriptPurpose
        )

        let questionEvidence = EvidenceRef(
            meetingID: meetingID,
            segmentID: questionSegmentID,
            startTime: 11,
            endTime: 16,
            quote: "Who owns the final privacy review before release?"
        )
        let riskEvidence = EvidenceRef(
            meetingID: meetingID,
            segmentID: riskSegmentID,
            startTime: 24,
            endTime: 31,
            quote: "The biggest risk is that notarization fails on the release build."
        )
        let summary = MeetingSummary(
            title: "Risk triage",
            oneParagraph: "The release discussion surfaced an owner question and a notarization risk.",
            bullets: ["Privacy ownership is still open.", "Notarization is the main release risk."],
            decisions: [],
            actionItems: [],
            openQuestions: [
                OpenQuestion(
                    question: "Who owns the final privacy review?",
                    context: "Release cannot close until ownership is clear.",
                    evidence: [questionEvidence],
                    confidence: 0.88
                )
            ],
            risks: [
                MeetingRisk(
                    title: "Notarization can fail",
                    details: "The release build may fail notarization.",
                    severity: .high,
                    evidence: [riskEvidence],
                    confidence: 0.86
                )
            ]
        )
        let service = MeetingIntelligenceService(
            provider: MockMeetingIntelligenceProvider(summary: summary),
            bundleStore: bundleStore
        )

        let artifact = try await service.generateSummary(meetingID: meetingID)

        XCTAssertEqual(artifact.summary.openQuestions.first?.question, "Who owns the final privacy review?")
        XCTAssertEqual(artifact.summary.risks.first?.severity, .high)
        XCTAssertEqual(artifact.summary.openQuestions.first?.evidence.first?.quote, questionEvidence.quote)
        XCTAssertEqual(artifact.summary.risks.first?.evidence.first?.quote, riskEvidence.quote)
    }

    func testFoundationModelsProviderBuildsGroundedSummaryFromGeneratedJSON() async throws {
        let meetingID = UUID(uuidString: "71717171-7171-7171-7171-717171717171")!
        let decisionSegmentID = UUID(uuidString: "72727272-7272-7272-7272-727272727272")!
        let actionSegmentID = UUID(uuidString: "73737373-7373-7373-7373-737373737373")!
        let questionSegmentID = UUID(uuidString: "78787878-7878-7878-7878-787878787878")!
        let riskSegmentID = UUID(uuidString: "79797979-7979-7979-7979-797979797979")!
        let decisionQuote = "We will ship the local beta after QA signs off."
        let actionQuote = "Alex will prepare the notarization checklist by Friday."
        let questionQuote = "Who owns the privacy review before the release gate closes?"
        let riskQuote = "The notarization risk is still high if signing fails."
        let generator = CapturingFoundationModelsTextGenerator(
            response: """
            {
              "title": "Local beta launch",
              "oneParagraph": "The local beta can ship after QA approval and notarization prep.",
              "bullets": ["QA sign-off gates the beta.", "Notarization preparation is assigned."],
              "decisions": [
                {
                  "title": "Gate beta on QA",
                  "details": "The local beta should wait for QA sign-off.",
                  "segmentID": "\(decisionSegmentID.uuidString)",
                  "quote": "\(decisionQuote)",
                  "confidence": 1.2
                }
              ],
              "actionItems": [
                {
                  "title": "Prepare notarization checklist",
                  "ownerName": "Alex",
                  "dueAt": "2026-07-03T12:00:00Z",
                  "segmentID": "\(actionSegmentID.uuidString)",
                  "quote": "\(actionQuote)",
                  "confidence": -0.4
                }
              ],
              "openQuestions": [
                {
                  "question": "Who owns the privacy review?",
                  "context": "The release gate still needs privacy ownership.",
                  "segmentID": "\(questionSegmentID.uuidString)",
                  "quote": "\(questionQuote)",
                  "confidence": 0.81
                }
              ],
              "risks": [
                {
                  "title": "Signing can block release",
                  "details": "Notarization remains high risk if signing fails.",
                  "severity": "high",
                  "segmentID": "\(riskSegmentID.uuidString)",
                  "quote": "\(riskQuote)",
                  "confidence": 0.77
                }
              ]
            }
            """
        )
        let provider = FoundationModelsMeetingIntelligenceProvider(
            availabilityProvider: StubFoundationModelsAvailabilityProvider(
                status: FoundationModelsAvailabilityStatus(isAvailable: true)
            ),
            textGenerator: generator
        )

        let summary = try await provider.summarize(
            segments: [
                TranscriptSegment(
                    id: decisionSegmentID,
                    speakerName: "Anna",
                    trackKind: .remoteSystem,
                    startTime: 4,
                    endTime: 12,
                    text: decisionQuote,
                    confidence: 0.94,
                    isFinal: true
                ),
                TranscriptSegment(
                    id: actionSegmentID,
                    speakerName: "Alex",
                    trackKind: .microphone,
                    startTime: 14,
                    endTime: 22,
                    text: actionQuote,
                    confidence: 0.92,
                    isFinal: true
                ),
                TranscriptSegment(
                    id: questionSegmentID,
                    speakerName: "Maya",
                    trackKind: .remoteSystem,
                    startTime: 24,
                    endTime: 30,
                    text: questionQuote,
                    confidence: 0.90,
                    isFinal: true
                ),
                TranscriptSegment(
                    id: riskSegmentID,
                    speakerName: "Anna",
                    trackKind: .remoteSystem,
                    startTime: 34,
                    endTime: 41,
                    text: riskQuote,
                    confidence: 0.89,
                    isFinal: true
                )
            ],
            meetingID: meetingID
        )

        XCTAssertEqual(provider.id, "foundation-models-meeting-intelligence")
        XCTAssertEqual(summary.title, "Local beta launch")
        XCTAssertEqual(summary.decisions.first?.evidence.first?.segmentID, decisionSegmentID)
        XCTAssertEqual(summary.decisions.first?.evidence.first?.quote, decisionQuote)
        XCTAssertEqual(summary.decisions.first?.confidence, 1)
        XCTAssertEqual(summary.actionItems.first?.evidence.first?.segmentID, actionSegmentID)
        XCTAssertEqual(summary.actionItems.first?.ownerName, "Alex")
        XCTAssertEqual(summary.actionItems.first?.confidence, 0)
        XCTAssertEqual(summary.openQuestions.first?.question, "Who owns the privacy review?")
        XCTAssertEqual(summary.openQuestions.first?.evidence.first?.segmentID, questionSegmentID)
        XCTAssertEqual(summary.risks.first?.title, "Signing can block release")
        XCTAssertEqual(summary.risks.first?.severity, .high)
        XCTAssertEqual(summary.risks.first?.evidence.first?.segmentID, riskSegmentID)
        XCTAssertEqual(generator.requests.count, 1)
        let request = generator.requests[0]
        XCTAssertFalse(request.prompt.contains("Meeting ID:"))
        XCTAssertFalse(request.prompt.contains(meetingID.uuidString))
        XCTAssertEqual(request.structuredResponseKind, .meetingSummary)
        XCTAssertTrue(request.prompt.contains(decisionSegmentID.uuidString))
        XCTAssertTrue(request.prompt.contains(actionQuote))
        XCTAssertTrue(request.prompt.contains(questionQuote))
        XCTAssertTrue(request.prompt.contains("Return one JSON object"))
        XCTAssertTrue(request.prompt.contains("Include exactly one decision, one action item, one open question, and one risk"))
        XCTAssertTrue(request.prompt.contains("Use null for dueAt unless the transcript contains an explicit ISO-8601 calendar date"))
        XCTAssertTrue(request.instructions.contains("Do not invent"))
    }

    func testFoundationModelsPromptCarriesUserAuthoredBookmarkWithoutTreatingItAsConclusion() async throws {
        let meetingID = UUID()
        let segment = TranscriptSegment(
            speakerName: "Anna",
            trackKind: .remoteSystem,
            startTime: 1,
            endTime: 2,
            text: "The transcript remains the only source for conclusions.",
            confidence: 0.9,
            isFinal: true
        )
        let bookmark = MeetingBookmark(
            meetingID: meetingID,
            timestamp: 1.5,
            createdAt: Date(timeIntervalSince1970: 1_780_020_000),
            category: .decision,
            note: "Review this; it is not itself a decision"
        )
        let generator = CapturingFoundationModelsTextGenerator(
            response: """
            {
              "title": "Grounded",
              "oneParagraph": "The transcript remains authoritative.",
              "bullets": ["The transcript remains authoritative."],
              "decisions": [],
              "actionItems": []
            }
            """
        )
        let provider = FoundationModelsMeetingIntelligenceProvider(
            availabilityProvider: StubFoundationModelsAvailabilityProvider(
                status: FoundationModelsAvailabilityStatus(isAvailable: true)
            ),
            textGenerator: generator
        )

        _ = try await provider.summarize(
            segments: [segment],
            bookmarkEvidence: [MeetingIntelligenceBookmarkEvidence(bookmark: bookmark)],
            meetingID: meetingID
        )

        let request = try XCTUnwrap(generator.requests.first)
        XCTAssertTrue(request.prompt.contains("User-authored marked moments"))
        XCTAssertTrue(request.prompt.contains("Review this; it is not itself a decision"))
        XCTAssertTrue(request.prompt.contains("provenance=userAuthored"))
        XCTAssertTrue(request.instructions.contains("Marked moments are emphasis/context only"))
        XCTAssertTrue(request.instructions.contains("never decisions or action items without transcript evidence"))
    }

    func testFoundationModelsBoundsTenThousandBookmarksAndKeepsTranscriptAndProvenance() async throws {
        let meetingID = UUID()
        let segment = TranscriptSegment(
            speakerName: "Anna",
            trackKind: .remoteSystem,
            startTime: 5_000,
            endTime: 5_010,
            text: "Transcript headroom must remain available.",
            confidence: 0.9,
            isFinal: true
        )
        let bookmarks = (0..<RecordingSessionMetadata.maxBookmarks).map { index in
            MeetingIntelligenceBookmarkEvidence(
                bookmark: MeetingBookmark(
                    id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!,
                    meetingID: meetingID,
                    timestamp: Double(index),
                    createdAt: Date(timeIntervalSince1970: 1_780_030_000 + Double(index)),
                    category: .important,
                    note: String(repeating: "e", count: 512)
                )
            )
        }
        let generator = CapturingFoundationModelsTextGenerator(
            response: """
            {"title":"Bounded","oneParagraph":"Bounded.","bullets":["Bounded."],"decisions":[],"actionItems":[],"openQuestions":[],"risks":[]}
            """
        )
        let provider = FoundationModelsMeetingIntelligenceProvider(
            availabilityProvider: StubFoundationModelsAvailabilityProvider(
                status: FoundationModelsAvailabilityStatus(isAvailable: true)
            ),
            textGenerator: generator
        )

        _ = try await provider.summarize(
            segments: [segment],
            bookmarkEvidence: Array(bookmarks.reversed()),
            meetingID: meetingID
        )

        let request = try XCTUnwrap(generator.requests.first)
        XCTAssertLessThanOrEqual(request.prompt.utf8.count, 16_384)
        XCTAssertTrue(request.prompt.contains(segment.id.uuidString))
        XCTAssertTrue(request.prompt.contains(segment.text))
        XCTAssertTrue(request.prompt.contains("provenance=userAuthored"))
        XCTAssertLessThanOrEqual(
            request.prompt.components(separatedBy: "provenance=userAuthored").count - 1,
            FoundationModelsMeetingIntelligenceProvider.maximumBookmarkEvidenceCount
        )
    }

    func testFoundationModelsClassifiesInvalidBookmarkEvidenceAsInputError() async throws {
        let meetingID = UUID()
        let provider = FoundationModelsMeetingIntelligenceProvider(
            availabilityProvider: StubFoundationModelsAvailabilityProvider(
                status: FoundationModelsAvailabilityStatus(isAvailable: true)
            ),
            textGenerator: CapturingFoundationModelsTextGenerator(response: "{}")
        )
        do {
            _ = try await provider.summarize(
                segments: [
                    TranscriptSegment(
                        speakerName: "Anna",
                        trackKind: .remoteSystem,
                        startTime: 0,
                        endTime: 1,
                        text: "Safe transcript",
                        confidence: 0.9,
                        isFinal: true
                    )
                ],
                bookmarkEvidence: [
                    MeetingIntelligenceBookmarkEvidence(
                        bookmark: MeetingBookmark(
                            meetingID: UUID(),
                            timestamp: 0.5,
                            createdAt: Date()
                        )
                    )
                ],
                meetingID: meetingID
            )
            XCTFail("Expected invalid bookmark input")
        } catch {
            XCTAssertEqual(
                error as? FoundationModelsMeetingIntelligenceError,
                .invalidBookmarkEvidence
            )
        }
    }

    func testFoundationModelsProviderFailsClosedWhenModelUnavailable() async throws {
        let generator = CapturingFoundationModelsTextGenerator(response: "{}")
        let provider = FoundationModelsMeetingIntelligenceProvider(
            availabilityProvider: StubFoundationModelsAvailabilityProvider(
                status: FoundationModelsAvailabilityStatus(
                    isAvailable: false,
                    reason: "Apple Intelligence is not enabled."
                )
            ),
            textGenerator: generator
        )

        do {
            _ = try await provider.summarize(
                segments: [
                    TranscriptSegment(
                        speakerName: "Anna",
                        trackKind: .remoteSystem,
                        startTime: 1,
                        endTime: 3,
                        text: "We need QA before launch.",
                        confidence: 0.9,
                        isFinal: true
                    )
                ],
                meetingID: UUID(uuidString: "74747474-7474-7474-7474-747474747474")!
            )
            XCTFail("Expected unavailable Foundation Models to fail closed")
        } catch {
            XCTAssertEqual(
                error as? FoundationModelsMeetingIntelligenceError,
                .modelUnavailable("Apple Intelligence is not enabled.")
            )
        }

        XCTAssertTrue(generator.requests.isEmpty)
    }

    func testFoundationModelsProviderRejectsUnknownEvidenceSegmentBeforeValidation() async throws {
        let provider = FoundationModelsMeetingIntelligenceProvider(
            availabilityProvider: StubFoundationModelsAvailabilityProvider(
                status: FoundationModelsAvailabilityStatus(isAvailable: true)
            ),
            textGenerator: CapturingFoundationModelsTextGenerator(
                response: """
                {
                  "title": "Invalid evidence",
                  "oneParagraph": "Provider cited an unknown segment.",
                  "bullets": [],
                  "decisions": [
                    {
                      "title": "Unknown",
                      "details": "Unknown",
                      "segmentID": "75757575-7575-7575-7575-757575757575",
                      "quote": "Missing quote",
                      "confidence": 0.5
                    }
                  ],
                  "actionItems": []
                }
                """
            )
        )

        do {
            _ = try await provider.summarize(
                segments: [
                    TranscriptSegment(
                        id: UUID(uuidString: "76767676-7676-7676-7676-767676767676")!,
                        speakerName: "Sam",
                        trackKind: .remoteSystem,
                        startTime: 1,
                        endTime: 2,
                        text: "Only this segment exists.",
                        confidence: 0.9,
                        isFinal: true
                    )
                ],
                meetingID: UUID(uuidString: "77777777-7777-7777-7777-777777777777")!
            )
            XCTFail("Expected unknown segment citation to fail closed")
        } catch {
            XCTAssertEqual(
                error as? FoundationModelsMeetingIntelligenceError,
                .unknownEvidenceSegment("75757575-7575-7575-7575-757575757575")
            )
        }
    }

    func testFoundationModelsProviderChunksLongTranscriptWithinModelContext() async throws {
        let generator = ContextBoundFoundationModelsTextGenerator()
        let provider = FoundationModelsMeetingIntelligenceProvider(
            availabilityProvider: StubFoundationModelsAvailabilityProvider(
                status: FoundationModelsAvailabilityStatus(isAvailable: true)
            ),
            textGenerator: generator
        )
        let segments = (0..<3).map { index in
            TranscriptSegment(
                speakerName: "Speaker \(index)",
                trackKind: .remoteSystem,
                startTime: Double(index * 10),
                endTime: Double(index * 10 + 8),
                text: "Chunk \(index) contains grounded meeting content.",
                confidence: 0.9,
                isFinal: true
            )
        }

        let summary = try await provider.summarize(segments: segments, meetingID: UUID())

        XCTAssertEqual(generator.requests.count, 3)
        XCTAssertTrue(generator.requests.allSatisfy { request in
            segments.filter { request.prompt.contains($0.id.uuidString) }.count == 1
        })
        XCTAssertEqual(summary.title, "Chunked meeting")
        XCTAssertEqual(summary.bullets, ["Grounded chunk summary"])
    }
}

private struct StubFoundationModelsAvailabilityProvider: FoundationModelsAvailabilityProviding {
    var status: FoundationModelsAvailabilityStatus

    func currentAvailability() -> FoundationModelsAvailabilityStatus {
        status
    }
}

private final class CapturingFoundationModelsTextGenerator: FoundationModelsTextGenerating, @unchecked Sendable {
    private let response: String
    private let lock = NSLock()
    private var _requests: [FoundationModelsTextGenerationRequest] = []

    var requests: [FoundationModelsTextGenerationRequest] {
        lock.withLock { _requests }
    }

    init(response: String) {
        self.response = response
    }

    let contextSize = 100_000

    func tokenCount(for request: FoundationModelsTextGenerationRequest) async throws -> Int {
        request.maximumResponseTokens + request.instructions.count + request.prompt.count
    }

    func generateText(_ request: FoundationModelsTextGenerationRequest) async throws -> String {
        lock.withLock {
            _requests.append(request)
        }
        return response
    }
}

private final class ContextBoundFoundationModelsTextGenerator: FoundationModelsTextGenerating, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [FoundationModelsTextGenerationRequest] = []

    let contextSize = 3_200

    var requests: [FoundationModelsTextGenerationRequest] {
        lock.withLock { _requests }
    }

    func tokenCount(for request: FoundationModelsTextGenerationRequest) async throws -> Int {
        let segmentCount = request.prompt
            .components(separatedBy: .newlines)
            .filter { $0.hasPrefix("[") }
            .count
        return request.maximumResponseTokens + 500 + (segmentCount * 1_200)
    }

    func generateText(_ request: FoundationModelsTextGenerationRequest) async throws -> String {
        lock.withLock { _requests.append(request) }
        return """
        {
          "title": "Chunked meeting",
          "oneParagraph": "Grounded chunk summary.",
          "bullets": ["Grounded chunk summary"],
          "decisions": [],
          "actionItems": [],
          "openQuestions": [],
          "risks": []
        }
        """
    }
}
