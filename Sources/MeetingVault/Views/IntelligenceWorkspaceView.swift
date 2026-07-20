import SwiftUI
import MeetingVaultCore

struct IntelligenceWorkspaceView: View {
    @EnvironmentObject private var store: MeetingVaultStore
    @Binding var selectedTab: IntelligenceWorkspaceTab

    var body: some View {
        TabView(selection: $selectedTab) {
            TranscriptAgentPane()
                .tabItem { Label("Agent", systemImage: "bubble.left.and.text.bubble.right") }
                .tag(IntelligenceWorkspaceTab.agent)

            PlaybackPane()
                .tabItem { Label("Playback", systemImage: "play.rectangle") }
                .tag(IntelligenceWorkspaceTab.playback)
                .accessibilityIdentifier(IntelligenceWorkspaceTab.playback.contentAccessibilityIdentifier)

            TranscriptEditorPane()
                .tabItem { Label("Editor", systemImage: "text.cursor") }
                .tag(IntelligenceWorkspaceTab.editor)
                .accessibilityIdentifier(IntelligenceWorkspaceTab.editor.contentAccessibilityIdentifier)

            ConfidenceReviewView()
                .tabItem { Label("Review", systemImage: "checkmark.bubble") }
                .tag(IntelligenceWorkspaceTab.review)
                .accessibilityIdentifier(IntelligenceWorkspaceTab.review.contentAccessibilityIdentifier)

            IntelligenceSummaryPane()
                .tabItem { Label("Summary", systemImage: "doc.text") }
                .tag(IntelligenceWorkspaceTab.summary)

            IntelligenceArtifactListPane(kind: .decisions)
                .tabItem { Label("Decisions", systemImage: "checkmark.seal") }
                .tag(IntelligenceWorkspaceTab.decisions)

            IntelligenceArtifactListPane(kind: .actions)
                .tabItem { Label("Actions", systemImage: "checklist") }
                .tag(IntelligenceWorkspaceTab.actions)

            IntelligenceArtifactListPane(kind: .questions)
                .tabItem { Label("Questions", systemImage: "questionmark.bubble") }
                .tag(IntelligenceWorkspaceTab.questions)

            IntelligenceArtifactListPane(kind: .risks)
                .tabItem { Label("Risks", systemImage: "exclamationmark.triangle") }
                .tag(IntelligenceWorkspaceTab.risks)

            ExportPane()
                .tabItem { Label("Exports", systemImage: "square.and.arrow.up") }
                .tag(IntelligenceWorkspaceTab.exports)
        }
        .padding(20)
        .background(VaultSceneBackground(tint: .purple))
        .navigationTitle("Agent")
    }
}

enum IntelligenceWorkspaceTab: String, CaseIterable, Identifiable {
    case agent
    case playback
    case editor
    case review
    case summary
    case decisions
    case actions
    case questions
    case risks
    case exports

    var id: String { rawValue }

    var contentAccessibilityIdentifier: String {
        "intelligence-tab-\(rawValue)-content"
    }

    static func launchTab(from arguments: [String]) -> IntelligenceWorkspaceTab? {
        guard let index = arguments.firstIndex(of: "--intelligence-tab"),
              arguments.indices.contains(arguments.index(after: index)) else {
            return nil
        }
        let value = arguments[arguments.index(after: index)]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return IntelligenceWorkspaceTab(rawValue: value)
    }
}

struct ExportPane: View {
    @EnvironmentObject private var store: MeetingVaultStore

    private var canExport: Bool {
        store.exportMarkdown
            || store.exportWebVTT
            || store.exportPDF
            || store.exportDOCX
            || store.exportJSON
            || store.exportAudioPackage
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VaultHeroBand(tint: .teal) {
                    HStack(alignment: .top, spacing: 12) {
                        VaultSectionHeader(
                            "Export Package",
                            subtitle: store.exportStatus,
                            systemImage: "square.and.arrow.up"
                        )
                        Spacer()
                        VaultStatusPill(
                            label: store.lastExportPackage.map { "\($0.files.count) files" } ?? "ready",
                            systemImage: store.lastExportPackage == nil ? "tray" : "checkmark.seal",
                            tint: store.lastExportPackage == nil ? .secondary : .green,
                            isActive: store.lastExportPackage != nil
                        )
                    }
                }

                VStack(alignment: .leading, spacing: 14) {
                    VaultSectionHeader(
                        "Formats",
                        subtitle: "Exports stay local and are written from encrypted transcript, intelligence, and audio artifacts.",
                        systemImage: "doc.badge.gearshape"
                    )

                    ViewThatFits(in: .horizontal) {
                        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 12) {
                            GridRow {
                                exportFormatToggle(.markdown)
                                exportFormatToggle(.webVTT)
                                exportFormatToggle(.pdf)
                            }
                            GridRow {
                                exportFormatToggle(.docx)
                                exportFormatToggle(.json)
                                exportFormatToggle(.audio)
                            }
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            exportFormatToggle(.markdown)
                            exportFormatToggle(.webVTT)
                            exportFormatToggle(.pdf)
                            exportFormatToggle(.docx)
                            exportFormatToggle(.json)
                            exportFormatToggle(.audio)
                        }
                    }
                    .toggleStyle(.checkbox)

                    HStack(spacing: 10) {
                        Button {
                            do {
                                _ = try store.exportSelectedMeeting()
                            } catch {
                                // The store updates exportStatus with user-facing recovery text.
                            }
                        } label: {
                            Label("Export Selected Meeting", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.glassProminent)
                        .disabled(!canExport)
                        .help("Create a local export package for the selected meeting")

                        VaultStatusPill(
                            label: canExport ? "local package" : "choose format",
                            systemImage: canExport ? "lock.shield" : "exclamationmark.triangle",
                            tint: canExport ? .green : .orange,
                            isActive: canExport
                        )
                    }
                }
                .vaultGlassPanel(cornerRadius: 18, tint: .teal)

                ExportPackageResultBlock(package: store.lastExportPackage)
                SharePreparationBlock()
                SystemIntegrationPreparationBlock()
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func exportFormatToggle(_ format: ExportFormatToggle) -> some View {
        Toggle(isOn: binding(for: format)) {
            Label(format.title, systemImage: format.systemImage)
        }
    }

    private func binding(for format: ExportFormatToggle) -> Binding<Bool> {
        switch format {
        case .markdown:
            $store.exportMarkdown
        case .webVTT:
            $store.exportWebVTT
        case .pdf:
            $store.exportPDF
        case .docx:
            $store.exportDOCX
        case .json:
            $store.exportJSON
        case .audio:
            $store.exportAudioPackage
        }
    }
}

private enum ExportFormatToggle {
    case markdown
    case webVTT
    case pdf
    case docx
    case json
    case audio

