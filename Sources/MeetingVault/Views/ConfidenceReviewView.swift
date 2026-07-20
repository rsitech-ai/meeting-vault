import MeetingVaultCore
import SwiftUI

struct ConfidenceReviewView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var store: MeetingVaultStore

    private var pendingItems: [TranscriptReviewItem] {
        store.selectedTranscriptReviewQueue?.pendingItems ?? []
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VaultHeroBand(tint: .purple) {
                    HStack(alignment: .top, spacing: 12) {
                        VaultSectionHeader(
                            "Confidence Review",
                            subtitle: store.transcriptReviewStatus,
                            systemImage: "checkmark.bubble"
                        )
                        .accessibilityIdentifier("confidence-review-title")
                        Spacer()
                        VaultStatusPill(
                            label: store.transcriptCorrectionInFlight ? "updating" : "\(pendingItems.count) open",
                            systemImage: store.transcriptCorrectionInFlight ? "arrow.trianglehead.2.clockwise.rotate.90" : "waveform.badge.magnifyingglass",
                            tint: pendingItems.isEmpty ? .green : .purple,
                            isActive: store.transcriptCorrectionInFlight || !pendingItems.isEmpty
                        )
                    }
                }

                reviewContent
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(VaultSceneBackground(tint: .purple))
        .animation(reduceMotion ? nil : VaultMotion.selection, value: pendingItems.map(\.id))
        .accessibilityIdentifier("confidence-review-view")
    }

    @ViewBuilder
    private var reviewContent: some View {
        if store.selectedMeeting == nil {
            honestEmptyState(
                title: "Select a meeting",
                detail: "Confidence Review is scoped to one encrypted meeting at a time.",
                symbol: "rectangle.stack.badge.person.crop"
            )
        } else if let queue = store.selectedTranscriptReviewQueue {
            if !queue.evidenceComplete {
                honestEmptyState(
                    title: "Provider evidence is incomplete",
                    detail: "The transcript remains available, but MeetingVault will not claim that no issues were found.",
                    symbol: "exclamationmark.shield"
                )
            } else if pendingItems.isEmpty {
                honestEmptyState(
                    title: "No review issues found",
                    detail: "The provider supplied complete evidence and no confidence, speaker, overlap, or reconstruction issue remains open.",
                    symbol: "checkmark.seal"
                )
            } else {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(pendingItems) { item in
                        ConfidenceReviewItemRow(
                            item: item,
                            segment: store.transcriptReviewSegment(for: item)
                        )
                        .id(item.id)
                    }
                }
                .accessibilityIdentifier("confidence-review-issue-content")
            }
        } else {
            honestEmptyState(
                title: "Review evidence unavailable",
                detail: "This transcript predates provider evidence or still needs local processing. No clean result is claimed.",
                symbol: "waveform.badge.exclamationmark"
            )
        }
    }

    private func honestEmptyState(title: String, detail: String, symbol: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(detail)
        }
        .frame(maxWidth: .infinity, minHeight: 260)
        .vaultGlassPanel(cornerRadius: 18, tint: .purple)
    }
}

