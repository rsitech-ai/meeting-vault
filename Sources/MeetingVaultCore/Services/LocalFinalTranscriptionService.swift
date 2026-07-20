import CryptoKit
import Foundation

public struct DiarizationTurn: Codable, Equatable, Sendable {
    public var speakerID: String
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    public var confidence: Double

    public init(
        speakerID: String,
        startTime: TimeInterval,
        endTime: TimeInterval,
        confidence: Double
    ) {
        self.speakerID = speakerID
        self.startTime = startTime
        self.endTime = endTime
        self.confidence = confidence
    }
}

public enum DiarizationReconciliationError: Error, Equatable, LocalizedError, Sendable {
    case invalidTurn
    case invalidSpeakerCount
    case decryptedChunkTooLarge(actual: Int, maximum: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidTurn: "The local diarizer returned an invalid speaker interval."
        case .invalidSpeakerCount: "Expected speaker count must be between one and ten."
        case let .decryptedChunkTooLarge(actual, maximum):
            "A decrypted audio chunk is too large (\(actual) bytes; limit \(maximum))."
        }
    }
}

public struct DiarizationReconciler: Sendable {
    public init() {}

    public func reconcile(
        asrSegments: [TranscriptSegment],
        remoteTurns: [DiarizationTurn],
        expectedRemoteSpeakerCount: Int?,
        speakerRenames: [String: String] = [:]
    ) throws -> [TranscriptSegment] {
        let maximum = expectedRemoteSpeakerCount ?? 10
        guard (1...10).contains(maximum) else {
            throw DiarizationReconciliationError.invalidSpeakerCount
        }
        for turn in remoteTurns {
            guard !turn.speakerID.isEmpty,
                  turn.startTime.isFinite, turn.endTime.isFinite,
                  turn.startTime >= 0, turn.endTime > turn.startTime,
                  turn.confidence.isFinite, (0...1).contains(turn.confidence) else {
                throw DiarizationReconciliationError.invalidTurn
            }
        }

        var speakerMap: [String: String] = [:]
        var nextSpeaker = 1
        func name(for raw: String) -> String {
            if let existing = speakerMap[raw] { return speakerRenames[existing] ?? existing }
            let number = min(nextSpeaker, maximum)
            let anonymous = "Speaker \(number)"
            speakerMap[raw] = anonymous
            if nextSpeaker < maximum { nextSpeaker += 1 }
            return speakerRenames[anonymous] ?? anonymous
        }

        var result: [TranscriptSegment] = []
        for input in asrSegments {
            if input.trackKind == .microphone {
                var segment = input
                segment.speakerName = "You"
                segment.isFinal = true
                result.append(segment)
                continue
            }
            guard input.trackKind == .remoteSystem else {
                result.append(input)
                continue
            }
            let overlaps = remoteTurns.filter {
                min(input.endTime, $0.endTime) > max(input.startTime, $0.startTime)
            }
            guard overlaps.count == 1, let turn = overlaps.first else {
                var segment = input
                // Chunk-level ASR has no word timing with which to assign one
                // sentence across zero or multiple diarization identities. Keep
                // the text exactly once and state the uncertainty honestly.
                segment.speakerName = "Multiple speakers"
                segment.isFinal = true
                result.append(segment)
                continue
            }
            var segment = input
            segment.speakerName = name(for: turn.speakerID)
            segment.confidence = min(input.confidence, turn.confidence)
            segment.isFinal = true
            result.append(segment)
        }
        return result.sorted {
            if $0.startTime == $1.startTime {
                if $0.endTime == $1.endTime { return $0.id.uuidString < $1.id.uuidString }
                return $0.endTime < $1.endTime
            }
            return $0.startTime < $1.startTime
        }
    }

}

public struct LocalFinalChunkRequest: Sendable {
    public var meetingID: UUID
    public var track: TrackKind
    public var startTime: TimeInterval
    public var duration: TimeInterval
    public var sampleData: Data
    public var codec: String
    public var localeIdentifier: String?

