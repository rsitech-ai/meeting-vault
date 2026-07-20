import MeetingVaultCore
import SwiftUI

struct MiniRecorderSpeakerPresentation: Equatable {
    var title: String
    var systemImage: String
    var isOverlap: Bool

    static func resolve(
        segments: [TranscriptSegment],
        elapsedTime: TimeInterval,
        evidenceGrace: TimeInterval = 1.5
    ) -> MiniRecorderSpeakerPresentation {
        let activeNames = Set(segments.compactMap { segment -> String? in
            guard segment.startTime <= elapsedTime,
                  segment.endTime >= elapsedTime else {
                return nil
            }
            return normalizedName(segment.speakerName)
        })
        if activeNames.count > 1 {
            return MiniRecorderSpeakerPresentation(
                title: "Overlapping speakers",
                systemImage: "person.2.wave.2",
                isOverlap: true
            )
        }
        if let name = activeNames.first {
            return speaker(name)
        }
        let recentName = segments
            .filter {
                $0.endTime < elapsedTime
                    && elapsedTime - $0.endTime <= evidenceGrace
            }
            .max(by: { $0.endTime < $1.endTime })
            .flatMap { normalizedName($0.speakerName) }
        if let recentName {
            return speaker(recentName)
        }
        return MiniRecorderSpeakerPresentation(
            title: "Speaker unavailable",
            systemImage: "person.crop.circle.badge.questionmark",
            isOverlap: false
        )
    }

    private static func normalizedName(_ value: String) -> String? {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    private static func speaker(_ name: String) -> MiniRecorderSpeakerPresentation {
        MiniRecorderSpeakerPresentation(
            title: "\(name) speaking",
            systemImage: name == "You" ? "person.wave.2.fill" : "person.wave.2",
            isOverlap: false
        )
    }
}

struct MiniRecorderView: View {
    @Environment(\.vaultReduceMotion) private var reduceMotion
    @EnvironmentObject private var store: MeetingVaultStore

    let returnToMeetingVault: () -> Void

    private var transport: MeetingRecordingTransportPresentation {
        store.recordingTransportPresentation
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            statusHeader
                .accessibilitySortPriority(6)
            elapsedAndSpeaker
                .accessibilitySortPriority(5)

            if store.recordingState == .recording {
                RecordingVoiceSignal(
                    snapshot: store.recordingLevelSnapshot,
                    expectsSystemAudio: store.selectedSource?.mode != .microphone
                )
                .accessibilitySortPriority(4)
            } else if store.recordingState == .processing {
                Label("Finalizing Recording", systemImage: "waveform.badge.magnifyingglass")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Finalizing Recording")
                    .accessibilitySortPriority(4)
            }

            actionRow
                .accessibilitySortPriority(3)
            returnButton
                .accessibilitySortPriority(2)
        }
        .padding(18)
        .frame(
            minWidth: MiniRecorderWindowPolicy.minimumSize.width,
            idealWidth: MiniRecorderWindowPolicy.idealSize.width,
            minHeight: MiniRecorderWindowPolicy.minimumSize.height,
            idealHeight: MiniRecorderWindowPolicy.idealSize.height,
            alignment: .topLeading
        )
        .background(.regularMaterial)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("MeetingVault Mini Recorder")
        .accessibilityIdentifier("mini-recorder")
    }

    private var statusHeader: some View {
        HStack(spacing: 10) {
            ZStack {
                if store.recordingState == .recording, !reduceMotion {
                    Circle()
                        .fill(.red.opacity(0.12))
                        .frame(width: 22, height: 22)
                }
                Image(systemName: statusSymbol)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(statusTint)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle)
                    .font(.headline)
                Text(store.activeRecordingPresentation?.sourceName ?? statusDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text("Local capture")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(statusTitle)
        .accessibilityValue(statusDetail)
    }

    private var elapsedAndSpeaker: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = elapsedTime(now: context.date)
            let speaker = MiniRecorderSpeakerPresentation.resolve(
                segments: store.liveTranscriptPreviewSegments,
                elapsedTime: elapsed
            )
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Elapsed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(elapsedText(elapsed))
                        .font(.title2.monospacedDigit().weight(.semibold))
                        .accessibilityLabel("Elapsed time")
                        .accessibilityValue(elapsedText(elapsed))
                }
                Spacer(minLength: 8)
                Label(speaker.title, systemImage: speaker.systemImage)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(speaker.isOverlap ? .orange : .secondary)
                    .lineLimit(1)
                    .accessibilityLabel("Active speaker")
                    .accessibilityValue(speaker.title)
            }
        }
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            Button(action: performTransportAction) {
                Label(
                    transport.action == .stop ? transport.title : "Finalizing Recording",
                    systemImage: transport.action == .stop ? transport.symbol : "hourglass"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .tint(.red)
            .disabled(transport.action != .stop)
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .accessibilityLabel(transport.accessibilityLabel)
            .accessibilityHint(transport.accessibilityHint)
            .accessibilityIdentifier("mini-recorder-transport")
            .help(transport.accessibilityHint)

            Button {
                store.markMomentIntent()
            } label: {
                Label(
                    store.recordingBookmarkPresentation.title,
                    systemImage: store.recordingBookmarkPresentation.systemImage
                )
            }
            .buttonStyle(.bordered)
            .disabled(!store.recordingBookmarkPresentation.isEnabled)
            .keyboardShortcut("m", modifiers: [.command, .shift])
            .accessibilityLabel(store.recordingBookmarkPresentation.accessibilityLabel)
            .accessibilityHint(store.recordingBookmarkPresentation.detail)
            .accessibilityIdentifier("mini-recorder-mark-moment")
            .help(store.recordingBookmarkPresentation.detail)
        }
    }

    private var returnButton: some View {
        Button(action: returnToMeetingVault) {
            Label("Return to MeetingVault", systemImage: "rectangle.on.rectangle")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .keyboardShortcut("o", modifiers: [.command, .shift])
        .accessibilityLabel("Return to MeetingVault")
        .accessibilityHint("Bring the full MeetingVault window to the front")
        .accessibilityIdentifier("mini-recorder-return")
        .help("Bring the full MeetingVault window to the front")
    }

    private var statusTitle: String {
        switch store.recordingState {
        case .recording: "Recording"
        case .processing: "Finalizing Recording"
        default: "Recording ended"
        }
    }

    private var statusDetail: String {
        switch store.recordingState {
        case .recording: "Audio is being encrypted locally"
        case .processing: store.recordingProcessingStatus
        default: "No active recording"
        }
    }

    private var statusSymbol: String {
        switch store.recordingState {
        case .recording: "record.circle.fill"
        case .processing: "hourglass"
        default: "stop.circle"
        }
    }

    private var statusTint: Color {
        switch store.recordingState {
        case .recording: .red
        case .processing: .orange
        default: .secondary
        }
    }

    private func performTransportAction() {
        guard transport.action == .stop else { return }
        store.stopRecordingIntent()
    }

    private func elapsedTime(now: Date) -> TimeInterval {
        guard let startedAt = store.activeRecordingPresentation?.startedAt else { return 0 }
        return RecordingElapsedTime.elapsed(startedAt: startedAt, now: now)
    }

    private func elapsedText(_ elapsed: TimeInterval) -> String {
        let totalSeconds = Int(max(0, elapsed))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }
}
