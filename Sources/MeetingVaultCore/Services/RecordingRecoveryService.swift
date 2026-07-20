import Foundation

public struct RecordingRecoveryService {
    private let bundleStore: EncryptedMeetingBundleStore
    private let chunkWriter: EncryptedAudioChunkWriter
    private let manifestWriter: @Sendable (MeetingBundleManifest, UUID) throws -> Void

    public init(
        bundleStore: EncryptedMeetingBundleStore,
        chunkWriter: EncryptedAudioChunkWriter,
        manifestWriter: (@Sendable (MeetingBundleManifest, UUID) throws -> Void)? = nil
    ) {
        self.bundleStore = bundleStore
        self.chunkWriter = chunkWriter
        self.manifestWriter = manifestWriter ?? { manifest, meetingID in
            try bundleStore.writeJSONArtifact(
                manifest,
                meetingID: meetingID,
                relativePath: "manifest.json.enc",
                purpose: "manifest"
            )
        }
    }

    public func scanRecoverableBundles() throws -> [RecoveredRecordingReport] {
        try bundleStore.listMeetingBundleIDs().compactMap { meetingID in
            try? recoverableReport(for: meetingID)
        }
    }

    public func recoverableReport(for meetingID: UUID) throws -> RecoveredRecordingReport {
        let manifest = try bundleStore.readManifest(meetingID: meetingID)
        let trackReports = try TrackKind.allCases.map { track in
            try report(for: track, meetingID: meetingID)
        }
        .filter { $0.chunkCount > 0 }

        let hasFinalTranscript = artifactExists(
            MeetingTranscript.self,
            meetingID: meetingID,
            relativePath: MeetingTranscript.finalTranscriptRelativePath,
            purpose: MeetingTranscript.finalTranscriptPurpose
        )
        let hasSummary = artifactExists(
            MeetingIntelligenceArtifact.self,
            meetingID: meetingID,
            relativePath: MeetingIntelligenceArtifact.summaryRelativePath,
            purpose: MeetingIntelligenceArtifact.summaryPurpose
        )

        var warnings = Set<RecordingRecoveryWarning>()
        if try bundleStore.artifactExists(
            meetingID: meetingID,
            relativePath: RecordingSessionMetadata.corruptQuarantineRelativePath
        ) {
            warnings.insert(.sessionMetadataCorrupt)
        }
        if trackReports.isEmpty {
            warnings.insert(.noAudioChunks)
        }
        if !hasFinalTranscript {
            warnings.insert(.finalTranscriptMissing)
        }
        if !hasSummary {
            warnings.insert(.summaryMissing)
        }
        let bookmarks: [MeetingBookmark]
        do {
            guard try bundleStore.artifactExists(
                meetingID: meetingID,
                relativePath: manifest.sessionMetadataPath
            ) else {
                warnings.insert(.sessionMetadataMissing)
                bookmarks = manifest.bookmarks
                return RecoveredRecordingReport(
                    meetingID: meetingID,
                    title: manifest.title,
                    createdAt: manifest.createdAt,
                    trackReports: trackReports,
                    hasFinalTranscript: hasFinalTranscript,
                    hasSummary: hasSummary,
                    warnings: warnings,
                    bookmarks: bookmarks
                )
            }
            let metadata = try bundleStore.readJSONArtifact(
                RecordingSessionMetadata.self,
                meetingID: meetingID,
                relativePath: manifest.sessionMetadataPath,
                purpose: RecordingSessionMetadata.purpose
            ).validated(expectedMeetingID: meetingID)
            bookmarks = metadata.bookmarks.sorted(by: bookmarkSort)
        } catch {
            warnings.insert(.sessionMetadataCorrupt)
            bookmarks = manifest.bookmarks
        }

        return RecoveredRecordingReport(
            meetingID: meetingID,
            title: manifest.title,
            createdAt: manifest.createdAt,
            trackReports: trackReports,
            hasFinalTranscript: hasFinalTranscript,
            hasSummary: hasSummary,
            warnings: warnings,
            bookmarks: bookmarks
        )
    }

