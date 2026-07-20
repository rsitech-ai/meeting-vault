@preconcurrency import AVFoundation
@preconcurrency import CoreML
import FluidAudio
import Foundation

private struct LoadedFluidAudioModels: @unchecked Sendable {
    var asr: AsrModels
    var diarizer: LSEENDDiarizer
}

/// FluidAudio is intentionally confined to this adapter file. The rest of the
/// app sees only provider-neutral frames, events, and descriptor-backed model
/// access. No ModelHub, download, cache preparation, or network API is called.
actor FluidAudioCoreMLBackend: LocalTranscriptionBackend {
    nonisolated let events: AsyncThrowingStream<LocalTranscriptionEvent, Error>
    private let continuation: AsyncThrowingStream<LocalTranscriptionEvent, Error>.Continuation
    private let microphoneASR: AsrManager
    private let remoteASR: AsrManager
    private let diarizer: LSEENDDiarizer
    private let language: Language?
    private var microphoneDecoderState = TdtDecoderState.make(decoderLayers: 2)
    private var remoteDecoderState = TdtDecoderState.make(decoderLayers: 2)
    private var samples: [TrackKind: [Float]] = [:]
    private var bufferStartTime: [TrackKind: TimeInterval] = [:]
    private var bufferEndTime: [TrackKind: TimeInterval] = [:]
    private var pendingSegments: [TrackKind: [TranscriptSegment]] = [:]
    private var diarizationSegments: [DiarizerSegment] = []
    private var terminal = false

    private static let transcriptionWindowSamples = 24_000
    private static let maximumBufferedSamplesPerTrack = 64_000
    private static let maximumDiarizationSegments = 256

    private init(
        models: LoadedFluidAudioModels,
        configuration: TranscriptionSessionConfiguration,
        pair: (
            stream: AsyncThrowingStream<LocalTranscriptionEvent, Error>,
            continuation: AsyncThrowingStream<LocalTranscriptionEvent, Error>.Continuation
        )
    ) async throws {
        microphoneASR = AsrManager(models: models.asr)
        remoteASR = AsrManager(models: models.asr)
        diarizer = models.diarizer
        language = switch configuration.context.localeIdentifier {
        case "pl-PL": .polish
        case "en-US": .english
        default: nil
        }
        events = pair.stream
        continuation = pair.continuation
        try await microphoneASR.loadModels(models.asr)
        try await remoteASR.loadModels(models.asr)
        continuation.yield(.status("Verified local Parakeet and LS-EEND models loaded"))
    }

    static func load(
        access: LocalModelRuntimeAccess,
        configuration: TranscriptionSessionConfiguration
    ) async throws -> FluidAudioCoreMLBackend {
        let models = try await loadVerifiedModels(access: access)
        let pair = AsyncThrowingStream<LocalTranscriptionEvent, Error>.makeStream(
            bufferingPolicy: .bufferingNewest(128)
        )
        return try await FluidAudioCoreMLBackend(
            models: models,
            configuration: configuration,
            pair: pair
        )
    }

    func submit(_ frame: CapturedPCMFrame) async throws {
        guard !terminal else { return }
        guard frame.track == .microphone || frame.track == .remoteSystem else { return }
        let mono = try Self.mono16kSamples(frame)
        if samples[frame.track, default: []].isEmpty {
            bufferStartTime[frame.track] = frame.meetingTime
        }
        samples[frame.track, default: []].append(contentsOf: mono)
        bufferEndTime[frame.track] = frame.meetingTime + Double(frame.frameCount) / frame.sampleRate
        if samples[frame.track, default: []].count > Self.maximumBufferedSamplesPerTrack {
            let overflow = samples[frame.track, default: []].count - Self.maximumBufferedSamplesPerTrack
            samples[frame.track]?.removeFirst(overflow)
            bufferStartTime[frame.track, default: frame.meetingTime] += Double(overflow) / 16_000
            continuation.yield(.degraded("Local ASR trimmed delayed preview audio; encrypted recording is unaffected"))
        }

        if frame.track == .remoteSystem {
            if let update = try diarizer.process(samples: mono, sourceSampleRate: 16_000) {
                retainDiarization(update.finalizedSegments + update.tentativeSegments)
                let active = Set(update.finalizedSegments.map(\.speakerIndex) + update.tentativeSegments.map(\.speakerIndex))
                    .sorted()
                    .map { "lseend-\($0)" }
                continuation.yield(.activeSpeakers(active))
            }
        }
        if samples[frame.track, default: []].count >= Self.transcriptionWindowSamples {
            try await flush(track: frame.track)
        }
    }

    func finish() async throws {
        guard !terminal else { return }
        terminal = true
        var finishError: Error?
        do {
            if let update = try diarizer.finalizeSession() {
                retainDiarization(update.finalizedSegments + update.tentativeSegments)
            }
            for track in [TrackKind.microphone, .remoteSystem] where !samples[track, default: []].isEmpty {
                try await flush(track: track)
            }
            for track in [TrackKind.microphone, .remoteSystem] {
                finalizePending(track: track)
            }
        } catch {
            finishError = error
        }
        // Terminal cleanup and stream completion are unconditional. A native
        // diarizer/ASR finalization error must never strand the event consumer
        // or retain a verified model lease.
        await microphoneASR.cleanup()
        await remoteASR.cleanup()
        if let finishError {
            continuation.finish(throwing: finishError)
            throw finishError
        }
        continuation.finish()
    }

    func cancel() async {
        guard !terminal else { return }
        terminal = true
        samples.removeAll()
        pendingSegments.removeAll()
        await microphoneASR.cleanup()
        await remoteASR.cleanup()
        continuation.finish()
    }

    private func flush(track: TrackKind) async throws {
        let chunk = samples.removeValue(forKey: track) ?? []
        guard !chunk.isEmpty else { return }
        let start = bufferStartTime.removeValue(forKey: track) ?? 0
        let end = max(start + 0.001, bufferEndTime.removeValue(forKey: track) ?? start)
        let result: ASRResult
        if track == .microphone {
            var state = microphoneDecoderState
            result = try await microphoneASR.transcribe(chunk, decoderState: &state, language: language)
            microphoneDecoderState = state
        } else {
            var state = remoteDecoderState
            result = try await remoteASR.transcribe(chunk, decoderState: &state, language: language)
            remoteDecoderState = state
        }
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        finalizePending(track: track)
        let confidence = min(1, max(0, Double(result.confidence)))
        if track == .microphone {
            let segment = TranscriptSegment(
                speakerName: "You",
                trackKind: .microphone,
                startTime: start,
                endTime: end,
                text: text,
                confidence: confidence,
                isFinal: false
            )
            pendingSegments[track] = [segment]
            continuation.yield(.partial(segment))
        } else {
            let speakers = diarizationSegments.filter {
                Double($0.endTime) > start && Double($0.startTime) < end
            }
            let identities = Array(Set(speakers.map(\.speakerIndex))).sorted()
            let segment = TranscriptSegment(
                speakerName: FluidAudioLiveSpeakerResolver.name(for: identities),
                trackKind: .remoteSystem,
                startTime: start,
                endTime: end,
                text: text,
                confidence: confidence,
                isFinal: false
            )
            pendingSegments[track] = [segment]
            continuation.yield(.partial(segment))
        }
    }

    private func finalizePending(track: TrackKind) {
        let pending = pendingSegments.removeValue(forKey: track) ?? []
        for var segment in pending {
            segment.isFinal = true
            continuation.yield(.final(segment))
        }
    }

    private func retainDiarization(_ newSegments: [DiarizerSegment]) {
        for segment in newSegments {
            if let index = diarizationSegments.firstIndex(where: {
                $0.speakerIndex == segment.speakerIndex
                    && $0.startFrame == segment.startFrame
                    && $0.endFrame == segment.endFrame
            }) {
                diarizationSegments[index] = segment
            } else {
                diarizationSegments.append(segment)
            }
        }
        diarizationSegments.sort { $0.endFrame < $1.endFrame }
        if diarizationSegments.count > Self.maximumDiarizationSegments {
            diarizationSegments.removeFirst(diarizationSegments.count - Self.maximumDiarizationSegments)
        }
    }

    private static func mono16kSamples(_ frame: CapturedPCMFrame) throws -> [Float] {
        let source = frame.floatSamples
        var mono = [Float](repeating: 0, count: frame.frameCount)
        for frameIndex in 0..<frame.frameCount {
            var sum: Float = 0
            for channel in 0..<frame.channelCount {
                sum += source[frameIndex * frame.channelCount + channel]
            }
            mono[frameIndex] = sum / Float(frame.channelCount)
        }
        guard frame.sampleRate != 16_000 else { return mono }
        let ratio = 16_000 / frame.sampleRate
        let outputCount = Int((Double(mono.count) * ratio).rounded())
        guard outputCount > 0, outputCount <= CapturedPCMFrame.maximumFrameCount * 8 else {
            throw LocalTranscriptionError.providerUnavailable("unsupported capture sample rate")
        }
        var output = [Float](repeating: 0, count: outputCount)
        for index in output.indices {
            let sourcePosition = Double(index) / ratio
            let lower = min(mono.count - 1, Int(sourcePosition.rounded(.down)))
            let upper = min(mono.count - 1, lower + 1)
            let fraction = Float(sourcePosition - Double(lower))
            output[index] = mono[lower] + (mono[upper] - mono[lower]) * fraction
        }
        return output
    }
}

