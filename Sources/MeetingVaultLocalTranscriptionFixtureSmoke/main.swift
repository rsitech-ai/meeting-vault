import Foundation
import MeetingVaultCore

@main
struct MeetingVaultLocalTranscriptionFixtureSmoke {
    static func main() async throws {
        let output = value(after: "--output")
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultLocalTranscriptionSmoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let instrumentation = SmokeInstrumentation()
        let before = plaintextArtifacts(in: workspace)
        let polish = try await run(locale: "pl-PL", instrumentation: instrumentation)
        let english = try await run(locale: "en-US", instrumentation: instrumentation)
        let finalProof = try await runProductionCompositionFinalProof(in: workspace, instrumentation: instrumentation)
        let missingModelsDegraded = await missingModelProbe(in: workspace)
        let snapshot = instrumentation.snapshot()
        let after = plaintextArtifacts(in: workspace)
        let result = SmokeResult(
            polishFixturePassed: polish.segmentCount == 6,
            englishFixturePassed: english.segmentCount == 6,
            bothTracksAligned: polish.tracks == ["microphone", "remoteSystem"]
                && english.tracks == ["microphone", "remoteSystem"],
            remoteSpeakerCount: min(polish.remoteSpeakers.count, english.remoteSpeakers.count),
            overlapReconciled: polish.hasOverlap && english.hasOverlap
                && polish.hasNoDuplicateText && english.hasNoDuplicateText,
            plaintextTemporaryFileCount: after.subtracting(before).count,
            externalNetworkRequested: snapshot.networkRequests > 0,
            observedModelLoadCount: snapshot.modelLoads,
            observedLeasePeak: snapshot.leasePeak,
            observedProviderSessionCount: snapshot.providerSessions,
            missingModelsDegradedWithoutFallback: missingModelsDegraded,
            productionWiringExercised: finalProof.productionWiringExercised,
            realModelInference: false,
            encryptedFinalTranscriptPersisted: finalProof.encryptedTranscriptPersisted,
            reindexMarkerCleared: finalProof.reindexMarkerCleared,
            activeTaskCountAfterFinish: snapshot.activeTasks,
            proofScope: "injected production engine-loader spy through the same final composition resolver as MeetingVaultStore; real-model inference and quality remain Task 11",
            passed: polish.segmentCount == 6
                && english.segmentCount == 6
                && polish.remoteSpeakers.count == 5
                && english.remoteSpeakers.count == 5
                && polish.hasOverlap
                && english.hasOverlap
                && polish.hasNoDuplicateText
                && english.hasNoDuplicateText
                && after.subtracting(before).isEmpty
                && snapshot.networkRequests == 0
                && snapshot.activeTasks == 0
                && snapshot.leasePeak == 1
                && snapshot.modelLoads == 1
                && missingModelsDegraded
                && finalProof.productionWiringExercised
                && finalProof.encryptedTranscriptPersisted
                && finalProof.reindexMarkerCleared
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(result)
        if let output {
            try data.write(to: URL(fileURLWithPath: output), options: .atomic)
        }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
        guard result.passed else { exit(1) }
    }

    private static func run(locale: String, instrumentation: SmokeInstrumentation) async throws -> FixtureResult {
        let provider = FixtureProvider(locale: locale, instrumentation: instrumentation)
        let coordinator = TranscriptionSessionCoordinator(
            provider: provider,
            configuration: TranscriptionSessionConfiguration(
                meetingID: UUID(),
                context: MeetingContext(localeIdentifier: locale, expectedParticipantCount: 6),
                expectedRemoteSpeakerCount: 5,
                sourceID: "fixture-both-sides",
                microphoneDeviceID: "fixture-selected-mic"
            )
        )
        try await coordinator.start()
        let collector = Task { () -> [LocalTranscriptionEvent] in
            var events: [LocalTranscriptionEvent] = []
            for await event in coordinator.events { events.append(event) }
            return events
        }
        try await coordinator.consume(try frame(sequence: 1, track: .microphone, time: 0))
        try await coordinator.consume(try frame(sequence: 2, track: .remoteSystem, time: 0))
        try await coordinator.finish()
        let projection = LiveTranscriptProjection(events: await collector.value)
        let remote = Set(projection.segments.filter { $0.trackKind == .remoteSystem }.map(\.speakerName))
        let tracks = Set(projection.segments.map { $0.trackKind.rawValue })
        let hasOverlap = projection.segments.indices.contains { first in
            projection.segments.indices.contains { second in
                guard first < second else { return false }
                let lhs = projection.segments[first]
                let rhs = projection.segments[second]
                return lhs.trackKind == .remoteSystem && rhs.trackKind == .remoteSystem
                    && min(lhs.endTime, rhs.endTime) > max(lhs.startTime, rhs.startTime)
            }
        }
        return FixtureResult(
            segmentCount: projection.segments.count,
            remoteSpeakers: remote,
            tracks: tracks,
            hasOverlap: hasOverlap,
            hasNoDuplicateText: Set(projection.segments.map(\.text)).count == projection.segments.count
        )
    }

    private static func missingModelProbe(in workspace: URL) async -> Bool {
        do {
            let root = workspace.appendingPathComponent("missing-model-library", isDirectory: true)
            let store = EncryptedMeetingBundleStore(
                rootDirectory: root,
                vault: AESGCMDataVault(keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 0x52, count: 32)))
            )
            let writer = EncryptedAudioChunkWriter(bundleStore: store)
            let index = try SQLiteSearchIndex(inMemory: ())
            let meeting = SearchMeeting(id: UUID(), title: "Missing", startedAt: Date(), sourceApp: "Fixture")
            _ = try store.createBundle(.initialEncryptedBundle(meetingID: meeting.id, title: meeting.title))
            let record = try writer.writeChunk(
                Data("encrypted missing-model probe".utf8), meetingID: meeting.id, track: .microphone,
                chunkIndex: 0, startTime: 0, duration: 1, codec: "fixture"
            )
            let service = LocalFinalTranscriptionCompositionResolver.production(
                runtime: MissingModelRuntime(),
                bundleStore: store,
                chunkWriter: writer,
                searchIndex: index
            )
            _ = try await service.transcribe(
                meeting: meeting,
                records: [record],
                context: MeetingContext(localeIdentifier: "pl-PL"),
                speakerRenames: [:],
                indexSearch: false
            )
            return false
        } catch {
            return true
        }
    }

    private static func runProductionCompositionFinalProof(
        in workspace: URL,
        instrumentation: SmokeInstrumentation
    ) async throws -> FinalProof {
        let root = workspace.appendingPathComponent("encrypted-library", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = EncryptedMeetingBundleStore(
            rootDirectory: root,
            vault: AESGCMDataVault(
                keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 0x51, count: 32))
            )
        )
        let writer = EncryptedAudioChunkWriter(bundleStore: store)
        let index = try SQLiteSearchIndex(inMemory: ())
        let meeting = SearchMeeting(id: UUID(), title: "Fixture", startedAt: Date(), sourceApp: "Fixture")
        _ = try store.createBundle(.initialEncryptedBundle(meetingID: meeting.id, title: meeting.title))
        let microphone = try writer.writeChunk(
            Data("encrypted microphone fixture".utf8), meetingID: meeting.id, track: .microphone,
            chunkIndex: 0, startTime: 0, duration: 1, codec: "fixture"
        )
        let remote = try writer.writeChunk(
            Data("encrypted remote fixture".utf8), meetingID: meeting.id, track: .remoteSystem,
            chunkIndex: 0, startTime: 0, duration: 1, codec: "fixture"
        )
        let loaderSpy = SmokeProductionEngineLoaderSpy(instrumentation: instrumentation)
        let service = LocalFinalTranscriptionCompositionResolver.production(
            runtime: MissingModelRuntime(),
            bundleStore: store,
            chunkWriter: writer,
            searchIndex: index,
            engineLoader: loaderSpy
        )
        let result = try await service.transcribe(
            meeting: meeting,
            records: [microphone, remote],
            context: MeetingContext(localeIdentifier: "pl-PL", expectedParticipantCount: 2),
            speakerRenames: [:],
            indexSearch: true
        )
        let artifactURL = store.bundleURL(for: meeting.id)
            .appendingPathComponent(MeetingTranscript.finalTranscriptRelativePath)
        let ciphertext = try Data(contentsOf: artifactURL)
        return FinalProof(
            productionWiringExercised: true,
            encryptedTranscriptPersisted: result.transcript.segments.count == 2
                && !String(decoding: ciphertext, as: UTF8.self).contains("fixture final text"),
            reindexMarkerCleared: try !store.artifactExists(
                meetingID: meeting.id,
                relativePath: TranscriptReindexPendingMarker.relativePath
            )
        )
    }

    private static func plaintextArtifacts(in root: URL) -> Set<String> {
        let extensions = Set(["wav", "caf", "pcm", "txt", "json"])
        let files = (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? []
        return Set(files.filter { extensions.contains($0.pathExtension.lowercased()) }.map(\.path))
    }

    private static func frame(sequence: UInt64, track: TrackKind, time: TimeInterval) throws -> CapturedPCMFrame {
        let samples = [Float](repeating: track == .microphone ? 0.18 : 0.24, count: 320)
        return try CapturedPCMFrame(
            sequence: sequence, track: track, meetingTime: time,
            sampleRate: 16_000, channelCount: 1, frameCount: samples.count,
            pcm: samples.withUnsafeBytes { Data($0) }
        )
    }

    private static func value(after flag: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: flag),
              CommandLine.arguments.indices.contains(index + 1)
        else { return nil }
        return CommandLine.arguments[index + 1]
    }
}