    var title: String {
        switch self {
        case .markdown: "Markdown"
        case .webVTT: "WebVTT"
        case .pdf: "PDF"
        case .docx: "DOCX"
        case .json: "JSON"
        case .audio: "Audio"
        }
    }

    var systemImage: String {
        switch self {
        case .markdown: "doc.plaintext"
        case .webVTT: "captions.bubble"
        case .pdf: "doc.richtext"
        case .docx: "doc.text"
        case .json: "curlybraces"
        case .audio: "waveform"
        }
    }
}

private struct SystemIntegrationPreparationBlock: View {
    @EnvironmentObject private var store: MeetingVaultStore
    @State private var confirmSystemHandoff = false

    private var proposalCount: Int {
        store.systemIntegrationReview?.proposals.count ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VaultSectionHeader(
                    "System Review",
                    subtitle: store.systemIntegrationStatus,
                    systemImage: "calendar.badge.clock"
                )
                Spacer()
                VaultStatusPill(
                    label: proposalCount == 0 ? "review ready" : "\(proposalCount) proposal(s)",
                    systemImage: proposalCount == 0 ? "tray" : "checkmark.seal",
                    tint: proposalCount == 0 ? .orange : .green,
                    isActive: proposalCount > 0
                )
            }

            HStack(spacing: 10) {
                Button {
                    do {
                        _ = try store.prepareSystemIntegrationReview()
                    } catch {
                        // The store updates systemIntegrationStatus with user-facing recovery text.
                    }
                } label: {
                    Label("Prepare Review", systemImage: "calendar.badge.plus")
                        .frame(minWidth: 180, minHeight: 44)
                }
                .buttonStyle(.glassProminent)
                .help("Prepare local Calendar, Contacts, and Reminders proposals without writing to system stores")

                Button {
                    confirmSystemHandoff = true
                } label: {
                    Label("Confirm Handoff", systemImage: "arrow.up.forward.app")
                        .frame(minWidth: 180, minHeight: 44)
                }
                .buttonStyle(.glassProminent)
                .disabled(store.systemIntegrationReview == nil)
                .help("Confirm before writing reviewed proposals to Calendar, Contacts, or Reminders through an approved system adapter")

                VaultStatusPill(
                    label: store.lastSystemIntegrationExecutionResult?.externalWriteExecuted == true ? "handoff complete" : (store.systemIntegrationReview?.externalWritePrepared == true ? "external write ready" : "review only"),
                    systemImage: store.lastSystemIntegrationExecutionResult?.externalWriteExecuted == true ? "checkmark.seal" : (store.systemIntegrationReview?.externalWritePrepared == true ? "arrow.up.forward.app" : "lock.shield"),
                    tint: store.lastSystemIntegrationExecutionResult?.externalWriteExecuted == true ? .green : (store.systemIntegrationReview?.externalWritePrepared == true ? .orange : .green),
                    isActive: store.systemIntegrationReview != nil
                )

                Spacer(minLength: 0)
            }
            .confirmationDialog(
                "Write reviewed proposals to Calendar, Contacts, or Reminders?",
                isPresented: $confirmSystemHandoff,
                titleVisibility: .visible
            ) {
                Button("Confirm System Handoff", role: .destructive) {
                    do {
                        _ = try store.confirmSystemIntegrationWrites()
                    } catch {
                        // The store updates systemIntegrationStatus with user-facing recovery text.
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("MeetingVault will only continue if an approved system adapter is configured. Review proposals are preserved if the handoff is unavailable.")
            }

            if let review = store.systemIntegrationReview {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(review.proposals) { proposal in
                        SystemIntegrationProposalRow(proposal: proposal)
                    }
                }
                .transition(.opacity)
            } else {
                Text("Prepare local proposals from selected meeting actions before any Calendar, Contacts, or Reminders handoff.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .vaultGlassPanel(cornerRadius: 18, tint: .indigo)
    }
}

private struct SystemIntegrationProposalRow: View {
    var proposal: MeetingSystemIntegrationProposal

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: proposal.kind.systemImageName)
                .foregroundStyle(.indigo)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(proposal.kind.displayTitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    VaultStatusPill(
                        label: proposal.executionMode == .reviewOnly ? "review only" : "confirmed write",
                        systemImage: proposal.executionMode == .reviewOnly ? "lock.shield" : "checkmark.circle",
                        tint: proposal.executionMode == .reviewOnly ? .green : .orange,
                        isActive: true
                    )
                }
                Text(proposal.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(2)
                Text(proposal.note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    if let ownerName = proposal.ownerName {
                        VaultStatusPill(label: ownerName, systemImage: "person", tint: .blue)
                    }
                    if let scheduledAt = proposal.scheduledAt {
                        VaultStatusPill(label: scheduledAt.formatted(date: .abbreviated, time: .omitted), systemImage: "calendar", tint: .orange)
                    }
                    VaultStatusPill(label: "\(proposal.evidence.count) evidence", systemImage: "scope", tint: .green)
                }
            }

            Spacer(minLength: 8)
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .help("\(proposal.kind.displayTitle) proposal")
    }
}

private struct SharePreparationBlock: View {
    @EnvironmentObject private var store: MeetingVaultStore

    private var canPrepareShare: Bool {
        store.lastExportPackage != nil
    }

    private var canOpenShare: Bool {
        store.lastShareManifest != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VaultSectionHeader(
                    "Share Preparation",
                    subtitle: store.shareStatus,
                    systemImage: "person.crop.circle.badge.checkmark"
                )
                Spacer()
                VaultStatusPill(
                    label: store.lastShareManifest.map { "\($0.files.count) ready" } ?? "needs export",
                    systemImage: store.lastShareManifest == nil ? "square.and.arrow.up" : "checkmark.seal",
                    tint: store.lastShareManifest == nil ? .orange : .green,
                    isActive: store.lastShareManifest != nil
                )
            }