enum FluidAudioLiveSpeakerResolver {
    static func name(for identities: [Int]) -> String {
        let unique = Array(Set(identities)).sorted()
        return switch unique.count {
        case 0: "remote-unassigned"
        case 1: "lseend-\(unique[0])"
        default: "Multiple speakers"
        }
    }
}

private extension FluidAudioCoreMLBackend {
    static func loadVerifiedModels(access: LocalModelRuntimeAccess) async throws -> LoadedFluidAudioModels {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        let preprocessor = try await loadModel(
            access: access, unit: "automatic-speech-recognition",
            relativePath: "parakeet-tdt-0.6b-v3/Preprocessor.mlmodelc", configuration: configuration
        )
        let encoder = try await loadModel(
            access: access, unit: "automatic-speech-recognition",
            relativePath: "parakeet-tdt-0.6b-v3/Encoder.mlmodelc", configuration: configuration
        )
        let decoder = try await loadModel(
            access: access, unit: "automatic-speech-recognition",
            relativePath: "parakeet-tdt-0.6b-v3/Decoder.mlmodelc", configuration: configuration
        )
        let joint = try await loadModel(
            access: access, unit: "automatic-speech-recognition",
            relativePath: "parakeet-tdt-0.6b-v3/JointDecisionv3.mlmodelc", configuration: configuration
        )
        let vocabulary = try await loadVocabulary(access: access)
        let asr = AsrModels(
            encoder: encoder,
            preprocessor: preprocessor,
            decoder: decoder,
            joint: joint,
            configuration: configuration,
            vocabulary: vocabulary,
            version: .v3
        )
        let lseend = try await loadLSEEND(access: access)
        return LoadedFluidAudioModels(
            asr: asr,
            diarizer: try LSEENDDiarizer(model: lseend)
        )
    }

