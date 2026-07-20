import MeetingVaultCore
import SwiftUI

enum RecordingVoiceSignalState: Equatable {
    case active
    case silent
    case missing
}

struct RecordingVoiceChannelPresentation: Equatable {
    var level: Double
    var state: RecordingVoiceSignalState
}

struct RecordingVoiceSignalPresentation: Equatable {
    var microphone: RecordingVoiceChannelPresentation
    var systemAudio: RecordingVoiceChannelPresentation

    static func resolve(
        snapshot: RecordingLevelSnapshot,
        now: ContinuousClock.Instant,
        staleAfter: Duration = .seconds(2)
    ) -> RecordingVoiceSignalPresentation {
        RecordingVoiceSignalPresentation(
            microphone: channel(
                level: snapshot.microphone,
                lastFrameAt: snapshot.lastMicrophoneFrameAt,
                now: now,
                staleAfter: staleAfter
            ),
            systemAudio: channel(
                level: snapshot.systemAudio,
                lastFrameAt: snapshot.lastSystemFrameAt,
                now: now,
                staleAfter: staleAfter
            )
        )
    }

    private static func channel(
        level: Double,
        lastFrameAt: ContinuousClock.Instant?,
        now: ContinuousClock.Instant,
        staleAfter: Duration
    ) -> RecordingVoiceChannelPresentation {
        let clampedLevel = min(1, max(0, level.isFinite ? level : 0))
        guard let lastFrameAt,
              lastFrameAt.duration(to: now) <= staleAfter
        else {
            return RecordingVoiceChannelPresentation(level: 0, state: .missing)
        }
        return RecordingVoiceChannelPresentation(
            level: clampedLevel,
            state: clampedLevel > 0.02 ? .active : .silent
        )
    }
}

struct RecordingVoiceSignalModel: Equatable {
    var snapshot: RecordingLevelSnapshot
    var staleAfter: Duration = .seconds(2)

    func refreshInterval(reduceMotion: Bool) -> TimeInterval {
        reduceMotion ? 1 : 1.0 / 12.0
    }

    func presentation(now: ContinuousClock.Instant) -> RecordingVoiceSignalPresentation {
        RecordingVoiceSignalPresentation.resolve(
            snapshot: snapshot,
            now: now,
            staleAfter: staleAfter
        )
    }
}

struct RecordingVoiceSignal: View {
    @Environment(\.vaultReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    let snapshot: RecordingLevelSnapshot
    let expectsSystemAudio: Bool

    var body: some View {
        let model = RecordingVoiceSignalModel(snapshot: snapshot)
        TimelineView(.periodic(from: .now, by: model.refreshInterval(reduceMotion: reduceMotion))) { context in
            let presentation = model.presentation(now: ContinuousClock().now)
            let pulse = (sin(context.date.timeIntervalSinceReferenceDate * 5.2) + 1) / 2

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    channel(
                        title: "You",
                        identifier: "recording-level-microphone",
                        systemImage: "mic.fill",
                        missingText: "No microphone signal",
                        activeText: "Speaking",
                        presentation: presentation.microphone,
                        pulse: pulse
                    )
                    if expectsSystemAudio {
                        channel(
                            title: "Meeting",
                            identifier: "recording-level-system-audio",
                            systemImage: "waveform",
                            missingText: "No system audio signal",
                            activeText: "Audio detected",
                            presentation: presentation.systemAudio,
                            pulse: pulse
                        )
                    }
                }
                VStack(spacing: 10) {
                    channel(
                        title: "You",
                        identifier: "recording-level-microphone",
                        systemImage: "mic.fill",
                        missingText: "No microphone signal",
                        activeText: "Speaking",
                        presentation: presentation.microphone,
                        pulse: pulse
                    )
                    if expectsSystemAudio {
                        channel(
                            title: "Meeting",
                            identifier: "recording-level-system-audio",
                            systemImage: "waveform",
                            missingText: "No system audio signal",
                            activeText: "Audio detected",
                            presentation: presentation.systemAudio,
                            pulse: pulse
                        )
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Live recording input")
        .accessibilityIdentifier("recording-voice-signal")
    }

    private func channel(
        title: String,
        identifier: String,
        systemImage: String,
        missingText: String,
        activeText: String,
        presentation: RecordingVoiceChannelPresentation,
        pulse: Double
    ) -> some View {
        HStack(spacing: 12) {
            ZStack {
                if !reduceMotion, presentation.state == .active {
                    Circle()
                        .fill(.red.opacity(0.24))
                        .frame(width: 39, height: 39)
                        .scaleEffect(0.87 + pulse * 0.13)
                        .opacity(0.5 + pulse * 0.5)
                }
                Image(systemName: systemImage)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(tint(for: presentation.state))
                    .frame(width: 30, height: 30)
                    .background(.primary.opacity(contrast == .increased ? 0.10 : 0.06), in: Circle())
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(title)
                        .font(.caption.weight(.semibold))
                    Text(statusText(
                        state: presentation.state,
                        missingText: missingText,
                        activeText: activeText
                    ))
                    .font(.caption)
                    .foregroundStyle(presentation.state == .missing ? .red : .secondary)
                    .lineLimit(1)
                }

                if reduceMotion {
                    ProgressView(value: presentation.level, total: 1)
                        .progressViewStyle(.linear)
                        .tint(tint(for: presentation.state))
                } else {
                    levelBars(level: presentation.level, state: presentation.state)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.primary.opacity(contrast == .increased ? 0.09 : 0.045), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(.primary.opacity(contrast == .increased ? 0.22 : 0.08), lineWidth: 1)
        }
        .animation(reduceMotion ? nil : .interactiveSpring(response: 0.22, dampingFraction: 0.78), value: presentation.level)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(
            "\(statusText(state: presentation.state, missingText: missingText, activeText: activeText)), level \(Int((presentation.level * 100).rounded())) percent"
        )
        .accessibilityIdentifier(identifier)
    }

    private func levelBars(level: Double, state: RecordingVoiceSignalState) -> some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<12, id: \.self) { index in
                let threshold = Double(index + 1) / 12
                Capsule()
                    .fill(threshold <= level ? tint(for: state) : Color.secondary.opacity(0.16))
                    .frame(maxWidth: .infinity)
                    .frame(height: 5 + Double(index % 4) * 1.8)
            }
        }
        .frame(height: 12)
    }

    private func statusText(
        state: RecordingVoiceSignalState,
        missingText: String,
        activeText: String
    ) -> String {
        switch state {
        case .active: activeText
        case .silent: "Quiet"
        case .missing: missingText
        }
    }

    private func tint(for state: RecordingVoiceSignalState) -> Color {
        switch state {
        case .active: .red
        case .silent: .secondary
        case .missing: .orange
        }
    }
}
