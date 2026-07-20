import Foundation

public enum MeetingBookmarkCategory: String, Codable, CaseIterable, Sendable {
    case important
    case decision
    case followUp
    case question
}

public struct MeetingBookmark: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var meetingID: UUID
    public var timestamp: TimeInterval
    public var createdAt: Date
    public var category: MeetingBookmarkCategory?
    public var note: String?
    /// The last raw gesture timestamp represented by this collapsed bookmark.
    /// Older artifacts omit it and therefore represent a single timestamp.
    public var collapsedThroughTimestamp: TimeInterval?
    /// Monotonic acceptance order used only to preserve the first accepted
    /// identity when an out-of-order timestamp extends a collapse cluster.
    public var acceptedSequence: UInt64?
    /// Highest acceptance order represented by this collapsed bookmark. This
    /// keeps later gestures monotonic after a cluster is persisted or reloaded.
    public var collapsedThroughSequence: UInt64?

    public init(
        id: UUID = UUID(),
        meetingID: UUID,
        timestamp: TimeInterval,
        createdAt: Date,
        category: MeetingBookmarkCategory? = nil,
        note: String? = nil,
        collapsedThroughTimestamp: TimeInterval? = nil,
        acceptedSequence: UInt64? = nil,
        collapsedThroughSequence: UInt64? = nil
    ) {
        self.id = id
        self.meetingID = meetingID
        self.timestamp = timestamp
        self.createdAt = createdAt
        self.category = category
        self.note = note
        self.collapsedThroughTimestamp = collapsedThroughTimestamp
        self.acceptedSequence = acceptedSequence
        self.collapsedThroughSequence = collapsedThroughSequence
    }

    public var collapseUpperBound: TimeInterval {
        max(timestamp, collapsedThroughTimestamp ?? timestamp)
    }

    public var acceptanceUpperBound: UInt64? {
        switch (acceptedSequence, collapsedThroughSequence) {
        case let (accepted?, collapsed?): max(accepted, collapsed)
        case let (accepted?, nil): accepted
        case let (nil, collapsed?): collapsed
        case (nil, nil): nil
        }
    }
}

public enum RecordingSessionMetadataValidationError: Error, Equatable, Sendable {
    case invalidStartedAt
    case invalidBookmarkTimestamp
    case invalidBookmarkCreatedAt
    case invalidRevision
    case tooManyBookmarks
    case bookmarkNoteTooLong
    case bookmarkMeetingMismatch
    case duplicateBookmarkID
    case emptyBookmarkNote
    case metadataMeetingMismatch
    case invalidPreviewEvidence
}

extension RecordingSessionMetadataValidationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidStartedAt:
            "The recording start time is invalid."
        case .invalidBookmarkTimestamp:
            "A recording bookmark timestamp is invalid."
        case .invalidBookmarkCreatedAt:
            "A recording bookmark creation time is invalid."
        case .invalidRevision:
            "The recording metadata revision is invalid."
        case .tooManyBookmarks:
            "The recording contains too many bookmarks."
        case .bookmarkNoteTooLong:
            "A recording bookmark note is too long."
        case .bookmarkMeetingMismatch:
            "A recording bookmark belongs to a different meeting."
        case .duplicateBookmarkID:
            "A recording bookmark identifier is duplicated."
        case .emptyBookmarkNote:
            "A recording bookmark note is empty."
        case .metadataMeetingMismatch:
            "Encrypted recording metadata belongs to a different meeting."
        case .invalidPreviewEvidence:
            "Live preview evidence contains an invalid range."
        }
    }
}

public struct RecordingSessionMetadata: Codable, Equatable, Sendable {
    public static let relativePath = "metadata/active-session.json.enc"
    public static let corruptQuarantineRelativePath = "diagnostics/recovery/active-session-corrupt.json.enc"
    public static let purpose = "metadata:active-session"
    public static let maxBookmarks = 10_000
    public static let maxBookmarkNoteUTF8Bytes = 4_096
    public static let maximumDuration: TimeInterval = 60 * 60 * 3
    public static let maximumRevision = Int.max - 1
    public static let maximumPreviewEvidenceItems = 50_000

    public var meetingID: UUID
    public var startedAt: Date
    public var context: MeetingContext
    public var bookmarks: [MeetingBookmark]
    public var previewEvidence: TranscriptPreviewEvidence
    public var revision: Int
    public var isFinalized: Bool

