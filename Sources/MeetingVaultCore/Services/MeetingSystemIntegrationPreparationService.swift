import Foundation

public enum MeetingSystemIntegrationPreparationError: Error, Equatable, LocalizedError, Sendable {
    case noActionableItems

    public var errorDescription: String? {
        switch self {
        case .noActionableItems:
            "No action items are available for Calendar, Contacts, or Reminders review."
        }
    }
}

public struct MeetingSystemIntegrationPreparationService: Sendable {
    public init() {}

    public func prepareReview(
        meeting: SearchMeeting,
        summary: MeetingSummary,
        generatedAt: Date = Date()
    ) throws -> MeetingSystemIntegrationReview {
        let proposals = proposals(for: meeting, summary: summary)
        guard !proposals.isEmpty else {
            throw MeetingSystemIntegrationPreparationError.noActionableItems
        }

        let counts = Dictionary(grouping: proposals, by: \.kind)
            .mapValues(\.count)
        let auditMetadata: [String: String] = [
            "meetingID": meeting.id.uuidString,
            "proposalCount": "\(proposals.count)",
            "calendarEventCount": "\(counts[.calendarEvent] ?? 0)",
            "reminderCount": "\(counts[.reminder] ?? 0)",
            "contactReviewCount": "\(counts[.contactReview] ?? 0)",
            "externalWritePrepared": "false"
        ]

        return MeetingSystemIntegrationReview(
            meetingID: meeting.id,
            generatedAt: generatedAt,
            proposals: proposals,
            externalWritePrepared: false,
            auditMetadata: auditMetadata,
            reviewSummary: "Prepared \(proposals.count) local review proposal(s). No Calendar, Contacts, or Reminders changes were written."
        )
    }

    private func proposals(
        for meeting: SearchMeeting,
        summary: MeetingSummary
    ) -> [MeetingSystemIntegrationProposal] {
        summary.actionItems.flatMap { action in
            proposals(for: action, meeting: meeting)
        }
    }

    private func proposals(
        for action: ActionItem,
        meeting: SearchMeeting
    ) -> [MeetingSystemIntegrationProposal] {
        var result: [MeetingSystemIntegrationProposal] = []

        if let dueDate = action.dueDate {
            result.append(
                MeetingSystemIntegrationProposal(
                    kind: .calendarEvent,
                    meetingID: meeting.id,
                    sourceActionItemID: action.id,
                    title: "Follow up: \(action.title)",
                    note: note(for: action, meeting: meeting),
                    ownerName: action.ownerName,
                    scheduledAt: dueDate,
                    evidence: action.evidence
                )
            )
        }

        result.append(
            MeetingSystemIntegrationProposal(
                kind: .reminder,
                meetingID: meeting.id,
                sourceActionItemID: action.id,
                title: action.title,
                note: note(for: action, meeting: meeting),
                ownerName: action.ownerName,
                scheduledAt: action.dueDate,
                evidence: action.evidence
            )
        )

        if let ownerName = action.ownerName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !ownerName.isEmpty {
            result.append(
                MeetingSystemIntegrationProposal(
                    kind: .contactReview,
                    meetingID: meeting.id,
                    sourceActionItemID: action.id,
                    title: "Review contact: \(ownerName)",
                    note: "Review whether \(ownerName) should be linked to this meeting follow-up before any Contacts change.",
                    ownerName: ownerName,
                    scheduledAt: nil,
                    evidence: action.evidence
                )
            )
        }

        return result
    }

    private func note(for action: ActionItem, meeting: SearchMeeting) -> String {
        var pieces = ["From \(meeting.title)."]
        if let ownerName = action.ownerName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !ownerName.isEmpty {
            pieces.append("Owner: \(ownerName).")
        }
        pieces.append("Evidence segments: \(action.evidence.count).")
        return pieces.joined(separator: " ")
    }
}
