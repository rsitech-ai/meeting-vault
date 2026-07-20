import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MeetingVaultCore

struct MeetingLibraryView: View {
    @EnvironmentObject private var store: MeetingVaultStore
    @State private var searchText = ""
    @State private var pendingDeleteMeeting: MeetingRecord?

    private var filteredMeetings: [MeetingRecord] {
        guard !searchText.isEmpty else { return store.meetings }
        return store.meetings.filter {
            $0.title.localizedCaseInsensitiveContains(searchText)
                || $0.sourceName.localizedCaseInsensitiveContains(searchText)
                || ($0.summary?.oneParagraph.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }

    var body: some View {
        HSplitView {
            List(selection: $store.selectedMeetingID) {
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
            .safeAreaInset(edge: .top) {
                LibraryHeaderView(meetingCount: store.meetings.count)
            }
            .searchable(text: $searchText, placement: .sidebar, prompt: "Search meetings")
            .frame(minWidth: 280, idealWidth: 340)

            MeetingDetailView(meeting: store.selectedMeeting)
                .frame(minWidth: 560)
        }
        .background(VaultSceneBackground(tint: .blue))
        .navigationTitle("Library")
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

    private func deleteMeeting(_ meeting: MeetingRecord) {
        defer { pendingDeleteMeeting = nil }
        do {
            try store.deleteMeetingFromLibrary(meetingID: meeting.id)
        } catch {
            store.logger.error("Library delete confirmation failed")
        }
    }
}

struct LibraryHeaderView: View {
    var meetingCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Private meeting vault")
                        .font(.title3.weight(.semibold))
                    Text("\(meetingCount) local records · encrypted-first workflow")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                VaultLiveSignal(tint: .blue, barCount: 7, compact: true)
            }

            VaultFlowDivider(tint: .blue)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

struct MeetingLibraryRow: View {
    @Environment(\.vaultReduceMotion) private var reduceMotion
    @EnvironmentObject private var store: MeetingVaultStore
    @State private var isHovered = false

    var meeting: MeetingRecord
    var selected: Bool
    var onDelete: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(meeting.title)
                    .font(.headline)
                    .lineLimit(1)
                    .accessibilityIdentifier("meeting-row-title-\(meeting.id.uuidString)")
                Spacer(minLength: 8)
                Image(systemName: meeting.state.statusSymbol)
                    .foregroundStyle(meeting.state.statusTint)
                    .imageScale(.small)
                    .symbolEffect(.pulse, options: .speed(0.8), value: !reduceMotion && meeting.state == .processing)
            }

            HStack(spacing: 8) {
                Label(meeting.sourceName, systemImage: "app.connected.to.app.below.fill")
                Text("·")
                Text(meeting.state.displayTitle)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(
            selected ? Color.accentColor.opacity(0.12) : (isHovered ? Color.primary.opacity(0.045) : .clear),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .animation(reduceMotion ? nil : VaultMotion.selection, value: selected)
        .animation(reduceMotion ? nil : VaultMotion.selection, value: isHovered)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Meeting row. \(meeting.title), \(meeting.sourceName), \(meeting.state.displayTitle)")
        .accessibilityIdentifier("meeting-record-row-\(meeting.id.uuidString)")
        .accessibilityHint(onDelete == nil ? "Open the context menu for meeting actions." : "Open the context menu for meeting actions, including Delete Recording.")
        .help("\(meeting.title), \(meeting.state.displayTitle), \(Int(meeting.durationSeconds / 60)) minutes")
        .contextMenu {
            Button {
                store.selectedMeetingID = meeting.id
                store.showWorkspace(.find)
            } label: {
                Label("Open Meeting", systemImage: "rectangle.stack")
            }

            Button {
                store.selectedMeetingID = meeting.id
                store.showWorkspace(.understand)
            } label: {
                Label("Open Agent", systemImage: "sparkles")
            }

            Button {
                store.selectedMeetingID = meeting.id
                store.copyVisibleTranscript()
            } label: {
                Label("Copy Transcript", systemImage: "doc.on.doc")
            }

            if let onDelete {
                Divider()

                Button(role: .destructive, action: onDelete) {
                    Label("Delete Recording", systemImage: "trash")
                }
            }
        }
    }
}

struct MeetingDetailView: View {
    @Environment(\.vaultReduceMotion) private var reduceMotion

    var meeting: MeetingRecord?

    var body: some View {
        Group {
            if let meeting {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        HeaderBlock(meeting: meeting)

                        LibraryAgentRouteBlock()
                        LibraryVisibleTranscriptBlock()
                        LocalRecordingImportBlock()

                        if let summary = meeting.summary {
                            SummaryBlock(summary: summary)
                        } else {
                            ContentUnavailableView(
                                "Processing Not Started",
                                systemImage: "text.badge.clock",
                                description: Text("The recording is safe, but transcript and intelligence passes still need to run.")
                            )
                            .vaultGlassPanel(cornerRadius: 20, tint: .orange)
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ContentUnavailableView("No Meeting Selected", systemImage: "tray")
            }
        }
        .animation(VaultMotion.reveal(reduceMotion: reduceMotion), value: meeting?.id)
    }
}

struct LibraryAgentRouteBlock: View {
    @EnvironmentObject private var store: MeetingVaultStore

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VaultSectionHeader(
                "Transcript Agent",
                subtitle: "Use Agent for presets, custom prompts, editable responses, evidence, and copy actions.",
                systemImage: "sparkles"
            )
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 8) {
                Button {
                    store.showWorkspace(.understand)
                } label: {
                    Label("Open Agent", systemImage: "arrow.right.circle")
                        .frame(minWidth: 150, minHeight: 42)
                }
                .buttonStyle(.glassProminent)
                .disabled(store.transcriptEditDraft.segments.isEmpty)
                .help("Open the transcript agent for prompts, editable answers, evidence, and copy actions")

                VaultStatusPill(
                    label: store.transcriptEditDraft.segments.isEmpty ? "no transcript" : "\(store.transcriptEditDraft.segments.count) segment(s)",
                    systemImage: "text.quote",
                    tint: store.transcriptEditDraft.segments.isEmpty ? .secondary : .purple,
                    isActive: !store.transcriptEditDraft.segments.isEmpty
                )
            }
        }
        .vaultGlassPanel(cornerRadius: 20, tint: .blue, interactive: true)
        .accessibilityIdentifier("library-agent-route")
    }
}

struct LocalRecordingImportBlock: View {
    @EnvironmentObject private var store: MeetingVaultStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VaultSectionHeader(
                    "Local Recording Import",
                    subtitle: "Choose a folder or one/more transcript and recording files, import them, then continue in the visible transcript agent.",
                    systemImage: "waveform.badge.plus"
                )
                Spacer()
                Button {
                    Task {
                        try? await store.importSelectedLocalRecordingSample()
                    }
                } label: {
                    Label("Import Selected", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.glassProminent)
                .disabled(store.selectedLocalRecordingSampleID == nil)
                .help("Import the selected local transcript and recording")
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    importChooserButtons
                }

                VStack(alignment: .leading, spacing: 8) {
                    importChooserButtons
                }
            }

            HStack(spacing: 10) {
                Picker(
                    "Sample",
                    selection: Binding(
                        get: { store.selectedLocalRecordingSampleID ?? "" },
                        set: { store.selectLocalRecordingSample(id: $0.isEmpty ? nil : $0) }
                    )
                ) {
                    if store.localRecordingSamples.isEmpty {
                        Text("No matched samples").tag("")
                    } else {
                        ForEach(store.localRecordingSamples) { sample in
                            Text("\(sample.title) · \(sample.audioURL.pathExtension.uppercased()) · \(byteCount(sample.audioByteCount))")
                                .tag(sample.id)
                        }
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
                .help("Choose a matched local transcript/audio pair")

                Button {
                    store.refreshLocalRecordingSamples()
                } label: {
                    Label("Scan Samples", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.glass)
                .help("Scan local transcript and recording folders for matched samples")
            }

            Text(store.localRecordingSampleStatus)
                .font(.callout)
                .foregroundStyle(.secondary)
                .contentTransition(.opacity)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Transcript")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    TextField(
                        "Transcript path (.txt, .srt, .vtt)",
                        text: Binding(
                            get: { store.localRecordingTranscriptPath },
                            set: { store.localRecordingTranscriptPath = $0 }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    .help("Path to a timestamped TXT, SRT, or WebVTT transcript file")
                }

                GridRow {
                    Text("Recording")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    TextField(
                        "Recording path (.mp3, .m4a, .aac, .wav, .aif, .aiff, .aifc, .caf)",
                        text: Binding(
                            get: { store.localRecordingAudioPath },
                            set: { store.localRecordingAudioPath = $0 }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    .help("Path to the matching local recording file")
                }
            }

            HStack(spacing: 10) {
                Button {
                    store.importConfiguredLocalRecording()
                } label: {
                    Label("Import Paths", systemImage: "tray.and.arrow.down")
                }
                .buttonStyle(.glass)
                .help("Import the transcript and recording paths shown above")

                VaultStatusPill(
                    label: "local import",
                    systemImage: "lock.shield",
                    tint: .green,
                    isActive: true
                )
                Text(store.localRecordingImportStatus)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
            }
        }
        .vaultGlassPanel(cornerRadius: 20, tint: .teal)
        .task {
            if store.localRecordingSamples.isEmpty {
                store.refreshLocalRecordingSamples()
            }
        }
    }

    private func byteCount(_ value: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file)
    }

    @ViewBuilder
    private var importChooserButtons: some View {
        Button {
            chooseLocalRecordingFolder()
        } label: {
            Label("Choose Folder", systemImage: "folder")
        }
        .buttonStyle(.glassProminent)
        .help("Choose a folder containing transcript and recording files")

        Button {
            chooseLocalRecordingFiles()
        } label: {
            Label("Choose Files", systemImage: "doc.badge.plus")
        }
        .buttonStyle(.glass)
        .help("Choose one or more transcript and recording files to import")
    }

    private func chooseLocalRecordingFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Local Recording Folder"
        panel.prompt = "Choose Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.urls.first {
            Task {
                try? await store.importLocalRecordingFolder(in: url)
            }
        }
    }

