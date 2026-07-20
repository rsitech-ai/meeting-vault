@preconcurrency import AVFAudio
import CoreMedia
import Foundation
@preconcurrency import Speech

public enum SpeechAnalyzerFinalTranscriptionError: Error, Equatable, LocalizedError, Sendable {
    case unavailableRuntime
    case transcriberUnavailable
    case unsupportedLocale(String)
    case assetsNotInstalled(String)
    case missingAudioData(String)
    case temporaryFileWriteFailed(String)
    case audioFileOpenFailed(String)
    case recognitionFailed(String)
    case noRecognitionResult(String)

    public var errorDescription: String? {
        switch self {
        case .unavailableRuntime:
            return "SpeechAnalyzer requires macOS 26 or newer."
        case .transcriberUnavailable:
            return "SpeechAnalyzer transcription is unavailable on this Mac."
        case let .unsupportedLocale(locale):
            return "SpeechAnalyzer does not support locale \(locale)."
        case let .assetsNotInstalled(status):
            return "SpeechAnalyzer speech assets are \(status). Install assets intentionally before using this provider."
        case let .missingAudioData(path):
            return "SpeechAnalyzer could not read decrypted audio for \(path)."
        case let .temporaryFileWriteFailed(message):
            return "SpeechAnalyzer could not prepare a temporary local audio file: \(message)"
        case let .audioFileOpenFailed(message):
            return "SpeechAnalyzer could not open the prepared audio file: \(message)"
        case let .recognitionFailed(message):
            return "SpeechAnalyzer final transcription failed: \(message)"
        case let .noRecognitionResult(locale):
            return "SpeechAnalyzer returned no final transcript for locale \(locale)."
        }
    }
}

public struct SpeechAnalyzerTranscriptResult: Equatable, Sendable {
    public var text: String
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    public var confidence: Double
    public var isFinal: Bool

    public init(
        text: String,
        startTime: TimeInterval,
        endTime: TimeInterval,
        confidence: Double,
        isFinal: Bool
    ) {
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.confidence = confidence
        self.isFinal = isFinal
    }
}

public protocol SpeechAnalyzerFileTranscribing: Sendable {
    func transcribeAudioFile(
        at url: URL,
        locale: Locale,
        request: TranscriptionRequest
    ) async throws -> [SpeechAnalyzerTranscriptResult]
}

public final class SpeechAnalyzerFinalTranscriptionEngine: TranscriptionEngine, @unchecked Sendable {
    public let id = "speech-analyzer-final"
    public let supportsRealtime = false

    private let fileTranscriber: any SpeechAnalyzerFileTranscribing
    private let temporaryDirectory: URL
    private let fileManager: FileManager

    public init(
        fileTranscriber: any SpeechAnalyzerFileTranscribing = SystemSpeechAnalyzerFileTranscriber(),
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        fileManager: FileManager = .default
    ) {
        self.fileTranscriber = fileTranscriber
        self.temporaryDirectory = temporaryDirectory
        self.fileManager = fileManager
    }

    public func transcribe(_ request: TranscriptionRequest) async throws -> [TranscriptSegment] {
        guard let audioData = request.audioData, !audioData.isEmpty else {
            throw SpeechAnalyzerFinalTranscriptionError.missingAudioData(request.audioChunkPath)
        }

        let scratchDirectory = temporaryDirectory
            .appendingPathComponent("MeetingVaultSpeechAnalyzerFinal", isDirectory: true)
        do {
            try fileManager.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
        } catch {
            throw SpeechAnalyzerFinalTranscriptionError.temporaryFileWriteFailed(error.localizedDescription)
        }

        let scratchURL = scratchDirectory
            .appendingPathComponent("\(request.meetingID.uuidString)-\(UUID().uuidString)")
            .appendingPathExtension(Self.fileExtension(for: request.audioCodec))
        do {
            try audioData.write(to: scratchURL, options: [.atomic])
        } catch {
            throw SpeechAnalyzerFinalTranscriptionError.temporaryFileWriteFailed(error.localizedDescription)
        }
        defer {
            try? fileManager.removeItem(at: scratchURL)
        }

        let locale = Self.locale(from: request.localeIdentifier)
        let results = try await fileTranscriber.transcribeAudioFile(
            at: scratchURL,
            locale: locale,
            request: request
        )
        let segments = results
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { result in
                TranscriptSegment(
                    speakerName: Self.speakerName(for: request.trackKind),
                    trackKind: request.trackKind ?? .mixedPlayback,
                    startTime: (request.startTime ?? 0) + result.startTime,
                    endTime: max(
                        (request.startTime ?? 0) + result.startTime + 0.1,
                        (request.startTime ?? 0) + result.endTime
                    ),
                    text: result.text,
                    confidence: result.confidence,
                    isFinal: result.isFinal
                )
            }
        guard !segments.isEmpty else {
            throw SpeechAnalyzerFinalTranscriptionError.noRecognitionResult(locale.identifier)
        }
        return segments
    }