    public init(
        meetingID: UUID,
        track: TrackKind,
        startTime: TimeInterval,
        duration: TimeInterval,
        sampleData: Data,
        codec: String,
        localeIdentifier: String?
    ) {
        self.meetingID = meetingID
        self.track = track
        self.startTime = startTime
        self.duration = duration
        self.sampleData = sampleData
        self.codec = codec
        self.localeIdentifier = localeIdentifier
    }
}

public protocol LocalFinalTranscriptionEngine: Sendable {
    func transcribeChunk(_ request: LocalFinalChunkRequest) async throws -> [TranscriptSegment]
    func diarizeRemoteChunk(_ request: LocalFinalChunkRequest) async throws -> [DiarizationTurn]
}

public protocol LocalFinalProviderConfigurationProviding: Sendable {
    func providerConfigurationVersion(for context: MeetingContext) throws -> String
}

public protocol LocalFinalPassCompletion: Sendable {
    func close() async throws
    func cancel() async
}

public struct LocalFinalPassOutput: Sendable {
    public var asrSegments: [TranscriptSegment]
    public var remoteTurns: [DiarizationTurn]
    public var completion: any LocalFinalPassCompletion

    public init(
        asrSegments: [TranscriptSegment],
        remoteTurns: [DiarizationTurn],
        completion: any LocalFinalPassCompletion
    ) {
        self.asrSegments = asrSegments
        self.remoteTurns = remoteTurns
        self.completion = completion
    }
}

public protocol LocalFinalPassTranscriptionEngine: LocalFinalTranscriptionEngine {
    func transcribePass(
        meeting: SearchMeeting,
        records: [AudioChunkRecord],
        context: MeetingContext,
        decryptedChunkReader: any LocalDecryptedAudioChunkReading,
        maximumDecryptedChunkBytes: Int
    ) async throws -> LocalFinalPassOutput
}

public protocol LocalDecryptedAudioChunkReading: Sendable {
    func withDecryptedChunk<T: Sendable>(
        _ record: AudioChunkRecord,
        _ body: @Sendable (Data) async throws -> T
    ) async throws -> T
}

public struct EncryptedAudioChunkReader: LocalDecryptedAudioChunkReading, @unchecked Sendable {
    private let writer: EncryptedAudioChunkWriter
    private let meetingID: UUID

    public init(writer: EncryptedAudioChunkWriter, meetingID: UUID) {
        self.writer = writer
        self.meetingID = meetingID
    }

    public func withDecryptedChunk<T: Sendable>(
        _ record: AudioChunkRecord,
        _ body: @Sendable (Data) async throws -> T
    ) async throws -> T {
        // Each encrypted checkpoint is independently opened and released. No
        // plaintext URL or temporary file is created.
        let data = try writer.readChunk(record, meetingID: meetingID)
        return try await body(data)
    }
}

public struct TranscriptReindexPendingMarker: Codable, Equatable, Sendable {
    public static let relativePath = "transcript/reindex-pending.json.enc"
    public static let purpose = "transcript:reindex-pending"
    public static let schemaVersion = 1

    public var schemaVersion: Int
    public var meetingID: UUID
    public var transcriptDigest: String
    public var targetIndexGeneration: Int
    public var phase: TranscriptReindexPendingPhase

    public init(
        meetingID: UUID,
        transcriptDigest: String,
        targetIndexGeneration: Int = 1,
        phase: TranscriptReindexPendingPhase = .indexingFinalProjection
    ) {
        self.schemaVersion = Self.schemaVersion
        self.meetingID = meetingID
        self.transcriptDigest = transcriptDigest
        self.targetIndexGeneration = targetIndexGeneration
        self.phase = phase
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, meetingID, transcriptDigest, targetIndexGeneration, phase
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        meetingID = try container.decode(UUID.self, forKey: .meetingID)
        transcriptDigest = try container.decode(String.self, forKey: .transcriptDigest)
        targetIndexGeneration = try container.decode(Int.self, forKey: .targetIndexGeneration)
        phase = try container.decodeIfPresent(TranscriptReindexPendingPhase.self, forKey: .phase)
            ?? .indexingFinalProjection
    }
}