    static func loadModel(
        access: LocalModelRuntimeAccess,
        unit: String,
        relativePath: String,
        configuration: MLModelConfiguration
    ) async throws -> MLModel {
        let result = ModelLoadResult()
        try await access.withVerifiedModelPackageURL(assetID: unit, relativePath: relativePath) { url in
            do {
                let model = try MLModel(
                    contentsOf: url,
                    configuration: configuration
                )
                result.set(.success(model))
            } catch {
                result.set(.failure(error))
            }
        }
        return try result.get()
    }

    static func loadLSEEND(access: LocalModelRuntimeAccess) async throws -> LSEENDModel {
        let result = LSEENDLoadResult()
        try await access.withVerifiedModelPackageURL(
            assetID: "streaming-speaker-diarization",
            relativePath: "ls-eend/dih3/optimized/dih3/100ms/ls_eend_dih3_100ms.mlmodelc"
        ) { url in
            do {
                result.set(.success(try LSEENDModel(
                    modelURL: url
                )))
            } catch {
                result.set(.failure(error))
            }
        }
        return try result.get()
    }

    static func loadVocabulary(access: LocalModelRuntimeAccess) async throws -> [Int: String] {
        let result = VocabularyLoadResult()
        try await access.withReadOnlyFileDescriptor(
            assetID: "automatic-speech-recognition",
            relativePath: "parakeet-tdt-0.6b-v3/parakeet_vocab.json"
        ) { descriptor in
            do {
                let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
                guard let data = try handle.readToEnd(), data.count <= 2 * 1_024 * 1_024,
                      let dictionary = try JSONSerialization.jsonObject(with: data) as? [String: String]
                else { throw LocalTranscriptionError.providerUnavailable("invalid local vocabulary") }
                result.set(.success(Dictionary(uniqueKeysWithValues: dictionary.compactMap {
                    guard let key = Int($0.key) else { return nil }
                    return (key, $0.value)
                })))
            } catch {
                result.set(.failure(error))
            }
        }
        return try result.get()
    }
}

private final class ModelLoadResult: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<MLModel, Error>?
    func set(_ result: Result<MLModel, Error>) { lock.withLock { self.result = result } }
    func get() throws -> MLModel { try lock.withLock { try result!.get() } }
}

private final class LSEENDLoadResult: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<LSEENDModel, Error>?
    func set(_ result: Result<LSEENDModel, Error>) { lock.withLock { self.result = result } }
    func get() throws -> LSEENDModel { try lock.withLock { try result!.get() } }
}

private final class VocabularyLoadResult: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<[Int: String], Error>?
    func set(_ result: Result<[Int: String], Error>) { lock.withLock { self.result = result } }
    func get() throws -> [Int: String] { try lock.withLock { try result!.get() } }
}
