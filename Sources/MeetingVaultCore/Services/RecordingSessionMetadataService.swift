import Foundation

public enum RecordingSessionMetadataServiceError: Error, Equatable, Sendable {
    case invalidMetadata
    case invalidBookmark
    case sessionNotActive
    case meetingMismatch
    case bookmarkNotFound
    case bookmarkOutsideRecording
    case metadataUnreadable
    case encryptedWriteFailed
    case revisionOverflow
}

extension RecordingSessionMetadataServiceError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidMetadata:
            "Meeting context is invalid. Review the language, participant count, names, and vocabulary."
        case .invalidBookmark:
            "The recording bookmark is invalid."
        case .sessionNotActive:
            "No active recording session can accept a bookmark."
        case .meetingMismatch:
            "The active recording session does not match this meeting."
        case .bookmarkNotFound:
            "The recording bookmark no longer exists."
        case .bookmarkOutsideRecording:
            "A recording bookmark is outside the captured duration."
        case .metadataUnreadable:
            "Encrypted recording metadata could not be read."
        case .encryptedWriteFailed:
            "Encrypted recording metadata could not be saved."
        case .revisionOverflow:
            "Encrypted recording metadata reached its revision limit."
        }
    }
}

public protocol RecordingSessionMetadataCreating: Sendable {
    func create(
        meetingID: UUID,
        startedAt: Date,
        context: MeetingContext
    ) async throws -> RecordingSessionMetadata
}

public protocol RecordingSessionMetadataManaging: RecordingSessionMetadataCreating, Actor {
    func markMoment(
        meetingID: UUID,
        timestamp: TimeInterval,
        category: MeetingBookmarkCategory?,
        note: String?
    ) async throws -> MeetingBookmark
    func recordPreviewEvidence(
        meetingID: UUID,
        evidence: TranscriptPreviewEvidence
    ) async throws -> RecordingSessionMetadata
    func finalize(meetingID: UUID, duration: TimeInterval) async throws -> RecordingSessionMetadata
}

public extension RecordingSessionMetadataManaging {
    func recordPreviewEvidence(
        meetingID: UUID,
        evidence: TranscriptPreviewEvidence
    ) async throws -> RecordingSessionMetadata {
        throw RecordingSessionMetadataServiceError.invalidMetadata
    }
}

