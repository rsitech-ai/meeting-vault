import Contacts
import EventKit
import Foundation
import MeetingVaultCore

protocol CalendarReminderWriting: AnyObject {
    var eventAuthorizationStatus: EKAuthorizationStatus { get }
    var reminderAuthorizationStatus: EKAuthorizationStatus { get }

    func saveCalendarEvent(
        title: String,
        notes: String,
        scheduledAt: Date
    ) throws

    func saveReminder(
        title: String,
        notes: String,
        dueDate: Date?
    ) throws
}

protocol ContactReviewWriting: AnyObject {
    var contactAuthorizationStatus: CNAuthorizationStatus { get }

    func saveContactReview(
        displayName: String,
        note: String
    ) throws
}

final class MeetingVaultSystemIntegrationExecutor: MeetingSystemIntegrationExecuting, @unchecked Sendable {
    private let calendarReminderWriter: CalendarReminderWriting
    private let contactWriter: ContactReviewWriting

    init(
        calendarReminderWriter: CalendarReminderWriting = EventKitCalendarReminderWriter(),
        contactWriter: ContactReviewWriting = ContactsReviewWriter()
    ) {
        self.calendarReminderWriter = calendarReminderWriter
        self.contactWriter = contactWriter
    }

    func executeSystemIntegration(
        proposals: [MeetingSystemIntegrationProposal],
        executedAt: Date
    ) throws -> [MeetingSystemIntegrationWriteReceipt] {
        try preflightPermissions(for: proposals)

        var receipts: [MeetingSystemIntegrationWriteReceipt] = []
        for proposal in proposals {
            do {
                switch proposal.kind {
                case .calendarEvent:
                    guard let scheduledAt = proposal.scheduledAt else {
                        throw MeetingSystemIntegrationExecutionError.missingCalendarSchedule
                    }
                    try calendarReminderWriter.saveCalendarEvent(
                        title: proposal.title,
                        notes: proposal.note,
                        scheduledAt: scheduledAt
                    )
                case .reminder:
                    try calendarReminderWriter.saveReminder(
                        title: proposal.title,
                        notes: proposal.note,
                        dueDate: proposal.scheduledAt
                    )
                case .contactReview:
                    guard let ownerName = proposal.ownerName?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !ownerName.isEmpty
                    else {
                        throw MeetingSystemIntegrationExecutionError.missingContactName
                    }
                    try contactWriter.saveContactReview(
                        displayName: ownerName,
                        note: proposal.note
                    )
                }
                receipts.append(
                    MeetingSystemIntegrationWriteReceipt(
                        proposalID: proposal.id,
                        kind: proposal.kind,
                        executedAt: executedAt
                    )
                )
            } catch {
                throw MeetingSystemIntegrationPartialWriteError(
                    meetingID: proposal.meetingID,
                    failedProposalID: proposal.id,
                    executedAt: executedAt,
                    receipts: receipts,
                    failureMessage: error.localizedDescription
                )
            }
        }
        return receipts
    }

    private func preflightPermissions(for proposals: [MeetingSystemIntegrationProposal]) throws {
        let kinds = Set(proposals.map(\.kind))
        if kinds.contains(.calendarEvent),
           !Self.eventKitAccessGranted(calendarReminderWriter.eventAuthorizationStatus) {
            throw MeetingSystemIntegrationExecutionError.calendarPermissionRequired
        }
        if kinds.contains(.reminder),
           !Self.eventKitAccessGranted(calendarReminderWriter.reminderAuthorizationStatus) {
            throw MeetingSystemIntegrationExecutionError.remindersPermissionRequired
        }
        if kinds.contains(.contactReview),
           contactWriter.contactAuthorizationStatus != .authorized {
            throw MeetingSystemIntegrationExecutionError.contactsPermissionRequired
        }
    }

    private static func eventKitAccessGranted(_ status: EKAuthorizationStatus) -> Bool {
        switch status {
        case .authorized, .fullAccess, .writeOnly:
            true
        case .notDetermined, .restricted, .denied:
            false
        @unknown default:
            false
        }
    }
}

private final class EventKitCalendarReminderWriter: CalendarReminderWriting {
    private let providedStore: EKEventStore?
    private let calendar: Calendar
    private lazy var store = providedStore ?? EKEventStore()

    init(store: EKEventStore? = nil, calendar: Calendar = .current) {
        self.providedStore = store
        self.calendar = calendar
    }

    var eventAuthorizationStatus: EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    var reminderAuthorizationStatus: EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .reminder)
    }

    func saveCalendarEvent(
        title: String,
        notes: String,
        scheduledAt: Date
    ) throws {
        let event = EKEvent(eventStore: store)
        event.title = title
        event.notes = notes
        event.startDate = scheduledAt
        event.endDate = scheduledAt.addingTimeInterval(30 * 60)
        event.calendar = store.defaultCalendarForNewEvents
        try store.save(event, span: .thisEvent, commit: true)
    }

    func saveReminder(
        title: String,
        notes: String,
        dueDate: Date?
    ) throws {
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.notes = notes
        if let dueDate {
            reminder.dueDateComponents = calendar.dateComponents([.year, .month, .day], from: dueDate)
        }
        reminder.calendar = store.defaultCalendarForNewReminders()
        try store.save(reminder, commit: true)
    }
}

private final class ContactsReviewWriter: ContactReviewWriting {
    private let providedStore: CNContactStore?
    private lazy var store = providedStore ?? CNContactStore()

    init(store: CNContactStore? = nil) {
        self.providedStore = store
    }

    var contactAuthorizationStatus: CNAuthorizationStatus {
        CNContactStore.authorizationStatus(for: .contacts)
    }

    func saveContactReview(
        displayName: String,
        note: String
    ) throws {
        let contact = CNMutableContact()
        let parts = displayName.split(separator: " ", maxSplits: 1).map(String.init)
        contact.givenName = parts.first ?? displayName
        if parts.count > 1 {
            contact.familyName = parts[1]
        }
        contact.note = note

        let request = CNSaveRequest()
        request.add(contact, toContainerWithIdentifier: nil)
        try store.execute(request)
    }
}
