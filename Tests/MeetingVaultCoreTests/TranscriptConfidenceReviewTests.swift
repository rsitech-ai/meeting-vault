import Foundation
import XCTest
@testable import MeetingVaultCore

final class TranscriptConfidenceReviewTests: XCTestCase {
    private let meetingID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    private let segmentID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!

    func testNilConfidenceCreatesNoIssueButTrueZeroDoes() throws {
        let service = TranscriptConfidenceReviewService()
        let transcript = transcript(confidence: 0)

        let noIssue = try service.deriveQueue(
            transcript: transcript,
            evidence: [try evidence(confidence: nil)],
            transcriptVersion: 1
        )
        XCTAssertTrue(noIssue.activeItems.isEmpty)
        XCTAssertTrue(noIssue.evidenceComplete)

        let zero = try service.deriveQueue(
            transcript: transcript,
            evidence: [try evidence(confidence: 0)],
            transcriptVersion: 1
        )
        XCTAssertEqual(zero.activeItems.map(\.reason), [.lowConfidence])
        XCTAssertEqual(zero.activeItems.first?.confidence, 0)
    }

    func testEvidenceRejectsNonFiniteAndOutOfRangeValuesAndInvalidBounds() {
        for value in [Double.nan, -.leastNonzeroMagnitude, 1.000_000_1] {
            XCTAssertThrowsError(try evidence(confidence: value)) { error in
                XCTAssertEqual(error as? TranscriptReviewValidationError, .invalidConfidence)
            }
        }
        XCTAssertThrowsError(
            try TranscriptSegmentEvidence(
                segmentID: segmentID,
                trackKind: .remoteSystem,
                startTime: 2,
                endTime: 2,
                confidence: 0.5,
                speakerConfidence: 0.5,
                overlapsSpeech: false,
                reconstructedFromPreviewGap: false,
                providerConfigurationVersion: "provider-v1"
            )
        ) { error in
            XCTAssertEqual(error as? TranscriptReviewValidationError, .invalidTimeRange)
        }
    }

    func testExactThresholdsAreNotFlaggedAndJustBelowAreFlagged() throws {
        let service = TranscriptConfidenceReviewService(
            transcriptConfidenceThreshold: 0.70,
            speakerConfidenceThreshold: 0.65
        )
        let exact = try service.deriveQueue(
            transcript: transcript(confidence: 0.70),
            evidence: [try evidence(confidence: 0.70, speakerConfidence: 0.65)],
            transcriptVersion: 1
        )
        XCTAssertTrue(exact.activeItems.isEmpty)

        let below = try service.deriveQueue(
            transcript: transcript(confidence: 0.699_999),
            evidence: [try evidence(confidence: 0.699_999, speakerConfidence: 0.649_999)],
            transcriptVersion: 1
        )
        XCTAssertEqual(Set(below.activeItems.map(\.reason)), Set([.lowConfidence, .uncertainSpeaker]))
    }

    func testAllProviderEvidenceReasonsAreDerivedWithStableIDs() throws {
        let service = TranscriptConfidenceReviewService()
        let evidence = try evidence(
            confidence: 0.9,
            speakerConfidence: 0.9,
            overlaps: true,
            reconstructed: true,
            speakerWasRevised: true
        )
        let first = try service.deriveQueue(
            transcript: transcript(confidence: 0.9),
            evidence: [evidence],
            transcriptVersion: 3
        )
        let second = try service.deriveQueue(
            transcript: transcript(confidence: 0.9),
            evidence: [evidence],
            transcriptVersion: 3
        )
        XCTAssertEqual(Set(first.activeItems.map(\.reason)), Set([.revisedSpeaker, .overlap, .reconstructedPreviewGap]))
        XCTAssertEqual(first.activeItems.map(\.id), second.activeItems.map(\.id))
    }

