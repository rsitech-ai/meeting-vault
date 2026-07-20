import SwiftUI
import MeetingVaultCore

struct ContentView: View {
    @Environment(\.vaultReduceMotion) private var reduceMotion
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var store: MeetingVaultStore
    @SceneStorage("focusedMeetingsSection") private var focusedMeetingsSection = MeetingsWorkspaceFocus.understand.rawValue
    @SceneStorage("selectedIntelligenceTab") private var selectedIntelligenceTab = IntelligenceWorkspaceTab.agent.rawValue
    @State private var workspacePresentationEvent: MeetingWorkspacePresentationEvent?
    private let launchArguments: [String]
    private let launchInspectorMode: MeetingInspectorMode?
    private let initialRouteTarget: MeetingWorkspaceRouteTarget?

    init(arguments: [String] = CommandLine.arguments) {
        launchArguments = arguments
        launchInspectorMode = MeetingInspectorMode.launchMode(from: arguments)
        initialRouteTarget = MeetingWorkspacePresentation.initialRouteTarget(from: arguments)
        _workspacePresentationEvent = State(
            initialValue: MeetingWorkspacePresentation.initialEvent(from: arguments)
        )
    }

    private var focusBinding: Binding<MeetingsWorkspaceFocus> {
        Binding(
            get: { MeetingsWorkspaceFocus(rawValue: focusedMeetingsSection) ?? .find },
            set: { focusedMeetingsSection = $0.rawValue }
        )
    }

    private var intelligenceTabBinding: Binding<IntelligenceWorkspaceTab> {
        Binding(
            get: { IntelligenceWorkspaceTab(rawValue: selectedIntelligenceTab) ?? .agent },
            set: { selectedIntelligenceTab = $0.rawValue }
        )
    }

    var body: some View {
        MeetingsWorkspaceView(
            focusedSection: focusBinding,
            selectedIntelligenceTab: intelligenceTabBinding,
            presentationEvent: workspacePresentationEvent,
            launchInspectorMode: launchInspectorMode
        )
        .overlay(alignment: .topLeading) {
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityElement()
                .accessibilityLabel(reduceMotion ? "Reduce Motion On" : "Reduce Motion Off")
                .accessibilityIdentifier("meeting-workspace-reduce-motion-\(reduceMotion ? "on" : "off")")
        }
        .navigationTitle("Meetings")
        .onAppear {
            MeetingVaultAppHandoffCenter.shared.register(store: store)
        }
        .task {
            await Task.yield()
            applyLaunchIntelligenceTab()
            if initialRouteTarget == .healthWindow {
                store.requestHealthRecoveryPresentation()
            }
        }
        .onChange(of: store.requestedSidebarItem) { _, requestedItem in
            guard requestedItem != nil else { return }
            store.clearRequestedSidebarItem()
        }
        .onChange(of: store.requestedWorkspaceFocus) { _, requestedFocus in
            guard let requestedFocus,
                  let focus = MeetingsWorkspaceFocus(rawValue: requestedFocus) else { return }
            presentWorkspace(focus)
            store.clearRequestedWorkspaceFocus()
        }
        .onChange(of: store.healthRecoveryPresentationEvent) { _, event in
            guard event != nil else { return }
            openWindow(id: HealthRecoveryPresentation.windowID)
        }
    }

    private func applyLaunchIntelligenceTab() {
        if let launchTab = IntelligenceWorkspaceTab.launchTab(from: launchArguments) {
            selectedIntelligenceTab = launchTab.rawValue
        }
    }

    private func presentWorkspace(_ focus: MeetingsWorkspaceFocus) {
        guard case .inspector = MeetingWorkspacePresentation.routeTarget(for: focus) else {
            store.requestHealthRecoveryPresentation()
            return
        }
        focusedMeetingsSection = focus.rawValue
        workspacePresentationEvent = .next(
            focus: focus,
            after: workspacePresentationEvent
        )
    }
}

enum SidebarItem: String, CaseIterable, Identifiable {
    case meetings
    case library
    case recorder
    case intelligence
    case diagnostics

    var id: String { rawValue }

    static var primaryItems: [SidebarItem] { [.meetings] }

    var title: String {
        switch self {
        case .meetings: "Meetings"
        case .library: "Library"
        case .recorder: "Recorder"
        case .intelligence: "Intelligence"
        case .diagnostics: "Diagnostics"
        }
    }

    var symbol: String {
        switch self {
        case .meetings: "rectangle.stack.badge.play"
        case .library: "tray.full"
        case .recorder: "waveform.circle"
        case .intelligence: "sparkles"
        case .diagnostics: "gauge.with.dots.needle.33percent"
        }
    }

    static var launchWorkspace: SidebarItem? {
        launchWorkspace(from: CommandLine.arguments)
    }

    static func launchWorkspace(from arguments: [String]) -> SidebarItem? {
        guard let index = arguments.firstIndex(of: "--workspace"),
              arguments.indices.contains(arguments.index(after: index)) else {
            return nil
        }
        let value = arguments[arguments.index(after: index)]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch value {
        case "meetings", "library", "recorder", "intelligence", "diagnostics":
            return .meetings
        default:
            return nil
        }
    }

    static func launchWorkspaceValue(from arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: "--workspace"),
              arguments.indices.contains(arguments.index(after: index)) else {
            return nil
        }
        return arguments[arguments.index(after: index)]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

enum MeetingsWorkspaceFocus: String, CaseIterable, Identifiable {
    case find
    case record
    case understand
    case review
    case export
    case recover

    var id: String { rawValue }

    static func launchFocus(from arguments: [String]) -> MeetingsWorkspaceFocus? {
        if IntelligenceWorkspaceTab.launchTab(from: arguments) != nil {
            return .review
        }
        guard let value = SidebarItem.launchWorkspaceValue(from: arguments) else { return nil }
        switch value {
        case "meetings":
            return .understand
        case "library":
            return .find
        case "recorder":
            return .record
        case "intelligence":
            return .understand
        case "diagnostics":
            return .recover
        default:
            return nil
        }
    }
}
