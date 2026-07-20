import Foundation

public struct RecordingProcessingRequest: Equatable, Sendable {
    public var meetingID: UUID
    public var title: String
    public var startedAt: Date
    public var sourceID: String
    public var sourceName: String
    public var includeMicrophone: Bool
    public var microphoneDeviceID: String?
    public var microphoneDeviceName: String?
    public var context: MeetingContext
    public private(set) var sessionMetadataPath: String
    public var consentStatus: ConsentStatus

    public var localeIdentifier: String? {
        get { context.localeIdentifier }
        set { context.localeIdentifier = newValue }
    }

    public init(
        meetingID: UUID,
        title: String,
        startedAt: Date,
        sourceID: String,
        sourceName: String,
        includeMicrophone: Bool,
        microphoneDeviceID: String? = nil,
        microphoneDeviceName: String? = nil,
        localeIdentifier: String? = nil,
        context: MeetingContext? = nil,
        consentStatus: ConsentStatus
    ) {
        self.meetingID = meetingID
        self.title = title
        self.startedAt = startedAt
        self.sourceID = sourceID
        self.sourceName = sourceName
        self.includeMicrophone = includeMicrophone
        self.microphoneDeviceID = microphoneDeviceID
        self.microphoneDeviceName = microphoneDeviceName
        self.context = context ?? MeetingContext(localeIdentifier: localeIdentifier)
        self.sessionMetadataPath = RecordingSessionMetadata.relativePath
        self.consentStatus = consentStatus
    }
}

public struct RecordingProcessingResult: Equatable, Sendable {
    public var record: MeetingRecord
    public var searchMeeting: SearchMeeting
    public var capture: CaptureRecordingResult
    public var transcription: FinalTranscriptionResult
    public var intelligence: MeetingIntelligenceArtifact
    public var bookmarks: [MeetingBookmark]

    public init(
        record: MeetingRecord,
        searchMeeting: SearchMeeting,
        capture: CaptureRecordingResult,
        transcription: FinalTranscriptionResult,
        intelligence: MeetingIntelligenceArtifact,
        bookmarks: [MeetingBookmark] = []
    ) {
        self.record = record
        self.searchMeeting = searchMeeting
        self.capture = capture
        self.transcription = transcription
        self.intelligence = intelligence
        self.bookmarks = bookmarks
    }
}

public final class ActiveRecordingProcessingSession: @unchecked Sendable {
    public let request: RecordingProcessingRequest
    fileprivate let captureTask: Task<CaptureRecordingResult, Error>
    fileprivate let stopSignal: CaptureRecordingStopSignal

    fileprivate init(
        request: RecordingProcessingRequest,
        captureTask: Task<CaptureRecordingResult, Error>,
        stopSignal: CaptureRecordingStopSignal
    ) {
        self.request = request
        self.captureTask = captureTask
        self.stopSignal = stopSignal
    }

    public func requestStop() {
        stopSignal.requestStop()
    }

    public func waitForCaptureCompletion() async throws {
        _ = try await captureTask.value
    }

    public func cancel() {
        stopSignal.requestStop()
        captureTask.cancel()
    }
}

public enum RecordingProcessingStage: String, Codable, CaseIterable, Sendable {
    case preparingBundle
    case recordingAudio
    case transcribingAudio
    case generatingIntelligence
    case savingLibrary
    case finished
}

public struct RecordingProcessingProgress: Equatable, Sendable {
    public var stage: RecordingProcessingStage
    public var fractionCompleted: Double
    public var message: String

    public init(
        stage: RecordingProcessingStage,
        fractionCompleted: Double,
        message: String
    ) {
        self.stage = stage
        self.fractionCompleted = min(max(fractionCompleted, 0), 1)
        self.message = message
    }
}

public enum RecordingProcessingError: Error, Equatable {
    case cancelled(stage: RecordingProcessingStage)
    case failed(stage: RecordingProcessingStage, message: String)
}

public enum RecordingPreparationError: Error, Equatable, Sendable {
    case metadataPreparationAndRollbackFailed(cause: RecordingSessionMetadataServiceError)
    case unexpectedPreparationAndRollbackFailed
    case completionAndRollbackFailed
}