    private func chooseLocalRecordingFiles() {
        let panel = NSOpenPanel()
        panel.title = "Choose Local Recording Files"
        panel.prompt = "Import"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = LocalRecordingImportService.supportedTranscriptExtensions
            .union(LocalRecordingImportService.supportedAudioExtensions)
            .compactMap { UTType(filenameExtension: $0) }

        if panel.runModal() == .OK {
            let urls = panel.urls
            Task {
                try? await store.importLocalRecordingSelection(urls: urls)
            }
        }
    }
}

struct LibraryVisibleTranscriptBlock: View {
    @Environment(\.vaultReduceMotion) private var reduceMotion
    @EnvironmentObject private var store: MeetingVaultStore

    private var visibleSegments: [TranscriptEditDraftSegment] {
        store.transcriptEditDraft.segments.filter { !$0.trimmedEditedText.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VaultSectionHeader(
                    "Selected Transcript",
                    subtitle: transcriptSubtitle,
                    systemImage: "text.quote"
                )
                Spacer()
                Button {
                    store.showWorkspace(.understand)
                } label: {
                    Label("Open Agent", systemImage: "sparkles")
                }
                .buttonStyle(.glassProminent)
                .disabled(!store.transcriptAgentHasVisibleTranscript)
                .help(store.transcriptAgentHasVisibleTranscript ? "Open the full transcript agent and editor workspace" : store.transcriptAgentReadinessStatus)

                Button {
                    store.copyVisibleTranscript()
                } label: {
                    Label("Copy Transcript", systemImage: "doc.on.doc")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.glass)
                .disabled(!store.transcriptAgentHasVisibleTranscript)
                .help(store.transcriptAgentHasVisibleTranscript ? "Copy the visible edited transcript to the clipboard" : store.transcriptAgentReadinessStatus)
                .accessibilityLabel("Copy visible transcript")
                .accessibilityHint(store.transcriptAgentHasVisibleTranscript ? "Copy the visible edited transcript to the clipboard." : store.transcriptAgentReadinessStatus)
            }

            if !store.transcriptAgentHasVisibleTranscript {
                ContentUnavailableView(
                    "Transcript Not Ready",
                    systemImage: "captions.bubble",
                    description: Text(store.transcriptAgentReadinessStatus)
                )
            } else {
                ForEach(visibleSegments) { segment in
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
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 12)
                    }
                    .padding(.vertical, 10)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("transcript-context-row-\(segment.id.uuidString)")
                    .contextMenu {
                        Button {
                            store.copyVisibleTranscript()
                        } label: {
                            Label("Copy Transcript", systemImage: "doc.on.doc")
                        }

                        Button {
                            store.showWorkspace(.understand)
                        } label: {
                            Label("Open Agent", systemImage: "sparkles")
                        }
                    }
                    .help("Transcript segment preview")

                    Divider()
                        .accessibilityIdentifier("transcript-segment-divider-\(segment.id.uuidString)")
                        .accessibilityHidden(true)
                }

