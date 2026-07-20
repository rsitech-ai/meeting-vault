import Foundation

public struct LocalRecordingImportRequest: Equatable, Sendable {
    public var transcriptURL: URL
    public var audioURL: URL
    public var title: String?
    public var sourceName: String
    public var consentStatus: ConsentStatus
    public var localeIdentifier: String?
    public var importedAt: Date

    public init(
        transcriptURL: URL,
        audioURL: URL,
        title: String? = nil,
        sourceName: String,
        consentStatus: ConsentStatus,
        localeIdentifier: String? = nil,
        importedAt: Date = Date()
    ) {
        self.transcriptURL = transcriptURL
        self.audioURL = audioURL
        self.title = title
        self.sourceName = sourceName
        self.consentStatus = consentStatus
        self.localeIdentifier = localeIdentifier
        self.importedAt = importedAt
    }
}

public struct LocalRecordingImportMetadata: Codable, Equatable, Sendable {
    public static let relativePath = "metadata/local-recording-import.json.enc"
    public static let purpose = "metadata:local-recording-import"

    public var importedAt: Date
    public var transcriptFileName: String
    public var audioFileName: String
    public var audioByteCount: Int
    public var transcriptLineCount: Int

    public init(
        importedAt: Date,
        transcriptFileName: String,
        audioFileName: String,
        audioByteCount: Int,
        transcriptLineCount: Int
    ) {
        self.importedAt = importedAt
        self.transcriptFileName = transcriptFileName
        self.audioFileName = audioFileName
        self.audioByteCount = audioByteCount
        self.transcriptLineCount = transcriptLineCount
    }
}

public struct LocalRecordingImportResult: Equatable, Sendable {
    public var record: MeetingRecord
    public var searchMeeting: SearchMeeting
    public var transcript: MeetingTranscript
    public var metadata: LocalRecordingImportMetadata
    public var audioChunks: [AudioChunkRecord]
    public var intelligenceOutcome: LocalRecordingIntelligenceOutcome

    public init(
        record: MeetingRecord,
        searchMeeting: SearchMeeting,
        transcript: MeetingTranscript,
        metadata: LocalRecordingImportMetadata,
        audioChunks: [AudioChunkRecord],
        intelligenceOutcome: LocalRecordingIntelligenceOutcome = .notRequested
    ) {
        self.record = record
        self.searchMeeting = searchMeeting
        self.transcript = transcript
        self.metadata = metadata
        self.audioChunks = audioChunks
        self.intelligenceOutcome = intelligenceOutcome
    }
}

public enum LocalRecordingIntelligenceOutcome: Equatable, Sendable {
    case notRequested
    case generated
    case unavailable(String)
}

public struct LocalRecordingSampleCandidate: Identifiable, Equatable, Sendable {
    public var id: String { transcriptURL.path }
    public var timestampKey: String
    public var title: String
    public var transcriptURL: URL
    public var audioURL: URL
    public var audioByteCount: Int

    public init(
        timestampKey: String,
        title: String,
        transcriptURL: URL,
        audioURL: URL,
        audioByteCount: Int
    ) {
        self.timestampKey = timestampKey
        self.title = title
        self.transcriptURL = transcriptURL
        self.audioURL = audioURL
        self.audioByteCount = audioByteCount
    }
}