public enum TranscriptReindexPendingPhase: String, Codable, Equatable, Sendable {
    case indexingFinalProjection
    case awaitingAuthoritativeLibraryCommit
}

public enum TranscriptReindexPreservationReason: Equatable, Sendable {
    case authoritativeLibraryCommitMissing
    case transcriptDigestMismatch
}

public enum TranscriptReindexRecoveryResult: Equatable, Sendable {
    case noMarker
    case rebuilt(digestMatchedMarker: Bool)
    case preserved(TranscriptReindexPreservationReason)
}

public struct TranscriptReindexRecoveryService: Sendable {
    private let bundleStore: EncryptedMeetingBundleStore
    private let searchIndex: SQLiteSearchIndex

    public init(bundleStore: EncryptedMeetingBundleStore, searchIndex: SQLiteSearchIndex) {
        self.bundleStore = bundleStore
        self.searchIndex = searchIndex
    }

    public func recover(meeting: SearchMeeting) throws -> TranscriptReindexRecoveryResult {
        guard try bundleStore.artifactExists(
            meetingID: meeting.id,
            relativePath: TranscriptReindexPendingMarker.relativePath
        ) else { return .noMarker }
        let marker: TranscriptReindexPendingMarker = try bundleStore.readJSONArtifact(
            TranscriptReindexPendingMarker.self,
            meetingID: meeting.id,
            relativePath: TranscriptReindexPendingMarker.relativePath,
            purpose: TranscriptReindexPendingMarker.purpose
        )
        guard marker.schemaVersion == TranscriptReindexPendingMarker.schemaVersion,
              marker.meetingID == meeting.id else {
            throw MeetingBundleStoreError.manifestMeetingMismatch
        }
        guard try hasAuthoritativeLibraryCommit(meetingID: meeting.id) else {
            return .preserved(.authoritativeLibraryCommitMissing)
        }
        let authoritativeMeeting: SearchMeeting = try bundleStore.readJSONArtifact(
            SearchMeeting.self,
            meetingID: meeting.id,
            relativePath: MeetingLibraryRepository.searchMeetingRelativePath,
            purpose: MeetingLibraryRepository.searchMeetingPurpose
        )
        guard authoritativeMeeting.id == meeting.id else {
            throw MeetingBundleStoreError.manifestMeetingMismatch
        }
        let transcript: MeetingTranscript = try bundleStore.readJSONArtifact(
            MeetingTranscript.self,
            meetingID: meeting.id,
            relativePath: MeetingTranscript.finalTranscriptRelativePath,
            purpose: MeetingTranscript.finalTranscriptPurpose
        )
        let digest = try LocalFinalTranscriptionService.transcriptDigest(transcript)
        guard digest == marker.transcriptDigest else {
            return .preserved(.transcriptDigestMismatch)
        }
        try searchIndex.replaceMeetingAndSegments(
            meeting: authoritativeMeeting,
            segments: LocalFinalTranscriptionService.searchSegments(transcript)
        )
        try bundleStore.deleteArtifact(
            meetingID: meeting.id,
            relativePath: TranscriptReindexPendingMarker.relativePath
        )
        return .rebuilt(digestMatchedMarker: true)
    }