            HStack(spacing: 12) {
                Picker("Destination", selection: $store.shareDestination) {
                    ForEach(MeetingShareDestination.allCases, id: \.self) { destination in
                        Label(destination.displayTitle, systemImage: destination.systemImage)
                            .tag(destination)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 280)
                .help("Choose the local share handoff to prepare")

                Button {
                    do {
                        _ = try store.prepareShareForLatestExportPackage()
                    } catch {
                        // The store updates shareStatus with user-facing recovery text.
                    }
                } label: {
                    Label("Prepare Share", systemImage: "hand.raised")
                }
                .buttonStyle(.glassProminent)
                .disabled(!canPrepareShare)
                .help("Prepare a user-confirmed local share manifest for the latest export package")

                Button {
                    do {
                        _ = try store.executePreparedShare(userConfirmed: true)
                    } catch {
                        // The store updates shareStatus with user-facing recovery text.
                    }
                } label: {
                    Label("Confirm & Open", systemImage: "checkmark.circle")
                }
                .buttonStyle(.glass)
                .disabled(!canOpenShare)
                .help("After reviewing the prepared files, open the selected local share destination")

                VaultStatusPill(
                    label: canOpenShare ? "ready to open" : (canPrepareShare ? "confirmation required" : "export first"),
                    systemImage: canOpenShare ? "checkmark.circle" : (canPrepareShare ? "hand.raised" : "tray"),
                    tint: canOpenShare ? .green : (canPrepareShare ? .green : .orange),
                    isActive: canPrepareShare || canOpenShare
                )
            }

            if let manifest = store.lastShareManifest {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Prepared files")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(manifest.files, id: \.url) { file in
                        HStack(spacing: 10) {
                            Image(systemName: file.format.iconName)
                                .foregroundStyle(.green)
                                .frame(width: 22)
                            Text(file.format.rawValue)
                                .font(.subheadline.weight(.semibold))
                            Text(file.url.lastPathComponent)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                        }
                        .padding(10)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
            } else {
                Text("Export the selected meeting first, then prepare a share handoff. External destinations still require explicit user confirmation.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .vaultGlassPanel(cornerRadius: 18, tint: .green)
    }
}

private struct ExportPackageResultBlock: View {
    var package: MeetingExportPackage?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VaultSectionHeader(
                "Latest Package",
                subtitle: package?.directory.path ?? "No package exported in this session.",
                systemImage: "folder"
            )

            if let package {
                ForEach(package.files, id: \.url) { file in
                    HStack(spacing: 12) {
                        Image(systemName: icon(for: file.format))
                            .foregroundStyle(.teal)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(file.format.rawValue)
                                .font(.subheadline.weight(.semibold))
                            Text(file.url.path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 12)
                    }
                    .padding(10)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .help(file.url.path)
                }
            } else {
	                Text("Choose formats and export the selected meeting to create Markdown, WebVTT, PDF, DOCX, JSON, and optional audio package files.")
	                    .font(.callout)
	                    .foregroundStyle(.secondary)
            }
        }
        .vaultGlassPanel(cornerRadius: 18, tint: .teal)
    }

    private func icon(for format: MeetingExportFormat) -> String {
        format.iconName
    }
}

private struct IntelligenceSummaryPane: View {
    @EnvironmentObject private var store: MeetingVaultStore

