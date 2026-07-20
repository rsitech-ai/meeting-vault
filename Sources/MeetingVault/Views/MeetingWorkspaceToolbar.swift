import SwiftUI

struct MeetingWorkspaceToolbar: ToolbarContent {
    @EnvironmentObject private var store: MeetingVaultStore
    @Binding var isInspectorPresented: Bool
    var route: (MeetingsWorkspaceFocus) -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            selectedMeetingContext
        }

        ToolbarItem(placement: .secondaryAction) {
            recordingStatus
        }

        ToolbarItem(placement: .secondaryAction) {
            AppearancePicker()
                .controlSize(.small)
                .fixedSize(horizontal: true, vertical: false)
        }

        ToolbarItem(placement: .navigation) {
            Button(action: recordingAction) {
                Label(transport.title, systemImage: transport.symbol)
            }
            .tint(transport.action == .stop ? .red : nil)
            .disabled(!transport.isEnabled)
            .help(recordingHelp)
            .accessibilityLabel(transport.accessibilityLabel)
            .accessibilityHint(transport.accessibilityHint)
            .accessibilityIdentifier("primary-recording-transport")
        }

        ToolbarItem(placement: .secondaryAction) {
            Button {
                isInspectorPresented.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
                    .labelStyle(.iconOnly)
            }
            .accessibilityLabel("Inspector")
            .help(isInspectorPresented ? "Hide inspector" : "Show inspector")
        }

        ToolbarItem(placement: .navigation) {
            Menu {
                Button("Import Recording") { route(.find) }
                    .accessibilityIdentifier("meetings-section-find-control")
                Button("Recording Setup") { route(.record) }
                    .accessibilityIdentifier("meetings-section-record-control")
                Button("Review Meeting") { route(.review) }
                    .accessibilityIdentifier("meetings-section-review-control")
                Button("Export Meeting") { route(.export) }
                    .accessibilityIdentifier("meetings-section-export-control")
                Divider()
                Button("Health & Diagnostics") { route(.recover) }
                    .accessibilityIdentifier("meetings-section-recover-control")
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .accessibilityIdentifier("meeting-workspace-more-menu")
        }
    }

    private var selectedMeetingContext: some View {
        Group {
            if let meeting = store.selectedMeeting {
                VStack(alignment: .leading, spacing: 1) {
                    Text(meeting.title)
                        .font(.headline)
                        .lineLimit(1)
                    Label(meeting.state.displayTitle, systemImage: meeting.state.statusSymbol)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Selected meeting, \(meeting.title), \(meeting.state.displayTitle)")
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Meetings")
                        .font(.headline)
                    Text("No meeting selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("No meeting selected")
            }
        }
        .frame(maxWidth: 280, alignment: .leading)
        .accessibilityIdentifier("selected-meeting-toolbar-context")
    }

    private var recordingStatus: some View {
        Label(transport.statusTitle, systemImage: transport.statusSymbol)
            .font(.caption.monospacedDigit())
            .foregroundStyle(transport.action == .stop ? .red : .secondary)
            .accessibilityIdentifier("recording-toolbar-status")
    }

    private var transport: MeetingRecordingTransportPresentation {
        store.recordingTransportPresentation
    }

    private var recordingHelp: String {
        transport.accessibilityHint
    }

    private func recordingAction() {
        switch transport.action {
        case .start:
            store.startRecordingIntent()
        case .stop:
            store.stopRecordingIntent()
        case nil:
            break
        }
    }
}