    public func clearAfterAuthoritativeCommit(
        meeting: SearchMeeting,
        transcript: MeetingTranscript
    ) throws -> TranscriptReindexRecoveryResult {
        guard try bundleStore.artifactExists(
            meetingID: meeting.id,
            relativePath: TranscriptReindexPendingMarker.relativePath
        ) else { return .noMarker }
        let marker: TranscriptReindexPendingMarker = try bundleStore.readJSONArtifact(
            TranscriptReindexPendingMarker.self,
            meetingID: meeting.id,
            relativePath: TranscriptReindexPendingMarker.relativePath,
            purpose: TranscriptReindexPendingMarker.purpose
        )
        guard marker.meetingID == meeting.id else { throw MeetingBundleStoreError.manifestMeetingMismatch }
        guard try hasAuthoritativeLibraryCommit(meetingID: meeting.id) else {
            return .preserved(.authoritativeLibraryCommitMissing)
        }
        guard try LocalFinalTranscriptionService.transcriptDigest(transcript) == marker.transcriptDigest else {
            return .preserved(.transcriptDigestMismatch)
        }
        try bundleStore.deleteArtifact(
            meetingID: meeting.id,
            relativePath: TranscriptReindexPendingMarker.relativePath
        )
        return .rebuilt(digestMatchedMarker: true)
    }

    private func hasAuthoritativeLibraryCommit(meetingID: UUID) throws -> Bool {
        try bundleStore.artifactExists(
            meetingID: meetingID,
            relativePath: MeetingLibraryRepository.recordRelativePath
        ) && bundleStore.artifactExists(
            meetingID: meetingID,
            relativePath: MeetingLibraryRepository.searchMeetingRelativePath
        )
    }
}

public struct LocalFinalTranscriptionService: FinalTranscriptionServicing, @unchecked Sendable {
    private let engine: any LocalFinalTranscriptionEngine
    private let bundleStore: EncryptedMeetingBundleStore
    private let searchIndex: SQLiteSearchIndex
    private let decryptedChunkReaderFactory: @Sendable (UUID) -> any LocalDecryptedAudioChunkReading
    private let maximumDecryptedChunkBytes: Int
    private let now: @Sendable () -> Date
    private let indexTransaction: @Sendable (SearchMeeting, [SearchTranscriptSegment]) throws -> Void

    public init(
        engine: any LocalFinalTranscriptionEngine,
        bundleStore: EncryptedMeetingBundleStore,
        searchIndex: SQLiteSearchIndex,
        decryptedChunkReader: any LocalDecryptedAudioChunkReading,
        maximumDecryptedChunkBytes: Int = 8 * 1_024 * 1_024,
        now: @escaping @Sendable () -> Date = Date.init,
        indexTransaction: (@Sendable (SearchMeeting, [SearchTranscriptSegment]) throws -> Void)? = nil
    ) {
        self.engine = engine
        self.bundleStore = bundleStore
        self.searchIndex = searchIndex
        self.decryptedChunkReaderFactory = { _ in decryptedChunkReader }
        self.maximumDecryptedChunkBytes = max(1, maximumDecryptedChunkBytes)
        self.now = now
        self.indexTransaction = indexTransaction ?? { meeting, segments in
            try searchIndex.replaceMeetingAndSegments(meeting: meeting, segments: segments)
        }
    }

    public init(
        engine: any LocalFinalTranscriptionEngine,
        bundleStore: EncryptedMeetingBundleStore,
        searchIndex: SQLiteSearchIndex,
        decryptedChunkReaderFactory: @escaping @Sendable (UUID) -> any LocalDecryptedAudioChunkReading,
        maximumDecryptedChunkBytes: Int = 8 * 1_024 * 1_024,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.engine = engine
        self.bundleStore = bundleStore
        self.searchIndex = searchIndex
        self.decryptedChunkReaderFactory = decryptedChunkReaderFactory
        self.maximumDecryptedChunkBytes = max(1, maximumDecryptedChunkBytes)
        self.now = now
        self.indexTransaction = { meeting, segments in
            try searchIndex.replaceMeetingAndSegments(meeting: meeting, segments: segments)
        }
    }