                Text("Showing all \(visibleTranscriptCount) selected transcript segment(s).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
            }
        }
        .vaultGlassPanel(cornerRadius: 20, tint: .purple)
        .animation(reduceMotion ? nil : VaultMotion.reveal, value: visibleTranscriptCount)
    }

    private var transcriptSubtitle: String {
        guard store.transcriptAgentHasVisibleTranscript else {
            return store.transcriptAgentReadinessStatus
        }
        let count = visibleTranscriptCount
        return "Prompting uses the full selected edited transcript shown below: \(count) segment(s)."
    }

    private var visibleTranscriptCount: Int {
        store.transcriptEditDraft.segments.filter { !$0.trimmedEditedText.isEmpty }.count
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
}

struct LibraryTranscriptPromptBlock: View {
    @EnvironmentObject private var store: MeetingVaultStore

    private var canAsk: Bool {
        store.transcriptAgentCanAsk
    }

    private var canCopy: Bool {
        !store.transcriptAskAnswerDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VaultSectionHeader(
                    "Agent",
                    subtitle: store.transcriptAgentReadinessStatus,
                    systemImage: "bubble.left.and.text.bubble.right"
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

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    transcriptStatusPills
                }

                VStack(alignment: .leading, spacing: 8) {
                    transcriptStatusPills
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Label("Preset prompts", systemImage: "sparkles.rectangle.stack")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 0) {
                    promptPresetButtons
                }
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Label("Custom prompt", systemImage: "pencil.and.list.clipboard")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                TextEditor(
                    text: Binding(
                        get: { store.transcriptAskPrompt },
                        set: { store.transcriptAskPrompt = $0 }
                    )
                )
                .font(.body)
                .frame(minHeight: 118)
                .scrollContentBackground(.hidden)
                .padding(12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(canAsk ? Color.blue.opacity(0.30) : Color.orange.opacity(0.22), lineWidth: 1)
                }
                .help("Write a custom grounded prompt for the selected meeting transcript")
            }

