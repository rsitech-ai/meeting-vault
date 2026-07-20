import SwiftUI
import MeetingVaultCore

struct ProcessingStatusBlock: View {
    @Environment(\.vaultReduceMotion) private var reduceMotion
    @EnvironmentObject private var store: MeetingVaultStore

    private var progress: RecordingProcessingProgress {
        store.recordingProcessingProgress ?? RecordingProcessingProgress(
            stage: .preparingBundle,
            fractionCompleted: 0,
            message: store.recordingProcessingStatus
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VaultSectionHeader(
                    "Processing",
                    subtitle: store.recordingProcessingStatus,
                    systemImage: store.recordingState == .processing ? "gearshape.2.fill" : "checkmark.seal"
                )

                Spacer()

                VaultStatusPill(
                    label: stageLabel(progress.stage),
                    systemImage: store.recordingState == .processing ? "hourglass" : "checkmark.circle",
                    tint: store.recordingState == .error ? .red : store.recordingState.statusTint,
                    isActive: store.recordingState == .processing
                )
            }

            ProgressView(value: progress.fractionCompleted)
                .progressViewStyle(.linear)
                .tint(store.recordingState.statusTint)
                .animation(reduceMotion ? nil : VaultMotion.selection, value: progress.fractionCompleted)
                .accessibilityLabel("Recording processing progress")
                .accessibilityValue("\(Int(progress.fractionCompleted * 100)) percent")

            HStack(spacing: 12) {
                Text(progress.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)

                Spacer()

                Button {
                    Task {
                        try? await store.retryRecordingProcessing()
                    }
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.glassProminent)
                .disabled(store.recordingProcessingFailureStage == nil)
                .help("Retry the last failed recording processing job")

                Button {
                    Task { await store.cancelRecordingProcessing() }
                } label: {
                    Label("Cancel Processing", systemImage: "xmark.circle")
                }
                .buttonStyle(.glass)
                .disabled(store.recordingState != .processing)
                .help("Cancel the active local recording processing job")
            }

            if store.hasRecordingCaptureRecoveryActions {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 12) {
                        recoveryStatusLabel
                        Spacer(minLength: 0)
                        detectInputsButton
                        openRecoveryButton
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        recoveryStatusLabel
                        HStack(spacing: 10) {
                            detectInputsButton
                            openRecoveryButton
                        }
                    }
                }
                .padding(10)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Recording recovery")
                .accessibilityValue(store.recordingProcessingRecoveryStatus)
            }
        }
        .vaultGlassPanel(cornerRadius: 20, tint: store.recordingState.statusTint)
    }

    private var recoveryStatusLabel: some View {
        Label(store.recordingProcessingRecoveryStatus, systemImage: "wrench.and.screwdriver")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var detectInputsButton: some View {
        Button {
            Task {
                await store.refreshInputsForRecordingRecovery()
            }
        } label: {
            Label("Detect Inputs", systemImage: "arrow.triangle.2.circlepath")
        }
        .buttonStyle(.glass)
        .help("Re-detect connected microphones and headsets before retrying capture")
    }

    private var openRecoveryButton: some View {
        Button {
            store.openRecordingRecoveryReview()
        } label: {
            Label("Open Recovery", systemImage: "waveform.path.badge.plus")
        }
        .buttonStyle(.glass)
        .help("Open Health & Recovery to review any incomplete encrypted recording bundles")
    }

    private func stageLabel(_ stage: RecordingProcessingStage) -> String {
        switch stage {
        case .preparingBundle:
            "Prepare"
        case .recordingAudio:
            "Capture"
        case .transcribingAudio:
            "Transcribe"
        case .generatingIntelligence:
            "AI"
        case .savingLibrary:
            "Save"
        case .finished:
            "Done"
        }
    }
}