    public func transcribe(
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

    public func transcribe(
        meeting: SearchMeeting,
        records: [AudioChunkRecord],
        context: MeetingContext,
        speakerRenames: [String: String] = [:],
        indexSearch: Bool = true,
        previewEvidence: TranscriptPreviewEvidence = .empty
    ) async throws -> FinalTranscriptionResult {
        guard !records.isEmpty else { throw FinalTranscriptionError.noAudioChunks }
        let validatedContext = try context.validated()
        let providerConfigurationVersion = try (engine as? any LocalFinalProviderConfigurationProviding)?
            .providerConfigurationVersion(for: validatedContext)
            ?? "unidentified:\(String(reflecting: type(of: engine)))"
        let decryptedChunkReader = decryptedChunkReaderFactory(meeting.id)
        let engine = self.engine
        let maximumDecryptedChunkBytes = self.maximumDecryptedChunkBytes
        var asrSegments: [TranscriptSegment] = []
        var remoteTurns: [DiarizationTurn] = []
        var passCompletion: (any LocalFinalPassCompletion)?
        if let passEngine = engine as? any LocalFinalPassTranscriptionEngine {
            let output = try await passEngine.transcribePass(
                meeting: meeting,
                records: records.sorted(by: Self.recordOrder),
                context: validatedContext,
                decryptedChunkReader: decryptedChunkReader,
                maximumDecryptedChunkBytes: maximumDecryptedChunkBytes
            )
            asrSegments = output.asrSegments
            remoteTurns = output.remoteTurns
            passCompletion = output.completion
        } else {
            for record in records.sorted(by: Self.recordOrder) {
                let output = try await decryptedChunkReader.withDecryptedChunk(record) { data in
                    guard data.count <= maximumDecryptedChunkBytes else {
                        throw DiarizationReconciliationError.decryptedChunkTooLarge(
                            actual: data.count,
                            maximum: maximumDecryptedChunkBytes
                        )
                    }
                    let request = LocalFinalChunkRequest(
                        meetingID: meeting.id,
                        track: record.track,
                        startTime: record.startTime,
                        duration: record.duration,
                        sampleData: data,
                        codec: record.codec,
                        localeIdentifier: validatedContext.localeIdentifier
                    )
                    async let transcript = engine.transcribeChunk(request)
                    if record.track == .remoteSystem {
                        async let diarization = engine.diarizeRemoteChunk(request)
                        return try await (transcript, diarization)
                    }
                    return try await (transcript, [])
                }
                asrSegments.append(contentsOf: output.0)
                remoteTurns.append(contentsOf: output.1)
            }
        }
        do {
            let reconciled = try DiarizationReconciler().reconcile(
                asrSegments: asrSegments,
                remoteTurns: remoteTurns,
                expectedRemoteSpeakerCount: validatedContext.expectedParticipantCount.map { max(1, $0 - 1) },
                speakerRenames: speakerRenames
            )
            let evidenced = try reconciled.map { segment in
                var value = segment
                let matchingTurns = segment.trackKind == .remoteSystem
                    ? remoteTurns.filter { min(segment.endTime, $0.endTime) > max(segment.startTime, $0.startTime) }
                    : []
                let existing = asrSegments.first(where: { $0.id == segment.id })?.reviewEvidence
                value.reviewEvidence = try TranscriptSegmentEvidence(
                    segmentID: segment.id,
                    trackKind: segment.trackKind,
                    startTime: segment.startTime,
                    endTime: segment.endTime,
                    confidence: existing?.confidence ?? segment.confidence,
                    speakerConfidence: existing?.speakerConfidence
                        ?? (segment.trackKind == .remoteSystem ? (matchingTurns.count == 1 ? matchingTurns[0].confidence : 0) : nil),
                    overlapsSpeech: existing?.overlapsSpeech ?? (matchingTurns.count > 1),
                    reconstructedFromPreviewGap: existing?.reconstructedFromPreviewGap
                        ?? previewEvidence.gaps.contains {
                            $0.intersects(
                                track: segment.trackKind,
                                startTime: segment.startTime,
                                endTime: segment.endTime
                            )
                        },
                    speakerWasRevised: existing?.speakerWasRevised
                        ?? Self.previewSpeakerWasRevised(segment: segment, evidence: previewEvidence),
                    providerConfigurationVersion: providerConfigurationVersion
                )
                return value
            }
            let transcript = MeetingTranscript(
                meetingID: meeting.id,
                transcriptVersion: 0,
                providerConfigurationVersion: providerConfigurationVersion,
                localeIdentifier: validatedContext.localeIdentifier,
                generatedAt: now(),
                segments: evidenced
            )
            let marker = TranscriptReindexPendingMarker(
                meetingID: meeting.id,
                transcriptDigest: try Self.transcriptDigest(transcript),
                phase: indexSearch ? .indexingFinalProjection : .awaitingAuthoritativeLibraryCommit
            )
            try bundleStore.writeJSONArtifact(
                marker,
                meetingID: meeting.id,
                relativePath: TranscriptReindexPendingMarker.relativePath,
                purpose: TranscriptReindexPendingMarker.purpose
            )
            try bundleStore.writeJSONArtifact(
                transcript,
                meetingID: meeting.id,
                relativePath: MeetingTranscript.finalTranscriptRelativePath,
                purpose: MeetingTranscript.finalTranscriptPurpose
            )
            let reviewQueue = try TranscriptConfidenceReviewService(now: now).deriveQueue(
                transcript: transcript,
                evidence: evidenced.compactMap { $0.reviewEvidence },
                transcriptVersion: transcript.transcriptVersion
            )
            try TranscriptReviewRepository(bundleStore: bundleStore).save(reviewQueue)
            if indexSearch {
                try indexTransaction(meeting, Self.searchSegments(transcript))
            }
            // Native model work is closed only after encrypted transcript
            // authority and, when requested, the derived-index transaction.
            // If close fails, the marker remains for authoritative recovery.
            try await passCompletion?.close()
            if indexSearch {
                try bundleStore.deleteArtifact(
                    meetingID: meeting.id,
                    relativePath: TranscriptReindexPendingMarker.relativePath
                )
            }
            return FinalTranscriptionResult(
                transcript: transcript,
                indexedSegmentCount: indexSearch ? evidenced.count : 0
            )
        } catch {
            await passCompletion?.cancel()
            throw error
        }
    }

    public static func transcriptDigest(_ transcript: MeetingTranscript) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return SHA256.hash(data: try encoder.encode(transcript)).map { String(format: "%02x", $0) }.joined()
    }

