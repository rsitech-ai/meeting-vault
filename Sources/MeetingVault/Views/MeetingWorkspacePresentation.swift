import Foundation
import MeetingVaultCore

enum MeetingInspectorMode: String, CaseIterable, Identifiable {
    case agent
    case details

    var id: String { rawValue }

    static func launchMode(from arguments: [String]) -> MeetingInspectorMode? {
        guard let index = arguments.firstIndex(of: "--meeting-inspector"),
              arguments.indices.contains(arguments.index(after: index)) else {
            return nil
        }
        return MeetingInspectorMode(
            rawValue: arguments[arguments.index(after: index)]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
        )
    }
}

enum MeetingInspectorDestination: String, CaseIterable, Identifiable {
    case importRecording
    case setup
    case review
    case export

    var id: String { rawValue }
}

enum MeetingWorkspaceRouteTarget: Equatable {
    case inspector(MeetingsWorkspaceFocus)
    case healthWindow
}

struct HealthRecoveryPresentationEvent: Equatable {
    var revision: Int

    static func next(after previous: HealthRecoveryPresentationEvent?) -> HealthRecoveryPresentationEvent {
        HealthRecoveryPresentationEvent(revision: (previous?.revision ?? 0) + 1)
    }
}

enum HealthRecoveryPresentation {
    static let windowID = "health-recovery"
}

enum MeetingRecordingTransportAction: Equatable {
    case start
    case stop
}

struct MeetingRecordingTransportPresentation: Equatable {
    var title: String
    var symbol: String
    var statusTitle: String
    var statusSymbol: String
    var detail: String
    var accessibilityLabel: String
    var accessibilityHint: String
    var action: MeetingRecordingTransportAction?

    var isEnabled: Bool { action != nil }
}

struct ActiveRecordingPresentation: Equatable, Sendable {
    let meetingID: UUID
    let startedAt: Date
    let sourceName: String
    let microphoneDeviceName: String?

    init(request: RecordingProcessingRequest) {
        meetingID = request.meetingID
        startedAt = request.startedAt
        sourceName = request.sourceName
        microphoneDeviceName = request.microphoneDeviceName
    }
}

struct RecordingBookmarkPresentation: Equatable, Sendable {
    var isEnabled: Bool
    var detail: String
    let title = "Mark Moment"
    let systemImage = "bookmark.fill"
    let accessibilityLabel = "Mark recording moment"
}

struct RecordingBookmarkNativeObservation: Equatable, Sendable {
    var acceptedCount: UInt64
    var lastStableIdentifier: UUID?

    var accessibilityValue: String {
        "accepted \(acceptedCount); last \(lastStableIdentifier?.uuidString.lowercased() ?? "none")"
    }
}

enum RecordingElapsedTime {
    static func elapsed(startedAt: Date, now: Date) -> TimeInterval {
        max(0, now.timeIntervalSince(startedAt))
    }
}

struct MeetingWorkspacePresentationEvent: Equatable {
    var focus: MeetingsWorkspaceFocus
    var revision: Int

    static func next(
        focus: MeetingsWorkspaceFocus,
        after previous: MeetingWorkspacePresentationEvent?
    ) -> MeetingWorkspacePresentationEvent {
        MeetingWorkspacePresentationEvent(
            focus: focus,
            revision: (previous?.revision ?? 0) + 1
        )
    }
}

struct MeetingWorkspaceInspectorPresentation: Equatable {
    var mode: MeetingInspectorMode
    var isPresented: Bool
}

enum MeetingWorkspacePresentation {
    static func initialEvent(from arguments: [String]) -> MeetingWorkspacePresentationEvent? {
        guard case let .inspector(focus) = initialRouteTarget(from: arguments) else { return nil }
        return .next(focus: focus, after: nil)
    }

    static func initialRouteTarget(from arguments: [String]) -> MeetingWorkspaceRouteTarget? {
        MeetingsWorkspaceFocus.launchFocus(from: arguments).map { routeTarget(for: $0) }
    }

    static func inspectorMode(for focus: MeetingsWorkspaceFocus) -> MeetingInspectorMode {
        focus == .understand ? .agent : .details
    }

    static func initialInspectorMode(
        persisted: MeetingInspectorMode,
        explicitLaunchMode: MeetingInspectorMode?,
        launchFocus: MeetingsWorkspaceFocus?
    ) -> MeetingInspectorMode {
        if let explicitLaunchMode {
            return explicitLaunchMode
        }
        if let launchFocus {
            return inspectorMode(for: launchFocus)
        }
        return persisted
    }

    static func destination(for focus: MeetingsWorkspaceFocus) -> MeetingInspectorDestination? {
        switch focus {
        case .find: .importRecording
        case .record: .setup
        case .understand: nil
        case .review: .review
        case .export: .export
        case .recover: nil
        }
    }