    var body: some View {
        ScrollView {
            if let summary = store.selectedMeeting?.summary {
                VStack(alignment: .leading, spacing: 16) {
                    VaultHeroBand(tint: .purple) {
                        VStack(alignment: .leading, spacing: 12) {
                            VaultSectionHeader(
                                summary.title,
                                subtitle: "Evidence-grounded summary for the selected meeting.",
                                systemImage: "doc.text.magnifyingglass"
                            )
                            Text(summary.oneParagraph)
                                .font(.title3.weight(.medium))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(summary.bullets, id: \.self) { bullet in
                            Label(bullet, systemImage: "checkmark.circle.fill")
                                .font(.callout)
                        }
                    }
                    .vaultGlassPanel(cornerRadius: 18, tint: .purple)

                    IntelligenceArtifactSection(title: "Decisions", rows: IntelligenceArtifactListKind.decisions.rows(from: summary))
                    IntelligenceArtifactSection(title: "Actions", rows: IntelligenceArtifactListKind.actions.rows(from: summary))
                    IntelligenceArtifactSection(title: "Open Questions", rows: IntelligenceArtifactListKind.questions.rows(from: summary))
                    IntelligenceArtifactSection(title: "Risks", rows: IntelligenceArtifactListKind.risks.rows(from: summary))
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                EmptyIntelligenceArtifactView(
                    title: "Summary Not Ready",
                    systemImage: "doc.text.magnifyingglass",
                    tint: .purple
                )
                .padding(20)
            }
        }
    }
}

private struct IntelligenceArtifactListPane: View {
    @EnvironmentObject private var store: MeetingVaultStore

    var kind: IntelligenceArtifactListKind

    var body: some View {
        ScrollView {
            if let summary = store.selectedMeeting?.summary {
                let rows = kind.rows(from: summary)
                VStack(alignment: .leading, spacing: 16) {
                    VaultHeroBand(tint: kind.tint) {
                        HStack(alignment: .top, spacing: 12) {
                            VaultSectionHeader(
                                kind.title,
                                subtitle: kind.subtitle,
                                systemImage: kind.systemImage
                            )
                            Spacer()
                            VaultStatusPill(
                                label: "\(rows.count)",
                                systemImage: "number",
                                tint: kind.tint,
                                isActive: !rows.isEmpty
                            )
                        }
                    }

                    if rows.isEmpty {
                        EmptyIntelligenceArtifactView(
                            title: "\(kind.title) Not Found",
                            systemImage: kind.systemImage,
                            tint: kind.tint
                        )
                    } else {
                        IntelligenceArtifactSection(title: kind.title, rows: rows)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                EmptyIntelligenceArtifactView(
                    title: "\(kind.title) Not Ready",
                    systemImage: kind.systemImage,
                    tint: kind.tint
                )
                .padding(20)
            }
        }
    }
}

private enum IntelligenceArtifactListKind {
    case decisions
    case actions
    case questions
    case risks

    var title: String {
        switch self {
        case .decisions: "Decisions"
        case .actions: "Actions"
        case .questions: "Open Questions"
        case .risks: "Risks"
        }
    }

    var subtitle: String {
        switch self {
        case .decisions:
            "Decisions generated from transcript-backed evidence."
        case .actions:
            "Follow-up tasks with owner and transcript evidence."
        case .questions:
            "Unresolved questions that need an owner or answer."
        case .risks:
            "Risks and blockers grounded in the selected transcript."
        }
    }

    var systemImage: String {
        switch self {
        case .decisions: "checkmark.seal"
        case .actions: "checklist"
        case .questions: "questionmark.bubble"
        case .risks: "exclamationmark.triangle"
        }
    }

    var tint: Color {
        switch self {
        case .decisions: .green
        case .actions: .orange
        case .questions: .blue
        case .risks: .red
        }
    }

    func rows(from summary: MeetingSummary) -> [IntelligenceArtifactRowModel] {
        switch self {
        case .decisions:
            summary.decisions.map {
                IntelligenceArtifactRowModel(
                    id: $0.id,
                    title: $0.title,
                    subtitle: $0.details,
                    timestamp: $0.evidence.first?.startTime,
                    badge: confidenceBadge($0.confidence),
                    tint: tint
                )
            }
        case .actions:
            summary.actionItems.map {
                IntelligenceArtifactRowModel(
                    id: $0.id,
                    title: $0.title,
                    subtitle: $0.ownerName.map { owner in "Owner: \(owner)" } ?? "Owner not assigned",
                    timestamp: $0.evidence.first?.startTime,
                    badge: confidenceBadge($0.confidence),
                    tint: tint
                )
            }
        case .questions:
            summary.openQuestions.map {
                IntelligenceArtifactRowModel(
                    id: $0.id,
                    title: $0.question,
                    subtitle: $0.context,
                    timestamp: $0.evidence.first?.startTime,
                    badge: confidenceBadge($0.confidence),
                    tint: tint
                )
            }
        case .risks:
            summary.risks.map {
                IntelligenceArtifactRowModel(
                    id: $0.id,
                    title: $0.title,
                    subtitle: $0.details,
                    timestamp: $0.evidence.first?.startTime,
                    badge: $0.severity.rawValue.uppercased(),
                    tint: tint
                )
            }
        }
    }

    private func confidenceBadge(_ value: Double) -> String {
        "\(Int((min(1, max(0, value)) * 100).rounded()))%"
    }
}

private struct IntelligenceArtifactRowModel: Identifiable {
    var id: UUID
    var title: String
    var subtitle: String
    var timestamp: TimeInterval?
    var badge: String
    var tint: Color
}

private struct IntelligenceArtifactSection: View {
    var title: String
    var rows: [IntelligenceArtifactRowModel]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VaultSectionHeader(title, subtitle: rows.isEmpty ? "No transcript-backed items found." : nil, systemImage: "scope")
            if rows.isEmpty {
                Text("No items found in the selected meeting summary.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(rows) { row in
                    IntelligenceArtifactRow(row: row)
                }
            }
        }
        .vaultGlassPanel(cornerRadius: 18, tint: rows.first?.tint ?? .purple)
    }
}

private struct IntelligenceArtifactRow: View {
    var row: IntelligenceArtifactRowModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "quote.bubble.fill")
                .foregroundStyle(row.tint)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(row.title)
                        .font(.subheadline.weight(.semibold))
                    VaultStatusPill(label: row.badge, systemImage: "scope", tint: row.tint)
                }
                Text(row.subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Text(timestamp(row.timestamp))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func timestamp(_ value: TimeInterval?) -> String {
        guard let value else { return "No evidence" }
        let minutes = Int(value) / 60
        let seconds = Int(value) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

private struct EmptyIntelligenceArtifactView: View {
    var title: String
    var systemImage: String
    var tint: Color

    var body: some View {
        VaultHeroBand(tint: tint) {
            ContentUnavailableView(
                title,
                systemImage: systemImage,
                description: Text("Record or import a meeting, then run transcription and intelligence to create grounded artifacts.")
            )
            .frame(maxWidth: .infinity, minHeight: 280)
        }
    }
}

private struct TranscriptAgentPane: View {
    @EnvironmentObject private var store: MeetingVaultStore

    private var canAsk: Bool {
        store.transcriptAgentCanAsk
    }

    private var canCopy: Bool {
        !store.transcriptAskAnswerDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VaultHeroBand(tint: .blue) {
                    HStack(alignment: .top, spacing: 16) {
                        VaultSectionHeader(
                            "Agent",
                            subtitle: "The latest selected recording transcript is visible here. Ask follow-up questions, edit the response, then copy the exact text you approved.",
                            systemImage: "bubble.left.and.text.bubble.right"
                        )

                        Spacer()

                        VStack(alignment: .trailing, spacing: 8) {
                            VaultStatusPill(
                                label: "\(store.transcriptEditDraft.segments.count) segments",
                                systemImage: "text.bubble",
                                tint: store.transcriptAgentHasVisibleTranscript ? .blue : .secondary,
                                isActive: store.transcriptAgentHasVisibleTranscript
                            )
                            VaultStatusPill(
                                label: "\(store.transcriptAskEvidence.count) evidence",
                                systemImage: store.transcriptAskEvidence.isEmpty ? "scope" : "checkmark.seal",
                                tint: store.transcriptAskEvidence.isEmpty ? Color.secondary : Color.green,
                                isActive: !store.transcriptAskEvidence.isEmpty
                            )
                        }
                    }
                }

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 16) {
                        TranscriptContextBlock(
                            segments: store.transcriptEditDraft.segments,
                            showsCopyButton: true
                        )
                        .frame(minWidth: 360, idealWidth: 460, maxWidth: 540, alignment: .topLeading)

                        AgentPromptAndAnswerBlock(canAsk: canAsk, canCopy: canCopy)
                            .frame(minWidth: 420, maxWidth: .infinity, alignment: .topLeading)
                    }

                    VStack(alignment: .leading, spacing: 16) {
                        TranscriptContextBlock(
                            segments: store.transcriptEditDraft.segments,
                            showsCopyButton: true
                        )
                        AgentPromptAndAnswerBlock(canAsk: canAsk, canCopy: canCopy)
                    }
                }

                TranscriptConversationHistoryBlock(turns: store.transcriptConversationTurns)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct AgentPromptAndAnswerBlock: View {
    @EnvironmentObject private var store: MeetingVaultStore

    var canAsk: Bool
    var canCopy: Bool

    private var presetColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 150), spacing: 8, alignment: .top)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                VaultSectionHeader(
                    "Prompt The Transcript",
                    subtitle: store.transcriptAgentReadinessStatus,
                    systemImage: "sparkles"
                )

                LazyVGrid(columns: presetColumns, alignment: .leading, spacing: 8) {
                    ForEach(TranscriptPromptPreset.allCases) { preset in
                        PromptPresetButton(preset: preset)
                    }
                }

                TextEditor(
                    text: Binding(
                        get: { store.transcriptAskPrompt },
                        set: { store.transcriptAskPrompt = $0 }
                    )
                )
                .font(.body)
                .frame(minHeight: 82)
                .scrollContentBackground(.hidden)
                .padding(10)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.blue.opacity(0.22), lineWidth: 1)
                }
                .help("Write a grounded prompt for the visible transcript")