    private static func previewSpeakerWasRevised(
        segment: TranscriptSegment,
        evidence: TranscriptPreviewEvidence
    ) -> Bool {
        guard segment.trackKind == .remoteSystem else { return false }
        let names = Set(evidence.speakerIdentities.compactMap { identity in
            identity.intersects(
                track: segment.trackKind,
                startTime: segment.startTime,
                endTime: segment.endTime
            ) ? identity.speakerName : nil
        })
        return names.count == 1 && names.first != segment.speakerName
    }

    public static func searchSegments(_ transcript: MeetingTranscript) -> [SearchTranscriptSegment] {
        transcript.segments.map {
            SearchTranscriptSegment(
                id: $0.id,
                meetingID: transcript.meetingID,
                speakerName: $0.speakerName,
                startTime: $0.startTime,
                endTime: $0.endTime,
                text: $0.text,
                confidence: $0.confidence,
                isFinal: true
            )
        }
    }

    private static func recordOrder(_ lhs: AudioChunkRecord, _ rhs: AudioChunkRecord) -> Bool {
        if lhs.startTime == rhs.startTime {
            if lhs.track == rhs.track { return lhs.chunkIndex < rhs.chunkIndex }
            return lhs.track == .microphone
        }
        return lhs.startTime < rhs.startTime
    }
}