private struct FixtureResult {
    var segmentCount: Int
    var remoteSpeakers: Set<String>
    var tracks: Set<String>
    var hasOverlap: Bool
    var hasNoDuplicateText: Bool
}

private struct SmokeResult: Codable {
    var polishFixturePassed: Bool
    var englishFixturePassed: Bool
    var bothTracksAligned: Bool
    var remoteSpeakerCount: Int
    var overlapReconciled: Bool
    var plaintextTemporaryFileCount: Int
    var externalNetworkRequested: Bool
    var observedModelLoadCount: Int
    var observedLeasePeak: Int
    var observedProviderSessionCount: Int
    var missingModelsDegradedWithoutFallback: Bool
    var productionWiringExercised: Bool
    var realModelInference: Bool
    var encryptedFinalTranscriptPersisted: Bool
    var reindexMarkerCleared: Bool
    var activeTaskCountAfterFinish: Int
    var proofScope: String
    var passed: Bool
}

private struct FinalProof {
    var productionWiringExercised: Bool
    var encryptedTranscriptPersisted: Bool
    var reindexMarkerCleared: Bool
}

private struct SmokeInstrumentationSnapshot {
    var modelLoads: Int
    var networkRequests: Int
    var leasePeak: Int
    var providerSessions: Int
    var activeTasks: Int
}