extension RecordingPreparationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .metadataPreparationAndRollbackFailed(cause):
            switch cause {
            case .invalidMetadata:
                "Meeting context preparation failed, and the incomplete recording bundle could not be removed."
            case .invalidBookmark,
                 .sessionNotActive,
                 .meetingMismatch,
                 .bookmarkNotFound,
                 .bookmarkOutsideRecording,
                 .metadataUnreadable,
                 .encryptedWriteFailed,
                 .revisionOverflow:
                "Encrypted recording metadata could not be saved, and the incomplete recording bundle could not be removed."
            }
        case .unexpectedPreparationAndRollbackFailed:
            "Recording preparation failed, and the incomplete recording bundle could not be removed."
        case .completionAndRollbackFailed:
            "Recording preparation could not be completed, and the incomplete recording bundle could not be removed."
        }
    }
}

extension RecordingProcessingError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .cancelled(stage):
            return "\(stage.rawValue) was cancelled."
        case let .failed(stage, message):
            return "\(stage.rawValue) failed: \(message)"
        }
    }
}

public struct RecordingProcessingService: @unchecked Sendable {
    private static let activeRecordingMaximumDuration: TimeInterval = 60 * 60 * 3

    private let captureService: CaptureRecordingService
    private let transcriptionService: any FinalTranscriptionServicing
    private let intelligenceService: MeetingIntelligenceService
    private let repository: MeetingLibraryRepository
    private let bundleStore: EncryptedMeetingBundleStore
    private let chunkWriter: EncryptedAudioChunkWriter?
    private let sessionMetadataService: any RecordingSessionMetadataCreating
    private let sessionMetadataManager: (any RecordingSessionMetadataManaging)?
    private let rollbackBundle: @Sendable (UUID) throws -> Void

    public init(
        captureService: CaptureRecordingService,
        transcriptionService: any FinalTranscriptionServicing,
        intelligenceService: MeetingIntelligenceService,
        repository: MeetingLibraryRepository,
        bundleStore: EncryptedMeetingBundleStore,
        chunkWriter: EncryptedAudioChunkWriter? = nil,
        sessionMetadataService: (any RecordingSessionMetadataCreating)? = nil,
        rollbackBundle: (@Sendable (UUID) throws -> Void)? = nil
    ) {
        self.captureService = captureService
        self.transcriptionService = transcriptionService
        self.intelligenceService = intelligenceService
        self.repository = repository
        self.bundleStore = bundleStore
        self.chunkWriter = chunkWriter
        self.sessionMetadataService = sessionMetadataService
            ?? RecordingSessionMetadataService(bundleStore: bundleStore)
        self.sessionMetadataManager = self.sessionMetadataService as? any RecordingSessionMetadataManaging
        self.rollbackBundle = rollbackBundle ?? { meetingID in
            try bundleStore.deleteBundle(meetingID: meetingID)
        }
    }

    public func process(
        _ request: RecordingProcessingRequest,
        progress: @escaping @Sendable (RecordingProcessingProgress) -> Void = { _ in },
        shouldCancel: @escaping @Sendable () -> Bool = { false }
    ) async throws -> RecordingProcessingResult {
        try report(
            .preparingBundle,
            fractionCompleted: 0.05,
            message: "Preparing encrypted meeting bundle",
            progress: progress,
            shouldCancel: shouldCancel
        )
        let preparedRequest = try await prepareBundleAndMetadata(for: request)

        try report(
            .recordingAudio,
            fractionCompleted: 0.20,
            message: preparedRequest.microphoneDeviceName.map { "Writing encrypted audio chunks with \($0)" }
                ?? "Writing encrypted audio chunks",
            progress: progress,
            shouldCancel: shouldCancel
        )
        let capture = try await runStage(.recordingAudio) {
            try await captureAudio(for: preparedRequest)
        }
        return try await finishCapturedRecording(
            preparedRequest,
            capture: capture,
            progress: progress,
            shouldCancel: shouldCancel
        )
    }