struct RecorderReadinessStrip: View {
    @EnvironmentObject private var store: MeetingVaultStore

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                readinessPill
                inputPill
                transcriptPill
            }

            VStack(alignment: .leading, spacing: 8) {
                readinessPill
                inputPill
                transcriptPill
            }
        }
        .vaultGlassPanel(cornerRadius: 18, tint: store.recordingState.statusTint)
    }

    private var readinessPill: some View {
        VaultStatusPill(
            label: readinessLabel,
            systemImage: store.latestPreflightResult == nil ? "exclamationmark.shield.fill" : "checkmark.shield",
            tint: store.preflightResult.canRecord ? .green : .orange,
            isActive: store.preflightResult.canRecord
        )
        .help("MeetingVault checks recording readiness automatically before Start")
    }

    private var readinessLabel: String {
        guard store.latestPreflightResult != nil else { return "readiness pending" }
        let issues = store.preflightResult.issues
        if issues.contains(.audioPermissionMissing),
           issues.contains(.microphonePermissionMissing),
           issues.contains(.speechPermissionMissing) {
            return "Screen + Mic + Speech blocked"
        }
        if issues.contains(.audioPermissionMissing) { return "Screen & System Audio blocked" }
        if issues.contains(.microphonePermissionMissing) { return "Microphone blocked" }
        if issues.contains(.speechPermissionMissing) { return "Speech Recognition blocked" }
        return store.recordingReadinessTitle
    }

    private var inputPill: some View {
        VaultStatusPill(
            label: store.selectedAudioInputDevice?.displayName ?? "input auto-detect",
            systemImage: store.selectedAudioInputDevice?.transportLabel == "Bluetooth" ? "airpodspro" : "mic",
            tint: store.selectedAudioInputDevice == nil ? .secondary : .green,
            isActive: store.recordingState == .recording
        )
        .help("Start Recording refreshes connected audio inputs before capture")
    }

    private var transcriptPill: some View {
        VaultStatusPill(
            label: store.liveTranscriptPreviewSegments.isEmpty ? "live transcript ready" : "\(store.liveTranscriptPreviewSegments.count) live lines",
            systemImage: "captions.bubble",
            tint: store.recordingState == .recording ? .red : .blue,
            isActive: store.recordingState == .recording
        )
        .help("Partial transcript lines appear during recording when the live provider is available")
    }
}

struct SourcePickerBlock: View {
    @EnvironmentObject private var store: MeetingVaultStore

    private var sourceChoiceColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 150), spacing: 8, alignment: .leading)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VaultSectionHeader(
                "Capture Source",
                subtitle: "Pick the app, process group, or fallback capture mode before recording.",
                systemImage: "dot.radiowaves.left.and.right"
            )

            LazyVGrid(columns: sourceChoiceColumns, alignment: .leading, spacing: 8) {
                ForEach(store.sources) { source in
                    CaptureSourceChoiceButton(
                        source: source,
                        selected: source.id == store.selectedSourceID
                    ) {
                        store.selectedSourceID = source.id
                    }
                }
            }
            .accessibilityIdentifier("capture-source-choice-row")

            VStack(spacing: 10) {
                ForEach(store.sources) { source in
                    SourceRow(source: source, selected: source.id == store.selectedSourceID)
                }
            }
        }
        .vaultGlassPanel(cornerRadius: 20, tint: .blue)
    }
}