    public func ensureSessionMetadataForRecoveredImport(
        meetingID: UUID,
        duration: TimeInterval
    ) throws -> RecordingSessionMetadata {
        var manifest = try bundleStore.readManifest(meetingID: meetingID)
        let metadata: RecordingSessionMetadata
        if try bundleStore.artifactExists(
            meetingID: meetingID,
            relativePath: manifest.sessionMetadataPath
        ) {
            do {
                var existing = try bundleStore.readJSONArtifact(
                    RecordingSessionMetadata.self,
                    meetingID: meetingID,
                    relativePath: manifest.sessionMetadataPath,
                    purpose: RecordingSessionMetadata.purpose
                ).validated(expectedMeetingID: meetingID)
                guard existing.bookmarks.allSatisfy({ $0.timestamp <= duration }) else {
                    throw RecordingSessionMetadataServiceError.bookmarkOutsideRecording
                }
                if !existing.isFinalized {
                    guard existing.revision < RecordingSessionMetadata.maximumRevision else {
                        throw RecordingSessionMetadataServiceError.revisionOverflow
                    }
                    existing.isFinalized = true
                    existing.revision += 1
                    try bundleStore.writeJSONArtifact(
                        existing,
                        meetingID: meetingID,
                        relativePath: manifest.sessionMetadataPath,
                        purpose: RecordingSessionMetadata.purpose
                    )
                }
                metadata = existing
            } catch RecordingSessionMetadataValidationError.metadataMeetingMismatch {
                throw RecordingSessionMetadataValidationError.metadataMeetingMismatch
            } catch let error as RecordingSessionMetadataServiceError {
                throw error
            } catch {
                try preserveCorruptSessionMetadata(meetingID: meetingID)
                let boundedBookmarks = manifest.bookmarks.filter { $0.timestamp <= duration }
                metadata = try RecordingSessionMetadata(
                    meetingID: meetingID,
                    startedAt: manifest.createdAt,
                    context: manifest.context,
                    bookmarks: boundedBookmarks,
                    revision: 0,
                    isFinalized: true
                ).validated(expectedMeetingID: meetingID)
                try bundleStore.writeJSONArtifact(
                    metadata,
                    meetingID: meetingID,
                    relativePath: manifest.sessionMetadataPath,
                    purpose: RecordingSessionMetadata.purpose
                )
            }
        } else {
            let boundedBookmarks = manifest.bookmarks.filter { $0.timestamp <= duration }
            metadata = try RecordingSessionMetadata(
                meetingID: meetingID,
                startedAt: manifest.createdAt,
                context: manifest.context,
                bookmarks: boundedBookmarks,
                revision: 0,
                isFinalized: true
            ).validated(expectedMeetingID: meetingID)
            try bundleStore.writeJSONArtifact(
                metadata,
                meetingID: meetingID,
                relativePath: manifest.sessionMetadataPath,
                purpose: RecordingSessionMetadata.purpose
            )
        }
        manifest.schemaVersion = 2
        manifest.context = metadata.context
        manifest.sessionMetadataPath = RecordingSessionMetadata.relativePath
        manifest.bookmarks = metadata.bookmarks
        try manifestWriter(manifest, meetingID)
        return try metadata.validated(expectedMeetingID: meetingID)
    }

    private func preserveCorruptSessionMetadata(meetingID: UUID) throws {
        let bundleURL = bundleStore.bundleURL(for: meetingID)
        let sourceURL = bundleURL.appendingPathComponent(RecordingSessionMetadata.relativePath)
        let quarantineURL = bundleURL.appendingPathComponent(
            RecordingSessionMetadata.corruptQuarantineRelativePath
        )
        guard !FileManager.default.fileExists(atPath: quarantineURL.path) else { return }
        try FileManager.default.createDirectory(
            at: quarantineURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: sourceURL, to: quarantineURL)
    }

    private func bookmarkSort(_ lhs: MeetingBookmark, _ rhs: MeetingBookmark) -> Bool {
        if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private func report(for track: TrackKind, meetingID: UUID) throws -> RecoveredTrackReport {
        let checkpoint = try chunkWriter.readCheckpoint(meetingID: meetingID, track: track)
        let firstStart = checkpoint.chunks.map(\.startTime).min()
        let lastEnd = checkpoint.chunks.map { $0.startTime + $0.duration }.max()
        return RecoveredTrackReport(
            track: track,
            chunkCount: checkpoint.chunks.count,
            totalDuration: checkpoint.totalDuration,
            firstStartTime: firstStart,
            lastEndTime: lastEnd
        )
    }

    private func artifactExists<Value: Decodable>(
        _ type: Value.Type,
        meetingID: UUID,
        relativePath: String,
        purpose: String
    ) -> Bool {
        do {
            _ = try bundleStore.readJSONArtifact(
                type,
                meetingID: meetingID,
                relativePath: relativePath,
                purpose: purpose
            )
            return true
        } catch {
            return false
        }
    }
}