            HStack(alignment: .center, spacing: 10) {
                Button {
                    store.askSelectedTranscriptFromLibrary()
                } label: {
                    Label("Ask Selected Transcript", systemImage: "sparkles")
                        .frame(minWidth: 220, minHeight: 46)
                }
                .buttonStyle(.glassProminent)
                .disabled(!canAsk)
                .help(canAsk ? "Ask the selected meeting transcript and open the Agent workspace" : "Ask the selected meeting transcript after it is finalized or imported. \(store.transcriptAgentReadinessStatus)")
                .accessibilityLabel("Ask Selected Transcript")
                .accessibilityIdentifier("Ask Selected Transcript Ask the selected meeting transcript")
                .accessibilityHint(canAsk ? "Ask the selected meeting transcript and open the Agent workspace." : store.transcriptAgentReadinessStatus)

                VaultStatusPill(
                    label: store.transcriptAskEvidence.isEmpty ? store.transcriptAgentReadinessStatus : "\(store.transcriptAskEvidence.count) evidence segment(s)",
                    systemImage: store.transcriptAskEvidence.isEmpty ? "scope" : "checkmark.seal",
                    tint: store.transcriptAskEvidence.isEmpty ? .secondary : .green,
                    isActive: !store.transcriptAskEvidence.isEmpty
                )
                Spacer(minLength: 0)
            }

