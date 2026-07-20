import Foundation

public struct TranscriptEditSession: Equatable, Sendable {
    public var meeting: SearchMeeting
    public var draft: TranscriptEditDraft
    public var history: TranscriptEditHistory

    public init(
        meeting: SearchMeeting,
        draft: TranscriptEditDraft,
        history: TranscriptEditHistory
    ) {
        self.meeting = meeting
        self.draft = draft
        self.history = history
    }
}

public struct TranscriptEditSessionSaveResult: Equatable, Sendable {
    public var session: TranscriptEditSession
    public var result: TranscriptEditResult

    public init(session: TranscriptEditSession, result: TranscriptEditResult) {
        self.session = session
        self.result = result
    }
}

public struct TranscriptEditSessionService {
    private let bundleStore: EncryptedMeetingBundleStore
    private let editingService: TranscriptEditingService

    public init(
        bundleStore: EncryptedMeetingBundleStore,
        searchIndex: SQLiteSearchIndex,
        auditWriter: PrivacyAuditLogWriter? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.bundleStore = bundleStore
        self.editingService = TranscriptEditingService(
            bundleStore: bundleStore,
            searchIndex: searchIndex,
            auditWriter: auditWriter,
            now: now
        )
    }

    public func loadSession(meeting: SearchMeeting) throws -> TranscriptEditSession {
        let transcript = try bundleStore.readJSONArtifact(
            MeetingTranscript.self,
            meetingID: meeting.id,
            relativePath: MeetingTranscript.finalTranscriptRelativePath,
            purpose: MeetingTranscript.finalTranscriptPurpose
        )
        let history = try loadHistory(meetingID: meeting.id)
        return TranscriptEditSession(
            meeting: meeting,
            draft: TranscriptEditDraft(transcript: transcript, history: history),
            history: history
        )
    }

    public func save(session: TranscriptEditSession) throws -> TranscriptEditSessionSaveResult {
        let edits = try session.draft.validatedEdits()
        let result = try editingService.applyEdits(meeting: session.meeting, edits: edits)
        let updatedSession = try loadSession(meeting: session.meeting)
        return TranscriptEditSessionSaveResult(session: updatedSession, result: result)
    }

    private func loadHistory(meetingID: UUID) throws -> TranscriptEditHistory {
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