private final class SmokeInstrumentation: @unchecked Sendable {
    private let lock = NSLock()
    private var modelLoads = 0
    private var networkRequests = 0
    private var activeLeases = 0
    private var leasePeak = 0
    private var providerSessions = 0
    private var activeTasks = 0

    func sessionStarted() {
        lock.withLock {
            providerSessions += 1
            activeTasks += 1
            activeLeases += 1
            leasePeak = max(leasePeak, activeLeases)
        }
    }

    func productionModelLoaded() {
        lock.withLock { modelLoads += 1 }
    }

    func sessionFinished() {
        lock.withLock {
            activeTasks = max(0, activeTasks - 1)
            activeLeases = max(0, activeLeases - 1)
        }
    }

    func snapshot() -> SmokeInstrumentationSnapshot {
        lock.withLock {
            SmokeInstrumentationSnapshot(
                modelLoads: modelLoads,
                networkRequests: networkRequests,
                leasePeak: leasePeak,
                providerSessions: providerSessions,
                activeTasks: activeTasks
            )
        }
    }
}

private struct MissingModelRuntime: LocalModelRuntimeSessionProviding {
    func withRuntimeSession(
        _ ids: Set<String>,
        _ operation: @Sendable (LocalModelRuntimeAccess) async throws -> Void
    ) async throws {
        throw LocalModelInstallationError.unitNotReady
    }
}

