import Foundation

public protocol FinalTranscriptionServicing: Sendable {
    func transcribe(
        meeting: SearchMeeting,
        records: [AudioChunkRecord],
        context: MeetingContext,
        speakerRenames: [String: String],
        indexSearch: Bool,
        previewEvidence: TranscriptPreviewEvidence
    ) async throws -> FinalTranscriptionResult
}

public extension FinalTranscriptionServicing {
    func transcribe(
        meeting: SearchMeeting,
        records: [AudioChunkRecord],
        context: MeetingContext,
        speakerRenames: [String: String],
        indexSearch: Bool
    ) async throws -> FinalTranscriptionResult {
        try await transcribe(
            meeting: meeting,
            records: records,
            context: context,
            speakerRenames: speakerRenames,
            indexSearch: indexSearch,
            previewEvidence: .empty
        )
    }
}

public enum FinalTranscriptionError: Error, Equatable {
    case noAudioChunks
}

public struct FinalTranscriptionService: FinalTranscriptionServicing, @unchecked Sendable {
    private let engine: any TranscriptionEngine
    private let bundleStore: EncryptedMeetingBundleStore
    private let chunkWriter: EncryptedAudioChunkWriter
    private let searchIndex: SQLiteSearchIndex
    private let now: @Sendable () -> Date

    public init(
        engine: any TranscriptionEngine,
        bundleStore: EncryptedMeetingBundleStore,
        chunkWriter: EncryptedAudioChunkWriter,
        searchIndex: SQLiteSearchIndex,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.engine = engine
        self.bundleStore = bundleStore
        self.chunkWriter = chunkWriter
        self.searchIndex = searchIndex
        self.now = now
    }

    public func transcribe(
        meeting: SearchMeeting,
        records: [AudioChunkRecord],
        localeIdentifier: String?,
        expectedRemoteSpeakerCount: Int? = nil,
        indexSearch: Bool = true
    ) async throws -> FinalTranscriptionResult {
        guard !records.isEmpty else {
            throw FinalTranscriptionError.noAudioChunks
        }

        var segments: [TranscriptSegment] = []
        for batch in transcriptionBatches(records) {
            let audioChunks = try batch.records.map {
                try chunkWriter.readChunk($0, meetingID: meeting.id)
            }
            let audioData = batch.records.count == 1
                ? audioChunks[0]
                : try LinearPCMAudioChunkAccumulator.mergeWAVChunks(audioChunks)
            let firstRecord = batch.records[0]
            let request = TranscriptionRequest(
                meetingID: meeting.id,
                audioChunkPath: batch.audioChunkPath,
                audioData: audioData,
                audioCodec: firstRecord.codec,
                trackKind: firstRecord.track,
                startTime: firstRecord.startTime,
                duration: batch.duration,
                localeIdentifier: localeIdentifier,
                expectedRemoteSpeakerCount: expectedRemoteSpeakerCount
            )
            segments.append(contentsOf: try await engine.transcribe(request))
        }
        segments.sort {
            if $0.startTime == $1.startTime {
                return trackRank($0.trackKind) < trackRank($1.trackKind)
            }
            return $0.startTime < $1.startTime
        }

        return try persistTranscript(
            meeting: meeting,
            segments: segments,
            localeIdentifier: localeIdentifier,
            indexSearch: indexSearch
        )
    }

    public func transcribe(
        meeting: SearchMeeting,
        records: [AudioChunkRecord],
        context: MeetingContext,
        speakerRenames _: [String: String] = [:],
        indexSearch: Bool = true,
        previewEvidence _: TranscriptPreviewEvidence = .empty
    ) async throws -> FinalTranscriptionResult {
        let validated = try context.validated()
        return try await transcribe(
            meeting: meeting,
            records: records,
            localeIdentifier: validated.localeIdentifier,
            expectedRemoteSpeakerCount: validated.expectedParticipantCount.map { max(1, $0 - 1) },
            indexSearch: indexSearch
        )
    }

