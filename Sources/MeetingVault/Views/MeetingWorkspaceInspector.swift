import SwiftUI

struct MeetingWorkspaceInspector: View {
    @EnvironmentObject private var store: MeetingVaultStore
    @Binding var mode: MeetingInspectorMode
    @Binding var focusedSection: MeetingsWorkspaceFocus
    @Binding var selectedIntelligenceTab: IntelligenceWorkspaceTab
    var route: (MeetingsWorkspaceFocus) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Picker("Inspector", selection: $mode) {
                Text("Agent").tag(MeetingInspectorMode.agent)
                Text("Details").tag(MeetingInspectorMode.details)
            }
            .pickerStyle(.segmented)
            .padding(12)

            Divider()

            Group {
                switch mode {
                case .agent:
                    agentContent
                case .details:
                    detailsContent
                }
            }
            .transition(.opacity)
        }
        .onChange(of: mode) { _, newMode in
            if newMode == .agent {
                route(.understand)
            }
        }
        .accessibilityIdentifier("meeting-workspace-inspector")
    }

    private var agentContent: some View {
        ScrollView {
            LibraryTranscriptPromptBlock()
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .accessibilityIdentifier("meetings-section-understand-content")
    }

    private var detailsContent: some View {
        VStack(spacing: 0) {
            detailsRouteMenu
                .padding(12)

            Divider()

            Group {
                if let destination = MeetingWorkspacePresentation.destination(for: focusedSection) {
                    advancedContent(destination)
                } else {
                    selectedMeetingDetails
                }
            }
        }
    }

    private var selectedMeetingDetails: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let meeting = store.selectedMeeting {
                    VStack(alignment: .leading, spacing: 12) {
                        VaultSectionHeader(
                            "Meeting Details",
                            subtitle: meeting.title,
                            systemImage: "info.circle"
                        )
                        detailRow("Status", value: meeting.state.displayTitle)
                        detailRow("Started", value: meeting.startedAt.formatted(date: .abbreviated, time: .shortened))
                        detailRow("Duration", value: durationText(meeting.durationSeconds))
                        detailRow("Source", value: meeting.sourceName)
                        detailRow("Consent", value: meeting.consentStatus.rawValue)
                    }
                    .vaultGlassPanel(cornerRadius: 18, tint: meeting.state.statusTint)
                } else {
                    ContentUnavailableView(
                        "No Meeting Selected",
                        systemImage: "waveform.badge.magnifyingglass",
                        description: Text("Select a meeting from the sidebar to inspect its details.")
                    )
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .accessibilityIdentifier("meeting-details-content")
    }

    private var detailsRouteMenu: some View {
        HStack {
            Label("Details", systemImage: "sidebar.trailing")
                .font(.headline)
            Spacer()
            Menu {
                destinationButton(.importRecording, title: "Import Recording", systemImage: "waveform.badge.plus")
                destinationButton(.setup, title: "Recording Setup", systemImage: "slider.horizontal.3")
                destinationButton(.review, title: "Review Meeting", systemImage: "rectangle.stack")
                destinationButton(.export, title: "Export Meeting", systemImage: "square.and.arrow.up")
                Divider()
                Button {
                    store.requestHealthRecoveryPresentation()
                } label: {
                    Label("Health & Diagnostics", systemImage: "cross.case")
                }
                .accessibilityIdentifier("meetings-section-recover-control")
            } label: {
                Label("Show", systemImage: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
        }
    }

    private func destinationButton(
        _ destination: MeetingInspectorDestination,
        title: String,
        systemImage: String
    ) -> some View {
        let focus = MeetingWorkspacePresentation.focus(for: destination)
        return Button {
            route(focus)
        } label: {
            Label(title, systemImage: systemImage)
        }
        .accessibilityIdentifier(focus.controlAccessibilityIdentifier)
    }

    @ViewBuilder
    private func advancedContent(_ destination: MeetingInspectorDestination) -> some View {
        switch destination {
        case .importRecording:
            importContent
        case .setup:
            setupContent
        case .review:
            reviewContent
        case .export:
            exportContent
        }
    }

    private var importContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                LocalRecordingImportBlock()
                LibraryAgentRouteBlock()
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .accessibilityIdentifier("meetings-section-find-content")
    }

    private var setupContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                LiveTransportCard()
                MeetingContextEditor()
                    .disabled(!captureSetupIsEditable)
                TranscriptionSetupCard()
                audioInputControls
                    .disabled(!captureSetupIsEditable)
                RecorderReadinessStrip()
                SourcePickerBlock()
                    .disabled(!captureSetupIsEditable)
                PreflightBlock(
                    result: store.preflightResult,
                    recoveryActions: store.permissionRecoveryActions
                )
                ProcessingStatusBlock()
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .accessibilityIdentifier("meetings-section-record-content")
    }

    private var captureSetupIsEditable: Bool {
        store.recordingState != .recording
            && store.recordingState != .processing
            && !store.recordingStartInFlight
    }

    private var audioInputControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            VaultSectionHeader(
                "Audio Input",
                subtitle: "Choose the microphone or headset track for your voice.",
                systemImage: "mic"
            )

            audioInputPicker
                .frame(maxWidth: .infinity)

            HStack(spacing: 8) {
                Button {
                    Task { await store.refreshAudioInputDevices() }
                } label: {
                    Label("Detect", systemImage: "arrow.triangle.2.circlepath")
                }
                .help("Detect connected microphones, Bluetooth headsets, and other audio inputs")

                Button {
                    store.runPreflight()
                } label: {
                    Label(store.latestPreflightResult == nil ? "Check Status" : "Check Again", systemImage: "checkmark.shield")
                }
                .help("Check recording readiness with current permissions and audio input")
            }
        }
        .vaultGlassPanel(cornerRadius: 18, tint: .blue)
        .accessibilityIdentifier("primary-audio-input-selection")
    }

    private var audioInputPicker: some View {
        Picker("Audio Input", selection: audioInputSelection) {
            if store.audioInputDevices.isEmpty {
                Text("Auto-detect input").tag("")
            } else {
                ForEach(store.audioInputDevices) { device in
                    Text("\(device.displayName) · \(device.transportLabel)")
                        .tag(device.id)
                }
            }
        }
        .labelsHidden()
    }

    private var audioInputSelection: Binding<String> {
        Binding(
            get: { store.selectedAudioInputDeviceID ?? "" },
            set: { store.selectAudioInputDevice(id: $0.isEmpty ? nil : $0) }
        )
    }

    private var reviewContent: some View {
        ConfidenceReviewView()
        .accessibilityIdentifier("meetings-section-review-content")
    }

    private var exportContent: some View {
        ExportPane()
            .padding(16)
            .accessibilityIdentifier("meetings-section-export-content")
    }

    private func detailRow(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .multilineTextAlignment(.trailing)
        }
        .font(.callout)
    }

    private func durationText(_ duration: TimeInterval) -> String {
        let totalMinutes = max(0, Int(duration / 60))
        return totalMinutes == 1 ? "1 minute" : "\(totalMinutes) minutes"
    }
}