    static func routeTarget(for focus: MeetingsWorkspaceFocus) -> MeetingWorkspaceRouteTarget {
        focus == .recover ? .healthWindow : .inspector(focus)
    }

    static func focus(for destination: MeetingInspectorDestination) -> MeetingsWorkspaceFocus {
        switch destination {
        case .importRecording: .find
        case .setup: .record
        case .review: .review
        case .export: .export
        }
    }

    static func inspectorMode(
        current: MeetingInspectorMode,
        afterExplicitRouteTo focus: MeetingsWorkspaceFocus?
    ) -> MeetingInspectorMode {
        guard let focus else { return current }
        return inspectorMode(for: focus)
    }

    static func inspectorPresentation(
        current: MeetingWorkspaceInspectorPresentation,
        after event: MeetingWorkspacePresentationEvent?
    ) -> MeetingWorkspaceInspectorPresentation {
        guard let event else { return current }
        return MeetingWorkspaceInspectorPresentation(
            mode: inspectorMode(for: event.focus),
            isPresented: true
        )
    }

    static func recordingTransport(
        state: RecordingState,
        canStart: Bool,
        canStop: Bool,
        blockerDetail: String = ""
    ) -> MeetingRecordingTransportPresentation {
        let title: String
        let symbol: String
        let action: MeetingRecordingTransportAction?

        switch state {
        case .recording:
            title = "Stop Recording"
            symbol = "stop.fill"
            action = canStop ? .stop : nil
        case .processing:
            title = "Finalizing…"
            symbol = "hourglass"
            action = nil
        case .paused:
            title = "Recovery Required"
            symbol = "cross.case"
            action = nil
        case .permissionNeeded, .error:
            title = "Start Recording"
            symbol = "record.circle"
            action = nil
        case .idle, .ready:
            title = "Start Recording"
            symbol = "record.circle"
            action = canStart ? .start : nil
        case .recovered:
            title = "Recovery Complete"
            symbol = "checkmark.circle"
            action = nil
        }

        let statusTitle: String
        let statusSymbol: String
        let accessibilityLabel: String
        let accessibilityHint: String
        switch state {
        case .recording:
            statusTitle = "Recording"
            statusSymbol = "record.circle.fill"
            accessibilityLabel = "Stop Recording"
            accessibilityHint = "Stops recording and starts final transcription."
        case .paused:
            statusTitle = "Recovery required"
            statusSymbol = "cross.case"
            accessibilityLabel = "Recording Recovery Required"
            accessibilityHint = blockerDetail
        case .processing:
            statusTitle = "Finalizing…"
            statusSymbol = "progress.indicator"
            accessibilityLabel = "Finalizing Recording"
            accessibilityHint = blockerDetail
        case .permissionNeeded:
            statusTitle = "Setup needed"
            statusSymbol = "exclamationmark.shield"
            accessibilityLabel = "Start Recording"
            accessibilityHint = blockerDetail
        case .error:
            statusTitle = "Recording unavailable"
            statusSymbol = "cross.case"
            accessibilityLabel = "Start Recording"
            accessibilityHint = blockerDetail
        case .recovered:
            statusTitle = "Recovered"
            statusSymbol = "checkmark.circle"
            accessibilityLabel = "Recording Recovered"
            accessibilityHint = blockerDetail
        case .idle, .ready:
            statusTitle = "Ready"
            statusSymbol = "checkmark.circle"
            accessibilityLabel = "Start Recording"
            accessibilityHint = blockerDetail
        }

        return MeetingRecordingTransportPresentation(
            title: title,
            symbol: symbol,
            statusTitle: statusTitle,
            statusSymbol: statusSymbol,
            detail: blockerDetail,
            accessibilityLabel: accessibilityLabel,
            accessibilityHint: accessibilityHint,
            action: action
        )
    }
}

extension MeetingVaultStore {
    var recordingTransportPresentation: MeetingRecordingTransportPresentation {
        MeetingWorkspacePresentation.recordingTransport(
            state: recordingState,
            canStart: canStartRecording,
            canStop: canStopRecording,
            blockerDetail: recordingTransportDetail
        )
    }

    private var recordingTransportDetail: String {
        switch recordingState {
        case .permissionNeeded:
            return recordingReadinessDetail
        case .error:
            return recordingProcessingStatus
        case .paused:
            return "Open Health & Recovery to recover this paused recording. \(recordingProcessingStatus)"
        case .processing:
            return recordingProcessingProgress?.message ?? recordingProcessingStatus
        case .recording:
            return activeRecordingPresentation?.microphoneDeviceName.map { "Recording with \($0)" }
                ?? activeRecordingPresentation.map { "Recording \($0.sourceName)" }
                ?? "Recording with the selected capture source"
        case .recovered:
            return "Recovered audio is safe. Start a new recording when ready."
        case .idle, .ready:
            return selectedAudioInputDevice.map { "Ready with \($0.displayName)" }
                ?? recordingReadinessDetail
        }
    }
}
