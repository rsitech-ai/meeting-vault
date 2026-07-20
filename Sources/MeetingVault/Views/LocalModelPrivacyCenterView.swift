import MeetingVaultCore
import SwiftUI

struct LocalModelPrivacyCenterView: View {
    @EnvironmentObject private var modelStore: LocalModelPrivacyCenterStore
    var microphoneStatus: String
    var systemAudioStatus: String
    var speechRecognitionStatus: String

    @State private var pendingRemovalID: String?
    @State private var confirmsNetworkMode = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VaultSectionHeader(
                "Local Models & Privacy",
                subtitle: "Install and verify local transcription assets before recording.",
                systemImage: "lock.laptopcomputer"
            )

            Text("Local transcription consumes authoritative captured audio frames under verified local model leases and never auto-downloads while recording.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Local transcription uses verified on-device models and captured audio frames")

            VStack(spacing: 0) {
                ForEach(modelStore.units) { unit in
                    LocalModelUnitRow(
                        unit: unit,
                        state: modelStore.states[unit.id],
                        selfCheck: modelStore.lastSelfChecks[unit.id],
                        install: { Task { await modelStore.install(unit.id) } },
                        cancel: { Task { await modelStore.cancel(unit.id) } },
                        repair: { Task { await modelStore.repair(unit.id) } },
                        prewarm: { Task { await modelStore.prewarm(unit.id) } },
                        prewarmAvailable: modelStore.isPrewarmAvailable,
                        remove: { pendingRemovalID = unit.id }
                    )
                    if unit.id != modelStore.units.last?.id {
                        Divider().padding(.vertical, 8)
                    }
                }
            }

            if modelStore.units.isEmpty {
                ContentUnavailableView(
                    "Local model metadata unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text("Restart MeetingVault after restoring its signed model manifest.")
                )
                .accessibilityLabel("Local model metadata unavailable")
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Transcription privacy mode").font(.headline)
                Picker("Transcription privacy mode", selection: privacySelection) {
                    Text("Local only").tag(TranscriptionPrivacyMode.localOnly)
                    Text("Apple on-device compatibility").tag(TranscriptionPrivacyMode.appleOnDeviceCompatible)
                    Text("Apple compatibility — may use network").tag(TranscriptionPrivacyMode.appleMayUseNetwork)
                }
                .pickerStyle(.menu)
                .accessibilityHint("Choose whether transcription must remain local or may use Apple Speech compatibility")
                .accessibilityIdentifier("local-model-privacy-mode")
                Text(modelStore.privacyMode.networkTruth)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                permissionRow("Microphone", microphoneStatus)
                permissionRow("System audio", systemAudioStatus)
                permissionRow("Speech Recognition", speechRecognitionStatus)
            }
            .font(.caption)

            Text("Model installation uses only approved HTTPS sources. Recording and provider loading never start a download.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Local model network behavior")
            Text(modelStore.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Local model status")
                .accessibilityIdentifier("local-model-status")
        }
        .vaultGlassPanel(cornerRadius: 18, tint: .indigo)
        .accessibilityIdentifier("local-model-privacy-center")
        .task { await modelStore.refresh() }
        .confirmationDialog(
            "Remove this verified local model?",
            isPresented: Binding(
                get: { pendingRemovalID != nil },
                set: { if !$0 { pendingRemovalID = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                guard let id = pendingRemovalID else { return }
                pendingRemovalID = nil
                Task { await modelStore.remove(id) }
            }
            Button("Cancel", role: .cancel) { pendingRemovalID = nil }
        } message: {
            Text("Removal is blocked while recording or final processing holds a model lease.")
        }
        .confirmationDialog(
            "Allow Apple Speech network compatibility?",
            isPresented: $confirmsNetworkMode,
            titleVisibility: .visible
        ) {
            Button("Allow may-use-network mode") {
                Task { await modelStore.confirmNetworkPrivacyMode() }
            }
            Button("Keep current mode", role: .cancel) {}
        } message: {
            Text("When on-device recognition is unavailable, Apple Speech may process audio on Apple servers. Speech permission alone never enables this mode.")
        }
    }

    private var privacySelection: Binding<TranscriptionPrivacyMode> {
        Binding(
            get: { modelStore.privacyMode },
            set: { mode in
                if mode == .appleMayUseNetwork {
                    confirmsNetworkMode = true
                } else {
                    Task { await modelStore.selectPrivacyMode(mode) }
                }
            }
        )
    }

    @ViewBuilder
    private func permissionRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).multilineTextAlignment(.leading)
        }
    }
}

