import Foundation

public enum MeetingExportFormat: String, Codable, CaseIterable, Hashable, Sendable {
    case markdown
    case webVTT
    case pdf
    case docx
    case json
    case audioPackage

    public var fileExtension: String {
        switch self {
        case .markdown: "md"
        case .webVTT: "vtt"
        case .pdf: "pdf"
        case .docx: "docx"
        case .json: "json"
        case .audioPackage: "audio"
        }
    }
}

public struct MeetingExportFile: Codable, Equatable, Sendable {
    public var format: MeetingExportFormat
    public var url: URL

    public init(format: MeetingExportFormat, url: URL) {
        self.format = format
        self.url = url
    }
}

public struct MeetingExportPackage: Equatable, Sendable {
    public var meetingID: UUID
    public var transcriptVersion: Int
    public var transcriptDigest: String
    public var directory: URL
    public var files: [MeetingExportFile]

    public init(
        meetingID: UUID,
        transcriptVersion: Int = 0,
        transcriptDigest: String = "legacy",
        directory: URL,
        files: [MeetingExportFile]
    ) {
        self.meetingID = meetingID
        self.transcriptVersion = max(0, transcriptVersion)
        self.transcriptDigest = transcriptDigest
        self.directory = directory
        self.files = files
    }

    public func fileURL(for format: MeetingExportFormat) -> URL {
        guard let file = files.first(where: { $0.format == format }) else {
            preconditionFailure("Export package does not contain \(format.rawValue)")
        }
        return file.url
    }
}

public struct MeetingExportPayload: Codable, Equatable, Sendable {
    public var meeting: SearchMeeting
    public var transcript: MeetingTranscript
    public var intelligence: MeetingIntelligenceArtifact
    public var bookmarks: [MeetingBookmark]

    public init(
        meeting: SearchMeeting,
        transcript: MeetingTranscript,
        intelligence: MeetingIntelligenceArtifact,
        bookmarks: [MeetingBookmark] = []
    ) {
        self.meeting = meeting
        self.transcript = transcript
        self.intelligence = intelligence
        self.bookmarks = bookmarks
    }

    private enum CodingKeys: String, CodingKey {
        case meeting
        case transcript
        case intelligence
        case bookmarks
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        meeting = try container.decode(SearchMeeting.self, forKey: .meeting)
        transcript = try container.decode(MeetingTranscript.self, forKey: .transcript)
        intelligence = try container.decode(MeetingIntelligenceArtifact.self, forKey: .intelligence)
        bookmarks = try container.decodeIfPresent([MeetingBookmark].self, forKey: .bookmarks) ?? []
    }
}

public struct MeetingAudioExportManifest: Codable, Equatable, Sendable {
    public var meetingID: UUID
    public var exportedAt: Date
    public var files: [MeetingAudioExportFile]

    public init(
        meetingID: UUID,
        exportedAt: Date,
        files: [MeetingAudioExportFile]
    ) {
        self.meetingID = meetingID
        self.exportedAt = exportedAt
        self.files = files
    }
}

public struct MeetingAudioExportFile: Codable, Equatable, Sendable {
    public var track: TrackKind
    public var chunkIndex: Int
    public var relativePath: String
    public var startTime: TimeInterval
    public var duration: TimeInterval
    public var byteCount: Int
    public var codec: String

    public init(
        track: TrackKind,
        chunkIndex: Int,
        relativePath: String,
        startTime: TimeInterval,
        duration: TimeInterval,
        byteCount: Int,
        codec: String
    ) {
        self.track = track
        self.chunkIndex = chunkIndex
        self.relativePath = relativePath
        self.startTime = startTime
        self.duration = duration
        self.byteCount = byteCount
        self.codec = codec
    }
}

public extension JSONEncoder {
    static var meetingVaultExport: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

public extension JSONDecoder {
    static var meetingVaultExport: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