            HStack(alignment: .center, spacing: 10) {
                Label("Editable response", systemImage: "square.and.pencil")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    store.copyTranscriptAskAnswer()
                } label: {
                    Label("Copy Edited Response", systemImage: "doc.on.doc")
                }
                .buttonStyle(.glassProminent)
                .disabled(!canCopy)
                .help("Copy the edited response to the clipboard")
            }

            TextEditor(
                text: Binding(
                    get: { store.transcriptAskAnswerDraft },
                    set: { store.updateTranscriptAskAnswerDraft($0) }
                )
            )
            .font(.callout)
            .frame(minHeight: 136)
            .scrollContentBackground(.hidden)
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
            }
            .help("Edit the response before copying it")

            if !store.transcriptConversationTurns.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Recent prompts", systemImage: "clock.arrow.circlepath")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    ForEach(store.transcriptConversationTurns.prefix(3)) { turn in
                        LibraryPromptTurnRow(turn: turn)
                    }
                }
                .transition(.opacity)
            }
        }
        .vaultGlassPanel(cornerRadius: 20, tint: .blue)
    }

    @ViewBuilder
    private var transcriptStatusPills: some View {
        VaultStatusPill(
            label: store.transcriptAgentHasVisibleTranscript ? "\(store.transcriptEditDraft.segments.count) visible segments" : "no transcript",
            systemImage: "text.quote",
            tint: store.transcriptAgentHasVisibleTranscript ? .purple : .secondary,
            isActive: store.transcriptAgentHasVisibleTranscript
        )
        VaultStatusPill(
            label: canAsk ? "prompt ready" : (store.transcriptAgentHasVisibleTranscript ? "write prompt" : "finalize transcript"),
            systemImage: canAsk ? "checkmark.circle" : "pencil",
            tint: canAsk ? .green : .orange,
            isActive: canAsk
        )
        VaultStatusPill(
            label: canCopy ? "editable response ready" : "answer pending",
            systemImage: canCopy ? "square.and.pencil" : "hourglass",
            tint: canCopy ? .green : .secondary,
            isActive: canCopy
        )
    }

    @ViewBuilder
    private var promptPresetButtons: some View {
        ForEach(Array(TranscriptPromptPreset.allCases.enumerated()), id: \.element.id) { index, preset in
            TranscriptPromptPresetRow(preset: preset) {
                store.applyTranscriptPromptPreset(preset)
            }

            if index < TranscriptPromptPreset.allCases.count - 1 {
                Divider()
                    .padding(.leading, 34)
            }
        }
    }
}

private struct TranscriptPromptPresetRow: View {
    var preset: TranscriptPromptPreset
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: preset.systemImage)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.title)
                        .font(.callout.weight(.semibold))
                    Text(preset.prompt)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .help("Use the \(preset.title.lowercased()) prompt")
        .accessibilityLabel(preset.title)
        .accessibilityHint("Use this preset prompt for the selected transcript")
    }
}

