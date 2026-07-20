import Foundation

public protocol MeetingSystemIntegrationExecuting: Sendable {
    func executeSystemIntegration(
        proposals: [MeetingSystemIntegrationProposal],
        executedAt: Date
    ) throws -> [MeetingSystemIntegrationWriteReceipt]
}

public struct MeetingSystemIntegrationExecutionService: Sendable {
    private let executor: (any MeetingSystemIntegrationExecuting)?

    public init(executor: (any MeetingSystemIntegrationExecuting)? = nil) {
        self.executor = executor
    }

    public func executeConfirmedWrites(
        review: MeetingSystemIntegrationReview?,
        confirmed: Bool,
        executedAt: Date = Date()
    ) throws -> MeetingSystemIntegrationExecutionResult {
        guard confirmed else {
            throw MeetingSystemIntegrationExecutionError.confirmationRequired
        }
        guard let review, !review.proposals.isEmpty else {
            throw MeetingSystemIntegrationExecutionError.noPreparedReview
        }
        guard let executor else {
            throw MeetingSystemIntegrationExecutionError.executorUnavailable
        }

        let writeReadyProposals = review.proposals.map { proposal in
            var proposal = proposal
            proposal.executionMode = .readyForConfirmedWrite
            proposal.requiresUserConfirmation = true
            return proposal
        }
        let receipts = try executor.executeSystemIntegration(
            proposals: writeReadyProposals,
            executedAt: executedAt
        )
        let counts = Dictionary(grouping: writeReadyProposals, by: \.kind)
            .mapValues(\.count)
        let auditMetadata: [String: String] = [
            "meetingID": review.meetingID.uuidString,
            "proposalCount": "\(writeReadyProposals.count)",
            "receiptCount": "\(receipts.count)",
            "calendarEventCount": "\(counts[.calendarEvent] ?? 0)",
            "reminderCount": "\(counts[.reminder] ?? 0)",
            "contactReviewCount": "\(counts[.contactReview] ?? 0)",
            "externalWritePrepared": "true",
            "externalWriteExecuted": receipts.isEmpty ? "false" : "true"
        ]

        return MeetingSystemIntegrationExecutionResult(
            meetingID: review.meetingID,
            executedAt: executedAt,
            receipts: receipts,
            externalWriteExecuted: !receipts.isEmpty,
            auditMetadata: auditMetadata,
            statusSummary: "Confirmed \(receipts.count) Calendar, Contacts, or Reminders write(s)."
        )
    }
}