    public func beginRecording(
        _ request: RecordingProcessingRequest,
        frameConsumers: [any CaptureFrameConsumer] = [],
        previewDropHandler: (@Sendable (Int) -> Void)? = nil
    ) async throws -> ActiveRecordingProcessingSession {
        let preparedRequest = try await prepareBundleAndMetadata(for: request)

        let stopSignal = CaptureRecordingStopSignal()
        let captureTask = Task {
            try await captureAudio(
                for: preparedRequest,
                stopSignal: stopSignal,
                frameConsumers: frameConsumers,
                previewDropHandler: previewDropHandler
            )
        }
        return ActiveRecordingProcessingSession(
            request: preparedRequest,
            captureTask: captureTask,
            stopSignal: stopSignal
        )
    }

    private func prepareBundleAndMetadata(
        for request: RecordingProcessingRequest
    ) async throws -> RecordingProcessingRequest {
        var preparedRequest = request
        do {
            preparedRequest.context = try request.context.validated()
        } catch {
            throw RecordingSessionMetadataServiceError.invalidMetadata
        }

        var manifest = MeetingBundleManifest.initialEncryptedBundle(
            meetingID: preparedRequest.meetingID,
            title: preparedRequest.title
        )
        manifest.createdAt = preparedRequest.startedAt
        manifest.context = preparedRequest.context
        manifest.sessionMetadataPath = preparedRequest.sessionMetadataPath
        _ = try bundleStore.createPreparingBundle(manifest)

        do {
            _ = try await sessionMetadataService.create(
                meetingID: preparedRequest.meetingID,
                startedAt: preparedRequest.startedAt,
                context: preparedRequest.context
            )
        } catch let metadataError {
            do {
                try rollbackBundle(preparedRequest.meetingID)
            } catch {
                if let cause = metadataError as? RecordingSessionMetadataServiceError {
                    throw RecordingPreparationError.metadataPreparationAndRollbackFailed(cause: cause)
                }
                throw RecordingPreparationError.unexpectedPreparationAndRollbackFailed
            }
            throw metadataError
        }
        do {
            try bundleStore.markBundlePreparationComplete(meetingID: preparedRequest.meetingID)
        } catch {
            do {
                try rollbackBundle(preparedRequest.meetingID)
            } catch {
                throw RecordingPreparationError.completionAndRollbackFailed
            }
            throw error
        }
        return preparedRequest
    }

    public func finishRecording(
        _ session: ActiveRecordingProcessingSession,
        // Intentionally ignored: live preview segments must never replace the
        // final audio transcription (fail-closed contract, see RecordingProcessingTests).
        liveTranscriptSegments _: [TranscriptSegment] = [],
        progress: @escaping @Sendable (RecordingProcessingProgress) -> Void = { _ in },
        shouldCancel: @escaping @Sendable () -> Bool = { false }
    ) async throws -> RecordingProcessingResult {
        try report(
            .recordingAudio,
            fractionCompleted: 0.20,
            message: session.request.microphoneDeviceName.map { "Finalizing encrypted audio chunks with \($0)" }
                ?? "Finalizing encrypted audio chunks",
            progress: progress,
            shouldCancel: shouldCancel
        )
        session.requestStop()
        let capture = try await runStage(.recordingAudio) {
            try await captureResultAfterStop(for: session)
        }
        return try await finishCapturedRecording(
            session.request,
            capture: capture,
            progress: progress,
            shouldCancel: shouldCancel
        )
    }

