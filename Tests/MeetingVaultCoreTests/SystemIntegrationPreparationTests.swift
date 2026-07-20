import Foundation
import XCTest
@testable import MeetingVaultCore

final class SystemIntegrationPreparationTests: XCTestCase {
    func testSystemIntegrationPreparationBuildsReviewOnlyCalendarReminderAndContactProposals() throws {
        let meetingID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let actionID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let evidenceID = UUID(uuidString: "99999999-8888-7777-6666-555555555555")!
        let dueDate = Date(timeIntervalSince1970: 1_800_000_000)
        let meeting = SearchMeeting(
            id: meetingID,
            title: "Launch review",
            startedAt: Date(timeIntervalSince1970: 1_799_900_000),
            sourceApp: "Microsoft Teams"
        )
        let summary = MeetingSummary(
            title: "Launch review",
            oneParagraph: "Private launch detail should not appear in audit metadata.",
            bullets: [],
            decisions: [],
            actionItems: [
                ActionItem(
                    id: actionID,
                    title: "Send the launch checklist to QA",
                    ownerName: "Anna",
                    dueDate: dueDate,
                    evidence: [
                        EvidenceRef(
                            id: evidenceID,
                            meetingID: meetingID,
                            segmentID: UUID(uuidString: "ABABABAB-1111-2222-3333-ABABABABABAB")!,
                            startTime: 42,
                            endTime: 51,
                            quote: "Send the launch checklist to QA"
                        )
                    ],
                    confidence: 0.92
                )
            ]
        )

        let review = try MeetingSystemIntegrationPreparationService().prepareReview(
            meeting: meeting,
            summary: summary,
            generatedAt: Date(timeIntervalSince1970: 1_800_001_000)
        )

        XCTAssertEqual(review.meetingID, meetingID)
        XCTAssertEqual(review.proposals.map(\.kind), [.calendarEvent, .reminder, .contactReview])
        XCTAssertTrue(review.proposals.allSatisfy { $0.executionMode == .reviewOnly })
        XCTAssertTrue(review.proposals.allSatisfy(\.requiresUserConfirmation))
        XCTAssertFalse(review.externalWritePrepared)
        XCTAssertEqual(review.proposals.map(\.sourceActionItemID), [actionID, actionID, actionID])
        XCTAssertEqual(review.proposals.first { $0.kind == .calendarEvent }?.scheduledAt, dueDate)
        XCTAssertEqual(review.proposals.first { $0.kind == .reminder }?.ownerName, "Anna")
        XCTAssertEqual(review.proposals.first { $0.kind == .contactReview }?.ownerName, "Anna")
        XCTAssertEqual(review.auditMetadata["meetingID"], meetingID.uuidString)
        XCTAssertEqual(review.auditMetadata["proposalCount"], "3")
        XCTAssertEqual(review.auditMetadata["calendarEventCount"], "1")
        XCTAssertEqual(review.auditMetadata["reminderCount"], "1")
        XCTAssertEqual(review.auditMetadata["contactReviewCount"], "1")

        let auditMetadata = review.auditMetadata.values.joined(separator: " ")
        XCTAssertFalse(auditMetadata.contains("Send the launch checklist"))
        XCTAssertFalse(auditMetadata.contains("Private launch detail"))
        XCTAssertFalse(auditMetadata.contains("Anna"))
    }

    func testSystemIntegrationPreparationFailsClosedWithoutActionableItems() {
        let meeting = SearchMeeting(
            id: UUID(),
            title: "Empty sync",
            startedAt: Date(timeIntervalSince1970: 1_800_002_000),
            sourceApp: "Microsoft Teams"
        )
        let summary = MeetingSummary(
            title: "Empty sync",
            oneParagraph: "No actions.",
            bullets: [],
            decisions: [],
            actionItems: []
        )

        XCTAssertThrowsError(
            try MeetingSystemIntegrationPreparationService().prepareReview(
                meeting: meeting,
                summary: summary
            )
        ) { error in
            XCTAssertEqual(error as? MeetingSystemIntegrationPreparationError, .noActionableItems)
        }
    }