    func testReconciliationPreservesResolvedAndDeferredStateAndSupersedesOldIdentity() throws {
        let service = TranscriptConfidenceReviewService()
        var old = try service.deriveQueue(
            transcript: transcript(confidence: 0.1),
            evidence: [try evidence(confidence: 0.1, overlaps: true)],
            transcriptVersion: 1
        )
        let lowID = try XCTUnwrap(old.activeItems.first(where: { $0.reason == .lowConfidence })?.id)
        let overlapID = try XCTUnwrap(old.activeItems.first(where: { $0.reason == .overlap })?.id)
        try old.updateStatus(itemID: lowID, status: .resolved)
        try old.updateStatus(itemID: overlapID, status: .deferred)

        let changedID = UUID(uuidString: "30000000-0000-0000-0000-000000000003")!
        let changedTranscript = MeetingTranscript(
            meetingID: meetingID,
            localeIdentifier: "en-US",
            segments: [segment(id: changedID, confidence: 0.1)]
        )
        let changedEvidence = try TranscriptSegmentEvidence(
            segmentID: changedID,
            trackKind: .remoteSystem,
            startTime: 10,
            endTime: 14,
            confidence: 0.1,
            speakerConfidence: 0.9,
            overlapsSpeech: true,
            reconstructedFromPreviewGap: false,
            providerConfigurationVersion: "provider-v1"
        )
        let reconciled = try service.deriveQueue(
            transcript: changedTranscript,
            evidence: [changedEvidence],
            transcriptVersion: 2,
            previous: old
        )

        XCTAssertEqual(reconciled.items.first(where: { $0.segmentID == changedID && $0.reason == .lowConfidence })?.status, .resolved)
        XCTAssertEqual(reconciled.items.first(where: { $0.segmentID == changedID && $0.reason == .overlap })?.status, .deferred)
        XCTAssertEqual(reconciled.items.first(where: { $0.id == lowID })?.status, .superseded)
        XCTAssertEqual(reconciled.items.first(where: { $0.id == overlapID })?.status, .superseded)
    }

