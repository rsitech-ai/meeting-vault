import SwiftUI
import MeetingVaultCore

struct MeetingWorkspaceSidebar: View {
    @EnvironmentObject private var store: MeetingVaultStore
    @Binding var searchText: String
    @Binding var pendingDeleteMeeting: MeetingRecord?
    var onImport: () -> Void

    private var filteredMeetings: [MeetingRecord] {
        guard !searchText.isEmpty else { return store.meetings }
        return store.meetings.filter {
            $0.title.localizedCaseInsensitiveContains(searchText)
                || $0.sourceName.localizedCaseInsensitiveContains(searchText)
                || ($0.summary?.oneParagraph.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }

    private var meetingSelectionBinding: Binding<UUID?> {
        Binding(
            get: { store.selectedMeetingID },
            set: { selection in
                if let selection {
                    store.selectedMeetingID = selection
                } else if store.meetings.isEmpty {
                    store.selectedMeetingID = nil
                }
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if filteredMeetings.isEmpty {
                    ContentUnavailableView {
                        Label(searchText.isEmpty ? "No Recordings Yet" : "No Matches", systemImage: "tray")
                    } description: {
                        Text(searchText.isEmpty ? "Start or import a recording." : "Clear search to show all recordings.")
                    }
                } else {
                    List(selection: meetingSelectionBinding) {
                        Section("Meetings") {
                            ForEach(filteredMeetings) { meeting in
                                MeetingLibraryRow(
                                    meeting: meeting,
                                    selected: meeting.id == store.selectedMeetingID,
                                    onDelete: {
                                        store.selectedMeetingID = meeting.id
                                        pendingDeleteMeeting = meeting
                                    }
                                )
                                .tag(meeting.id)
                            }
                        }
                    }
                    .listStyle(.sidebar)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text(store.libraryDeleteStatus)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Button(action: onImport) {
                    Label("Import Local Recording", systemImage: "waveform.badge.plus")
                        .frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(.glass)
                .help("Open local transcript and recording import tools")
            }
            .padding(12)
        }
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search meetings")
        .accessibilityIdentifier("meeting-workspace-sidebar")
    }
}
