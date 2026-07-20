import Foundation

public struct MeetingIntelligenceRequest: Equatable, Sendable {
    public var meetingID: UUID
    public var segments: [TranscriptSegment]
    public var bookmarkEvidence: [MeetingIntelligenceBookmarkEvidence]

    public init(
        meetingID: UUID,
        segments: [TranscriptSegment],
        bookmarkEvidence: [MeetingIntelligenceBookmarkEvidence] = []
    ) {
        self.meetingID = meetingID
        self.segments = segments
        self.bookmarkEvidence = bookmarkEvidence
    }
}

public enum MeetingIntelligenceEvidenceProvenance: String, Codable, Equatable, Sendable {
    case userAuthored
}

public struct MeetingIntelligenceBookmarkEvidence: Codable, Equatable, Sendable {
    public var bookmark: MeetingBookmark
    public var provenance: MeetingIntelligenceEvidenceProvenance

    public init(
        bookmark: MeetingBookmark,
        provenance: MeetingIntelligenceEvidenceProvenance = .userAuthored
    ) {
        self.bookmark = bookmark
        self.provenance = provenance
    }
}

public struct MeetingIntelligenceService: @unchecked Sendable {
    private let provider: any MeetingIntelligenceProvider
    private let bundleStore: EncryptedMeetingBundleStore
    private let now: @Sendable () -> Date

    public init(
        provider: any MeetingIntelligenceProvider,
        bundleStore: EncryptedMeetingBundleStore,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.provider = provider
        self.bundleStore = bundleStore
        self.now = now
    }

    public func generateSummary(meetingID: UUID) async throws -> MeetingIntelligenceArtifact {
        let transcript = try bundleStore.readJSONArtifact(
            MeetingTranscript.self,
            meetingID: meetingID,
            relativePath: MeetingTranscript.finalTranscriptRelativePath,
            purpose: MeetingTranscript.finalTranscriptPurpose
        )
        let bookmarkEvidence = try loadBookmarkEvidence(meetingID: meetingID)
        let summary = try await provider.summarize(
            segments: transcript.segments,
            bookmarkEvidence: bookmarkEvidence,
            meetingID: meetingID
        )
        let promotedSummary = try MeetingGeneratedTitleService.summaryWithGeneratedTitle(
            from: summary,
            transcript: transcript
        )
        try IntelligenceValidator.validate(promotedSummary, against: transcript)

        let artifact = MeetingIntelligenceArtifact(
            meetingID: meetingID,
            transcriptVersion: transcript.transcriptVersion,
            transcriptDigest: try LocalFinalTranscriptionService.transcriptDigest(transcript),
            providerID: provider.id,
            generatedAt: now(),
            summary: promotedSummary
        )
        try bundleStore.writeJSONArtifact(
            artifact,
            meetingID: meetingID,
            relativePath: MeetingIntelligenceArtifact.summaryRelativePath,
            purpose: MeetingIntelligenceArtifact.summaryPurpose
        )
        return artifact
    }

    private func loadBookmarkEvidence(meetingID: UUID) throws -> [MeetingIntelligenceBookmarkEvidence] {
        let manifest = try bundleStore.readManifest(meetingID: meetingID)
        let bookmarks: [MeetingBookmark]
        if try bundleStore.artifactExists(meetingID: meetingID, relativePath: manifest.sessionMetadataPath) {
            bookmarks = try bundleStore.readJSONArtifact(
                RecordingSessionMetadata.self,
                meetingID: meetingID,
                relativePath: manifest.sessionMetadataPath,
                purpose: RecordingSessionMetadata.purpose
            ).validated(expectedMeetingID: meetingID).bookmarks
        } else {
            bookmarks = manifest.bookmarks
        }
        return bookmarks
            .sorted {
                if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
                return $0.id.uuidString < $1.id.uuidString
            }
            .map { MeetingIntelligenceBookmarkEvidence(bookmark: $0) }
    }

}

public final class MockMeetingIntelligenceProvider: MeetingIntelligenceProvider, @unchecked Sendable {
    public let id: String
    private let summary: MeetingSummary
    private let lock = NSLock()
    private var _requests: [MeetingIntelligenceRequest] = []

    public var requests: [MeetingIntelligenceRequest] {
        lock.lock()
        defer { lock.unlock() }
        return _requests
    }

    public init(id: String = "mock-intelligence", summary: MeetingSummary) {
        self.id = id
        self.summary = summary
    }

    public func summarize(segments: [TranscriptSegment], meetingID: UUID) async throws -> MeetingSummary {
        appendRequest(MeetingIntelligenceRequest(meetingID: meetingID, segments: segments))
        return summary
    }

    public func summarize(
        segments: [TranscriptSegment],
        bookmarkEvidence: [MeetingIntelligenceBookmarkEvidence],
        meetingID: UUID
    ) async throws -> MeetingSummary {
        appendRequest(
            MeetingIntelligenceRequest(
                meetingID: meetingID,
                segments: segments,
                bookmarkEvidence: bookmarkEvidence
            )
        )
        return summary
    }

    private func appendRequest(_ request: MeetingIntelligenceRequest) {
        lock.lock()
        defer { lock.unlock() }
        _requests.append(request)
    }
}
