import Foundation

public struct MeetingLibraryEntry: Equatable, Sendable {
    public var record: MeetingRecord
    public var searchMeeting: SearchMeeting
    public var transcript: MeetingTranscript
    public var editHistory: TranscriptEditHistory

    public init(
        record: MeetingRecord,
        searchMeeting: SearchMeeting,
        transcript: MeetingTranscript,
        editHistory: TranscriptEditHistory
    ) {
        self.record = record
        self.searchMeeting = searchMeeting
        self.transcript = transcript
        self.editHistory = editHistory
    }
}

public struct MeetingLibrarySnapshot: Equatable, Sendable {
    public var records: [MeetingRecord]
    public var searchMeetingsByID: [UUID: SearchMeeting]
    public var editSessionsByMeetingID: [UUID: TranscriptEditSession]

    public init(
        records: [MeetingRecord],
        searchMeetingsByID: [UUID: SearchMeeting],
        editSessionsByMeetingID: [UUID: TranscriptEditSession]
    ) {
        self.records = records
        self.searchMeetingsByID = searchMeetingsByID
        self.editSessionsByMeetingID = editSessionsByMeetingID
    }
}

public struct MeetingLibraryRepository {
    public static let recordRelativePath = "metadata/meeting-record.json.enc"
    public static let recordPurpose = "metadata:meeting-record"
    public static let searchMeetingRelativePath = "metadata/search-meeting.json.enc"
    public static let searchMeetingPurpose = "metadata:search-meeting"

    private let bundleStore: EncryptedMeetingBundleStore
    private let searchIndex: SQLiteSearchIndex
    private let editSessionService: TranscriptEditSessionService
    private let afterAtomicIndexCommit: @Sendable () throws -> Void

    public init(
        bundleStore: EncryptedMeetingBundleStore,
        searchIndex: SQLiteSearchIndex,
        afterAtomicIndexCommit: @escaping @Sendable () throws -> Void = {}
    ) {
        self.bundleStore = bundleStore
        self.searchIndex = searchIndex
        self.afterAtomicIndexCommit = afterAtomicIndexCommit
        self.editSessionService = TranscriptEditSessionService(
            bundleStore: bundleStore,
            searchIndex: searchIndex
        )
    }

    public func save(_ entry: MeetingLibraryEntry) throws {
        if !FileManager.default.fileExists(atPath: bundleStore.bundleURL(for: entry.record.id).path) {
            var manifest = MeetingBundleManifest.initialEncryptedBundle(
                meetingID: entry.record.id,
                title: entry.record.title
            )
            manifest.createdAt = entry.record.startedAt
            manifest.recovered = entry.record.state == .recovered
            _ = try bundleStore.createBundle(manifest)
        } else {
            try updateManifestTitle(meetingID: entry.record.id, title: entry.record.title)
        }

        try bundleStore.writeJSONArtifact(
            entry.record,
            meetingID: entry.record.id,
            relativePath: Self.recordRelativePath,
            purpose: Self.recordPurpose
        )
        try bundleStore.writeJSONArtifact(
            entry.searchMeeting,
            meetingID: entry.record.id,
            relativePath: Self.searchMeetingRelativePath,
            purpose: Self.searchMeetingPurpose
        )
        try bundleStore.writeJSONArtifact(
            entry.transcript,
            meetingID: entry.record.id,
            relativePath: MeetingTranscript.finalTranscriptRelativePath,
            purpose: MeetingTranscript.finalTranscriptPurpose
        )
        try bundleStore.writeJSONArtifact(
            entry.editHistory,
            meetingID: entry.record.id,
            relativePath: TranscriptEditHistory.relativePath,
            purpose: TranscriptEditHistory.purpose
        )
        if !(try bundleStore.artifactExists(
            meetingID: entry.record.id,
            relativePath: TranscriptReviewQueue.relativePath
        )) {
            let review = try TranscriptConfidenceReviewService().deriveQueue(
                transcript: entry.transcript,
                evidence: entry.transcript.segments.compactMap { $0.reviewEvidence },
                transcriptVersion: entry.transcript.transcriptVersion
            )
            try TranscriptReviewRepository(bundleStore: bundleStore).save(review)
        }

        try searchIndex.replaceMeetingAndSegments(
            meeting: entry.searchMeeting,
            segments: LocalFinalTranscriptionService.searchSegments(entry.transcript)
        )
        try afterAtomicIndexCommit()
        _ = try TranscriptReindexRecoveryService(
            bundleStore: bundleStore,
            searchIndex: searchIndex
        ).clearAfterAuthoritativeCommit(meeting: entry.searchMeeting, transcript: entry.transcript)
    }

