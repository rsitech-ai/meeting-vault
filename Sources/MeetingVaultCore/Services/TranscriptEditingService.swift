import Foundation

public struct TranscriptEditingService {
    private let bundleStore: EncryptedMeetingBundleStore
    private let searchIndex: SQLiteSearchIndex
    private let auditWriter: PrivacyAuditLogWriter?
    private let now: @Sendable () -> Date

    public init(
        bundleStore: EncryptedMeetingBundleStore,
        searchIndex: SQLiteSearchIndex,
        auditWriter: PrivacyAuditLogWriter? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.bundleStore = bundleStore
        self.searchIndex = searchIndex
        self.auditWriter = auditWriter
        self.now = now
    }

    public func applyEdits(
        meeting: SearchMeeting,
        edits: [TranscriptSegmentEdit],
        updateSearchIndex: Bool = true
    ) throws -> TranscriptEditResult {
        guard !edits.isEmpty else {
            throw TranscriptEditError.emptyEdits
        }

        let transcript = try bundleStore.readJSONArtifact(
            MeetingTranscript.self,
            meetingID: meeting.id,
            relativePath: MeetingTranscript.finalTranscriptRelativePath,
            purpose: MeetingTranscript.finalTranscriptPurpose
        )

        let editBySegmentID = Dictionary(uniqueKeysWithValues: edits.map { ($0.segmentID, $0) })
        for edit in edits {
            guard transcript.segments.contains(where: { $0.id == edit.segmentID }) else {
                throw TranscriptEditError.segmentNotFound(edit.segmentID)
            }
            if edit.replacementText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw TranscriptEditError.blankReplacementText(edit.segmentID)
            }
        }

        let editedSegments = transcript.segments.map { segment in
            guard let edit = editBySegmentID[segment.id] else {
                return segment
            }
            return TranscriptSegment(
                id: segment.id,
                speakerName: edit.replacementSpeakerName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? segment.speakerName,
                trackKind: segment.trackKind,
                startTime: segment.startTime,
                endTime: segment.endTime,
                text: edit.replacementText.trimmingCharacters(in: .whitespacesAndNewlines),
                confidence: segment.confidence,
                isFinal: segment.isFinal,
                reviewEvidence: segment.reviewEvidence
            )
        }

        let editTime = now()
        var editHistory = try loadEditHistory(meetingID: meeting.id)
        let historyEntry = TranscriptEditHistoryEntry(
            version: editHistory.latestVersion + 1,
            editedAt: editTime,
            editedSegmentIDs: edits.map(\.segmentID)
        )
        let editedTranscript = MeetingTranscript(
            meetingID: transcript.meetingID,
            transcriptVersion: historyEntry.version,
            providerConfigurationVersion: transcript.providerConfigurationVersion,
            localeIdentifier: transcript.localeIdentifier,
            generatedAt: transcript.generatedAt,
            editedAt: editTime,
            segments: editedSegments
        )
        editHistory.entries.append(historyEntry)

        try bundleStore.writeJSONArtifact(
            editedTranscript,
            meetingID: meeting.id,
            relativePath: MeetingTranscript.finalTranscriptRelativePath,
            purpose: MeetingTranscript.finalTranscriptPurpose
        )
        try bundleStore.writeJSONArtifact(
            editHistory,
            meetingID: meeting.id,
            relativePath: TranscriptEditHistory.relativePath,
            purpose: TranscriptEditHistory.purpose
        )
        if updateSearchIndex {
            try searchIndex.replaceMeetingAndSegments(
                meeting: meeting,
                segments: LocalFinalTranscriptionService.searchSegments(editedTranscript)
            )
        }
        try auditWriter?.append(
            action: .transcriptEdit,
            meetingID: meeting.id,
            metadata: [
                "editedSegmentCount": "\(edits.count)",
                "version": "\(historyEntry.version)"
            ]
        )

        return TranscriptEditResult(
            transcript: editedTranscript,
            editedSegmentCount: edits.count,
            version: historyEntry.version
        )
    }

    private func loadEditHistory(meetingID: UUID) throws -> TranscriptEditHistory {
        let historyURL = bundleStore.bundleURL(for: meetingID)
            .appendingPathComponent(TranscriptEditHistory.relativePath)
        guard FileManager.default.fileExists(atPath: historyURL.path) else {
            return TranscriptEditHistory(meetingID: meetingID)
        }
        return try bundleStore.readJSONArtifact(
            TranscriptEditHistory.self,
            meetingID: meetingID,
            relativePath: TranscriptEditHistory.relativePath,
            purpose: TranscriptEditHistory.purpose
        )
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