    private func finishCapturedRecording(
        _ request: RecordingProcessingRequest,
        capture: CaptureRecordingResult,
        progress: @escaping @Sendable (RecordingProcessingProgress) -> Void,
        shouldCancel: @escaping @Sendable () -> Bool
    ) async throws -> RecordingProcessingResult {
        let recordingDuration = duration(from: capture.records)
        var finalizedBookmarks: [MeetingBookmark] = []
        var previewEvidence = TranscriptPreviewEvidence.empty
        if let sessionMetadataManager {
            let metadata = try await sessionMetadataManager.finalize(
                meetingID: request.meetingID,
                duration: recordingDuration
            )
            try promoteSessionMetadata(metadata, meetingID: request.meetingID)
            finalizedBookmarks = metadata.bookmarks
            previewEvidence = metadata.previewEvidence
        }
        let provisionalSearchMeeting = SearchMeeting(
            id: request.meetingID,
            title: request.title,
            startedAt: request.startedAt,
            sourceApp: request.sourceName
        )
        try report(
            .transcribingAudio,
            fractionCompleted: 0.45,
            message: "Transcribing captured audio",
            progress: progress,
            shouldCancel: shouldCancel
        )
        let transcription = try await runStage(.transcribingAudio) {
            try await transcriptionService.transcribe(
                meeting: provisionalSearchMeeting,
                records: capture.records,
                context: request.context,
                speakerRenames: [:],
                indexSearch: false,
                previewEvidence: previewEvidence
            )
        }
        try report(
            .generatingIntelligence,
            fractionCompleted: 0.70,
            message: "Generating grounded meeting intelligence",
            progress: progress,
            shouldCancel: shouldCancel
        )
        let intelligence = try await runStage(.generatingIntelligence) {
            try await intelligenceService.generateSummary(meetingID: request.meetingID)
        }
        let generatedTitle = try Self.generatedTitle(
            from: intelligence.summary,
            transcript: transcription.transcript
        )
        let searchMeeting = SearchMeeting(
            id: request.meetingID,
            title: generatedTitle,
            startedAt: request.startedAt,
            sourceApp: request.sourceName
        )
        let record = MeetingRecord(
            id: request.meetingID,
            title: generatedTitle,
            startedAt: request.startedAt,
            durationSeconds: recordingDuration,
            sourceName: request.sourceName,
            state: .ready,
            consentStatus: request.consentStatus,
            summary: intelligence.summary
        )
        try report(
            .savingLibrary,
            fractionCompleted: 0.90,
            message: "Saving meeting to local library",
            progress: progress,
            shouldCancel: shouldCancel
        )
        try await runStage(.savingLibrary) {
            try updateManifestTitle(meetingID: request.meetingID, title: generatedTitle)
            try repository.save(
                MeetingLibraryEntry(
                    record: record,
                    searchMeeting: searchMeeting,
                    transcript: transcription.transcript,
                    editHistory: TranscriptEditHistory(meetingID: request.meetingID)
                )
            )
        }

        try report(
            .finished,
            fractionCompleted: 1,
            message: "Processing complete",
            progress: progress,
            shouldCancel: shouldCancel
        )
        return RecordingProcessingResult(
            record: record,
            searchMeeting: searchMeeting,
            capture: capture,
            transcription: transcription,
            intelligence: intelligence,
            bookmarks: finalizedBookmarks
        )
    }

    private func captureAudio(
        for request: RecordingProcessingRequest,
        stopSignal: CaptureRecordingStopSignal? = nil,
        frameConsumers: [any CaptureFrameConsumer] = [],
        previewDropHandler: (@Sendable (Int) -> Void)? = nil
    ) async throws -> CaptureRecordingResult {
        try await captureService.record(
            CaptureRecordingRequest(
                meetingID: request.meetingID,
                sourceID: request.sourceID,
                includeMicrophone: request.includeMicrophone,
                microphoneDeviceID: request.microphoneDeviceID,
                microphoneDeviceName: request.microphoneDeviceName,
                maximumDuration: stopSignal == nil ? 30 : Self.activeRecordingMaximumDuration,
                stopSignal: stopSignal,
                frameConsumers: frameConsumers,
                previewDropHandler: previewDropHandler
            )
        )
    }

    private func captureResultAfterStop(
        for session: ActiveRecordingProcessingSession
    ) async throws -> CaptureRecordingResult {
        do {
            return try await session.captureTask.value
        } catch let error as CaptureRecordingError {
            guard case .interrupted = error,
                  let recoveredCapture = try recoverCaptureFromCheckpoints(for: session.request)
            else {
                throw error
            }
            return recoveredCapture
        }
    }