private struct CaptureSourceChoiceButton: View {
    var source: CaptureSource
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(source.displayName, systemImage: source.isRecommended ? "star.circle.fill" : "waveform")
                .font(.caption.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    selected ? Color.blue.opacity(0.18) : Color.secondary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(selected ? Color.blue.opacity(0.45) : Color.secondary.opacity(0.14), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(source.displayName)
        .accessibilityValue(selected ? "selected" : "not selected")
        .accessibilityIdentifier("capture-source-\(source.id)")
        .help("Use \(source.displayName) as the recording capture source")
    }
}

private struct SourceRow: View {
    @Environment(\.vaultReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var source: CaptureSource
    var selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: source.isRecommended ? "star.circle.fill" : "waveform")
                .foregroundStyle(source.isRecommended ? .yellow : .secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(source.displayName)
                        .font(.subheadline.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    if selected {
                        Text("selected")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.blue)
                    }
                }
                Text(source.mode.displayLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(source.mode.displayLabel)
                    .accessibilityIdentifier("capture-source-mode-\(source.id)")
                VaultAudioLevelBar(value: source.level, tint: selected ? .blue : .secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(selected ? AnyShapeStyle(.thinMaterial) : AnyShapeStyle(Color.secondary.opacity(0.08)))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(selected ? Color.blue.opacity(0.35) : .clear, lineWidth: 1)
        }
        .contentTransition(.opacity)
        .background(
            isHovered ? Color.primary.opacity(0.035) : .clear,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .animation(reduceMotion ? nil : VaultMotion.selection, value: selected)
        .animation(reduceMotion ? nil : VaultMotion.selection, value: isHovered)
        .onHover { isHovered = $0 }
        .help("\(source.displayName), \(source.mode.displayLabel), level \(Int(source.level * 100)) percent")
    }
}

private extension CaptureMode {
    var displayLabel: String {
        switch self {
        case .selectedApplication: "Selected application"
        case .processGroup: "Application process group"
        case .systemAudio: "System audio"
        case .outputDevice: "Output device"
        case .microphone: "Microphone"
        case .screenCaptureFallback: "ScreenCaptureKit fallback"
        }
    }
}

struct LiveTranscriptionPreviewBlock: View {
    @Environment(\.vaultReduceMotion) private var reduceMotion
    @EnvironmentObject private var store: MeetingVaultStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VaultSectionHeader(
                    "Live Transcript Stream",
                    subtitle: "\(store.liveTranscriptionStatus). Partial lines appear here before the final transcript pass.",
                    systemImage: "captions.bubble"
                )
            }

            if store.liveTranscriptPreviewSegments.isEmpty {
                HStack(alignment: .center, spacing: 14) {
                    VaultPulseHalo(
                        tint: store.recordingState == .recording ? .red : .blue,
                        isActive: store.recordingState == .recording,
                        size: 72,
                        systemImage: "waveform"
                    )
                    VStack(alignment: .leading, spacing: 5) {
                        Text(store.recordingState == .recording ? "Listening for speech" : "Ready for live transcription")
                            .font(.title3.weight(.semibold))
                        Text("Start recording to see real-time partial transcript lines here as soon as the provider emits speech.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(12)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else {
                ForEach(store.liveTranscriptPreviewSegments) { segment in
                    HStack(alignment: .top, spacing: 12) {
                        Text(timeRange(segment))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 82, alignment: .leading)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(segment.speakerName)
                                    .font(.caption.weight(.semibold))
                                VaultStatusPill(
                                    label: segment.isFinal ? "final" : "live",
                                    systemImage: segment.isFinal ? "checkmark.seal" : "waveform",
                                    tint: segment.isFinal ? .green : .red,
                                    isActive: !segment.isFinal && store.recordingState == .recording
                                )
                            }
                            Text(segment.text)
                                .font(segment.id == store.liveTranscriptPreviewSegments.last?.id ? .title3.weight(.semibold) : .callout)
                                .lineLimit(3)
                        }
                        Spacer()
                    }
                    .padding(12)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
        }
        .vaultGlassPanel(cornerRadius: 24, tint: store.recordingState == .recording ? .red : .blue, interactive: true)
        .animation(reduceMotion ? nil : VaultMotion.selection, value: store.liveTranscriptPreviewSegments)
    }

    private func timeRange(_ segment: TranscriptSegment) -> String {
        "\(durationText(segment.startTime))-\(durationText(segment.endTime))"
    }