                HStack {
                    Button {
                        store.askSelectedTranscript()
                    } label: {
                        Label("Ask Transcript", systemImage: "sparkles")
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(!canAsk)
                    .help(canAsk ? "Ask a grounded question about the visible transcript" : "Ask a grounded question about the visible transcript after it is finalized or imported. \(store.transcriptAgentReadinessStatus)")
                    .accessibilityIdentifier("Ask Transcript Ask a grounded question about the visible transcript")
                    .accessibilityHint(canAsk ? "Runs the transcript agent against the visible transcript." : store.transcriptAgentReadinessStatus)

                    Spacer()

                    VaultStatusPill(
                        label: store.transcriptAskEvidence.isEmpty ? "Needs evidence" : "Grounded",
                        systemImage: store.transcriptAskEvidence.isEmpty ? "scope" : "checkmark.seal",
                        tint: store.transcriptAskEvidence.isEmpty ? .secondary : .green,
                        isActive: !store.transcriptAskEvidence.isEmpty
                    )
                }
            }
            .vaultGlassPanel(cornerRadius: 18, tint: .blue)

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    VaultSectionHeader(
                        "Editable Agent Response",
                        subtitle: "This is the response that will be copied. You can rewrite it before it leaves the app.",
                        systemImage: "pencil.and.outline"
                    )
                    Spacer()
                    Button {
                        store.copyTranscriptAskAnswer()
                    } label: {
                        Label("Copy Response", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.glass)
                    .disabled(!canCopy)
                    .help("Copy the edited response to the clipboard")
                }

                TextEditor(
                    text: Binding(
                        get: { store.transcriptAskAnswerDraft },
                        set: { store.updateTranscriptAskAnswerDraft($0) }
                    )
                )
                .font(.body)
                .frame(minHeight: 158)
                .scrollContentBackground(.hidden)
                .padding(10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
                }
                .help("Edit the agent response before copying it")

                if store.transcriptAskEvidence.isEmpty {
                    Text("Evidence appears here after the answer is grounded in transcript segments.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.transcriptAskEvidence) { evidence in
                        TranscriptEvidenceRow(evidence: evidence)
                    }
                }
            }
            .vaultGlassPanel(cornerRadius: 18, tint: .green)
        }
    }
}

private struct PromptPresetButton: View {
    @EnvironmentObject private var store: MeetingVaultStore

    var preset: TranscriptPromptPreset

    var body: some View {
        Button {
            store.applyTranscriptPromptPreset(preset)
        } label: {
            Label(preset.title, systemImage: preset.systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.glass)
        .controlSize(.small)
        .help("Use the \(preset.title.lowercased()) transcript prompt")
    }
}

private struct TranscriptConversationHistoryBlock: View {
    var turns: [TranscriptConversationTurn]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VaultSectionHeader(
                "Recent Turns",
                subtitle: turns.isEmpty
                    ? "Ask the transcript to start a local conversation."
                    : "Editable responses are kept here for quick review during this session.",
                systemImage: "clock.arrow.circlepath"
            )

            if turns.isEmpty {
                Text("No transcript questions yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(turns) { turn in
                    TranscriptConversationTurnRow(turn: turn)
                }
            }
        }
        .vaultGlassPanel(cornerRadius: 18, tint: .purple)
    }
}

private struct TranscriptConversationTurnRow: View {
    var turn: TranscriptConversationTurn

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Label("Prompt", systemImage: "person.crop.circle.badge.questionmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(turn.createdAt, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                VaultStatusPill(
                    label: "\(turn.evidence.count) evidence",
                    systemImage: turn.evidence.isEmpty ? "scope" : "checkmark.seal",
                    tint: turn.evidence.isEmpty ? .secondary : .green,
                    isActive: !turn.evidence.isEmpty
                )
            }

            Text(turn.question)
                .font(.subheadline.weight(.semibold))

            Text(turn.answerDraft)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(4)
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .help("Recent local transcript-agent turn")
    }
}

private struct TranscriptContextBlock: View {
    @EnvironmentObject private var store: MeetingVaultStore

    var segments: [TranscriptEditDraftSegment]
    var showsCopyButton = false