    private func recoverCaptureFromCheckpoints(
        for request: RecordingProcessingRequest
    ) throws -> CaptureRecordingResult? {
        guard let chunkWriter else { return nil }
        let records = try TrackKind.allCases
            .flatMap { track in
                try chunkWriter.readCheckpoint(meetingID: request.meetingID, track: track).chunks
            }
            .sorted(by: sortRecords)
        guard !records.isEmpty else { return nil }
        let remoteDropouts = records.contains { $0.track == .remoteSystem } ? 1 : 0
        let microphoneDropouts = records.contains { $0.track == .microphone } ? 1 : 0
        return CaptureRecordingResult(
            records: records,
            healthReport: CaptureHealthReport(
                remoteDropouts: remoteDropouts,
                microphoneDropouts: microphoneDropouts,
                remoteClippingPercent: 0,
                microphoneClippingPercent: 0,
                silentPeriods: [],
                deviceChanges: [],
                transcriptionEngine: "pending",
                intelligenceProvider: "pending"
            ),
            microphoneDeviceID: request.includeMicrophone ? request.microphoneDeviceID : nil,
            microphoneDeviceName: request.includeMicrophone ? request.microphoneDeviceName : nil
        )
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

    private func trackRank(_ track: TrackKind) -> Int {
        switch track {
        case .remoteSystem: 0
        case .microphone: 1
        case .mixedPlayback: 2
        }
    }

    private func duration(from records: [AudioChunkRecord]) -> TimeInterval {
        records
            .map { $0.startTime + $0.duration }
            .max() ?? 0
    }

    private func updateManifestTitle(meetingID: UUID, title: String) throws {
        var manifest = try bundleStore.readManifest(meetingID: meetingID)
        manifest.title = title
        try bundleStore.writeJSONArtifact(
            manifest,
            meetingID: meetingID,
            relativePath: "manifest.json.enc",
            purpose: "manifest"
        )
    }

    private func promoteSessionMetadata(
        _ metadata: RecordingSessionMetadata,
        meetingID: UUID
    ) throws {
        let metadata = try metadata.validated(expectedMeetingID: meetingID)
        var manifest = try bundleStore.readManifest(meetingID: meetingID)
        manifest.schemaVersion = 2
        manifest.context = metadata.context
        manifest.sessionMetadataPath = RecordingSessionMetadata.relativePath
        manifest.bookmarks = metadata.bookmarks
        try bundleStore.writeJSONArtifact(
            manifest,
            meetingID: meetingID,
            relativePath: "manifest.json.enc",
            purpose: "manifest"
        )
    }

    private static func generatedTitle(
        from summary: MeetingSummary,
        transcript: MeetingTranscript
    ) throws -> String {
        do {
            return try MeetingGeneratedTitleService.title(from: summary, transcript: transcript)
        } catch MeetingGeneratedTitleError.emptyTitle {
            throw RecordingProcessingError.failed(
                stage: .generatingIntelligence,
                message: "Meeting intelligence returned an empty generated title."
            )
        }
    }

    private func report(
        _ stage: RecordingProcessingStage,
        fractionCompleted: Double,
        message: String,
        progress: @escaping @Sendable (RecordingProcessingProgress) -> Void,
        shouldCancel: @escaping @Sendable () -> Bool
    ) throws {
        progress(
            RecordingProcessingProgress(
                stage: stage,
                fractionCompleted: fractionCompleted,
                message: message
            )
        )
        if shouldCancel() {
            throw RecordingProcessingError.cancelled(stage: stage)
        }
    }

    private func runStage<Value>(
        _ stage: RecordingProcessingStage,
        operation: () async throws -> Value
    ) async throws -> Value {
        do {
            return try await operation()
        } catch let error as RecordingProcessingError {
            throw error
        } catch {
            throw RecordingProcessingError.failed(
                stage: stage,
                message: Self.failureMessage(for: error)
            )
        }
    }

    private static func failureMessage(for error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription,
           !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return description
        }
        return String(describing: error)
    }
}
