import AppKit
import Foundation
import MeetingVaultCore

@MainActor
final class MeetingVaultAppHandoffCenter {
    static let shared = MeetingVaultAppHandoffCenter()

    private weak var store: MeetingVaultStore?
    private var pendingActions: [MeetingAutomationAction] = []

    private init() {}

    func register(store: MeetingVaultStore) {
        self.store = store
        drainPendingActions()
    }

    @discardableResult
    func route(_ action: MeetingAutomationAction) -> Bool {
        guard let store else {
            pendingActions.append(action)
            return false
        }

        apply(action, to: store)
        return true
    }

    @discardableResult
    func routeMarkMoment() -> RecordingBookmarkOperation? {
        guard let store else { return nil }
        return store.markMomentIntent()
    }

    private func drainPendingActions() {
        guard let store, !pendingActions.isEmpty else { return }
        let actions = pendingActions
        pendingActions.removeAll()
        actions.forEach { apply($0, to: store) }
    }

    private func apply(_ action: MeetingAutomationAction, to store: MeetingVaultStore) {
        if let application = NSApp {
            application.activate(ignoringOtherApps: true)
        }
        switch action {
        case .openRecorder:
            store.showWorkspace(.record)
        case .runPreflight:
            store.showWorkspace(.record)
            store.runPreflight()
        case .startRecording:
            store.showWorkspace(.record)
            store.startRecordingIntent()
        case .stopRecording:
            store.showWorkspace(.record)
            store.stopRecordingIntent()
        case .prepareShare:
            store.showWorkspace(.export)
            store.shareStatus = "Review the selected meeting export, then choose Prepare Local Share."
        case .sendWebhook:
            store.showWorkspace(.recover)
        }
    }
}
