import Foundation

public enum MeetingBundleManifestDecodingError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion
}

extension MeetingBundleManifestDecodingError: LocalizedError {
    public var errorDescription: String? {
        "The encrypted meeting bundle uses an unsupported schema version."
    }
}

public struct AudioTrackManifest: Codable, Equatable, Sendable {
    public var kind: TrackKind
    public var relativePath: String
    public var codec: String
    public var sampleRate: Double
    public var channels: Int
    public var encrypted: Bool
    public var checksum: String?

    public init(
        kind: TrackKind,
        relativePath: String,
        codec: String,
        sampleRate: Double,
        channels: Int,
        encrypted: Bool,
        checksum: String? = nil
    ) {
        self.kind = kind
        self.relativePath = relativePath
        self.codec = codec
        self.sampleRate = sampleRate
        self.channels = channels
        self.encrypted = encrypted
        self.checksum = checksum
    }
}

public struct MeetingBundleManifest: Codable, Equatable, Sendable {
    public var meetingID: UUID
    public var schemaVersion: Int
    public var createdAt: Date
    public var title: String
    public var tracks: [AudioTrackManifest]
    public var transcriptPath: String
    public var auditLogPath: String
    public var recovered: Bool
    public var context: MeetingContext
    public var sessionMetadataPath: String
    public var bookmarks: [MeetingBookmark]

    public init(
        meetingID: UUID,
        schemaVersion: Int = 2,
        createdAt: Date = Date(),
        title: String,
        tracks: [AudioTrackManifest],
        transcriptPath: String = "transcript/segments.json.enc",
        auditLogPath: String = "diagnostics/audit.jsonl",
        recovered: Bool = false,
        context: MeetingContext = MeetingContext(),
        sessionMetadataPath: String = RecordingSessionMetadata.relativePath,
        bookmarks: [MeetingBookmark] = []
    ) {
        self.meetingID = meetingID
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.title = title
        self.tracks = tracks
        self.transcriptPath = transcriptPath
        self.auditLogPath = auditLogPath
        self.recovered = recovered
        self.context = context
        self.sessionMetadataPath = sessionMetadataPath
        self.bookmarks = bookmarks.sorted(by: Self.bookmarkSort)
    }

    private enum CodingKeys: String, CodingKey {
        case meetingID
        case schemaVersion
        case createdAt
        case title
        case tracks
        case transcriptPath
        case auditLogPath
        case recovered
        case context
        case sessionMetadataPath
        case bookmarks
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        meetingID = try container.decode(UUID.self, forKey: .meetingID)
        schemaVersion = if container.contains(.schemaVersion) {
            try container.decode(Int.self, forKey: .schemaVersion)
        } else {
            1
        }
        guard schemaVersion == 1 || schemaVersion == 2 else {
            throw MeetingBundleManifestDecodingError.unsupportedSchemaVersion
        }
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        title = try container.decode(String.self, forKey: .title)
        tracks = try container.decode([AudioTrackManifest].self, forKey: .tracks)
        transcriptPath = try container.decodeIfPresent(String.self, forKey: .transcriptPath)
            ?? "transcript/segments.json.enc"
        auditLogPath = try container.decodeIfPresent(String.self, forKey: .auditLogPath)
            ?? "diagnostics/audit.jsonl"
        recovered = try container.decodeIfPresent(Bool.self, forKey: .recovered) ?? false
        if schemaVersion == 1 {
            context = try container.decodeIfPresent(MeetingContext.self, forKey: .context) ?? MeetingContext()
            sessionMetadataPath = try container.decodeIfPresent(String.self, forKey: .sessionMetadataPath)
                ?? RecordingSessionMetadata.relativePath
            bookmarks = try container.decodeIfPresent([MeetingBookmark].self, forKey: .bookmarks) ?? []
        } else {
            context = try container.decode(MeetingContext.self, forKey: .context)
            sessionMetadataPath = try container.decode(String.self, forKey: .sessionMetadataPath)
            guard sessionMetadataPath == RecordingSessionMetadata.relativePath else {
                throw DecodingError.dataCorruptedError(
                    forKey: .sessionMetadataPath,
                    in: container,
                    debugDescription: "Schema-v2 session metadata path is invalid."
                )
            }
            bookmarks = try container.decodeIfPresent([MeetingBookmark].self, forKey: .bookmarks) ?? []
        }
        bookmarks.sort(by: Self.bookmarkSort)
        let metadata = RecordingSessionMetadata(
            meetingID: meetingID,
            startedAt: createdAt,
            context: context,
            bookmarks: bookmarks
        )
        do {
            _ = try metadata.validated()
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .bookmarks,
                in: container,
                debugDescription: "Meeting bookmark metadata is invalid."
            )
        }
    }

    public static func initialEncryptedBundle(meetingID: UUID, title: String) -> MeetingBundleManifest {
        MeetingBundleManifest(
            meetingID: meetingID,
            title: title,
            tracks: [
                AudioTrackManifest(
                    kind: .remoteSystem,
                    relativePath: "audio/remote_original.caf.enc",
                    codec: "CAF/LPCM",
                    sampleRate: 48_000,
                    channels: 2,
                    encrypted: true
                ),
                AudioTrackManifest(
                    kind: .microphone,
                    relativePath: "audio/mic_original.caf.enc",
                    codec: "CAF/LPCM",
                    sampleRate: 48_000,
                    channels: 1,
                    encrypted: true
                ),
                AudioTrackManifest(
                    kind: .mixedPlayback,
                    relativePath: "audio/mixed_playback.m4a.enc",
                    codec: "M4A/AAC",
                    sampleRate: 48_000,
                    channels: 2,
                    encrypted: true
                )
            ]
        )
    }

    private static func bookmarkSort(_ lhs: MeetingBookmark, _ rhs: MeetingBookmark) -> Bool {
        if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