private struct ConfidenceReviewItemRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var store: MeetingVaultStore
    let item: TranscriptReviewItem
    let segment: TranscriptEditDraftSegment?
    @State private var correctedText: String
    @State private var correctedSpeaker: String

    init(item: TranscriptReviewItem, segment: TranscriptEditDraftSegment?) {
        self.item = item
        self.segment = segment
        _correctedText = State(initialValue: segment?.editedText ?? "")
        _correctedSpeaker = State(initialValue: segment?.effectiveEditedSpeakerName ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Label(item.reason.reviewTitle, systemImage: item.reason.systemImage)
                    .font(.headline)
                Text(timeRange)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                if let confidence = item.confidence {
                    Text(confidence, format: .percent.precision(.fractionLength(0)))
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(confidence < 0.7 ? .orange : .secondary)
                        .accessibilityLabel("Confidence")
                }
            }

            Text(item.reason.reviewDetail)
                .font(.callout)
                .foregroundStyle(.secondary)

            if segment != nil {
                ViewThatFits(in: .horizontal) {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                        correctionRows
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        correctionRows
                    }
                }
            } else {
                Label("This evidence can no longer be matched to one transcript segment.", systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    correctionButtons
                    Spacer(minLength: 0)
                    dispositionButtons
                }
                VStack(alignment: .leading, spacing: 10) {
                    correctionButtons
                    HStack(spacing: 10) { dispositionButtons }
                }
            }
            .controlSize(.regular)
            .accessibilityIdentifier("confidence-review-correction-controls")
        }
        .padding(16)
        .vaultGlassPanel(cornerRadius: 18, tint: .purple)
        .transition(reduceMotion ? .identity : .opacity.combined(with: .move(edge: .bottom)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Transcript review issue: \(item.reason.reviewTitle), \(timeRange)")
        .accessibilityIdentifier("confidence-review-item-\(item.id.uuidString.lowercased())")
    }

    private var timeRange: String {
        "\(Self.timestamp(item.startTime))–\(Self.timestamp(item.endTime)) · \(item.trackKind == .microphone ? "You" : "Meeting audio")"
    }

    @ViewBuilder
    private var correctionRows: some View {
        GridRow {
            Text("Speaker").foregroundStyle(.secondary)
            TextField("Speaker", text: $correctedSpeaker)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Corrected speaker")
                .accessibilityIdentifier("confidence-review-corrected-speaker")
        }
        GridRow {
            Text("Transcript").foregroundStyle(.secondary)
            TextField("Corrected transcript", text: $correctedText, axis: .vertical)
                .lineLimit(2...5)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Corrected transcript text")
                .accessibilityIdentifier("confidence-review-corrected-transcript")
        }
    }

    private var correctionButtons: some View {
        Group {
            Button {
                store.playTranscriptReviewItem(item)
            } label: {
                Label("Play Exact Range", systemImage: "play.fill")
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .help("Play only this encrypted transcript range")
            .accessibilityIdentifier("confidence-review-play-range")

            Button {
                store.correctTranscriptReviewItem(
                    item: item,
                    replacementText: correctedText,
                    replacementSpeakerName: correctedSpeaker
                )
            } label: {
                Label("Save Correction", systemImage: "checkmark.circle.fill")
            }
            .buttonStyle(.glassProminent)
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(segment == nil || correctedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.transcriptCorrectionInFlight)
            .accessibilityIdentifier("confidence-review-save-correction")
        }
    }

    private var dispositionButtons: some View {
        Group {
            Button("Defer") {
                store.setTranscriptReviewStatus(itemID: item.id, status: .deferred)
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .accessibilityIdentifier("confidence-review-defer")

            Button("Resolve") {
                store.setTranscriptReviewStatus(itemID: item.id, status: .resolved)
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .accessibilityIdentifier("confidence-review-resolve")
        }
    }

    private static func timestamp(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(seconds.rounded(.down)))
        return String(format: "%02d:%02d", value / 60, value % 60)
    }
}

private extension TranscriptReviewReason {
    var reviewTitle: String {
        switch self {
        case .lowConfidence: "Check wording"
        case .uncertainSpeaker: "Check speaker"
        case .revisedSpeaker: "Speaker changed"
        case .overlap: "Overlapping voices"
        case .reconstructedPreviewGap: "Recovered preview gap"
        }
    }

    var reviewDetail: String {
        switch self {
        case .lowConfidence: "The provider marked this wording below the review threshold."
        case .uncertainSpeaker: "The words are available, but speaker attribution is uncertain."
        case .revisedSpeaker: "Final diarization changed the speaker shown during the live preview."
        case .overlap: "More than one voice overlaps this range; verify both wording and speaker."
        case .reconstructedPreviewGap: "Final local transcription reconstructed audio omitted from the live preview."
        }
    }

    var systemImage: String {
        switch self {
        case .lowConfidence: "text.magnifyingglass"
        case .uncertainSpeaker: "person.crop.circle.badge.questionmark"
        case .revisedSpeaker: "person.2.badge.gearshape"
        case .overlap: "waveform.path.ecg.rectangle"
        case .reconstructedPreviewGap: "arrow.trianglehead.2.clockwise.rotate.90"
        }
    }
}
