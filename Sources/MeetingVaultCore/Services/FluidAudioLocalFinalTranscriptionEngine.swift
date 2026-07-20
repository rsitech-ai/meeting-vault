@preconcurrency import CoreML
import CryptoKit
import FluidAudio
import Foundation

enum BoundedPLDAParameters {
    static let maximumJSONBytes = 8 * 1_024 * 1_024

    static func parse(_ data: Data, expectedDimension: Int = 128) throws -> [Double] {
        guard !data.isEmpty, data.count <= maximumJSONBytes, expectedDimension > 0 else {
            throw LocalTranscriptionError.providerUnavailable("invalid bounded PLDA parameters")
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tensors = root["tensors"] as? [String: Any],
              let psi = tensors["psi"] as? [String: Any],
              let encoded = psi["data_base64"] as? String,
              let decoded = Data(base64Encoded: encoded),
              decoded.count == expectedDimension * MemoryLayout<Float>.size else {
            throw LocalTranscriptionError.providerUnavailable("invalid PLDA psi dimension")
        }
        let floats = decoded.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        guard floats.count == expectedDimension, floats.allSatisfy(\.isFinite) else {
            throw LocalTranscriptionError.providerUnavailable("invalid PLDA psi values")
        }
        return floats.map(Double.init)
    }
}

/// Production authoritative final pass. One verified runtime lease owns both
/// Parakeet ASR and offline diarization for the entire meeting. Model packages
/// are loaded only from descriptor-verified normal paths; no FluidAudio model
/// hub, cache preparation, download, or provider audio engine is used.
public final class FluidAudioLocalFinalTranscriptionEngine: LocalFinalPassTranscriptionEngine, @unchecked Sendable {
    private let runtime: any LocalModelRuntimeSessionProviding
    private let chunkWriter: EncryptedAudioChunkWriter
    private let requiredUnits: Set<String> = [
        "automatic-speech-recognition",
        "offline-speaker-diarization",
    ]

    public init(
        runtime: any LocalModelRuntimeSessionProviding,
        chunkWriter: EncryptedAudioChunkWriter
    ) {
        self.runtime = runtime
        self.chunkWriter = chunkWriter
    }