    public init(
        meetingID: UUID,
        startedAt: Date,
        context: MeetingContext,
        bookmarks: [MeetingBookmark] = [],
        previewEvidence: TranscriptPreviewEvidence = .empty,
        revision: Int = 0,
        isFinalized: Bool = false
    ) {
        self.meetingID = meetingID
        self.startedAt = startedAt
        self.context = context
        self.bookmarks = bookmarks
        self.previewEvidence = previewEvidence
        self.revision = revision
        self.isFinalized = isFinalized
    }

    public func validated(expectedMeetingID: UUID? = nil) throws -> RecordingSessionMetadata {
        guard startedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw RecordingSessionMetadataValidationError.invalidStartedAt
        }
        guard revision >= 0, revision <= Self.maximumRevision else {
            throw RecordingSessionMetadataValidationError.invalidRevision
        }
        guard bookmarks.count <= Self.maxBookmarks else {
            throw RecordingSessionMetadataValidationError.tooManyBookmarks
        }
        guard previewEvidence.gaps.count <= Self.maximumPreviewEvidenceItems,
              previewEvidence.speakerIdentities.count <= Self.maximumPreviewEvidenceItems,
              previewEvidence.gaps.allSatisfy({
                  $0.startTime >= 0 && $0.endTime <= Self.maximumDuration && $0.endTime > $0.startTime
              }),
              previewEvidence.speakerIdentities.allSatisfy({
                  $0.startTime >= 0 && $0.endTime <= Self.maximumDuration && $0.endTime > $0.startTime
                      && !$0.speakerName.isEmpty
              }) else {
            throw RecordingSessionMetadataValidationError.invalidPreviewEvidence
        }
        var bookmarkIDs = Set<UUID>()
        for bookmark in bookmarks {
            guard bookmark.timestamp.isFinite,
                  bookmark.timestamp >= 0,
                  bookmark.timestamp <= Self.maximumDuration else {
                throw RecordingSessionMetadataValidationError.invalidBookmarkTimestamp
            }
            guard bookmark.collapseUpperBound.isFinite,
                  bookmark.collapseUpperBound >= bookmark.timestamp,
                  bookmark.collapseUpperBound <= Self.maximumDuration else {
                throw RecordingSessionMetadataValidationError.invalidBookmarkTimestamp
            }
            if let acceptedSequence = bookmark.acceptedSequence,
               let collapsedThroughSequence = bookmark.collapsedThroughSequence,
               collapsedThroughSequence < acceptedSequence {
                throw RecordingSessionMetadataValidationError.invalidRevision
            }
            guard bookmark.createdAt.timeIntervalSinceReferenceDate.isFinite else {
                throw RecordingSessionMetadataValidationError.invalidBookmarkCreatedAt
            }
            if let note = bookmark.note,
               note.utf8.count > Self.maxBookmarkNoteUTF8Bytes {
                throw RecordingSessionMetadataValidationError.bookmarkNoteTooLong
            }
            if let note = bookmark.note,
               note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw RecordingSessionMetadataValidationError.emptyBookmarkNote
            }
            guard bookmark.meetingID == meetingID else {
                throw RecordingSessionMetadataValidationError.bookmarkMeetingMismatch
            }
            guard bookmarkIDs.insert(bookmark.id).inserted else {
                throw RecordingSessionMetadataValidationError.duplicateBookmarkID
            }
        }

        var copy = self
        copy.context = try context.validated()
        if let expectedMeetingID, meetingID != expectedMeetingID {
            throw RecordingSessionMetadataValidationError.metadataMeetingMismatch
        }
        return copy
    }

    private enum CodingKeys: String, CodingKey {
        case meetingID
        case startedAt
        case context
        case bookmarks
        case previewEvidence
        case revision
        case isFinalized
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        meetingID = try container.decode(UUID.self, forKey: .meetingID)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        context = try container.decode(MeetingContext.self, forKey: .context)
        bookmarks = try container.decodeIfPresent([MeetingBookmark].self, forKey: .bookmarks) ?? []
        previewEvidence = try container.decodeIfPresent(
            TranscriptPreviewEvidence.self,
            forKey: .previewEvidence
        ) ?? .empty
        revision = try container.decodeIfPresent(Int.self, forKey: .revision) ?? 0
        isFinalized = try container.decodeIfPresent(Bool.self, forKey: .isFinalized) ?? false
    }
}
