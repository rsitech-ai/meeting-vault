#!/usr/bin/env swift
import AVFAudio
import CoreMedia
import Dispatch
import Foundation
import Speech

struct SpeechAnalyzerSmokeReport: Codable {
    var timestamp: String
    var status: String
    var transcriptionStatus: String
    var localeIdentifier: String
    var resolvedLocaleIdentifier: String?
    var sdkAvailable: Bool
    var transcriberAvailable: Bool
    var assetStatus: String?
    var compatibleAudioFormatDescription: String?
    var usedSyntheticSpeechFixture: Bool
    var privateAudioRecorded: Bool
    var microphoneOpened: Bool
    var assetPreparationRequested: Bool
    var downloadRequested: Bool
    var fixtureAudioGenerated: Bool
    var fixtureAudioDeleted: Bool
    var syntheticTextStored: Bool
    var expectedKeywords: [String]
    var transcriptText: String?
    var containsExpectedKeywords: Bool
    var segmentCount: Int
    var issues: [String]
}

enum SpeechAnalyzerSmokeError: Error, LocalizedError {
    case fixtureGenerationFailed(String)
    case audioFileOpenFailed(String)
    case recognitionFailed(String)
    case timeout(String)

    var errorDescription: String? {
        switch self {
        case let .fixtureGenerationFailed(message):
            return "Synthetic speech fixture generation failed: \(message)"
        case let .audioFileOpenFailed(message):
            return "Could not open synthetic speech fixture: \(message)"
        case let .recognitionFailed(message):
            return "SpeechAnalyzer recognition failed: \(message)"
        case let .timeout(label):
            return "\(label) timed out"
        }
    }
}

struct SpeechAnalyzerSmokeSegment {
    var text: String
    var startTime: TimeInterval
    var endTime: TimeInterval
    var isFinal: Bool
}

struct SpeechAnalyzerFixtureSmoke {
    static let defaultPhrase = "MeetingVault synthetic SpeechAnalyzer smoke test. Consent, decisions, and action items stay local."
    static let defaultKeywords = ["consent", "decisions", "action"]

