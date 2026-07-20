import SwiftUI
import MeetingVaultCore

struct MeetingTranscriptWorkspace: View {
    @EnvironmentObject private var store: MeetingVaultStore
    var onShowRecordingSetup: () -> Void
    var onImport: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if store.selectedMeeting == nil && store.liveTranscriptPreviewSegments.isEmpty {
                    MeetingWorkspaceEmptyState(
                        onShowRecordingSetup: onShowRecordingSetup,
                        onImport: onImport
                    )
                } else {
                    if let meeting = store.selectedMeeting {
                        MeetingTranscriptHeader(meeting: meeting)
                    }
                    if !store.playbackTimeline.bookmarks.isEmpty {
                        MarkedMomentsView()
                    } else if store.selectedBookmarkStatus.contains("unavailable") {
                        Label(store.selectedBookmarkStatus, systemImage: "bookmark.slash")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("marked-moments-status")
                    }
                    LiveTranscriptionPreviewBlock()
                    LibraryVisibleTranscriptBlock()
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityIdentifier("meeting-transcript-workspace")
    }
}

private struct MarkedMomentsView: View {
    @EnvironmentObject private var store: MeetingVaultStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Marked Moments", systemImage: "bookmark.fill")
                .font(.headline)
                .accessibilityLabel("Recovered marked moments")
                .accessibilityValue(
                    store.playbackTimeline.bookmarks
                        .map { $0.id.uuidString.lowercased() }
                        .joined(separator: " ")
                )
                .accessibilityIdentifier("marked-moments-observation")
            ForEach(store.playbackTimeline.bookmarks) { bookmark in
                let accessibility = MeetingBookmarkAccessibilityPresentation(bookmark: bookmark)
                Button {
                    store.seekTranscriptPlayback(to: bookmark.timestamp)
                } label: {
                    HStack(spacing: 8) {
                        Text(timestamp(bookmark.timestamp))
                            .monospacedDigit()
                        if let category = bookmark.category {
                            Text(category.rawValue)
                        }
                        if let note = bookmark.note {
                            Text(note).lineLimit(1)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(accessibility.label)
                .accessibilityValue(accessibility.value)
                .accessibilityIdentifier("marked-moment-\(bookmark.id.uuidString.lowercased())")
            }
        }
        .accessibilityIdentifier("marked-moments")
    }

    private func timestamp(_ value: TimeInterval) -> String {
        let seconds = max(0, Int(value.rounded(.down)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

struct MeetingBookmarkAccessibilityPresentation: Equatable {
    var label: String
    var value: String

    init(bookmark: MeetingBookmark) {
        let seconds = max(0, Int(bookmark.timestamp.rounded(.down)))
        let timestamp = String(format: "%02d:%02d", seconds / 60, seconds % 60)
        label = "Marked moment at \(timestamp)"
        var values: [String] = []
        if let category = bookmark.category {
            values.append("Category \(category.rawValue).")
        }
        if let note = bookmark.note {
            let sanitized = Self.sanitized(note)
            if !sanitized.isEmpty {
                values.append("Note \(sanitized).")
            }
        }
        value = values.isEmpty ? "No category or note." : values.joined(separator: " ")
    }

    private static func sanitized(_ value: String) -> String {
        let printable = String(value.unicodeScalars.filter { scalar in
            scalar.value == 0x09
                || scalar.value == 0x0A
                || scalar.value == 0x0D
                || scalar.value >= 0x20
        })
        return printable.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

private struct MeetingTranscriptHeader: View {
    @EnvironmentObject private var store: MeetingVaultStore
    var meeting: MeetingRecord

    private var playbackState: TranscriptPlaybackSessionState {
        store.playbackSessionState
    }

    private var firstPlayableCueID: UUID? {
        store.playbackTimeline.cues.first(where: \.isPlayable)?.segmentID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(meeting.title)
                        .font(.title2.weight(.semibold))
                        .lineLimit(2)
                    Label(meeting.sourceName, systemImage: "app.connected.to.app.below.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Label(meeting.state.displayTitle, systemImage: meeting.state.statusSymbol)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(meeting.state.statusTint)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("meeting-transcript-header")

            if store.playbackMatchesSelectedMeeting {
                VStack(spacing: 6) {
                    HStack(spacing: 8) {
                        Button {
                            if let firstPlayableCueID {
                                store.playTranscriptCue(firstPlayableCueID)
                            }
                        } label: {
                            Label("Play", systemImage: "play.fill")
                                .labelStyle(.iconOnly)
                        }
                        .accessibilityLabel("Play transcript audio")
                        .disabled(firstPlayableCueID == nil)
                        .help("Play the first transcript cue with matching encrypted audio")

                        Button {
                            store.pauseTranscriptPlayback()
                        } label: {
                            Label("Pause", systemImage: "pause.fill")
                                .labelStyle(.iconOnly)
                        }
                        .accessibilityLabel("Pause playback")
                        .disabled(playbackState.transportState != .playing)
                        .help("Pause transcript audio playback")

                        Button {
                            store.stopTranscriptPlayback()
                        } label: {
                            Label("Stop", systemImage: "stop.fill")
                                .labelStyle(.iconOnly)
                        }
                        .accessibilityLabel("Stop playback")
                        .disabled(playbackState.transportState == .idle || playbackState.transportState == .stopped)
                        .help("Stop transcript audio playback")

                        Spacer(minLength: 8)

                        Text("\(durationText(playbackState.currentTime)) / \(durationText(store.playbackTimeline.duration))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }

                    Slider(
                        value: Binding(
                            get: { playbackState.currentTime },
                            set: { store.seekTranscriptPlayback(to: $0) }
                        ),
                        in: 0...max(store.playbackTimeline.duration, 1)
                    )
                    .disabled(store.playbackTimeline.duration <= 0)
                    .help("Scrub transcript audio")
                }
                .controlSize(.small)
                .accessibilityIdentifier("meeting-playback-transport")
            }
        }
        .padding(.horizontal, 2)
    }

    private func durationText(_ seconds: TimeInterval) -> String {
        let totalSeconds = max(0, Int(seconds.rounded(.down)))
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}

private struct MeetingWorkspaceEmptyState: View {
    var onShowRecordingSetup: () -> Void
    var onImport: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("No Meeting Selected", systemImage: "text.bubble")
        } description: {
            Text("Choose a meeting, prepare a new recording, or import a local recording.")
        } actions: {
            HStack {
                Button("Recording Setup", systemImage: "slider.horizontal.3", action: onShowRecordingSetup)
                    .buttonStyle(.borderedProminent)
                Button("Import Recording", systemImage: "waveform.badge.plus", action: onImport)
            }
        }
    }
}