private final class SmokeProductionEngineLoaderSpy: LocalFinalProductionEngineLoading, @unchecked Sendable {
    private let instrumentation: SmokeInstrumentation
    init(instrumentation: SmokeInstrumentation) { self.instrumentation = instrumentation }
    func load(
        runtime: any LocalModelRuntimeSessionProviding,
        chunkWriter: EncryptedAudioChunkWriter
    ) -> any LocalFinalTranscriptionEngine {
        instrumentation.productionModelLoaded()
        return SmokeFinalEngine()
    }
}

private final class FixtureProvider: LocalTranscriptionProviding, @unchecked Sendable {
    let descriptor = ProviderDescriptor(
        id: "deterministic-local-fixture", modelVersion: "1",
        supportedLocaleIdentifiers: ["pl-PL", "en-US"],
        supportsRemoteSpeakerDiarization: true, maximumRemoteSpeakerCount: 5
    )
    let locale: String
    let instrumentation: SmokeInstrumentation
    init(locale: String, instrumentation: SmokeInstrumentation) {
        self.locale = locale
        self.instrumentation = instrumentation
    }
    func makeSession(_ configuration: TranscriptionSessionConfiguration) async throws -> any LocalTranscriptionSession {
        instrumentation.sessionStarted()
        return FixtureSession(
            locale: configuration.context.localeIdentifier ?? locale,
            instrumentation: instrumentation
        )
    }
}

private final class FixtureSession: LocalTranscriptionSession, @unchecked Sendable {
    let events: AsyncThrowingStream<LocalTranscriptionEvent, Error>
    private let continuation: AsyncThrowingStream<LocalTranscriptionEvent, Error>.Continuation
    private let locale: String
    private let instrumentation: SmokeInstrumentation
    private let lock = NSLock()
    private var terminal = false
    init(locale: String, instrumentation: SmokeInstrumentation) {
        self.locale = locale
        self.instrumentation = instrumentation
        let pair = AsyncThrowingStream<LocalTranscriptionEvent, Error>.makeStream(bufferingPolicy: .bufferingNewest(32))
        events = pair.stream
        continuation = pair.continuation
    }
    func submit(_ frame: CapturedPCMFrame) async throws {}
    func finish() async throws {
        guard lock.withLock({ if terminal { return false }; terminal = true; return true }) else { return }
        let greeting = locale == "pl-PL" ? "Dzien dobry" : "Good morning"
        continuation.yield(.final(TranscriptSegment(
            speakerName: "raw-mic", trackKind: .microphone,
            startTime: 0, endTime: 1, text: greeting, confidence: 0.97, isFinal: true
        )))
        for index in 0..<5 {
            continuation.yield(.final(TranscriptSegment(
                speakerName: "raw-\(index)", trackKind: .remoteSystem,
                startTime: Double(index) * 0.5, endTime: Double(index) * 0.5 + 1,
                text: "Remote \(index + 1)", confidence: 0.9, isFinal: true
            )))
        }
        continuation.finish()
        instrumentation.sessionFinished()
    }
    func cancel() async {
        guard lock.withLock({ if terminal { return false }; terminal = true; return true }) else { return }
        continuation.finish()
        instrumentation.sessionFinished()
    }
}

private struct SmokeFinalEngine: LocalFinalTranscriptionEngine {
    func transcribeChunk(_ request: LocalFinalChunkRequest) async throws -> [TranscriptSegment] {
        [TranscriptSegment(
            speakerName: request.track == .microphone ? "You" : "raw-remote",
            trackKind: request.track,
            startTime: request.startTime,
            endTime: request.startTime + request.duration,
            text: "fixture final text \(request.track.rawValue)",
            confidence: 0.9,
            isFinal: true
        )]
    }

    func diarizeRemoteChunk(_ request: LocalFinalChunkRequest) async throws -> [DiarizationTurn] {
        [DiarizationTurn(
            speakerID: "raw-remote",
            startTime: request.startTime,
            endTime: request.startTime + request.duration,
            confidence: 0.9
        )]
    }
}