    public func providerConfigurationVersion(for context: MeetingContext) throws -> String {
        let validated = try context.validated()
        let manifest = try LocalModelManifest.loadBundled()
        let asr = try Self.manifestIdentity(
            feature: "automatic-speech-recognition",
            manifest: manifest
        )
        let diarization = try Self.manifestIdentity(
            feature: "offline-speaker-diarization",
            manifest: manifest
        )
        let configuration = [
            "locale=\(validated.localeIdentifier ?? "automatic")",
            "remoteSpeakers=\(validated.expectedParticipantCount.map { max(1, $0 - 1) } ?? 10)",
            "exclusiveSegments=false",
            "compute=cpuAndNeuralEngine",
        ].joined(separator: "|")
        let digest = SHA256.hash(data: Data(configuration.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "fluidaudio-0.15.5|asr:\(asr)|offline:\(diarization)|config:\(digest)"
    }

    private static func manifestIdentity(
        feature: String,
        manifest: LocalModelManifest
    ) throws -> String {
        let assets = manifest.assets.filter { $0.feature == feature }
        guard !assets.isEmpty else {
            throw LocalTranscriptionError.providerUnavailable("missing \(feature) manifest identity")
        }
        let versions = Set(assets.map(\.version)).sorted().joined(separator: ",")
        let revisions = Set(assets.map(\.sourceRevision)).sorted().joined(separator: ",")
        return "\(versions)@\(revisions)"
    }

    public func transcribePass(
        meeting: SearchMeeting,
        records: [AudioChunkRecord],
        context: MeetingContext,
        decryptedChunkReader: any LocalDecryptedAudioChunkReading,
        maximumDecryptedChunkBytes: Int
    ) async throws -> LocalFinalPassOutput {
        let lifecycle = FluidAudioFinalRuntimeLifecycle()
        let runtime = self.runtime
        let units = requiredUnits
        let task = Task {
            do {
                try await runtime.withRuntimeSession(units) { access in
                    do {
                        let stack = try await FluidAudioFinalStack.load(access: access, context: context)
                        await lifecycle.resolve(.success(stack))
                        await lifecycle.waitUntilReleased()
                    } catch {
                        await lifecycle.resolve(.failure(error))
                        throw error
                    }
                }
            } catch {
                await lifecycle.resolve(.failure(error))
                throw error
            }
        }

        let stack: FluidAudioFinalStack
        do {
            stack = try await lifecycle.stack()
        } catch {
            _ = try? await task.value
            throw error
        }

        do {
            var segments: [TranscriptSegment] = []
            for record in records {
                let produced = try await decryptedChunkReader.withDecryptedChunk(record) { data in
                    guard data.count <= maximumDecryptedChunkBytes else {
                        throw DiarizationReconciliationError.decryptedChunkTooLarge(
                            actual: data.count,
                            maximum: maximumDecryptedChunkBytes
                        )
                    }
                    return try await stack.transcribe(
                        data: data,
                        track: record.track,
                        startTime: record.startTime,
                        duration: record.duration
                    )
                }
                segments.append(contentsOf: produced)
            }

            let remoteRecords = records.filter { $0.track == .remoteSystem }
            let turns: [DiarizationTurn]
            if remoteRecords.isEmpty {
                turns = []
            } else {
                let source = EncryptedRemoteAudioSampleSource(
                    writer: chunkWriter,
                    meetingID: meeting.id,
                    records: remoteRecords,
                    maximumChunkBytes: maximumDecryptedChunkBytes
                )
                turns = try await stack.diarize(source: source)
            }
            return LocalFinalPassOutput(
                asrSegments: segments,
                remoteTurns: turns,
                completion: FluidAudioFinalPassCompletion(stack: stack, lifecycle: lifecycle, task: task)
            )
        } catch {
            await stack.cleanup()
            await lifecycle.release()
            _ = try? await task.value
            throw error
        }
    }

    public func transcribeChunk(_ request: LocalFinalChunkRequest) async throws -> [TranscriptSegment] {
        throw LocalTranscriptionError.providerUnavailable("final pass requires a meeting-scoped runtime")
    }

    public func diarizeRemoteChunk(_ request: LocalFinalChunkRequest) async throws -> [DiarizationTurn] {
        throw LocalTranscriptionError.providerUnavailable("offline diarization requires the complete remote timeline")
    }
}

private actor FluidAudioFinalRuntimeLifecycle {
    private var resolution: Result<FluidAudioFinalStack, Error>?
    private var waiters: [CheckedContinuation<Result<FluidAudioFinalStack, Error>, Never>] = []
    private var released = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func resolve(_ result: Result<FluidAudioFinalStack, Error>) {
        guard resolution == nil else { return }
        resolution = result
        let current = waiters
        waiters.removeAll()
        current.forEach { $0.resume(returning: result) }
    }

    func stack() async throws -> FluidAudioFinalStack {
        let result: Result<FluidAudioFinalStack, Error>
        if let resolution {
            result = resolution
        } else {
            result = await withCheckedContinuation { waiters.append($0) }
        }
        return try result.get()
    }

    func release() {
        guard !released else { return }
        released = true
        let current = releaseWaiters
        releaseWaiters.removeAll()
        current.forEach { $0.resume() }
    }

    func waitUntilReleased() async {
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }
}

private final class FluidAudioFinalPassCompletion: LocalFinalPassCompletion, @unchecked Sendable {
    private let stack: FluidAudioFinalStack
    private let lifecycle: FluidAudioFinalRuntimeLifecycle
    private let task: Task<Void, Error>
    private let lock = NSLock()
    private var terminal = false

    init(stack: FluidAudioFinalStack, lifecycle: FluidAudioFinalRuntimeLifecycle, task: Task<Void, Error>) {
        self.stack = stack
        self.lifecycle = lifecycle
        self.task = task
    }

    func close() async throws {
        guard beginTerminal() else { return }
        await stack.cleanup()
        await lifecycle.release()
        try await task.value
    }

    func cancel() async {
        guard beginTerminal() else { return }
        await stack.cleanup()
        await lifecycle.release()
        _ = try? await task.value
    }

    private func beginTerminal() -> Bool {
        lock.withLock {
            guard !terminal else { return false }
            terminal = true
            return true
        }
    }

    deinit {
        guard beginTerminal() else { return }
        let stack = stack
        let lifecycle = lifecycle
        Task {
            await stack.cleanup()
            await lifecycle.release()
        }
    }
}

private actor FluidAudioFinalStack {
    private let microphoneASR: AsrManager
    private let remoteASR: AsrManager
    nonisolated(unsafe) private let diarizer: OfflineDiarizerManager
    private let language: Language?
    private var microphoneState = TdtDecoderState.make(decoderLayers: 2)
    private var remoteState = TdtDecoderState.make(decoderLayers: 2)
    private var cleaned = false

    private init(
        asrModels: AsrModels,
        offlineModels: OfflineDiarizerModels,
        context: MeetingContext
    ) async throws {
        microphoneASR = AsrManager(models: asrModels)
        remoteASR = AsrManager(models: asrModels)
        language = switch context.localeIdentifier {
        case "pl-PL": .polish
        case "en-US": .english
        default: nil
        }
        var config = OfflineDiarizerConfig.default
        let maximum = min(10, max(1, context.expectedParticipantCount.map { $0 - 1 } ?? 10))
        config = config.withSpeakers(min: 1, max: maximum)
        config.exclusiveSegments = false
        diarizer = OfflineDiarizerManager(config: config)
        diarizer.initialize(models: offlineModels)
        try await microphoneASR.loadModels(asrModels)
        try await remoteASR.loadModels(asrModels)
    }

    static func load(access: LocalModelRuntimeAccess, context: MeetingContext) async throws -> FluidAudioFinalStack {
        async let asr = FluidAudioFinalModelLoader.loadASR(access: access)
        async let offline = FluidAudioFinalModelLoader.loadOffline(access: access)
        return try await FluidAudioFinalStack(asrModels: asr, offlineModels: offline, context: context)
    }

    func transcribe(
        data: Data,
        track: TrackKind,
        startTime: TimeInterval,
        duration: TimeInterval
    ) async throws -> [TranscriptSegment] {
        let samples = try BoundedWAVAudio.decodeMono16K(data)
        guard !samples.isEmpty else { return [] }
        let result: ASRResult
        if track == .microphone {
            var state = microphoneState
            result = try await microphoneASR.transcribe(samples, decoderState: &state, language: language)
            microphoneState = state
        } else {
            var state = remoteState
            result = try await remoteASR.transcribe(samples, decoderState: &state, language: language)
            remoteState = state
        }
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        return [TranscriptSegment(
            speakerName: track == .microphone ? "You" : "remote-unassigned",
            trackKind: track,
            startTime: startTime,
            endTime: max(startTime + 0.001, startTime + duration),
            text: text,
            confidence: min(1, max(0, Double(result.confidence))),
            isFinal: true
        )]
    }

    func diarize(source: EncryptedRemoteAudioSampleSource) async throws -> [DiarizationTurn] {
        do {
            let result = try await diarizer.process(audioSource: source, audioLoadingSeconds: 0)
            return result.segments.compactMap { segment in
                let start = Double(segment.startTimeSeconds)
                let end = Double(segment.endTimeSeconds)
                guard start.isFinite, end.isFinite, end > start else { return nil }
                let quality = Double(segment.qualityScore)
                return DiarizationTurn(
                    speakerID: segment.speakerId,
                    startTime: start,
                    endTime: end,
                    confidence: quality.isFinite ? min(1, max(0, quality)) : 0
                )
            }
        } catch OfflineDiarizationError.noSpeechDetected {
            return []
        }
    }

    func cleanup() async {
        guard !cleaned else { return }
        cleaned = true
        await microphoneASR.cleanup()
        await remoteASR.cleanup()
    }
}

private enum FluidAudioFinalModelLoader {
    static func loadASR(access: LocalModelRuntimeAccess) async throws -> AsrModels {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        async let preprocessor = loadModel(access, "automatic-speech-recognition", "parakeet-tdt-0.6b-v3/Preprocessor.mlmodelc", configuration)
        async let encoder = loadModel(access, "automatic-speech-recognition", "parakeet-tdt-0.6b-v3/Encoder.mlmodelc", configuration)
        async let decoder = loadModel(access, "automatic-speech-recognition", "parakeet-tdt-0.6b-v3/Decoder.mlmodelc", configuration)
        async let joint = loadModel(access, "automatic-speech-recognition", "parakeet-tdt-0.6b-v3/JointDecisionv3.mlmodelc", configuration)
        async let vocabulary = loadVocabulary(access)
        return try await AsrModels(
            encoder: encoder,
            preprocessor: preprocessor,
            decoder: decoder,
            joint: joint,
            configuration: configuration,
            vocabulary: vocabulary,
            version: .v3
        )
    }

    static func loadOffline(access: LocalModelRuntimeAccess) async throws -> OfflineDiarizerModels {
        let inference = MLModelConfiguration()
        inference.computeUnits = .cpuAndNeuralEngine
        let cpu = MLModelConfiguration()
        cpu.computeUnits = .cpuOnly
        async let segmentation = loadModel(access, "offline-speaker-diarization", "speaker-diarization/Segmentation.mlmodelc", inference)
        async let fbank = loadModel(access, "offline-speaker-diarization", "speaker-diarization/FBank.mlmodelc", cpu)
        async let embedding = loadModel(access, "offline-speaker-diarization", "speaker-diarization/Embedding.mlmodelc", inference)
        async let rho = loadModel(access, "offline-speaker-diarization", "speaker-diarization/PldaRho.mlmodelc", inference)
        async let psi = loadPLDA(access)
        return try await OfflineDiarizerModels(
            segmentationModel: segmentation,
            fbankModel: fbank,
            embeddingModel: embedding,
            pldaRhoModel: rho,
            pldaPsi: psi,
            compilationDuration: 0
        )
    }

    private static func loadModel(
        _ access: LocalModelRuntimeAccess,
        _ assetID: String,
        _ path: String,
        _ configuration: MLModelConfiguration
    ) async throws -> MLModel {
        let box = FinalModelLoadBox<MLModel>()
        try await access.withVerifiedModelPackageURL(assetID: assetID, relativePath: path) { url in
            box.store(Result { try MLModel(contentsOf: url, configuration: configuration) })
        }
        return try box.value()
    }

    private static func loadVocabulary(_ access: LocalModelRuntimeAccess) async throws -> [Int: String] {
        let box = FinalModelLoadBox<[Int: String]>()
        try await access.withReadOnlyFileDescriptor(
            assetID: "automatic-speech-recognition",
            relativePath: "parakeet-tdt-0.6b-v3/parakeet_vocab.json"
        ) { descriptor in
            box.store(Result {
                let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
                guard let data = try handle.readToEnd(), data.count <= 2 * 1_024 * 1_024,
                      let object = try JSONSerialization.jsonObject(with: data) as? [String: String] else {
                    throw LocalTranscriptionError.providerUnavailable("invalid local vocabulary")
                }
                return Dictionary(uniqueKeysWithValues: object.compactMap { key, value in
                    Int(key).map { ($0, value) }
                })
            })
        }
        return try box.value()
    }

    private static func loadPLDA(_ access: LocalModelRuntimeAccess) async throws -> [Double] {
        let box = FinalModelLoadBox<[Double]>()
        try await access.withReadOnlyFileDescriptor(
            assetID: "offline-speaker-diarization",
            relativePath: "speaker-diarization/plda-parameters.json"
        ) { descriptor in
            box.store(Result {
                let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
                guard let data = try handle.readToEnd() else {
                    throw LocalTranscriptionError.providerUnavailable("missing PLDA parameters")
                }
                return try BoundedPLDAParameters.parse(data)
            })
        }
        return try box.value()
    }
}

private final class FinalModelLoadBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?
    func store(_ result: Result<Value, Error>) { lock.withLock { self.result = result } }
    func value() throws -> Value {
        try lock.withLock {
            guard let result else { throw LocalTranscriptionError.providerUnavailable("model load did not complete") }
            return try result.get()
        }
    }
}

final class EncryptedRemoteAudioSampleSource: AudioSampleSource, @unchecked Sendable {
    private let writer: EncryptedAudioChunkWriter
    private let meetingID: UUID
    private let records: [AudioChunkRecord]
    private let maximumChunkBytes: Int
    private let lock = NSLock()
    private var cachedIndex: Int?
    private var cachedSamples: [Float] = []
    let sampleCount: Int

