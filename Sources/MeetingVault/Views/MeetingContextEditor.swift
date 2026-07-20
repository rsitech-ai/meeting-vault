import MeetingVaultCore
import SwiftUI

struct MeetingContextEditor: View {
    @EnvironmentObject private var store: MeetingVaultStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VaultSectionHeader(
                    "Meeting Context",
                    subtitle: "Optional local hints improve transcription and speaker matching.",
                    systemImage: "person.2.wave.2"
                )
                Spacer(minLength: 12)
                Button {
                    store.reusePreviousMeetingContext()
                } label: {
                    Label("Reuse Previous", systemImage: "arrow.uturn.backward.circle")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Reuse previous meeting context")
                .accessibilityHint("Copies only the validated context from the selected meeting")
                .accessibilityIdentifier("meeting-context-reuse")
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    languagePicker
                    participantCountPicker
                }
                VStack(alignment: .leading, spacing: 12) {
                    languagePicker
                    participantCountPicker
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                TextField("Names separated by commas", text: participantNamesBinding)
                    .accessibilityLabel("Participant names")
                    .accessibilityHint("Optional private names used only for this recording")
                    .accessibilityIdentifier("meeting-context-participant-names")

                TextField("Terms separated by commas", text: vocabularyBinding)
                    .accessibilityLabel("Meeting vocabulary")
                    .accessibilityHint("Optional private terminology used only for this recording")
                    .accessibilityIdentifier("meeting-context-vocabulary")
            }
            .textFieldStyle(.roundedBorder)

            Text(store.meetingContextReuseStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("meeting-context-status")
        }
        .vaultGlassPanel(cornerRadius: 18, tint: .indigo)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("meeting-context-editor")
    }

    private var languagePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Language")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Picker("Language", selection: languageBinding) {
                Text("Automatic").tag(Optional<String>.none)
                Text("Polish").tag(Optional("pl-PL"))
                Text("English").tag(Optional("en-US"))
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .accessibilityLabel("Meeting language")
            .accessibilityIdentifier("meeting-context-language")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var participantCountPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Participants")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Picker("Participants", selection: participantCountBinding) {
                Text("Not specified").tag(Optional<Int>.none)
                ForEach(1...10, id: \.self) { count in
                    Text("\(count)").tag(Optional(count))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .accessibilityLabel("Expected participant count")
            .accessibilityIdentifier("meeting-context-participant-count")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var languageBinding: Binding<String?> {
        Binding(
            get: { store.meetingContextForEditor.localeIdentifier },
            set: { newValue in
                store.mutateMeetingContextDraft { $0.localeIdentifier = newValue }
            }
        )
    }

    private var participantCountBinding: Binding<Int?> {
        Binding(
            get: { store.meetingContextForEditor.expectedParticipantCount },
            set: { newValue in
                store.mutateMeetingContextDraft { $0.expectedParticipantCount = newValue }
            }
        )
    }

    private var participantNamesBinding: Binding<String> {
        Binding(
            get: { store.meetingContextForEditor.participantNames.joined(separator: ", ") },
            set: { newValue in
                store.mutateMeetingContextDraft {
                    $0.participantNames = Self.commaSeparatedEntries(newValue)
                }
            }
        )
    }

    private var vocabularyBinding: Binding<String> {
        Binding(
            get: { store.meetingContextForEditor.vocabulary.joined(separator: ", ") },
            set: { newValue in
                store.mutateMeetingContextDraft {
                    $0.vocabulary = Self.commaSeparatedEntries(newValue)
                }
            }
        )
    }

    private static func commaSeparatedEntries(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        return text.components(separatedBy: ",")
    }
}