    private static func locale(from identifier: String?) -> Locale {
        let trimmed = identifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else {
            return Locale.current
        }
        return Locale(identifier: trimmed)
    }

    private static func fileExtension(for codec: String?) -> String {
        let normalized = codec?.lowercased() ?? ""
        if normalized.contains("wav") {
            return "wav"
        }
        if normalized.contains("aiff") || normalized.contains("aifc") {
            return "aiff"
        }
        if normalized.contains("mp3") {
            return "mp3"
        }
        if normalized.contains("m4a") || normalized.contains("aac") {
            return "m4a"
        }
        return "caf"
    }

    private static func speakerName(for track: TrackKind?) -> String {
        switch track {
        case .microphone:
            return "You"
        case .remoteSystem:
            return "Meeting audio"
        case .mixedPlayback:
            return "Playback mix"
        case nil:
            return "Meeting audio"
        }
    }
}

public final class SystemSpeechAnalyzerFileTranscriber: SpeechAnalyzerFileTranscribing, @unchecked Sendable {
    public init() {}

    public func transcribeAudioFile(
        at url: URL,
        locale: Locale,
        request: TranscriptionRequest
    ) async throws -> [SpeechAnalyzerTranscriptResult] {
        guard #available(macOS 26.0, *) else {
            throw SpeechAnalyzerFinalTranscriptionError.unavailableRuntime
        }
        guard SpeechTranscriber.isAvailable else {
            throw SpeechAnalyzerFinalTranscriptionError.transcriberUnavailable
        }
        guard let supportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw SpeechAnalyzerFinalTranscriptionError.unsupportedLocale(locale.identifier)
        }

        let transcriber = SpeechTranscriber(
            locale: supportedLocale,
            preset: .timeIndexedTranscriptionWithAlternatives
        )
        let modules: [any SpeechModule] = [transcriber]
        let assetStatus = await AssetInventory.status(forModules: modules)
        guard String(describing: assetStatus) == "installed" else {
            throw SpeechAnalyzerFinalTranscriptionError.assetsNotInstalled(String(describing: assetStatus))
        }

        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: url)
        } catch {
            throw SpeechAnalyzerFinalTranscriptionError.audioFileOpenFailed(error.localizedDescription)
        }

        let analyzer = SpeechAnalyzer(modules: modules)
        do {
            async let collectedResults = Self.collectResults(from: transcriber)
            try await analyzer.prepareToAnalyze(in: audioFile.processingFormat)
            _ = try await analyzer.analyzeSequence(from: audioFile)
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            return try await collectedResults
        } catch {
            throw SpeechAnalyzerFinalTranscriptionError.recognitionFailed(error.localizedDescription)
        }
    }

    @available(macOS 26.0, *)
    private static func collectResults(
        from transcriber: SpeechTranscriber
    ) async throws -> [SpeechAnalyzerTranscriptResult] {
        var results: [SpeechAnalyzerTranscriptResult] = []
        for try await result in transcriber.results {
            let text = String(result.text.characters)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            results.append(
                SpeechAnalyzerTranscriptResult(
                    text: text,
                    startTime: max(0, CMTimeGetSeconds(result.range.start)),
                    endTime: max(0.1, CMTimeGetSeconds(result.range.end)),
                    confidence: 0,
                    isFinal: result.isFinal
                )
            )
        }
        return results
    }
}