    init(
        writer: EncryptedAudioChunkWriter,
        meetingID: UUID,
        records: [AudioChunkRecord],
        maximumChunkBytes: Int
    ) {
        self.writer = writer
        self.meetingID = meetingID
        self.records = records.sorted { $0.startTime < $1.startTime }
        self.maximumChunkBytes = maximumChunkBytes
        self.sampleCount = Int(ceil((records.map { $0.startTime + $0.duration }.max() ?? 0) * 16_000))
    }

    func copySamples(into destination: UnsafeMutablePointer<Float>, offset: Int, count: Int) throws {
        guard count > 0, offset < sampleCount else { return }
        let count = min(count, sampleCount - max(0, offset))
        destination.initialize(repeating: 0, count: count)
        try lock.withLock {
            let requestedStart = max(0, offset)
            let requestedEnd = requestedStart + count
            for (index, record) in records.enumerated() {
                let recordStart = Int((record.startTime * 16_000).rounded())
                let recordEnd = recordStart + Int((record.duration * 16_000).rounded())
                let overlapStart = max(requestedStart, recordStart)
                let overlapEnd = min(requestedEnd, recordEnd)
                guard overlapEnd > overlapStart else { continue }
                let samples = try samplesForRecord(index)
                let sourceOffset = overlapStart - recordStart
                let copyCount = min(overlapEnd - overlapStart, max(0, samples.count - sourceOffset))
                guard copyCount > 0 else { continue }
                samples.withUnsafeBufferPointer { source in
                    destination.advanced(by: overlapStart - requestedStart).update(
                        from: source.baseAddress!.advanced(by: sourceOffset),
                        count: copyCount
                    )
                }
            }
        }
    }