    static func run() async {
        let rootURL = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let date = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
        var outputURL = rootURL
            .appendingPathComponent("docs", isDirectory: true)
            .appendingPathComponent("evidence", isDirectory: true)
            .appendingPathComponent("speech-analyzer-fixture-smoke-\(date).json")
        var localeIdentifier = "en-US"
        var requirePass = false
        var installAssets = false
        var phrase = defaultPhrase

        var iterator = CommandLine.arguments.dropFirst().makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--output":
                guard let path = iterator.next() else {
                    fputs("--output requires a path\n", stderr)
                    exit(2)
                }
                outputURL = URL(fileURLWithPath: path)
            case "--locale":
                guard let value = iterator.next() else {
                    fputs("--locale requires an identifier like en-US\n", stderr)
                    exit(2)
                }
                localeIdentifier = value
            case "--phrase":
                guard let value = iterator.next() else {
                    fputs("--phrase requires text\n", stderr)
                    exit(2)
                }
                phrase = value
            case "--install-assets", "--prepare-assets":
                installAssets = true
            case "--require-pass":
                requirePass = true
            case "--help", "-h":
                print("""
                usage: script/speech_analyzer_fixture_smoke.swift [--output PATH] [--locale en-US] [--phrase TEXT] [--install-assets] [--require-pass]

                Checks SpeechAnalyzer/SpeechTranscriber availability and asset status
                without requesting permissions, opening the microphone, reading private
                recordings, or downloading assets by default. If assets are already installed, it
                generates a non-private synthetic speech fixture with /usr/bin/say and
                runs SpeechAnalyzer final transcription over that fixture.

                Use --install-assets only when an operator intentionally approves Apple
                SpeechAnalyzer asset installation for the selected locale. That path may
                download Apple on-device speech assets, but still does not open the
                microphone or read private recordings.

                By default, blocked provider or asset state writes status=blocked and
                exits 0. Use --require-pass to turn blocked/fail into a non-zero exit
                for release gates that require real provider evidence.
                """)
                exit(0)
            default:
                fputs("unknown argument: \(argument)\n", stderr)
                exit(2)
            }
        }

        var report = baseReport(localeIdentifier: localeIdentifier)

        if #available(macOS 26.0, *) {
            await runAvailable(
                report: &report,
                outputURL: outputURL,
                localeIdentifier: localeIdentifier,
                phrase: phrase,
                installAssets: installAssets,
                requirePass: requirePass
            )
        } else {
            report.issues.append("SpeechAnalyzer requires macOS 26 or newer.")
            write(report: report, to: outputURL)
            finish(report: report, requirePass: requirePass)
        }
    }

    static func baseReport(localeIdentifier: String) -> SpeechAnalyzerSmokeReport {
        SpeechAnalyzerSmokeReport(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            status: "blocked",
            transcriptionStatus: "not-run",
            localeIdentifier: localeIdentifier,
            resolvedLocaleIdentifier: nil,
            sdkAvailable: false,
            transcriberAvailable: false,
            assetStatus: nil,
            compatibleAudioFormatDescription: nil,
            usedSyntheticSpeechFixture: true,
            privateAudioRecorded: false,
            microphoneOpened: false,
            assetPreparationRequested: false,
            downloadRequested: false,
            fixtureAudioGenerated: false,
            fixtureAudioDeleted: false,
            syntheticTextStored: true,
            expectedKeywords: defaultKeywords,
            transcriptText: nil,
            containsExpectedKeywords: false,
            segmentCount: 0,
            issues: []
        )
    }

    @available(macOS 26.0, *)
    static func runAvailable(
        report: inout SpeechAnalyzerSmokeReport,
        outputURL: URL,
        localeIdentifier: String,
        phrase: String,
        installAssets: Bool,
        requirePass: Bool
    ) async {
        report.sdkAvailable = true
        guard SpeechTranscriber.isAvailable else {
            report.issues.append("SpeechTranscriber is not available on this runtime.")
            write(report: report, to: outputURL)
            finish(report: report, requirePass: requirePass)
        }

        report.transcriberAvailable = true
        let requestedLocale = Locale(identifier: localeIdentifier)
        guard let supportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
            report.issues.append("No SpeechTranscriber locale equivalent was found for \(localeIdentifier).")
            write(report: report, to: outputURL)
            finish(report: report, requirePass: requirePass)
        }

        report.resolvedLocaleIdentifier = supportedLocale.identifier
        let transcriber = SpeechTranscriber(
            locale: supportedLocale,
            preset: .timeIndexedTranscriptionWithAlternatives
        )
        let modules: [any SpeechModule] = [transcriber]
        let assetStatus = await AssetInventory.status(forModules: modules)
        report.assetStatus = String(describing: assetStatus)
        let compatibleFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules)
        report.compatibleAudioFormatDescription = compatibleFormat.map(describe(format:))

        guard await prepareAssetsIfNeeded(
            modules: modules,
            currentStatus: assetStatus,
            installAssets: installAssets,
            report: &report
        ) else {
            write(report: report, to: outputURL)
            finish(report: report, requirePass: requirePass)
        }

        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultSpeechAnalyzerFixtureSmoke-\(UUID().uuidString)", isDirectory: true)
        let fixtureURL = tempDirectory.appendingPathComponent("synthetic-fixture.aiff")

        do {
            try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
            try generateSyntheticSpeech(phrase: phrase, outputURL: fixtureURL)
            report.fixtureAudioGenerated = true

            let segments = try await withTimeout(seconds: 30, label: "SpeechAnalyzer fixture recognition") {
                try await transcribeFixture(at: fixtureURL, transcriber: transcriber, modules: modules)
            }
            let transcriptText = segments.map(\.text).joined(separator: " ")
            report.transcriptionStatus = "pass"
            report.transcriptText = transcriptText
            report.segmentCount = segments.count
            report.containsExpectedKeywords = containsExpectedKeywords(transcriptText)
            if report.containsExpectedKeywords {
                report.status = "pass"
            } else {
                report.status = "fail"
                report.issues.append("SpeechAnalyzer completed but did not recognize all expected synthetic keywords.")
            }
        } catch {
            report.status = "fail"
            report.transcriptionStatus = "fail"
            report.issues.append(error.localizedDescription)
        }

        try? FileManager.default.removeItem(at: tempDirectory)
        report.fixtureAudioDeleted = !FileManager.default.fileExists(atPath: fixtureURL.path)
        write(report: report, to: outputURL)
        finish(report: report, requirePass: requirePass)
    }

    @available(macOS 26.0, *)
    static func prepareAssetsIfNeeded(
        modules: [any SpeechModule],
        currentStatus: AssetInventory.Status,
        installAssets: Bool,
        report: inout SpeechAnalyzerSmokeReport
    ) async -> Bool {
        guard currentStatus != .installed else {
            return true
        }

        guard installAssets else {
            report.issues.append("SpeechAnalyzer assets are \(String(describing: currentStatus)). The smoke did not request downloads, open the microphone, or generate fixture audio. Rerun with --install-assets only after explicit operator approval.")
            return false
        }

        report.assetPreparationRequested = true
        do {
            guard let request = try await AssetInventory.assetInstallationRequest(supporting: modules) else {
                report.issues.append("SpeechAnalyzer assets are \(String(describing: currentStatus)), but no asset installation request was available.")
                return false
            }
            report.downloadRequested = true
            try await withTimeout(seconds: 600, label: "SpeechAnalyzer asset installation") {
                try await request.downloadAndInstall()
            }
            let refreshedStatus = await AssetInventory.status(forModules: modules)
            report.assetStatus = String(describing: refreshedStatus)
            if refreshedStatus == .installed {
                return true
            }
            report.issues.append("SpeechAnalyzer asset installation completed without reaching installed status: \(String(describing: refreshedStatus)).")
            return false
        } catch {
            report.status = "fail"
            report.transcriptionStatus = "not-run"
            report.issues.append(error.localizedDescription)
            return false
        }
    }

    @available(macOS 26.0, *)
    static func transcribeFixture(
        at url: URL,
        transcriber: SpeechTranscriber,
        modules: [any SpeechModule]
    ) async throws -> [SpeechAnalyzerSmokeSegment] {
        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: url)
        } catch {
            throw SpeechAnalyzerSmokeError.audioFileOpenFailed(error.localizedDescription)
        }

        let analyzer = SpeechAnalyzer(modules: modules)
        do {
            async let collectedResults = collectResults(from: transcriber)
            try await analyzer.prepareToAnalyze(in: audioFile.processingFormat)
            _ = try await analyzer.analyzeSequence(from: audioFile)
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            return try await collectedResults
        } catch {
            throw SpeechAnalyzerSmokeError.recognitionFailed(error.localizedDescription)
        }
    }

    @available(macOS 26.0, *)
    static func collectResults(from transcriber: SpeechTranscriber) async throws -> [SpeechAnalyzerSmokeSegment] {
        var segments: [SpeechAnalyzerSmokeSegment] = []
        for try await result in transcriber.results {
            let text = String(result.text.characters)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            segments.append(
                SpeechAnalyzerSmokeSegment(
                    text: text,
                    startTime: max(0, CMTimeGetSeconds(result.range.start)),
                    endTime: max(0.1, CMTimeGetSeconds(result.range.end)),
                    isFinal: result.isFinal
                )
            )
        }
        return segments
    }

    static func generateSyntheticSpeech(phrase: String, outputURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = [
            "-v", "Samantha",
            "--data-format=LEI16@16000",
            "-o", outputURL.path,
            phrase
        ]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(decoding: errorData, as: UTF8.self)
            throw SpeechAnalyzerSmokeError.fixtureGenerationFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    static func containsExpectedKeywords(_ text: String) -> Bool {
        let normalized = text.lowercased()
        return defaultKeywords.allSatisfy { normalized.contains($0) }
    }

    static func describe(format: AVAudioFormat) -> String {
        let sampleRate = Int(format.sampleRate.rounded())
        return "\(sampleRate) Hz, \(format.channelCount) channel(s), \(describe(commonFormat: format.commonFormat))"
    }

    static func describe(commonFormat: AVAudioCommonFormat) -> String {
        switch commonFormat {
        case .pcmFormatFloat32:
            "32-bit float PCM"
        case .pcmFormatFloat64:
            "64-bit float PCM"
        case .pcmFormatInt16:
            "16-bit integer PCM"
        case .pcmFormatInt32:
            "32-bit integer PCM"
        case .otherFormat:
            "other audio format"
        @unknown default:
            "unknown audio format"
        }
    }

    static func withTimeout<T: Sendable>(
        seconds: UInt64,
        label: String,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                throw SpeechAnalyzerSmokeError.timeout(label)
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    static func write(report: SpeechAnalyzerSmokeReport, to outputURL: URL) {
        do {
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(report)
            try data.write(to: outputURL, options: [.atomic])
            print("[OK] SpeechAnalyzer fixture smoke wrote \(outputURL.path) status=\(report.status)")
        } catch {
            fputs("failed to write smoke report: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    static func finish(report: SpeechAnalyzerSmokeReport, requirePass: Bool) -> Never {
        if report.status == "pass" || !requirePass {
            exit(0)
        }
        exit(1)
    }
}

Task {
    await SpeechAnalyzerFixtureSmoke.run()
}
dispatchMain()