private struct LibraryPromptTurnRow: View {
    var turn: TranscriptConversationTurn

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(turn.createdAt, style: .time)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 64, alignment: .leading)

                Text(turn.question)
                    .font(.callout.weight(.semibold))
                    .lineLimit(2)

                Spacer(minLength: 8)

                VaultStatusPill(
                    label: "\(turn.evidence.count) evidence",
                    systemImage: turn.evidence.isEmpty ? "scope" : "checkmark.seal",
                    tint: turn.evidence.isEmpty ? .secondary : .green,
                    isActive: !turn.evidence.isEmpty
                )
            }

            Text(turn.answerDraft)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .help("Recent transcript prompt and editable response")
    }
}

struct HeaderBlock: View {
    @Environment(\.vaultReduceMotion) private var reduceMotion

    var meeting: MeetingRecord

    var body: some View {
        VaultHeroBand(tint: meeting.state.statusTint) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        VaultStatusPill(
                            label: meeting.state.displayTitle,
                            systemImage: meeting.state.statusSymbol,
                            tint: meeting.state.statusTint,
                            isActive: meeting.state == .processing || meeting.state == .recording
                        )
                        Text(meeting.title)
                            .font(.largeTitle.weight(.semibold))
                            .lineLimit(2)
                    }
                    Spacer()
                    Image(systemName: "waveform.badge.magnifyingglass")
                        .font(.system(size: 42, weight: .semibold))
                        .foregroundStyle(.tint)
                        .symbolEffect(.pulse, options: .speed(0.65), value: !reduceMotion && meeting.state == .processing)
                }

                HStack(spacing: 12) {
                    VaultStatusPill(label: meeting.sourceName, systemImage: "app.connected.to.app.below.fill", tint: .blue)
                    VaultStatusPill(label: meeting.consentStatus.rawValue, systemImage: "hand.raised", tint: .green)
                    VaultStatusPill(label: durationText, systemImage: "clock", tint: .orange)
                }
            }
        }
    }

    private var durationText: String {
        let minutes = Int(meeting.durationSeconds / 60)
        return "\(minutes)m"
    }
}

struct SummaryBlock: View {
    var summary: MeetingSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VaultSectionHeader(
                "Grounded Summary",
                subtitle: "Evidence-linked meeting intelligence generated from transcript artifacts.",
                systemImage: "sparkles"
            )

            Text(summary.oneParagraph)
                .font(.title3.weight(.medium))

            VStack(alignment: .leading, spacing: 10) {
                ForEach(summary.bullets, id: \.self) { bullet in
                    Label(bullet, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.primary)
                }
            }

            EvidenceSection(title: "Decisions", items: summary.decisions.map { ($0.title, $0.evidence.first?.startTime) })
            EvidenceSection(title: "Actions", items: summary.actionItems.map { ($0.title, $0.evidence.first?.startTime) })
            EvidenceSection(title: "Open Questions", items: summary.openQuestions.map { ($0.question, $0.evidence.first?.startTime) })
            EvidenceSection(title: "Risks", items: summary.risks.map { ("\($0.severity.rawValue.uppercased()) · \($0.title)", $0.evidence.first?.startTime) })
        }
        .vaultGlassPanel(cornerRadius: 20, tint: .purple)
    }
}

private struct EvidenceSection: View {
    var title: String
    var items: [(String, TimeInterval?)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            ForEach(items, id: \.0) { item in
                HStack {
                    Text(item.0)
                        .lineLimit(2)
                        .layoutPriority(1)
                    Spacer()
                    Text(timestamp(item.1))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                .padding(10)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }

    private func timestamp(_ value: TimeInterval?) -> String {
        guard let value else { return "No evidence" }
        let minutes = Int(value) / 60
        let seconds = Int(value) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
