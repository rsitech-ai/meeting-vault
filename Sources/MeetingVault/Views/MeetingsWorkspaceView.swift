import SwiftUI
import MeetingVaultCore

struct MeetingsWorkspaceView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var store: MeetingVaultStore
    @Binding var focusedSection: MeetingsWorkspaceFocus
    @Binding var selectedIntelligenceTab: IntelligenceWorkspaceTab
    var presentationEvent: MeetingWorkspacePresentationEvent?
    var launchInspectorMode: MeetingInspectorMode?
    @SceneStorage("meetingWorkspaceInspectorPresented") private var isInspectorPresented = true
    @SceneStorage("meetingWorkspaceInspectorMode") private var inspectorModeValue = MeetingInspectorMode.agent.rawValue
    @State private var searchText = ""
    @State private var pendingDeleteMeeting: MeetingRecord?
    @State private var routePresentationEvent: MeetingWorkspacePresentationEvent?

    private var inspectorMode: Binding<MeetingInspectorMode> {
        Binding(
            get: { MeetingInspectorMode(rawValue: inspectorModeValue) ?? .agent },
            set: { inspectorModeValue = $0.rawValue }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if let runtimeInitializationError = store.runtimeInitializationError {
                Label(
                    "Encrypted library unavailable: \(runtimeInitializationError)",
                    systemImage: "exclamationmark.shield.fill"
                )
                .font(.callout)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.red.opacity(0.08))
                .accessibilityIdentifier("library-initialization-error")
            }

            NavigationSplitView {
                MeetingWorkspaceSidebar(
                    searchText: $searchText,
                    pendingDeleteMeeting: $pendingDeleteMeeting,
                    onImport: { route(.find) }
                )
                .navigationSplitViewColumnWidth(min: 190, ideal: 240, max: 300)
            } detail: {
                if focusedSection == .review {
                    IntelligenceWorkspaceView(selectedTab: $selectedIntelligenceTab)
                        .accessibilityIdentifier("full-width-review-workspace")
                } else {
                    MeetingTranscriptWorkspace(
                        onShowRecordingSetup: { route(.record) },
                        onImport: { route(.find) }
                    )
                }
            }
        }
        .background(
            VaultSceneBackground(
                tint: store.recordingState == .recording || store.recordingState == .processing
                    ? store.recordingState.statusTint
                    : .blue,
                animated: store.recordingState == .recording || store.recordingState == .processing
            )
        )
        .navigationTitle("Meetings")
        .toolbar {
            MeetingWorkspaceToolbar(
                isInspectorPresented: $isInspectorPresented,
                route: route
            )
        }
        .inspector(isPresented: $isInspectorPresented) {
            MeetingWorkspaceInspector(
                mode: inspectorMode,
                focusedSection: $focusedSection,
                selectedIntelligenceTab: $selectedIntelligenceTab,
                route: route
            )
            .frame(
                minWidth: 320,
                maxWidth: 520,
                minHeight: 0,
                maxHeight: .infinity,
                alignment: .topLeading
            )
            .inspectorColumnWidth(min: 320, ideal: 380, max: 520)
        }
        .onAppear {
            applyInitialPresentation()
        }
        .task {
            Task {
                await store.refreshPermissionsIfNeeded()
            }
            await store.monitorAudioInputDevices()
        }
        .onChange(of: presentationEvent) { _, event in
            guard let event else { return }
            applyPresentationEvent(event)
        }
        .onChange(of: routePresentationEvent) { _, event in
            guard let event else { return }
            applyPresentationEvent(event)
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task {
                await store.refreshPermissions()
            }
        }
        .alert(
            "Delete recording?",
            isPresented: Binding(
                get: { pendingDeleteMeeting != nil },
                set: { if !$0 { pendingDeleteMeeting = nil } }
            ),
            presenting: pendingDeleteMeeting
        ) { meeting in
            Button("Delete", role: .destructive) {
                deleteMeeting(meeting)
            }
            Button("Cancel", role: .cancel) {
                pendingDeleteMeeting = nil
            }
        } message: { meeting in
            Text("This removes \"\(meeting.title)\" from the local encrypted library and search index. This cannot be undone.")
        }
    }

    private func route(_ focus: MeetingsWorkspaceFocus) {
        guard case let .inspector(inspectorFocus) = MeetingWorkspacePresentation.routeTarget(for: focus) else {
            store.requestHealthRecoveryPresentation()
            return
        }
        routePresentationEvent = .next(
            focus: inspectorFocus,
            after: routePresentationEvent
        )
    }

    private func applyPresentationEvent(_ event: MeetingWorkspacePresentationEvent) {
        guard case .inspector = MeetingWorkspacePresentation.routeTarget(for: event.focus) else { return }
        focusedSection = event.focus
        if event.focus == .review {
            selectedIntelligenceTab = .review
        }
        let presentation = MeetingWorkspacePresentation.inspectorPresentation(
            current: MeetingWorkspaceInspectorPresentation(
                mode: inspectorMode.wrappedValue,
                isPresented: isInspectorPresented
            ),
            after: event
        )
        inspectorModeValue = presentation.mode.rawValue
        isInspectorPresented = presentation.isPresented
    }

    private func applyInitialPresentation() {
        if let presentationEvent {
            focusedSection = presentationEvent.focus
        }
        inspectorModeValue = MeetingWorkspacePresentation.initialInspectorMode(
            persisted: inspectorMode.wrappedValue,
            explicitLaunchMode: launchInspectorMode,
            launchFocus: presentationEvent?.focus
        ).rawValue
        if presentationEvent != nil || launchInspectorMode != nil {
            isInspectorPresented = true
        }
    }

    private func deleteMeeting(_ meeting: MeetingRecord) {
        defer { pendingDeleteMeeting = nil }
        do {
            try store.deleteMeetingFromLibrary(meetingID: meeting.id)
        } catch {
            store.logger.error("Library delete confirmation failed")
        }
    }
}

extension MeetingsWorkspaceFocus {
    var title: String {
        switch self {
        case .find: "Library"
        case .record: "Setup"
        case .understand: "Agent"
        case .review: "Review"
        case .export: "Export"
        case .recover: "Health"
        }
    }

    var systemImage: String {
        switch self {
        case .find: "magnifyingglass"
        case .record: "record.circle"
        case .understand: "sparkles"
        case .review: "rectangle.stack"
        case .export: "square.and.arrow.up"
        case .recover: "cross.case"
        }
    }

    var tint: Color {
        switch self {
        case .find: .blue
        case .record: .red
        case .understand: .blue
        case .review: .purple
        case .export: .green
        case .recover: .orange
        }
    }

    var accessibilityLabel: String {
        "Meetings section \(title)"
    }

    var controlAccessibilityIdentifier: String {
        "meetings-section-\(rawValue)-control"
    }

    var contentAccessibilityIdentifier: String {
        "meetings-section-\(rawValue)-content"
    }
}