    func testQueueRoundTripsEncryptedAndRejectsCrossMeetingLoad() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ReviewQueue-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EncryptedMeetingBundleStore(
            rootDirectory: root,
            vault: AESGCMDataVault(keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 41, count: 32)))
        )
        _ = try store.createBundle(.initialEncryptedBundle(meetingID: meetingID, title: "Review"))
        let repository = TranscriptReviewRepository(bundleStore: store)
        let queue = try TranscriptConfidenceReviewService(
            now: { Date(timeIntervalSince1970: 1_780_000_000) }
        ).deriveQueue(
            transcript: transcript(confidence: 0.2),
            evidence: [try evidence(confidence: 0.2)],
            transcriptVersion: 1
        )

        try repository.save(queue)
        XCTAssertEqual(try repository.load(meetingID: meetingID), queue)
        let bytes = try Data(contentsOf: store.bundleURL(for: meetingID).appendingPathComponent(TranscriptReviewQueue.relativePath))
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("provider-v1"))

        var crossed = queue
        crossed.meetingID = UUID()
        try store.writeJSONArtifact(crossed, meetingID: meetingID, relativePath: TranscriptReviewQueue.relativePath, purpose: TranscriptReviewQueue.purpose)
        XCTAssertThrowsError(try repository.load(meetingID: meetingID)) { error in
            XCTAssertEqual(error as? TranscriptReviewRepositoryError, .meetingMismatch)
        }
    }

    func testDuplicateEvidenceIsRejectedAndAmbiguousFallbackDoesNotInheritResolution() throws {
        let service = TranscriptConfidenceReviewService()
        let baseEvidence = try evidence(confidence: 0.1)
        XCTAssertThrowsError(try service.deriveQueue(
            transcript: transcript(confidence: 0.1),
            evidence: [baseEvidence, baseEvidence],
            transcriptVersion: 1
        )) { error in
            XCTAssertEqual(error as? TranscriptReviewValidationError, .duplicateSegmentID)
        }

        let oldFirst = try TranscriptReviewItem(
            id: UUID(), segmentID: UUID(), trackKind: .remoteSystem,
            startTime: 10, endTime: 14, reason: .lowConfidence, confidence: 0.1,
            status: .resolved, transcriptVersion: 1, providerConfigurationVersion: "provider-v1"
        )
        let oldSecond = try TranscriptReviewItem(
            id: UUID(), segmentID: UUID(), trackKind: .remoteSystem,
            startTime: 10.1, endTime: 14.1, reason: .lowConfidence, confidence: 0.1,
            status: .deferred, transcriptVersion: 1, providerConfigurationVersion: "provider-v1"
        )
        let oldQueue = try TranscriptReviewQueue(
            meetingID: meetingID,
            transcriptDigest: "old",
            transcriptVersion: 1,
            evidenceComplete: true,
            generatedAt: Date(timeIntervalSince1970: 1),
            items: [oldFirst, oldSecond]
        )
        let reconciled = try service.deriveQueue(
            transcript: transcript(confidence: 0.1),
            evidence: [baseEvidence],
            transcriptVersion: 2,
            previous: oldQueue
        )
        XCTAssertEqual(reconciled.items.first(where: { $0.segmentID == segmentID })?.status, .needsReview)
        XCTAssertEqual(reconciled.items.filter { $0.status == .superseded }.count, 2)
    }

    func testProviderConfigurationChangeSupersedesInsteadOfInheritingResolvedState() throws {
        let service = TranscriptConfidenceReviewService()
        var old = try service.deriveQueue(
            transcript: transcript(confidence: 0.1),
            evidence: [try evidence(confidence: 0.1)],
            transcriptVersion: 1
        )
        let oldID = try XCTUnwrap(old.activeItems.first?.id)
        try old.updateStatus(itemID: oldID, status: .resolved)
        let newEvidence = try TranscriptSegmentEvidence(
            segmentID: segmentID,
            trackKind: .remoteSystem,
            startTime: 10,
            endTime: 14,
            confidence: 0.1,
            speakerConfidence: 0.9,
            overlapsSpeech: false,
            reconstructedFromPreviewGap: false,
            providerConfigurationVersion: "provider-v2"
        )

        let changed = try service.deriveQueue(
            transcript: transcript(confidence: 0.1),
            evidence: [newEvidence],
            transcriptVersion: 2,
            previous: old
        )

        XCTAssertEqual(changed.activeItems.first?.status, .needsReview)
        XCTAssertEqual(changed.activeItems.first?.providerConfigurationVersion, "provider-v2")
        XCTAssertEqual(changed.items.first(where: { $0.id == oldID })?.status, .superseded)
    }

    private func transcript(confidence: Double) -> MeetingTranscript {
        MeetingTranscript(meetingID: meetingID, localeIdentifier: "en-US", segments: [segment(id: segmentID, confidence: confidence)])
    }

    private func segment(id: UUID, confidence: Double) -> TranscriptSegment {
        TranscriptSegment(id: id, speakerName: "Speaker 1", trackKind: .remoteSystem, startTime: 10, endTime: 14, text: "Review this exact line", confidence: confidence, isFinal: true)
    }

    private func evidence(
        confidence: Double?,
        speakerConfidence: Double? = 0.9,
        overlaps: Bool = false,
        reconstructed: Bool = false,
        speakerWasRevised: Bool = false
    ) throws -> TranscriptSegmentEvidence {
        try TranscriptSegmentEvidence(
            segmentID: segmentID,
            trackKind: .remoteSystem,
            startTime: 10,
            endTime: 14,
            confidence: confidence,
            speakerConfidence: speakerConfidence,
            overlapsSpeech: overlaps,
            reconstructedFromPreviewGap: reconstructed,
            speakerWasRevised: speakerWasRevised,
            providerConfigurationVersion: "provider-v1"
        )
    }
}
