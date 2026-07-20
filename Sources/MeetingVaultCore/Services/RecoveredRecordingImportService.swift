import Foundation

public struct RecoveredRecordingImportService: @unchecked Sendable {
    private let recoveryService: RecordingRecoveryService
    private let transcriptionService: any FinalTranscriptionServicing
    private let intelligenceService: MeetingIntelligenceService
    private let repository: MeetingLibraryRepository
    private let chunkWriter: EncryptedAudioChunkWriter

    public init(
        recoveryService: RecordingRecoveryService,
        transcriptionService: any FinalTranscriptionServicing,
        intelligenceService: MeetingIntelligenceService,
        repository: MeetingLibraryRepository,
        chunkWriter: EncryptedAudioChunkWriter
    ) {
        self.recoveryService = recoveryService
        self.transcriptionService = transcriptionService
        self.intelligenceService = intelligenceService
        self.repository = repository
        self.chunkWriter = chunkWriter
    }

    public func importRecoveredRecording(
        _ request: RecoveredRecordingImportRequest
    ) async throws -> RecoveredRecordingImportResult {
        let report = try recoveryService.recoverableReport(for: request.meetingID)
        let records = try readAudioChunkRecords(meetingID: request.meetingID)
        guard !records.isEmpty else {
            throw RecoveredRecordingImportError.noAudioChunks(request.meetingID)
        }
        let recoveredDuration = duration(from: records)
        let recoveredMetadata = try recoveryService.ensureSessionMetadataForRecoveredImport(
            meetingID: request.meetingID,
            duration: recoveredDuration
        )
        let recoveredBookmarks = recoveredMetadata.bookmarks.sorted(by: bookmarkSort)

        let searchMeeting = SearchMeeting(
            id: request.meetingID,
            title: report.title,
            startedAt: report.createdAt,
            sourceApp: request.sourceName
        )
        let transcription = try await transcriptionService.transcribe(
            meeting: searchMeeting,
            records: records,
            context: MeetingContext(localeIdentifier: request.localeIdentifier),
            speakerRenames: [:],
            indexSearch: true,
            previewEvidence: recoveredMetadata.previewEvidence
        )
        let intelligence = try await intelligenceService.generateSummary(meetingID: request.meetingID)
        let generatedTitle = try MeetingGeneratedTitleService.title(
            from: intelligence.summary,
            transcript: transcription.transcript
        )
        let promotedSearchMeeting = SearchMeeting(
            id: searchMeeting.id,
            title: generatedTitle,
            startedAt: searchMeeting.startedAt,
            sourceApp: searchMeeting.sourceApp
        )
        let record = MeetingRecord(
            id: request.meetingID,
            title: generatedTitle,
            startedAt: report.createdAt,
            durationSeconds: recoveredDuration,
            sourceName: request.sourceName,
            state: .recovered,
            consentStatus: request.consentStatus,
            summary: intelligence.summary
        )
        try repository.save(
            MeetingLibraryEntry(
                record: record,
                searchMeeting: promotedSearchMeeting,
                transcript: transcription.transcript,
                editHistory: TranscriptEditHistory(meetingID: request.meetingID)
            )
        )

        return RecoveredRecordingImportResult(
            reportBeforeImport: report,
            record: record,
            searchMeeting: promotedSearchMeeting,
            transcription: transcription,
            intelligence: intelligence,
            audioChunks: records,
            bookmarks: recoveredBookmarks
        )
    }

    private func readAudioChunkRecords(meetingID: UUID) throws -> [AudioChunkRecord] {
        let checkpoints = try TrackKind.allCases.map {
            try chunkWriter.readCheckpoint(meetingID: meetingID, track: $0)
        }
        return checkpoints
            .flatMap(\.chunks)
            .sorted(by: sortRecords)
    }

    private func sortRecords(_ lhs: AudioChunkRecord, _ rhs: AudioChunkRecord) -> Bool {
        if lhs.startTime == rhs.startTime {
            if lhs.track == rhs.track {
                return lhs.chunkIndex < rhs.chunkIndex
            }
            return trackRank(lhs.track) < trackRank(rhs.track)
        }
        return lhs.startTime < rhs.startTime
    }

    private func bookmarkSort(_ lhs: MeetingBookmark, _ rhs: MeetingBookmark) -> Bool {
        if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private func duration(from records: [AudioChunkRecord]) -> TimeInterval {
        records.map { $0.startTime + $0.duration }.max() ?? 0
    }

    private func trackRank(_ track: TrackKind) -> Int {
        switch track {
        case .remoteSystem: 0
        case .microphone: 1
        case .mixedPlayback: 2
        }
    }
}