    func testSystemIntegrationExecutionRequiresConfirmationAndExecutor() throws {
        let review = try makeReview()
        let service = MeetingSystemIntegrationExecutionService()

        XCTAssertThrowsError(
            try service.executeConfirmedWrites(review: review, confirmed: false)
        ) { error in
            XCTAssertEqual(error as? MeetingSystemIntegrationExecutionError, .confirmationRequired)
        }

        XCTAssertThrowsError(
            try service.executeConfirmedWrites(review: review, confirmed: true)
        ) { error in
            XCTAssertEqual(error as? MeetingSystemIntegrationExecutionError, .executorUnavailable)
        }

        XCTAssertThrowsError(
            try service.executeConfirmedWrites(review: nil, confirmed: true)
        ) { error in
            XCTAssertEqual(error as? MeetingSystemIntegrationExecutionError, .noPreparedReview)
        }
    }

    func testSystemIntegrationExecutionUsesInjectedExecutorAndRedactsAuditMetadata() throws {
        let executedAt = Date(timeIntervalSince1970: 1_800_003_000)
        let review = try makeReview()
        let executor = CapturingSystemIntegrationExecutor()
        let service = MeetingSystemIntegrationExecutionService(executor: executor)

        let result = try service.executeConfirmedWrites(
            review: review,
            confirmed: true,
            executedAt: executedAt
        )

        XCTAssertEqual(result.meetingID, review.meetingID)
        XCTAssertEqual(result.receipts.count, 3)
        XCTAssertTrue(result.externalWriteExecuted)
        XCTAssertEqual(result.auditMetadata["proposalCount"], "3")
        XCTAssertEqual(result.auditMetadata["receiptCount"], "3")
        XCTAssertEqual(result.auditMetadata["calendarEventCount"], "1")
        XCTAssertEqual(result.auditMetadata["reminderCount"], "1")
        XCTAssertEqual(result.auditMetadata["contactReviewCount"], "1")
        XCTAssertEqual(result.auditMetadata["externalWritePrepared"], "true")
        XCTAssertEqual(result.auditMetadata["externalWriteExecuted"], "true")
        XCTAssertEqual(executor.lastProposals?.map(\.executionMode), [.readyForConfirmedWrite, .readyForConfirmedWrite, .readyForConfirmedWrite])
        XCTAssertTrue(executor.lastProposals?.allSatisfy(\.requiresUserConfirmation) ?? false)

        let auditMetadata = result.auditMetadata.values.joined(separator: " ")
        XCTAssertFalse(auditMetadata.contains("Send the launch checklist"))
        XCTAssertFalse(auditMetadata.contains("Private launch detail"))
        XCTAssertFalse(auditMetadata.contains("Anna"))
    }

    private func makeReview() throws -> MeetingSystemIntegrationReview {
        let meetingID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let actionID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let evidenceID = UUID(uuidString: "99999999-8888-7777-6666-555555555555")!
        let dueDate = Date(timeIntervalSince1970: 1_800_000_000)
        let meeting = SearchMeeting(
            id: meetingID,
            title: "Launch review",
            startedAt: Date(timeIntervalSince1970: 1_799_900_000),
            sourceApp: "Microsoft Teams"
        )
        let summary = MeetingSummary(
            title: "Launch review",
            oneParagraph: "Private launch detail should not appear in audit metadata.",
            bullets: [],
            decisions: [],
            actionItems: [
                ActionItem(
                    id: actionID,
                    title: "Send the launch checklist to QA",
                    ownerName: "Anna",
                    dueDate: dueDate,
                    evidence: [
                        EvidenceRef(
                            id: evidenceID,
                            meetingID: meetingID,
                            segmentID: UUID(uuidString: "ABABABAB-1111-2222-3333-ABABABABABAB")!,
                            startTime: 42,
                            endTime: 51,
                            quote: "Send the launch checklist to QA"
                        )
                    ],
                    confidence: 0.92
                )
            ]
        )

        return try MeetingSystemIntegrationPreparationService().prepareReview(
            meeting: meeting,
            summary: summary,
            generatedAt: Date(timeIntervalSince1970: 1_800_001_000)
        )
    }
}

private final class CapturingSystemIntegrationExecutor: MeetingSystemIntegrationExecuting, @unchecked Sendable {
    var lastProposals: [MeetingSystemIntegrationProposal]?

    func executeSystemIntegration(
        proposals: [MeetingSystemIntegrationProposal],
        executedAt: Date
    ) throws -> [MeetingSystemIntegrationWriteReceipt] {
        lastProposals = proposals
        return proposals.map { proposal in
            MeetingSystemIntegrationWriteReceipt(
                proposalID: proposal.id,
                kind: proposal.kind,
                executedAt: executedAt
            )
        }
    }
}
