import AppIntents
import Foundation
import MeetingVaultCore

struct OpenMeetingVaultRecorderIntent: AppIntent {
    static let title: LocalizedStringResource = "Open MeetingVault Recorder"
    static let description = IntentDescription("Open MeetingVault to the Recorder workspace.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let plan = MeetingAutomationPlanner().plan(
            MeetingAutomationRequest(
                action: .openRecorder,
                surface: .appIntent,
                localOnlyMode: true,
                approval: .userConfirmed
            )
        )
        MeetingVaultAppHandoffCenter.shared.route(.openRecorder)
        return .result(dialog: IntentDialog(stringLiteral: plan.reviewSummary))
    }
}

struct CheckMeetingVaultReadinessIntent: AppIntent {
    static let title: LocalizedStringResource = "Check MeetingVault Readiness"
    static let description = IntentDescription("Open Recorder and refresh recording permissions, input, and readiness.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let plan = MeetingAutomationPlanner().plan(
            MeetingAutomationRequest(
                action: .runPreflight,
                surface: .appIntent,
                localOnlyMode: true,
                approval: .userConfirmed
            )
        )
        MeetingVaultAppHandoffCenter.shared.route(.runPreflight)
        return .result(dialog: IntentDialog(stringLiteral: plan.reviewSummary))
    }
}

struct StartMeetingVaultRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Start MeetingVault Recording"
    static let description = IntentDescription("Open Recorder and start recording through the same preflight gate as the app button.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let plan = MeetingAutomationPlanner().plan(
            MeetingAutomationRequest(
                action: .startRecording,
                surface: .appIntent,
                sourceID: "selected-input",
                localOnlyMode: true,
                approval: .userConfirmed
            )
        )
        MeetingVaultAppHandoffCenter.shared.route(.startRecording)
        return .result(dialog: IntentDialog(stringLiteral: plan.reviewSummary))
    }
}

struct StopMeetingVaultRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop MeetingVault Recording"
    static let description = IntentDescription("Open Recorder and stop the current recording for local processing.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let plan = MeetingAutomationPlanner().plan(
            MeetingAutomationRequest(
                action: .stopRecording,
                surface: .appIntent,
                localOnlyMode: true,
                approval: .userConfirmed
            )
        )
        MeetingVaultAppHandoffCenter.shared.route(.stopRecording)
        return .result(dialog: IntentDialog(stringLiteral: plan.reviewSummary))
    }
}

struct MarkMeetingVaultMomentIntent: AppIntent {
    static let title: LocalizedStringResource = "Mark MeetingVault Moment"
    static let description = IntentDescription("Save the current moment in the active encrypted recording.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let operation = MeetingVaultAppHandoffCenter.shared.routeMarkMoment() else {
            return .result(
                dialog: IntentDialog(
                    stringLiteral: "Open MeetingVault and start recording before marking a moment."
                )
            )
        }
        switch await operation.outcome() {
        case .saved:
            return .result(dialog: "The marked moment was saved in the encrypted recording.")
        case .failed:
            return .result(dialog: "The marked moment could not be saved.")
        }
    }
}

struct PrepareMeetingVaultShareIntent: AppIntent {
    static let title: LocalizedStringResource = "Prepare MeetingVault Share"
    static let description = IntentDescription("Open Intelligence exports so a local share can be reviewed and explicitly prepared.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let plan = MeetingAutomationPlanner().plan(
            MeetingAutomationRequest(
                action: .prepareShare,
                surface: .appIntent,
                meetingID: UUID(),
                localOnlyMode: true,
                approval: .userConfirmed
            )
        )
        MeetingVaultAppHandoffCenter.shared.route(.prepareShare)
        return .result(dialog: IntentDialog(stringLiteral: plan.reviewSummary))
    }
}

struct MeetingVaultAppShortcuts: AppShortcutsProvider {
    static let shortcutTileColor: ShortcutTileColor = .blue

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenMeetingVaultRecorderIntent(),
            phrases: [
                "Open Recorder in \(.applicationName)",
                "Show \(.applicationName) Recorder"
            ],
            shortTitle: "Open Recorder",
            systemImageName: "waveform.circle"
        )
        AppShortcut(
            intent: CheckMeetingVaultReadinessIntent(),
            phrases: [
                "Check \(.applicationName) readiness",
                "Run \(.applicationName) preflight"
            ],
            shortTitle: "Check Recording Readiness",
            systemImageName: "checkmark.shield"
        )
        AppShortcut(
            intent: StartMeetingVaultRecordingIntent(),
            phrases: [
                "Start recording in \(.applicationName)",
                "Begin \(.applicationName) recording"
            ],
            shortTitle: "Start Recording",
            systemImageName: "record.circle"
        )
        AppShortcut(
            intent: StopMeetingVaultRecordingIntent(),
            phrases: [
                "Stop recording in \(.applicationName)",
                "Finish \(.applicationName) recording"
            ],
            shortTitle: "Stop Recording",
            systemImageName: "stop.circle"
        )
        AppShortcut(
            intent: MarkMeetingVaultMomentIntent(),
            phrases: [
                "Mark this moment in \(.applicationName)",
                "Bookmark this in \(.applicationName)"
            ],
            shortTitle: "Mark Moment",
            systemImageName: "bookmark.fill"
        )
        AppShortcut(
            intent: PrepareMeetingVaultShareIntent(),
            phrases: [
                "Prepare \(.applicationName) share",
                "Prepare local share in \(.applicationName)"
            ],
            shortTitle: "Prepare Local Share",
            systemImageName: "square.and.arrow.up"
        )
    }
}