    private var hasVisibleTranscript: Bool {
        segments.contains { !$0.trimmedEditedText.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VaultSectionHeader(
                    "Visible Transcript",
                    subtitle: hasVisibleTranscript
                        ? "Prompts use these edited speaker labels and transcript lines."
                        : "Finalize a recording or import a matched local transcript/audio pair before asking Agent.",
                    systemImage: "text.quote"
                )

                Spacer()

                if showsCopyButton {
                    Button {
                        store.copyVisibleTranscript()
                    } label: {
                        Label("Copy Transcript", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.glass)
                    .disabled(!hasVisibleTranscript)
                    .help("Copy the visible edited transcript to the clipboard")
                }
            }

            if segments.isEmpty {
                ContentUnavailableView(
                    "No Visible Transcript",
                    systemImage: "text.badge.xmark",
                    description: Text("Live lines become promptable after Stop finishes final transcription and saves the meeting.")
                )
                .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                ForEach(segments) { segment in
                    HStack(alignment: .top, spacing: 12) {
                        Text(timeRange(segment.startTime, segment.endTime))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 96, alignment: .leading)

                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 8) {
                                Text(segment.effectiveEditedSpeakerName)
                                    .font(.caption.weight(.semibold))
                                VaultStatusPill(
                                    label: segment.trackKind.rawValue,
                                    systemImage: segment.trackKind == .microphone ? "mic" : "waveform",
                                    tint: segment.trackKind == .microphone ? .green : .blue
                                )
                            }
                            Text(segment.trimmedEditedText)
                                .lineLimit(3)
                                .foregroundStyle(segment.trimmedEditedText.isEmpty ? .secondary : .primary)
                        }

                        Spacer(minLength: 12)
                    }
                    .padding(10)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("transcript-context-row-\(segment.id.uuidString)")
                    .contextMenu {
                        Button {
                            store.copyVisibleTranscript()
                        } label: {
                            Label("Copy Transcript", systemImage: "doc.on.doc")
                        }

                        Button {
                            store.showWorkspace(.review)
                        } label: {
                            Label("Open Review", systemImage: "rectangle.stack")
                        }
                    }
                    .help("Transcript context segment")
                }
            }
        }
        .vaultGlassPanel(cornerRadius: 18, tint: .purple)
    }
}

private struct TranscriptEvidenceRow: View {
    var evidence: TranscriptQuestionEvidence

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(.green)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(timeRange(evidence.startTime, evidence.endTime))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(evidence.speakerName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Text(evidence.quote)
                    .font(.callout)
            }