    public func persistTranscript(
        meeting: SearchMeeting,
        segments: [TranscriptSegment],
        localeIdentifier: String?,
        indexSearch: Bool = true
    ) throws -> FinalTranscriptionResult {
        let transcript = MeetingTranscript(
            meetingID: meeting.id,
            localeIdentifier: localeIdentifier,
            generatedAt: now(),
            segments: segments
        )
        try bundleStore.writeJSONArtifact(
            transcript,
            meetingID: meeting.id,
            relativePath: MeetingTranscript.finalTranscriptRelativePath,
            purpose: MeetingTranscript.finalTranscriptPurpose
        )
        let reviewEvidence = transcript.segments.compactMap(\.reviewEvidence)
        let reviewQueue = try TranscriptConfidenceReviewService(now: now).deriveQueue(
            transcript: transcript,
            evidence: reviewEvidence,
            transcriptVersion: transcript.transcriptVersion
        )
        try TranscriptReviewRepository(bundleStore: bundleStore).save(reviewQueue)

        let searchableSegments = transcript.segments.map { segment in
            SearchTranscriptSegment(
                id: segment.id,
                meetingID: meeting.id,
                speakerName: segment.speakerName,
                startTime: segment.startTime,
                endTime: segment.endTime,
                text: segment.text,
                confidence: segment.confidence,
                isFinal: segment.isFinal
            )
        }
        if indexSearch {
            try searchIndex.upsertMeeting(meeting)
            try searchIndex.upsertSegments(searchableSegments)
        }

        return FinalTranscriptionResult(
            transcript: transcript,
            indexedSegmentCount: searchableSegments.count
        )
    }

    private func transcriptionBatches(_ records: [AudioChunkRecord]) -> [TranscriptionBatch] {
        let sorted = records.sorted {
            if $0.track == $1.track {
                if $0.startTime == $1.startTime {
                    return $0.chunkIndex < $1.chunkIndex
                }
                return $0.startTime < $1.startTime
            }
            return trackRank($0.track) < trackRank($1.track)
        }
        var batches: [TranscriptionBatch] = []
        var current: [AudioChunkRecord] = []

        func canAppend(_ record: AudioChunkRecord) -> Bool {
            guard let previous = current.last,
                  previous.track == record.track,
                  Self.isWAV(previous.codec),
                  Self.isWAV(record.codec)
            else { return false }
            let gap = abs(record.startTime - (previous.startTime + previous.duration))
            let duration = record.startTime + record.duration - (current.first?.startTime ?? record.startTime)
            return gap <= 0.05 && duration <= Self.maximumTranscriptionBatchDuration
        }

        for record in sorted {
            if current.isEmpty || canAppend(record) {
                current.append(record)
                continue
            }
            batches.append(TranscriptionBatch(records: current))
            current = [record]
        }
        if !current.isEmpty {
            batches.append(TranscriptionBatch(records: current))
        }
        return batches
    }

    private static let maximumTranscriptionBatchDuration: TimeInterval = 45

    private static func isWAV(_ codec: String) -> Bool {
        codec.localizedCaseInsensitiveContains("wav")
    }

    private func trackRank(_ track: TrackKind) -> Int {
        switch track {
        case .remoteSystem: 0
        case .microphone: 1
        case .mixedPlayback: 2
        }
    }
}

private struct TranscriptionBatch {
    var records: [AudioChunkRecord]

    var audioChunkPath: String {
        guard records.count > 1 else { return records[0].relativePath }
        return "\(records[0].relativePath)+\(records.count)-chunk-batch"
    }

    var duration: TimeInterval {
        guard let first = records.first, let last = records.last else { return 0 }
        return max(0, last.startTime + last.duration - first.startTime)
    }
}

public final class MockTranscriptionEngine: TranscriptionEngine, @unchecked Sendable {
    public let id: String
    public let supportsRealtime: Bool
    private let responsesByAudioChunkPath: [String: [TranscriptSegment]]
    private let lock = NSLock()
    private var _requests: [TranscriptionRequest] = []

    public var requests: [TranscriptionRequest] {
        lock.lock()
        defer { lock.unlock() }
        return _requests
    }

    public init(
        id: String = "mock-transcription",
        supportsRealtime: Bool = true,
        responsesByAudioChunkPath: [String: [TranscriptSegment]]
    ) {
        self.id = id
        self.supportsRealtime = supportsRealtime
        self.responsesByAudioChunkPath = responsesByAudioChunkPath
    }

    public func transcribe(_ request: TranscriptionRequest) async throws -> [TranscriptSegment] {
        appendRequest(request)
        return responsesByAudioChunkPath[request.audioChunkPath] ?? []
    }

    private func appendRequest(_ request: TranscriptionRequest) {
        lock.lock()
        defer { lock.unlock() }
        _requests.append(request)
    }
}
