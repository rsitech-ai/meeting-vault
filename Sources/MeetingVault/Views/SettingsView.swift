import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: MeetingVaultStore
    @EnvironmentObject private var miniRecorderPreferences: MiniRecorderPresentationPreferences

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VaultHeroBand(tint: .blue) {
                    HStack(alignment: .center, spacing: 14) {
                        VaultSectionHeader(
                            "MeetingVault Settings",
                            subtitle: "Privacy, recording, and production-readiness controls.",
                            systemImage: "gearshape.2"
                        )
                        Spacer()
                        VaultLiveSignal(tint: .blue, barCount: 8, compact: true)
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Appearance")
                        .font(.headline)
                    AppearancePicker()
                    Text("Follow the Mac appearance or keep MeetingVault in Light or Dark mode.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .vaultGlassPanel(cornerRadius: 18, tint: .blue)

                VStack(alignment: .leading, spacing: 12) {
                    Text("Recording")
                        .font(.headline)
                    Toggle(
                        "Show Mini Recorder when recording starts",
                        isOn: $miniRecorderPreferences.automaticallyShowMiniRecorder
                    )
                    .tint(.green)
                    .accessibilityHint("Show the compact recording utility automatically for each new recording")
                    Toggle("Require consent status before recording", isOn: $store.requireConsentBeforeRecording)
                        .tint(.green)
                    StatusLine(label: "Meeting bundles", value: "Always encrypted with AES-GCM")
                }
                .vaultGlassPanel(cornerRadius: 18, tint: .green)

                VStack(alignment: .leading, spacing: 12) {
                    Text("Privacy")
                        .font(.headline)
                    Text("Transcripts, audio, summaries, and Agent history are stored in encrypted local bundles. Apple Speech may process speech on Apple servers when on-device recognition is unavailable; MeetingVault has no developer-operated transcript backend.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    VaultFlowDivider(tint: .purple)
                }
                .vaultGlassPanel(cornerRadius: 18, tint: .purple)

                LocalModelPrivacyCenterView(
                    microphoneStatus: store.microphoneAuthorizationState.rawValue,
                    systemAudioStatus: store.preflightResult.issues.contains(.audioPermissionMissing)
                        ? "Needs permission review"
                        : "Allowed at last preflight",
                    speechRecognitionStatus: store.appleSpeechAuthorizationState.rawValue
                )

                VStack(alignment: .leading, spacing: 12) {
                    Text("Status")
                        .font(.headline)
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 235), spacing: 12, alignment: .top)],
                        alignment: .leading,
                        spacing: 10
                    ) {
                        StatusLine(label: "Readiness", value: "Local app shell")
                        StatusLine(label: "Encrypted storage", value: "AES-GCM contract tested")
                        StatusLine(label: "Master key", value: "Local-file default; Keychain explicit")
                        StatusLine(label: "Bundle store", value: "Encrypted manifest round-trip tested")
                        StatusLine(label: "Audio chunks", value: "Encrypted checkpoint writer tested")
                        StatusLine(label: "Playback", value: "Transcript/audio timeline tested")
                        StatusLine(label: "Automation", value: "App Intents and local handoff tested")
                        StatusLine(label: "Recovery", value: "Checkpoint scanner tested")
                        StatusLine(label: "Retention", value: "Review and confirmed cleanup tested")
                        StatusLine(label: "Audit log", value: "Redacted event review tested")
                        StatusLine(label: "Capture mock", value: "Remote/microphone chunk persistence tested")
                        StatusLine(label: "Capture primary", value: "Core Audio tap adapter tested")
                        StatusLine(label: "Capture fallback", value: "ScreenCaptureKit adapter tested")
                        StatusLine(label: "Search", value: "In-memory FTS rebuilt from encrypted bundles")
                        StatusLine(label: "Transcription", value: "Encrypted final transcript pipeline tested")
                        StatusLine(label: "Transcript edits", value: "Draft editor UI and encrypted history tested")
                        StatusLine(label: "Intelligence", value: "Grounded summary artifact pipeline tested")
                        StatusLine(label: "Exports", value: "Markdown/VTT/PDF/DOCX/JSON/audio package tested")
                        StatusLine(label: "Permissions", value: "System adapter boundary tested")
                        StatusLine(label: "Distribution", value: "Developer ID planned")
                    }
                    .accessibilityIdentifier("settings-status-content")
                }
                .vaultGlassPanel(cornerRadius: 18, tint: .orange)
            }
            .padding(20)
        }
        .background(VaultSceneBackground(tint: .blue))
        .frame(minWidth: 640, idealWidth: 720, minHeight: 620, idealHeight: 820)
    }
}

private struct StatusLine: View {
    var label: String
    var value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 20)
            Text(value)
                .multilineTextAlignment(.trailing)
        }
        .font(.callout)
    }
}