    private func durationText(_ seconds: TimeInterval) -> String {
        let totalSeconds = max(0, Int(seconds.rounded(.down)))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

struct PreflightBlock: View {
    @Environment(\.vaultReduceMotion) private var reduceMotion
    @EnvironmentObject private var store: MeetingVaultStore

    var result: RecordingPreflightResult
    var recoveryActions: [PermissionRecoveryAction]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VaultSectionHeader(
                "Preflight",
                subtitle: result.canRecord
                    ? "Permissions are ready for recording with the selected input."
                    : "Recording stays fail-closed until permissions, consent, and disk checks are green.",
                systemImage: result.canRecord ? "checkmark.shield.fill" : "exclamationmark.shield.fill"
            )

            if result.canRecord {
                Label("Ready to record", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.headline)
                    .transition(
                        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.97))
                    )
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(result.issues, id: \.rawValue) { issue in
                        Label(message(for: issue, result: result), systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    if result.issues.contains(.diskSpaceLow) {
                        HStack(alignment: .center, spacing: 10) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Storage Recovery")
                                    .font(.subheadline.weight(.semibold))
                                Text("Review expired MeetingVault recordings in Diagnostics before deleting anything.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer(minLength: 12)

                            Button {
                                store.reviewStoragePressure()
                            } label: {
                                Label("Review Storage", systemImage: "internaldrive")
                            }
                            .buttonStyle(.glass)
                            .help("Open Diagnostics Retention Review")
                        }
                        .padding(.top, 4)

                        Text(store.storageRecoveryStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .contentTransition(.opacity)
                    }
                    ForEach(recoveryActions, id: \.kind.rawValue) { action in
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(action.title)
                                    .font(.subheadline.weight(.semibold))
                                Text(action.message)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer(minLength: 12)

                            if action.kind == .microphone && store.microphoneAuthorizationState == .notDetermined {
                                Button {
                                    Task {
                                        await store.requestMicrophoneAuthorizationOnce()
                                    }
                                } label: {
                                    Label("Request Once", systemImage: "mic.badge.plus")
                                }
                                .buttonStyle(.glassProminent)
                                .help("Ask macOS for Microphone permission once")
                            } else if action.kind == .speechRecognition && store.appleSpeechAuthorizationState == .notDetermined {
                                Button {
                                    Task {
                                        await store.requestAppleSpeechAuthorizationOnce()
                                    }
                                } label: {
                                    Label("Request Once", systemImage: "hand.raised")
                                }
                                .buttonStyle(.glassProminent)
                                .help("Ask macOS for Speech Recognition permission once")
                            } else {
                                Button {
                                    store.openPermissionRecoverySettings(kind: action.kind)
                                } label: {
                                    Label("Open Settings", systemImage: "gearshape")
                                }
                                .buttonStyle(.glass)
                                .help("Open the matching System Settings permission pane")
                            }
                        }
                        .padding(.top, 4)
                    }

                    if store.hasPermissionRecoveryActions {
                        Text(store.permissionRecoveryStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .contentTransition(.opacity)
                    }
                }
                .transition(.opacity)
            }
        }
        .vaultGlassPanel(cornerRadius: 20, tint: result.canRecord ? .green : .orange)
        .animation(reduceMotion ? nil : VaultMotion.selection, value: result.canRecord)
    }

    private func message(for issue: PreflightIssue, result: RecordingPreflightResult) -> String {
        switch issue {
        case .audioPermissionMissing:
            "Screen & System Audio Recording permission is not granted."
        case .microphonePermissionMissing:
            "Microphone permission is not granted."
        case .speechPermissionMissing:
            "Speech Recognition permission is not granted."
        case .diskSpaceLow:
            if let estimate = result.storageEstimate {
                "Free storage is \(byteCount(estimate.availableBytes)); MeetingVault requires \(byteCount(estimate.requiredFreeDiskBytes)) for a 3-hour two-track recording plus transcript and safety reserve."
            } else {
                "Free storage is below the long-recording safety threshold."
            }
        case .consentRequired:
            "Consent or disclosure status is required before recording."
        case .doNotRecord:
            "This meeting is marked do not record."
        }
    }

    private func byteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