private struct LocalModelUnitRow: View {
    var unit: LocalModelInstallUnit
    var state: LocalModelAssetState?
    var selfCheck: ModelSelfCheck?
    var install: () -> Void
    var cancel: () -> Void
    var repair: () -> Void
    var prewarm: () -> Void
    var prewarmAvailable: Bool
    var remove: () -> Void

    var body: some View {
        DisclosureGroup {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                detail("Provider", unit.provider)
                detail("Model", unit.model)
                detail("Version", unit.version)
                detail("Source", unit.source)
                detail("License", unit.licenseName)
                detail("Size", ByteCountFormatter.string(fromByteCount: unit.expectedBytes, countStyle: .file))
                detail("Location", unit.relativeLocation)
                GridRow {
                    Text("SHA-256").foregroundStyle(.secondary)
                    Text(unit.aggregateSHA256)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                detail("Files", "\(unit.fileCount) manifest-verified files")
                detail("Inference", "Local; network is used only for explicit installation")
                detail("Last self-check", selfCheckDescription)
            }
            .font(.caption)
            .padding(.top, 8)
        } label: {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(unit.model).font(.headline)
                    Text(unit.id).font(.caption).foregroundStyle(.secondary)
                    if let state, state.status == .downloading {
                        ProgressView(value: Double(state.completedBytes), total: Double(max(1, state.totalBytes)))
                            .accessibilityLabel("\(unit.model) install progress")
                            .accessibilityValue("\(state.completedBytes) of \(state.totalBytes) bytes")
                    }
                }
                Spacer()
                Text(statusTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusColor)
                actions
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(unit.model), \(statusTitle)")
        .accessibilityHint("Show provider, model, version, source, license, size, SHA-256, location, and local-network details")
    }

    @ViewBuilder
    private var actions: some View {
        switch state?.status ?? .notInstalled {
        case .notInstalled:
            Button("Install", action: install)
                .accessibilityLabel("Install \(unit.model)")
                .accessibilityHint("Download from the approved source, verify every file, and promote atomically")
        case .downloading, .verifying:
            Button("Cancel", action: cancel)
                .accessibilityLabel("Cancel \(unit.model) install")
                .accessibilityHint("Keep private verified resume data without making the model selectable")
        case .repairNeeded:
            Button("Repair", action: repair)
                .accessibilityLabel("Repair \(unit.model)")
                .accessibilityHint("Verify existing files and download only missing or invalid files")
        case .ready:
            HStack(spacing: 6) {
                Button("Prewarm", action: prewarm)
                    .disabled(!prewarmAvailable)
                    .accessibilityLabel("Prewarm \(unit.model)")
                    .accessibilityHint("Run the bounded local provider self-check")
                Button("Remove", role: .destructive, action: remove)
                    .accessibilityLabel("Remove \(unit.model)")
                    .accessibilityHint("Remove only when no recording or final pass uses this model")
            }
        case .unsupported:
            Text("Unsupported").foregroundStyle(.secondary)
        }
    }

    private var statusTitle: String {
        switch state?.status ?? .notInstalled {
        case .notInstalled: "Not Installed"
        case .downloading: "Downloading"
        case .verifying: "Verifying"
        case .ready: "Ready"
        case .repairNeeded: "Repair Needed"
        case .unsupported: "Unsupported"
        }
    }

    private var statusColor: Color {
        switch state?.status ?? .notInstalled {
        case .ready: .green
        case .repairNeeded: .orange
        case .downloading, .verifying: .blue
        case .notInstalled, .unsupported: .secondary
        }
    }

    private var selfCheckDescription: String {
        guard let selfCheck else { return "Not run" }
        return selfCheck.passed ? "Passed in \(selfCheck.duration.formatted(.number.precision(.fractionLength(2)))) s" : "Failed"
    }

    @ViewBuilder
    private func detail(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }
}