    private func updateManifestTitle(meetingID: UUID, title: String) throws {
        var manifest = try bundleStore.readManifest(meetingID: meetingID)
        guard manifest.title != title else { return }
        manifest.title = title
        try bundleStore.writeJSONArtifact(
            manifest,
            meetingID: meetingID,
            relativePath: "manifest.json.enc",
            purpose: "manifest"
        )
    }

    public func loadSnapshot() throws -> MeetingLibrarySnapshot {
        var records: [MeetingRecord] = []
        var searchMeetingsByID: [UUID: SearchMeeting] = [:]
        var editSessionsByMeetingID: [UUID: TranscriptEditSession] = [:]

        for meetingID in try bundleStore.listMeetingBundleIDs() {
            let requiredArtifacts = [
                Self.recordRelativePath,
                Self.searchMeetingRelativePath,
                MeetingTranscript.finalTranscriptRelativePath
            ]
            let isPersistedLibraryEntry = try requiredArtifacts.allSatisfy {
                try bundleStore.artifactExists(meetingID: meetingID, relativePath: $0)
            }
            guard isPersistedLibraryEntry else {
                continue
            }
            let record = try bundleStore.readJSONArtifact(
                MeetingRecord.self,
                meetingID: meetingID,
                relativePath: Self.recordRelativePath,
                purpose: Self.recordPurpose
            )
            let searchMeeting = try bundleStore.readJSONArtifact(
                SearchMeeting.self,
                meetingID: meetingID,
                relativePath: Self.searchMeetingRelativePath,
                purpose: Self.searchMeetingPurpose
            )
            let recovery = try TranscriptReindexRecoveryService(
                bundleStore: bundleStore,
                searchIndex: searchIndex
            ).recover(meeting: searchMeeting)
            let session = try editSessionService.loadSession(meeting: searchMeeting)
            if case .preserved = recovery {
                // A pending marker with missing authority or a digest mismatch
                // is a fail-closed recovery state. Do not mutate its derived
                // search projection until a matching authoritative commit exists.
            } else {
                try searchIndex.replaceMeetingAndSegments(
                    meeting: searchMeeting,
                    segments: session.draft.segments.map {
                        SearchTranscriptSegment(
                            id: $0.id,
                            meetingID: meetingID,
                            speakerName: $0.effectiveEditedSpeakerName,
                            startTime: $0.startTime,
                            endTime: $0.endTime,
                            text: $0.trimmedEditedText,
                            confidence: $0.confidence,
                            isFinal: true
                        )
                    }
                )
            }
            records.append(record)
            searchMeetingsByID[meetingID] = searchMeeting
            editSessionsByMeetingID[meetingID] = session
        }

        return MeetingLibrarySnapshot(
            records: records.sorted { lhs, rhs in
                if lhs.startedAt == rhs.startedAt {
                    return lhs.title < rhs.title
                }
                return lhs.startedAt > rhs.startedAt
            },
            searchMeetingsByID: searchMeetingsByID,
            editSessionsByMeetingID: editSessionsByMeetingID
        )
    }

    public func saveLocalRecordingImportMetadata(
        _ metadata: LocalRecordingImportMetadata,
        meetingID: UUID
    ) throws {
        try bundleStore.writeJSONArtifact(
            metadata,
            meetingID: meetingID,
            relativePath: LocalRecordingImportMetadata.relativePath,
            purpose: LocalRecordingImportMetadata.purpose
        )
    }

    public func discard(meetingID: UUID) throws {
        try searchIndex.deleteMeeting(id: meetingID)
        let bundleURL = bundleStore.bundleURL(for: meetingID)
        if FileManager.default.fileExists(atPath: bundleURL.path) {
            try bundleStore.deleteBundle(meetingID: meetingID)
        }
    }
}