            Spacer(minLength: 12)
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct TranscriptEditorPane: View {
    @EnvironmentObject private var store: MeetingVaultStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VaultHeroBand(tint: .blue) {
                    HStack(alignment: .top, spacing: 16) {
                        VaultSectionHeader(
                            "Transcript Editor",
                            subtitle: "Editing \(store.transcriptEditMeetingTitle). Review speaker labels and transcript text before summaries, exports, and shared artifacts use them.",
                            systemImage: "text.cursor"
                        )

                        Spacer()

                        VStack(alignment: .trailing, spacing: 8) {
                            VaultStatusPill(
                                label: "v\(store.transcriptEditDraft.currentVersion)",
                                systemImage: "clock.arrow.circlepath",
                                tint: .blue
                            )
                            VaultStatusPill(
                                label: "\(store.transcriptEditDraft.changedSegmentCount) pending",
                                systemImage: store.transcriptEditDraft.hasChanges ? "pencil.line" : "checkmark.circle",
                                tint: store.transcriptEditDraft.hasChanges ? .orange : .green,
                                isActive: store.transcriptEditDraft.hasChanges
                            )
                        }
                    }
                }

                HStack(spacing: 12) {
                    Button {
                        store.saveTranscriptDraft()
                    } label: {
                        Label("Save Edits", systemImage: "checkmark.circle")
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(!store.transcriptEditDraft.hasChanges)
                    .help("Validate transcript edits and save a new local edit-history version")

                    Button {
                        store.revertTranscriptDraft()
                    } label: {
                        Label("Revert Draft", systemImage: "arrow.uturn.backward.circle")
                    }
                    .buttonStyle(.glass)
                    .disabled(!store.transcriptEditDraft.hasChanges)
                    .help("Discard unsaved transcript edits")

                    Button {
                        do {
                            _ = try store.restoreTranscriptDraftFromSaved(userConfirmed: !store.transcriptEditDraft.hasChanges)
                        } catch {
                            // Store state carries the user-facing confirmation or failure message.
                        }
                    } label: {
                        Label("Reload Saved", systemImage: "arrow.down.doc")
                    }
                    .buttonStyle(.glass)
                    .help("Reload the latest encrypted saved transcript")

                    if store.transcriptRestoreNeedsConfirmation {
                        Button {
                            do {
                                _ = try store.restoreTranscriptDraftFromSaved(userConfirmed: true)
                            } catch {
                                // Store state carries the user-facing failure message.
                            }
                        } label: {
                            Label("Confirm Restore", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                        }
                        .buttonStyle(.glassProminent)
                        .tint(.orange)
                        .help("Discard unsaved transcript edits and reload the latest encrypted saved transcript")
                    }

                    Spacer()

                    Text(store.transcriptEditStatus)
                        .font(.callout)
                        .foregroundStyle(store.transcriptEditDraft.hasChanges || store.transcriptRestoreNeedsConfirmation ? .orange : .secondary)
                        .contentTransition(.opacity)
                }

                ForEach(store.transcriptEditDraft.segments) { segment in
                    TranscriptSegmentEditorRow(segmentID: segment.id)
                }

                TranscriptEditHistoryBlock(history: store.transcriptEditHistory)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private func timeRange(_ startTime: TimeInterval, _ endTime: TimeInterval) -> String {
    "\(durationText(startTime))-\(durationText(endTime))"
}

private func durationText(_ seconds: TimeInterval) -> String {
    let totalSeconds = max(0, Int(seconds.rounded(.down)))
    let minutes = totalSeconds / 60
    let seconds = totalSeconds % 60
    return String(format: "%02d:%02d", minutes, seconds)
}

private extension MeetingShareDestination {
    var displayTitle: String {
        switch self {
        case .systemShareSheet:
            "System Share Sheet"
        case .finderReveal:
            "Finder Reveal"
        case .manualCopy:
            "Manual Copy"
        }
    }

    var systemImage: String {
        switch self {
        case .systemShareSheet:
            "square.and.arrow.up"
        case .finderReveal:
            "folder"
        case .manualCopy:
            "doc.on.doc"
        }
    }
}

private extension MeetingExportFormat {
    var iconName: String {
        switch self {
        case .markdown:
            "doc.plaintext"
        case .webVTT:
            "captions.bubble"
        case .pdf:
            "doc.richtext"
        case .docx:
            "doc.text"
        case .json:
            "curlybraces"
        case .audioPackage:
            "waveform"
        }
    }
}

private struct TranscriptSegmentEditorRow: View {
    @Environment(\.vaultReduceMotion) private var reduceMotion
    @EnvironmentObject private var store: MeetingVaultStore
    @State private var isHovered = false

    var segmentID: UUID

    private var segment: TranscriptEditDraftSegment? {
        store.transcriptDraftSegment(id: segmentID)
    }

    var body: some View {
        if let segment {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(timeRange(segment))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 96, alignment: .leading)

                    TextField(
                        "Speaker",
                        text: Binding(
                            get: { store.transcriptDraftSegment(id: segmentID)?.editedSpeakerName ?? "" },
                            set: { store.updateTranscriptDraftSpeaker(id: segmentID, speakerName: $0) }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                    .help("Edit the speaker label for this transcript segment")

                    VaultStatusPill(
                        label: segment.trackKind.rawValue,
                        systemImage: segment.trackKind == .microphone ? "mic" : "waveform",
                        tint: segment.trackKind == .microphone ? .green : .blue
                    )

                    Spacer()

                    if segment.hasChanges {
                        Button {
                            store.revertTranscriptDraftSegment(id: segmentID)
                        } label: {
                            Label("Revert Segment", systemImage: "arrow.uturn.backward")
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.glass)
                        .help("Revert this transcript segment")
                    }
                }

                TextEditor(
                    text: Binding(
                        get: { store.transcriptDraftSegment(id: segmentID)?.editedText ?? "" },
                        set: { store.updateTranscriptDraftText(id: segmentID, text: $0) }
                    )
                )
                .font(.body)
                .frame(minHeight: 72)
                .scrollContentBackground(.hidden)
                .padding(10)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(segment.hasChanges ? Color.orange.opacity(0.45) : Color.secondary.opacity(0.12), lineWidth: 1)
                }
                .help("Edit transcript text for this segment")
            }
            .vaultGlassPanel(cornerRadius: 18, tint: segment.hasChanges ? .orange : .blue)
            .background(
                isHovered ? Color.primary.opacity(0.035) : .clear,
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .animation(reduceMotion ? nil : VaultMotion.selection, value: isHovered)
            .onHover { isHovered = $0 }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("transcript-editor-row-\(segment.id.uuidString)")
            .contextMenu {
                Button {
                    store.saveTranscriptDraft()
                } label: {
                    Label("Save Edits", systemImage: "checkmark.circle")
                }
                .disabled(!store.transcriptEditDraft.hasChanges)

                Button {
                    store.revertTranscriptDraftSegment(id: segmentID)
                } label: {
                    Label("Revert Segment", systemImage: "arrow.uturn.backward")
                }
                .disabled(!segment.hasChanges)

                Button {
                    do {
                        _ = try store.restoreTranscriptDraftFromSaved(userConfirmed: !store.transcriptEditDraft.hasChanges)
                    } catch {
                        // Store state carries the user-facing confirmation or failure message.
                    }
                } label: {
                    Label("Reload Saved", systemImage: "arrow.down.doc")
                }
            }
            .help("Editable transcript segment")
        }
    }

    private func timeRange(_ segment: TranscriptEditDraftSegment) -> String {
        "\(durationText(segment.startTime))-\(durationText(segment.endTime))"
    }

    private func durationText(_ seconds: TimeInterval) -> String {
        let totalSeconds = max(0, Int(seconds.rounded(.down)))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

private struct TranscriptEditHistoryBlock: View {
    @EnvironmentObject private var store: MeetingVaultStore

    var history: TranscriptEditHistory

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VaultSectionHeader(
                "Edit History",
                subtitle: "Metadata-only versions are stored without transcript text or speaker names. Restore reloads the latest encrypted saved transcript.",
                systemImage: "clock.arrow.circlepath"
            )

            HStack(spacing: 10) {
                Button {
                    do {
                        _ = try store.restoreTranscriptDraftFromSaved(userConfirmed: !store.transcriptEditDraft.hasChanges)
                    } catch {
                        // Store state carries the user-facing confirmation or failure message.
                    }
                } label: {
                    Label("Reload Latest Saved", systemImage: "arrow.down.doc")
                }
                .buttonStyle(.glassProminent)
                .disabled(history.latestVersion == 0 && !store.transcriptEditDraft.hasChanges)
                .help("Reload the latest encrypted saved transcript artifact")

                if store.transcriptRestoreNeedsConfirmation {
                    Button {
                        do {
                            _ = try store.restoreTranscriptDraftFromSaved(userConfirmed: true)
                        } catch {
                            // Store state carries the user-facing failure message.
                        }
                    } label: {
                        Label("Confirm Restore", systemImage: "exclamationmark.triangle")
                    }
                    .buttonStyle(.glassProminent)
                    .tint(.orange)
                    .help("Confirm discarding unsaved edits before reloading the saved transcript")
                }

                VaultStatusPill(
                    label: store.transcriptRestoreNeedsConfirmation ? "confirmation required" : "latest saved",
                    systemImage: store.transcriptRestoreNeedsConfirmation ? "exclamationmark.triangle" : "checkmark.seal",
                    tint: store.transcriptRestoreNeedsConfirmation ? .orange : .green,
                    isActive: store.transcriptRestoreNeedsConfirmation
                )
            }

            if history.entries.isEmpty {
                Text("No saved transcript edits yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(history.entries.reversed()) { entry in
                    HStack(spacing: 12) {
                        VaultStatusPill(label: "v\(entry.version)", systemImage: "number", tint: .blue)
                        Text(entry.editedAt, style: .relative)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(entry.editedSegmentCount) segment(s)")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        }
        .vaultGlassPanel(cornerRadius: 18, tint: .purple)
    }
}

private struct PlaybackPane: View {
    @EnvironmentObject private var store: MeetingVaultStore

    private var timeline: TranscriptPlaybackTimeline {
        store.playbackTimeline
    }

    private var playbackState: TranscriptPlaybackSessionState {
        store.playbackSessionState
    }

    private var firstPlayableCueID: UUID? {
        timeline.cues.first(where: \.isPlayable)?.segmentID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                VaultSectionHeader(
                    "Transcript Audio",
                    subtitle: playbackState.statusMessage,
                    systemImage: "play.rectangle"
                )
                Spacer()
                VaultStatusPill(
                    label: playbackState.transportState.rawValue,
                    systemImage: playbackState.transportState == .playing ? "play.circle.fill" : "waveform",
                    tint: playbackTint,
                    isActive: playbackState.transportState == .playing
                )
                VaultLiveSignal(tint: playbackTint, barCount: 9, compact: true)
            }

            GlassEffectContainer(spacing: 14) {
                HStack(spacing: 14) {
                    VaultMetricTile(label: "Duration", value: durationText(timeline.duration), systemImage: "timer", tint: .blue)
                    VaultMetricTile(label: "Cues", value: "\(timeline.cues.count)", systemImage: "text.bubble", tint: .purple)
                    VaultMetricTile(label: "Playable", value: "\(timeline.cues.filter(\.isPlayable).count)", systemImage: "checkmark.circle", tint: .green)
                    VaultMetricTile(label: "Warnings", value: "\(timeline.warnings.count)", systemImage: "exclamationmark.triangle", tint: timeline.warnings.isEmpty ? .green : .orange)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Button {
                        if let firstPlayableCueID {
                            store.playTranscriptCue(firstPlayableCueID)
                        }
                    } label: {
                        Label("Play", systemImage: "play.fill")
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(firstPlayableCueID == nil)
                    .help("Play the first cue with matching encrypted audio")

                    Button {
                        store.pauseTranscriptPlayback()
                    } label: {
                        Label("Pause", systemImage: "pause.fill")
                    }
                    .buttonStyle(.glass)
                    .disabled(playbackState.transportState != .playing)
                    .help("Pause transcript audio playback")

                    Button {
                        store.stopTranscriptPlayback()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(.glass)
                    .disabled(playbackState.transportState == .idle || playbackState.transportState == .stopped)
                    .help("Stop transcript audio playback")

                    Spacer()

                    Text(durationText(playbackState.currentTime))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Slider(
                    value: Binding(
                        get: { playbackState.currentTime },
                        set: { store.seekTranscriptPlayback(to: $0) }
                    ),
                    in: 0...max(timeline.duration, 1)
                )
                .disabled(timeline.duration <= 0)
                .help("Scrub the transcript playback position")
            }
            .vaultGlassPanel(cornerRadius: 18, tint: playbackTint)

            List(timeline.cues) { cue in
                PlaybackCueRow(
                    cue: cue,
                    timeRange: timeRange(cue),
                    isSelected: playbackState.selectedCueID == cue.segmentID
                )
            }
            .listStyle(.inset)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .vaultGlassPanel(cornerRadius: 22, tint: playbackTint)
    }

    private var playbackTint: Color {
        switch playbackState.transportState {
        case .playing:
            return .green
        case .failed:
            return .orange
        case .paused:
            return .blue
        case .idle, .stopped:
            return timeline.warnings.isEmpty ? .green : .blue
        }
    }

    private func timeRange(_ cue: TranscriptPlaybackCue) -> String {
        "\(durationText(cue.startTime))-\(durationText(cue.endTime))"
    }

    private func durationText(_ seconds: TimeInterval) -> String {
        let totalSeconds = max(0, Int(seconds.rounded(.down)))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

private struct PlaybackCueRow: View {
    @Environment(\.vaultReduceMotion) private var reduceMotion
    @EnvironmentObject private var store: MeetingVaultStore
    @State private var isHovered = false

    var cue: TranscriptPlaybackCue
    var timeRange: String
    var isSelected: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Button {
                store.playTranscriptCue(cue.segmentID)
            } label: {
                Image(systemName: cue.isPlayable ? "play.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.title3)
                    .foregroundStyle(cue.isPlayable ? .green : .orange)
                    .symbolEffect(.pulse, options: .speed(0.8), value: !reduceMotion && !cue.isPlayable)
                    .frame(width: 24)
            }
            .buttonStyle(.glass)
            .labelStyle(.iconOnly)
            .disabled(!cue.isPlayable)
            .help(cue.isPlayable ? "Play this transcript cue" : "This cue is missing matching audio")

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(timeRange)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(cue.speakerName ?? cue.trackKind.rawValue)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    if !cue.isPlayable {
                        Text("audio repair")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                }
                Text(cue.text)
                    .lineLimit(2)
            }

            Spacer(minLength: 12)

            Text(cue.trackKind.rawValue)
                .font(.caption)
                .foregroundStyle(isSelected ? .primary : .secondary)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, isSelected ? 8 : 0)
        .background(isSelected ? Color.green.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isHovered && !isSelected ? Color.primary.opacity(0.035) : .clear)
        }
        .animation(reduceMotion ? nil : VaultMotion.selection, value: isHovered)
        .animation(reduceMotion ? nil : VaultMotion.selection, value: isSelected)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("playback-cue-row-\(cue.segmentID.uuidString)")
        .contextMenu {
            Button {
                store.playTranscriptCue(cue.segmentID)
            } label: {
                Label("Play Cue", systemImage: "play.fill")
            }
            .disabled(!cue.isPlayable)

            Button {
                store.pauseTranscriptPlayback()
            } label: {
                Label("Pause Playback", systemImage: "pause.fill")
            }
            .disabled(store.playbackSessionState.transportState != .playing)

            Button {
                store.stopTranscriptPlayback()
            } label: {
                Label("Stop Playback", systemImage: "stop.fill")
            }
            .disabled(store.playbackSessionState.transportState == .idle || store.playbackSessionState.transportState == .stopped)
        }
        .help(cue.isPlayable ? "Transcript cue has matching audio metadata" : "Transcript cue is missing a matching audio chunk")
    }
}

private struct PlaceholderPane: View {
    var title: String
    var systemImage: String
    var tint: Color

    var body: some View {
        VaultHeroBand(tint: tint) {
            ContentUnavailableView(
                title,
                systemImage: systemImage,
                description: Text("This workflow is still gated by provider smoke, production wiring, or release validation evidence.")
            )
            .frame(maxWidth: .infinity, minHeight: 280)
        }
    }
}