public actor RecordingSessionMetadataService: RecordingSessionMetadataManaging {
    /// Marks at or inside this boundary are one user gesture. The earliest
    /// timestamp, creation date, and identifier win. Non-nil category/note
    /// values from the later mark replace their matching fields; nil preserves
    /// the existing user-authored value. Identical retries do not bump revision.
    public static let collapseWindow: TimeInterval = 0.5

    private let bundleStore: EncryptedMeetingBundleStore
    private let now: @Sendable () -> Date

    public init(
        bundleStore: EncryptedMeetingBundleStore,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.bundleStore = bundleStore
        self.now = now
    }

    public func create(
        meetingID: UUID,
        startedAt: Date,
        context: MeetingContext
    ) async throws -> RecordingSessionMetadata {
        let metadata: RecordingSessionMetadata
        do {
            metadata = try RecordingSessionMetadata(
                meetingID: meetingID,
                startedAt: startedAt,
                context: context
            ).validated()
        } catch {
            throw RecordingSessionMetadataServiceError.invalidMetadata
        }

        do {
            try write(metadata)
        } catch {
            throw RecordingSessionMetadataServiceError.encryptedWriteFailed
        }
        return metadata
    }

    public func read(meetingID: UUID) throws -> RecordingSessionMetadata {
        try bundleStore.readJSONArtifact(
            RecordingSessionMetadata.self,
            meetingID: meetingID,
            relativePath: RecordingSessionMetadata.relativePath,
            purpose: RecordingSessionMetadata.purpose
        ).validated(expectedMeetingID: meetingID)
    }

    public func markMoment(
        meetingID: UUID,
        timestamp: TimeInterval,
        category: MeetingBookmarkCategory? = nil,
        note: String? = nil
    ) async throws -> MeetingBookmark {
        guard timestamp.isFinite,
              timestamp >= 0,
              timestamp <= RecordingSessionMetadata.maximumDuration else {
            throw RecordingSessionMetadataServiceError.invalidBookmark
        }
        if let note {
            guard !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  note.utf8.count <= RecordingSessionMetadata.maxBookmarkNoteUTF8Bytes else {
                throw RecordingSessionMetadataServiceError.invalidBookmark
            }
        }

        var metadata = try loadActive(meetingID: meetingID)
        let (nextSequence, sequenceOverflow) =
            (metadata.bookmarks.compactMap(\.acceptanceUpperBound).max() ?? 0).addingReportingOverflow(1)
        guard !sequenceOverflow else {
            throw RecordingSessionMetadataServiceError.revisionOverflow
        }
        let candidate = MeetingBookmark(
            meetingID: meetingID,
            timestamp: timestamp,
            createdAt: now(),
            category: category,
            note: note,
            acceptedSequence: nextSequence
        )
        let previousBookmarks = metadata.bookmarks
        metadata.bookmarks.append(candidate)
        metadata.bookmarks = Self.normalizedBookmarks(metadata.bookmarks)
        let bookmark = metadata.bookmarks.first {
            timestamp >= $0.timestamp && timestamp <= $0.collapseUpperBound
        } ?? candidate
        guard metadata.bookmarks != previousBookmarks else { return bookmark }
        if Self.userProjection(metadata.bookmarks) != Self.userProjection(previousBookmarks) {
            try incrementRevision(&metadata)
        }
        try persistValidated(metadata)
        return bookmark
    }

    public func editBookmark(
        meetingID: UUID,
        bookmarkID: UUID,
        category: MeetingBookmarkCategory?,
        note: String?
    ) throws -> MeetingBookmark {
        if let note {
            guard !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  note.utf8.count <= RecordingSessionMetadata.maxBookmarkNoteUTF8Bytes else {
                throw RecordingSessionMetadataServiceError.invalidBookmark
            }
        }
        var metadata = try loadActive(meetingID: meetingID)
        guard let index = metadata.bookmarks.firstIndex(where: { $0.id == bookmarkID }) else {
            throw RecordingSessionMetadataServiceError.bookmarkNotFound
        }
        var edited = metadata.bookmarks[index]
        edited.category = category
        edited.note = note
        guard edited != metadata.bookmarks[index] else { return edited }
        metadata.bookmarks[index] = edited
        try incrementRevision(&metadata)
        try persistValidated(metadata)
        return edited
    }

    public func finalize(meetingID: UUID, duration: TimeInterval) async throws -> RecordingSessionMetadata {
        guard duration.isFinite,
              duration >= 0,
              duration <= RecordingSessionMetadata.maximumDuration else {
            throw RecordingSessionMetadataServiceError.bookmarkOutsideRecording
        }
        var metadata = try load(meetingID: meetingID)
        guard !metadata.isFinalized else { return metadata }
        guard metadata.bookmarks.allSatisfy({ $0.timestamp <= duration }) else {
            throw RecordingSessionMetadataServiceError.bookmarkOutsideRecording
        }
        metadata.isFinalized = true
        try incrementRevision(&metadata)
        try persistValidated(metadata)
        return metadata
    }

    public func recordPreviewEvidence(
        meetingID: UUID,
        evidence: TranscriptPreviewEvidence
    ) async throws -> RecordingSessionMetadata {
        var metadata = try loadActive(meetingID: meetingID)
        guard metadata.previewEvidence != evidence else { return metadata }
        metadata.previewEvidence = evidence
        do {
            _ = try metadata.validated(expectedMeetingID: meetingID)
        } catch {
            throw RecordingSessionMetadataServiceError.invalidMetadata
        }
        try incrementRevision(&metadata)
        try persistValidated(metadata)
        return metadata
    }

    private func loadActive(meetingID: UUID) throws -> RecordingSessionMetadata {
        let metadata = try load(meetingID: meetingID)
        guard !metadata.isFinalized else {
            throw RecordingSessionMetadataServiceError.sessionNotActive
        }
        return metadata
    }

    private func load(meetingID: UUID) throws -> RecordingSessionMetadata {
        do {
            guard try bundleStore.artifactExists(
                meetingID: meetingID,
                relativePath: RecordingSessionMetadata.relativePath
            ) else {
                throw RecordingSessionMetadataServiceError.sessionNotActive
            }
            return try read(meetingID: meetingID).validated(expectedMeetingID: meetingID)
        } catch RecordingSessionMetadataValidationError.metadataMeetingMismatch {
            throw RecordingSessionMetadataServiceError.meetingMismatch
        } catch let error as RecordingSessionMetadataServiceError {
            throw error
        } catch {
            throw RecordingSessionMetadataServiceError.metadataUnreadable
        }
    }

    private func persistValidated(_ metadata: RecordingSessionMetadata) throws {
        let validated: RecordingSessionMetadata
        do {
            validated = try metadata.validated()
        } catch {
            throw RecordingSessionMetadataServiceError.invalidBookmark
        }
        do {
            try write(validated)
        } catch let error as RecordingSessionMetadataServiceError {
            throw error
        } catch {
            throw RecordingSessionMetadataServiceError.encryptedWriteFailed
        }
    }

    private func write(_ metadata: RecordingSessionMetadata) throws {
        try bundleStore.writeJSONArtifact(
            metadata,
            meetingID: metadata.meetingID,
            relativePath: RecordingSessionMetadata.relativePath,
            purpose: RecordingSessionMetadata.purpose
        )
    }

    private func incrementRevision(_ metadata: inout RecordingSessionMetadata) throws {
        guard metadata.revision < RecordingSessionMetadata.maximumRevision else {
            throw RecordingSessionMetadataServiceError.revisionOverflow
        }
        metadata.revision += 1
    }

    public static func normalizedBookmarks(_ bookmarks: [MeetingBookmark]) -> [MeetingBookmark] {
        let sorted = bookmarks.enumerated().sorted { lhs, rhs in
            if lhs.element.timestamp != rhs.element.timestamp {
                return lhs.element.timestamp < rhs.element.timestamp
            }
            if lhs.element.createdAt != rhs.element.createdAt {
                return lhs.element.createdAt < rhs.element.createdAt
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
        guard var current = sorted.first else { return [] }
        var members = [current]
        var result: [MeetingBookmark] = []

        func collapse(_ cluster: [MeetingBookmark]) -> MeetingBookmark {
            let earliestTimestamp = cluster.map(\.timestamp).min() ?? cluster[0].timestamp
            let identity = cluster.enumerated().min { lhs, rhs in
                let lhsSequence = lhs.element.acceptedSequence ?? 0
                let rhsSequence = rhs.element.acceptedSequence ?? 0
                if lhsSequence != rhsSequence { return lhsSequence < rhsSequence }
                if lhs.element.createdAt != rhs.element.createdAt {
                    return lhs.element.createdAt < rhs.element.createdAt
                }
                return lhs.offset < rhs.offset
            }?.element ?? cluster[0]
            let latestTimestamp = cluster.map(\.collapseUpperBound).max() ?? earliestTimestamp
            let latestSequence = cluster.compactMap(\.acceptanceUpperBound).max()
            let category = cluster.compactMap { bookmark -> (TimeInterval, String, MeetingBookmarkCategory)? in
                bookmark.category.map { (bookmark.collapseUpperBound, $0.rawValue, $0) }
            }.max { lhs, rhs in
                lhs.0 != rhs.0 ? lhs.0 < rhs.0 : lhs.1 < rhs.1
            }?.2
            let note = cluster.compactMap { bookmark -> (TimeInterval, String)? in
                bookmark.note.map { (bookmark.collapseUpperBound, $0) }
            }.max { lhs, rhs in
                lhs.0 != rhs.0 ? lhs.0 < rhs.0 : lhs.1 < rhs.1
            }?.1
            return MeetingBookmark(
                id: identity.id,
                meetingID: identity.meetingID,
                timestamp: earliestTimestamp,
                createdAt: identity.createdAt,
                category: category,
                note: note,
                collapsedThroughTimestamp: latestTimestamp > earliestTimestamp ? latestTimestamp : nil,
                acceptedSequence: identity.acceptedSequence,
                collapsedThroughSequence: latestSequence.flatMap { latest in
                    latest != identity.acceptedSequence ? latest : nil
                }
            )
        }

        for bookmark in sorted.dropFirst() {
            let upperBound = members.map(\.collapseUpperBound).max() ?? current.collapseUpperBound
            if bookmark.timestamp - upperBound <= collapseWindow {
                members.append(bookmark)
            } else {
                result.append(collapse(members))
                current = bookmark
                members = [bookmark]
            }
        }
        result.append(collapse(members))
        return result.sorted(by: bookmarkSort)
    }

    public static func bookmarkSort(_ lhs: MeetingBookmark, _ rhs: MeetingBookmark) -> Bool {
        if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func userProjection(_ bookmarks: [MeetingBookmark]) -> [MeetingBookmark] {
        bookmarks.map {
            MeetingBookmark(
                id: $0.id,
                meetingID: $0.meetingID,
                timestamp: $0.timestamp,
                createdAt: $0.createdAt,
                category: $0.category,
                note: $0.note
            )
        }
    }
}
