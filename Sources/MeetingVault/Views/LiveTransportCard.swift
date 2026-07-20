import Foundation
import SwiftUI

struct LiveTransportCard: View {
    @Environment(\.vaultReduceMotion) private var reduceMotion
    @EnvironmentObject private var store: MeetingVaultStore

    private var transport: MeetingRecordingTransportPresentation {
        store.recordingTransportPresentation
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                VaultSectionHeader(
                    "Live Transport",
                    subtitle: transport.detail,
                    systemImage: "waveform"
                )
                Spacer(minLength: 12)
                VaultStatusPill(
                    label: transport.statusTitle,
                    systemImage: transport.statusSymbol,
                    tint: store.recordingState.statusTint,
                    isActive: store.recordingState == .recording
                )
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 18) {
                    transportControl
                    recordingContext
                }
                VStack(alignment: .leading, spacing: 14) {
                    transportControl
                    recordingContext
                }
            }

            if store.recordingState == .recording {
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
                .accessibilityLabel(store.recordingBookmarkPresentation.accessibilityLabel)
                .accessibilityHint(store.recordingBookmarkPresentation.detail)
                .accessibilityIdentifier("mark-moment-button")
                .help(store.recordingBookmarkPresentation.detail)

                Text(store.recordingBookmarkStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Recording bookmark observation")
                    .accessibilityValue(store.recordingBookmarkNativeObservation.accessibilityValue)
                    .accessibilityIdentifier("recording-bookmark-observation")

                RecordingVoiceSignal(
                    snapshot: store.recordingLevelSnapshot,
                    expectsSystemAudio: store.selectedSource?.mode != .microphone
                )
                .transition(reduceMotion ? .identity : .opacity.combined(with: .move(edge: .top)))

                liveTranscriptionPanel
                    .transition(reduceMotion ? .identity : .opacity.combined(with: .move(edge: .top)))
                if store.recordingPreviewDropCount > 0 {
                    Label(store.recordingPreviewDropStatus, systemImage: "waveform.badge.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("recording-preview-drop-status")
                }
            }
        }
        .vaultGlassPanel(
            cornerRadius: 22,
            tint: store.recordingState.statusTint,
            interactive: transport.action != nil
        )
        .animation(reduceMotion ? nil : VaultMotion.selection, value: store.recordingState)
        .accessibilityIdentifier("live-recording-transport")
    }

    private var transportControl: some View {
        Button(action: performTransportAction) {
            HStack(spacing: 12) {
                Image(systemName: transport.symbol)
                    .font(.title2.weight(.semibold))
                    .symbolRenderingMode(.hierarchical)
                Text(transport.title)
                    .font(.title3.weight(.semibold))
                if store.recordingState == .recording,
                   let startedAt = store.activeRecordingPresentation?.startedAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(elapsedText(startedAt: startedAt, now: context.date))
                            .font(.title3.monospacedDigit().weight(.medium))
                            .contentTransition(.numericText())
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 58)
            .padding(.horizontal, 14)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
        .tint(transport.action == .stop ? .red : nil)
        .disabled(!transport.isEnabled)
        .accessibilityLabel(transport.accessibilityLabel)
        .accessibilityHint(transport.accessibilityHint)
        .accessibilityIdentifier("primary-live-recording-transport")
        .help(transport.accessibilityHint)
        .frame(minWidth: 230)
    }

    private var liveTranscriptionPanel: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                Circle()
                    .fill(store.liveActiveSpeakers.isEmpty ? Color.secondary : Color.green)
                    .frame(width: 7, height: 7)
                    .scaleEffect(reduceMotion || store.liveActiveSpeakers.isEmpty ? 1 : 1.24)
                    .animation(
                        reduceMotion ? nil : .easeInOut(duration: 0.72).repeatForever(autoreverses: true),
                        value: store.liveActiveSpeakers.isEmpty
                    )
                    .accessibilityHidden(true)
                Text(store.liveTranscriptionStatus)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 0)
                Label(
                    store.transcriptionPrivacyPresentation.label,
                    systemImage: store.transcriptionPrivacyPresentation.systemImage
                )
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityValue(store.transcriptionPrivacyPresentation.accessibilityValue)
                    .accessibilityIdentifier("live-transcription-privacy")
            }

            if let segment = store.liveTranscriptPreviewSegments.last {
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Text(segment.speakerName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(segment.trackKind == .microphone ? Color.accentColor : Color.secondary)
                        .lineLimit(1)
                    Text(segment.text)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .id(segment.id)
                .transition(reduceMotion ? .identity : .opacity.combined(with: .move(edge: .bottom)))
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.updatesFrequently)
                .accessibilityIdentifier("live-transcription-preview")
            } else {
                Text("Listening for speech…")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .accessibilityIdentifier("live-transcription-preview")
            }

            if !store.liveActiveSpeakers.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(store.liveActiveSpeakers, id: \.self) { speaker in
                            Label(speaker, systemImage: speaker == "You" ? "mic.fill" : "person.wave.2.fill")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .accessibilityLabel("Active speakers")
                .accessibilityIdentifier("live-active-speakers")
            }
        }
        .padding(12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Live transcription observation")
        .accessibilityValue(
            "state \(store.recordingState.rawValue); segments \(store.liveTranscriptPreviewSegments.count); last \(store.liveTranscriptPreviewSegments.last?.id.uuidString.lowercased() ?? "none")"
        )
        .accessibilityIdentifier("live-transcription-observation")
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.primary.opacity(0.07))
        }
        .animation(reduceMotion ? nil : VaultMotion.selection, value: store.liveTranscriptPreviewSegments.last?.id)
        .animation(reduceMotion ? nil : VaultMotion.selection, value: store.liveActiveSpeakers)
    }

    private var recordingContext: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(
                store.activeRecordingPresentation?.sourceName
                    ?? store.selectedSource?.displayName
                    ?? "No capture source selected",
                systemImage: "dot.radiowaves.left.and.right"
            )
            Label(
                store.activeRecordingPresentation?.microphoneDeviceName
                    ?? store.selectedAudioInputDevice?.displayName
                    ?? "Input will be detected at Start",
                systemImage: "mic"
            )
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func performTransportAction() {
        switch transport.action {
        case .start:
            store.startRecordingIntent()
        case .stop:
            store.stopRecordingIntent()
        case nil:
            break
        }
    }

    private func elapsedText(startedAt: Date, now: Date) -> String {
        let totalSeconds = Int(RecordingElapsedTime.elapsed(startedAt: startedAt, now: now))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }
}
