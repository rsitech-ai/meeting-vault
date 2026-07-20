import Foundation

public struct RecoveredRecordingImportRequest: Equatable, Sendable {
    public var meetingID: UUID
    public var sourceName: String
    public var localeIdentifier: String?
    public var consentStatus: ConsentStatus

    public init(
        meetingID: UUID,
        sourceName: String,
        localeIdentifier: String? = nil,
        consentStatus: ConsentStatus
    ) {
        self.meetingID = meetingID
        self.sourceName = sourceName
        self.localeIdentifier = localeIdentifier
        self.consentStatus = consentStatus
    }
}

public struct RecoveredRecordingImportResult: Equatable, Sendable {
    public var reportBeforeImport: RecoveredRecordingReport
    public var record: MeetingRecord
    public var searchMeeting: SearchMeeting
    public var transcription: FinalTranscriptionResult
    public var intelligence: MeetingIntelligenceArtifact
    public var audioChunks: [AudioChunkRecord]
    public var bookmarks: [MeetingBookmark]

    public init(
        reportBeforeImport: RecoveredRecordingReport,
        record: MeetingRecord,
        searchMeeting: SearchMeeting,
        transcription: FinalTranscriptionResult,
        intelligence: MeetingIntelligenceArtifact,
        audioChunks: [AudioChunkRecord],
        bookmarks: [MeetingBookmark] = []
    ) {
        self.reportBeforeImport = reportBeforeImport
        self.record = record
        self.searchMeeting = searchMeeting
        self.transcription = transcription
        self.intelligence = intelligence
        self.audioChunks = audioChunks
        self.bookmarks = bookmarks
    }
}

public enum RecoveredRecordingImportError: Error, Equatable {
    case noAudioChunks(UUID)
}
