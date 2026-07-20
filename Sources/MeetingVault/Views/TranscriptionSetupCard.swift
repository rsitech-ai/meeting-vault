import MeetingVaultCore
import SwiftUI

struct TranscriptionSetupCard: View {
    @EnvironmentObject private var store: MeetingVaultStore

    var body: some View {
        let presentation = store.transcriptionSetupPresentation
        VStack(alignment: .leading, spacing: 10) {
            VaultSectionHeader(
                "Transcription Setup",
                subtitle: "Confirmed before recording; encrypted capture remains available if transcription is degraded.",
                systemImage: "captions.bubble"
            )

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) { facts(presentation) }
                VStack(alignment: .leading, spacing: 8) { facts(presentation) }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    readiness(presentation)
                    Spacer(minLength: 8)
                    recoveryControl(presentation)
                }
                VStack(alignment: .leading, spacing: 8) {
                    readiness(presentation)
                    recoveryControl(presentation)
                }
            }
            .accessibilityIdentifier("transcription-recovery-row")
        }
        .vaultGlassPanel(cornerRadius: 18, tint: .teal)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("transcription-setup")
    }

    @ViewBuilder
    private func facts(_ presentation: TranscriptionSetupPresentation) -> some View {
        setupFact(
            "Provider",
            "\(presentation.provider) · \(presentation.version)",
            identifier: "transcription-provider"
        )
        setupFact("Language", presentation.locale, identifier: "transcription-locale")
        setupFact("Privacy", presentation.privacy, identifier: "transcription-privacy-truth")
    }

    private func setupFact(_ title: String, _ value: String, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.caption).lineLimit(2).accessibilityIdentifier(identifier)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func recoveryControl(_ presentation: TranscriptionSetupPresentation) -> some View {
        if presentation.recoveryTitle == "Open Local Models & Privacy" {
            SettingsLink {
                Text(presentation.recoveryTitle ?? "Settings")
            }
            .accessibilityIdentifier("transcription-recovery")
        } else if presentation.recoveryTitle == "Open Speech Recognition Settings" {
            Button(presentation.recoveryTitle ?? "Open Settings") {
                store.openPermissionRecoverySettings(kind: .speechRecognition)
            }
            .buttonStyle(.link)
            .accessibilityIdentifier("transcription-recovery")
        } else if let recoveryTitle = presentation.recoveryTitle {
            Text(recoveryTitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("transcription-recovery")
        }
    }

    private func readiness(_ presentation: TranscriptionSetupPresentation) -> some View {
        Label {
            Text(presentation.readiness)
                .font(.callout.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: presentation.recoveryTitle == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(presentation.recoveryTitle == nil ? .green : .orange)
        }
        .accessibilityIdentifier("transcription-readiness")
    }
}