    private func samplesForRecord(_ index: Int) throws -> [Float] {
        if cachedIndex == index { return cachedSamples }
        let data = try writer.readChunk(records[index], meetingID: meetingID)
        guard data.count <= maximumChunkBytes else {
            throw DiarizationReconciliationError.decryptedChunkTooLarge(actual: data.count, maximum: maximumChunkBytes)
        }
        let samples = try BoundedWAVAudio.decodeMono16K(data)
        cachedIndex = index
        cachedSamples = samples
        return samples
    }
}

enum BoundedWAVAudio {
    static func decodeMono16K(_ data: Data) throws -> [Float] {
        guard data.count >= 44,
              String(decoding: data[0..<4], as: UTF8.self) == "RIFF",
              String(decoding: data[8..<12], as: UTF8.self) == "WAVE",
              String(decoding: data[12..<16], as: UTF8.self) == "fmt ",
              data.finalUInt32LE(at: 16) == 16,
              String(decoding: data[36..<40], as: UTF8.self) == "data" else {
            throw FrameFedFinalTranscriptionError.invalidWAV
        }
        let format = data.finalUInt16LE(at: 20)
        let channels = Int(data.finalUInt16LE(at: 22))
        let sampleRate = Double(data.finalUInt32LE(at: 24))
        let blockAlign = Int(data.finalUInt16LE(at: 32))
        let bits = data.finalUInt16LE(at: 34)
        let byteCount = Int(data.finalUInt32LE(at: 40))
        guard channels > 0, channels <= CapturedPCMFrame.maximumChannelCount,
              sampleRate > 0, sampleRate.isFinite, blockAlign > 0,
              byteCount > 0, byteCount.isMultiple(of: blockAlign), data.count >= 44 + byteCount else {
            throw FrameFedFinalTranscriptionError.invalidWAV
        }
        let payload = data[44..<(44 + byteCount)]
        let interleaved: [Float]
        switch (format, bits) {
        case (3, 32): interleaved = payload.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        case (1, 16): interleaved = payload.withUnsafeBytes {
            $0.bindMemory(to: Int16.self).map { Float(Int16(littleEndian: $0)) / Float(Int16.max) }
        }
        default: throw FrameFedFinalTranscriptionError.unsupportedWAVFormat(audioFormat: format, bitsPerSample: bits)
        }
        guard interleaved.count.isMultiple(of: channels), interleaved.allSatisfy(\.isFinite) else {
            throw FrameFedFinalTranscriptionError.invalidWAV
        }
        let frames = interleaved.count / channels
        var mono = [Float](repeating: 0, count: frames)
        for frame in 0..<frames {
            for channel in 0..<channels { mono[frame] += interleaved[frame * channels + channel] }
            mono[frame] /= Float(channels)
        }
        guard sampleRate != 16_000 else { return mono }
        let ratio = 16_000 / sampleRate
        let outputCount = Int((Double(mono.count) * ratio).rounded())
        guard outputCount > 0 else { return [] }
        return (0..<outputCount).map { index in
            let position = Double(index) / ratio
            let lower = min(mono.count - 1, Int(position.rounded(.down)))
            let upper = min(mono.count - 1, lower + 1)
            let fraction = Float(position - Double(lower))
            return mono[lower] + (mono[upper] - mono[lower]) * fraction
        }
    }
}

private extension Data {
    func finalUInt16LE(at offset: Int) -> UInt16 {
        self[offset..<(offset + 2)].enumerated().reduce(0) { $0 | (UInt16($1.element) << UInt16($1.offset * 8)) }
    }
    func finalUInt32LE(at offset: Int) -> UInt32 {
        self[offset..<(offset + 4)].enumerated().reduce(0) { $0 | (UInt32($1.element) << UInt32($1.offset * 8)) }
    }
}
