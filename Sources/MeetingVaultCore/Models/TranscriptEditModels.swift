import Foundation

public enum TranscriptEditError: Error, Equatable {
    case emptyEdits
    case segmentNotFound(UUID)
    case blankReplacementText(UUID)
}

public struct TranscriptSegmentEdit: Codable, Equatable, Sendable {
    public var segmentID: UUID
    public var replacementText: String
    public var replacementSpeakerName: String?

    public init(
        segmentID: UUID,
        replacementText: String,
        replacementSpeakerName: String? = nil
    ) {
        self.segmentID = segmentID
        self.replacementText = replacementText
        self.replacementSpeakerName = replacementSpeakerName
    }
}

public struct TranscriptEditResult: Equatable, Sendable {
    public var transcript: MeetingTranscript
    public var editedSegmentCount: Int
    public var version: Int

    public init(transcript: MeetingTranscript, editedSegmentCount: Int, version: Int) {
        self.transcript = transcript
        self.editedSegmentCount = editedSegmentCount
        self.version = version
    }
}

public struct TranscriptEditHistory: Codable, Equatable, Sendable {
    public static let relativePath = "transcript/edit-history.json.enc"
    public static let purpose = "transcript:edit-history"

    public var meetingID: UUID
    public var entries: [TranscriptEditHistoryEntry]

    public init(meetingID: UUID, entries: [TranscriptEditHistoryEntry] = []) {
        self.meetingID = meetingID
        self.entries = entries.sorted { $0.version < $1.version }
    }

    public var latestVersion: Int {
        entries.map(\.version).max() ?? 0
    }
}

public struct TranscriptEditHistoryEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var version: Int
    public var editedAt: Date
    public var editedSegmentIDs: [UUID]
    public var editedSegmentCount: Int

    public init(
        id: UUID = UUID(),
        version: Int,
        editedAt: Date,
        editedSegmentIDs: [UUID]
    ) {
        self.id = id
        self.version = version
        self.editedAt = editedAt
        self.editedSegmentIDs = editedSegmentIDs.sorted { $0.uuidString < $1.uuidString }
        self.editedSegmentCount = editedSegmentIDs.count
    }
}

public struct TranscriptEditDraft: Equatable, Sendable {
    public var meetingID: UUID
    public var currentVersion: Int
    public var localeIdentifier: String?
    public var generatedAt: Date
    public var editedAt: Date?
    public var providerConfigurationVersion: String
    public var segments: [TranscriptEditDraftSegment]

    public init(transcript: MeetingTranscript, history: TranscriptEditHistory? = nil) {
        self.meetingID = transcript.meetingID
        self.currentVersion = max(transcript.transcriptVersion, history?.latestVersion ?? 0)
        self.localeIdentifier = transcript.localeIdentifier
        self.generatedAt = transcript.generatedAt
        self.editedAt = transcript.editedAt
        self.providerConfigurationVersion = transcript.providerConfigurationVersion
        self.segments = transcript.segments.map { TranscriptEditDraftSegment(segment: $0) }
    }

    public var hasChanges: Bool {
        segments.contains(where: \.hasChanges)
    }

    public var changedSegmentCount: Int {
        segments.filter(\.hasChanges).count
    }

    public mutating func updateSegment(
        id: UUID,
        speakerName: String?,
        text: String
    ) throws {
        guard let index = segments.firstIndex(where: { $0.id == id }) else {
            throw TranscriptEditError.segmentNotFound(id)
        }
        segments[index].editedSpeakerName = speakerName
        segments[index].editedText = text
    }

    public mutating func revertSegment(id: UUID) throws {
        guard let index = segments.firstIndex(where: { $0.id == id }) else {
            throw TranscriptEditError.segmentNotFound(id)
        }
        segments[index].revert()
    }

    public mutating func revertAll() {
        for index in segments.indices {
            segments[index].revert()
        }
    }

    public mutating func markSaved(version: Int) {
        currentVersion = version
        for index in segments.indices {
            segments[index].markSaved()
        }
    }

    public func validatedEdits() throws -> [TranscriptSegmentEdit] {
        try segments
            .filter(\.hasChanges)
            .map { segment in
                let text = segment.editedText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else {
                    throw TranscriptEditError.blankReplacementText(segment.id)
                }
                return TranscriptSegmentEdit(
                    segmentID: segment.id,
                    replacementText: text,
                    replacementSpeakerName: segment.effectiveEditedSpeakerName == segment.originalSpeakerName
                        ? nil
                        : segment.effectiveEditedSpeakerName
                )
            }
    }
}

public struct TranscriptEditDraftSegment: Equatable, Identifiable, Sendable {
    public var id: UUID
    public var originalSpeakerName: String
    public var originalText: String
    public var editedSpeakerName: String?
    public var editedText: String
    public var trackKind: TrackKind
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    public var confidence: Double
    public var reviewEvidence: TranscriptSegmentEvidence?

    public init(segment: TranscriptSegment) {
        self.id = segment.id
        self.originalSpeakerName = segment.speakerName
        self.originalText = segment.text
        self.editedSpeakerName = segment.speakerName
        self.editedText = segment.text
        self.trackKind = segment.trackKind
        self.startTime = segment.startTime
        self.endTime = segment.endTime
        self.confidence = segment.confidence
        self.reviewEvidence = segment.reviewEvidence
    }

    public var hasChanges: Bool {
        trimmedEditedText != originalText || effectiveEditedSpeakerName != originalSpeakerName
    }

    public var trimmedEditedText: String {
        editedText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var trimmedEditedSpeakerName: String? {
        editedSpeakerName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    public var effectiveEditedSpeakerName: String {
        trimmedEditedSpeakerName ?? originalSpeakerName
    }

    public mutating func revert() {
        editedSpeakerName = originalSpeakerName
        editedText = originalText
    }

    public mutating func markSaved() {
        originalSpeakerName = effectiveEditedSpeakerName
        originalText = trimmedEditedText
        editedSpeakerName = originalSpeakerName
        editedText = originalText
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
