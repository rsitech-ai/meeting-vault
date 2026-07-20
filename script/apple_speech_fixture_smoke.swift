#!/usr/bin/env swift
import AVFoundation
import Dispatch
import Foundation
import Speech

struct SmokeReport: Codable {
    var timestamp: String
    var status: String
    var finalStatus: String
    var liveStatus: String
    var authorizationState: String
    var permissionRequestRequested: Bool
    var permissionRequestAttempted: Bool
    var permissionRequestBlockedReason: String?
    var localeIdentifier: String
    var usedSyntheticSpeechFixture: Bool
    var privateAudioRecorded: Bool
    var microphoneOpened: Bool
    var fixtureAudioGenerated: Bool
    var fixtureAudioDeleted: Bool
    var syntheticTextStored: Bool
    var expectedKeywords: [String]
    var finalTranscriptText: String?
    var finalContainsExpectedKeywords: Bool
    var finalConfidence: Double?
    var liveTranscriptText: String?
    var liveContainsExpectedKeywords: Bool
    var livePartialEventCount: Int
    var issues: [String]
}

enum SmokeError: Error, LocalizedError {
    case timeout(String)
    case recognizerUnavailable(String)
    case recognizerNotReady(String)
    case recognitionFailed(String)
    case missingResult(String)
    case fixtureGenerationFailed(String)

    var errorDescription: String? {
        switch self {
        case let .timeout(label):
            return "\(label) timed out"
        case let .recognizerUnavailable(locale):
            return "Apple Speech recognizer is unavailable for \(locale)"
        case let .recognizerNotReady(locale):
            return "Apple Speech recognizer is not ready for \(locale)"
        case let .recognitionFailed(message):
            return "Apple Speech recognition failed: \(message)"
        case let .missingResult(label):
            return "\(label) returned no transcript"
        case let .fixtureGenerationFailed(message):
            return "Synthetic speech fixture generation failed: \(message)"
        }
    }
}

struct RecognitionOutput {
    var text: String
    var confidence: Double?
    var partialEventCount: Int
}

private final class RecognitionState: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    private var task: SFSpeechRecognitionTask?

    func setTask(_ task: SFSpeechRecognitionTask) {
        lock.withLock {
            self.task = task
        }
    }

    func resume<T>(
        _ continuation: CheckedContinuation<T, Error>,
        result: Result<T, Error>
    ) {
        let shouldResume = lock.withLock {
            guard !resumed else { return false }
            resumed = true
            task?.cancel()
            task = nil
            return true
        }
        guard shouldResume else { return }
        continuation.resume(with: result)
    }
}

struct AppleSpeechFixtureSmoke {
    static let appName = "MeetingVault"
    static let defaultPhrase = "MeetingVault synthetic smoke test. Consent, decisions, and action items stay local."
    static let defaultKeywords = ["consent", "decisions", "action"]

    static func run() async {
        let rootURL = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let date = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
        var outputURL = rootURL
            .appendingPathComponent("docs", isDirectory: true)
            .appendingPathComponent("evidence", isDirectory: true)
            .appendingPathComponent("apple-speech-fixture-smoke-\(date).json")
        var localeIdentifier = "en-US"
        var requirePass = false
        var requestPermission = false
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
            case "--request-permission":
                requestPermission = true
            case "--require-pass":
                requirePass = true
            case "--help", "-h":
                print("""
                usage: script/apple_speech_fixture_smoke.swift [--output PATH] [--locale en-US] [--phrase TEXT] [--request-permission] [--require-pass]

                Generates a non-private synthetic speech fixture with /usr/bin/say,
                checks current Speech Recognition authorization without prompting by default,
                then runs Apple Speech final URL recognition and buffer-fed live
                recognition over that fixture. It never opens the microphone and
                writes privacy-safe JSON evidence.

                Use --request-permission only when an operator intentionally approves
                a one-time macOS Speech Recognition permission prompt. The request is
                attempted only when the current executable bundle declares
                NSSpeechRecognitionUsageDescription; unbundled script runs fail closed.
                The supported app path is Diagnostics > Apple Speech Permission >
                Request Once. Recording and transcription starts do not request this
                permission.

                By default, blocked provider or permission state writes status=blocked
                and exits 0. Use --require-pass to turn blocked/fail into a non-zero
                exit for release gates that require real provider evidence.
                """)
                exit(0)
            default:
                fputs("unknown argument: \(argument)\n", stderr)
                exit(2)
            }
        }

        var authorizationState = speechAuthorizationState()
        var permissionRequestAttempted = false
        var permissionRequestBlockedReason: String?
        if authorizationState == "notDetermined", requestPermission {
            if canRequestSpeechAuthorizationFromCurrentExecutable() {
                permissionRequestAttempted = true
                authorizationState = await requestSpeechAuthorizationState()
            } else {
                permissionRequestBlockedReason = "the current executable bundle does not declare NSSpeechRecognitionUsageDescription"
            }
        }
        var report = SmokeReport(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            status: "blocked",
            finalStatus: "not-run",
            liveStatus: "not-run",
            authorizationState: authorizationState,
            permissionRequestRequested: requestPermission,
            permissionRequestAttempted: permissionRequestAttempted,
            permissionRequestBlockedReason: permissionRequestBlockedReason,
            localeIdentifier: localeIdentifier,
            usedSyntheticSpeechFixture: true,
            privateAudioRecorded: false,
            microphoneOpened: false,
            fixtureAudioGenerated: false,
            fixtureAudioDeleted: false,
            syntheticTextStored: true,
            expectedKeywords: defaultKeywords,
            finalTranscriptText: nil,
            finalContainsExpectedKeywords: false,
            finalConfidence: nil,
            liveTranscriptText: nil,
            liveContainsExpectedKeywords: false,
            livePartialEventCount: 0,
            issues: []
        )

        guard authorizationState == "authorized" else {
            if let permissionRequestBlockedReason {
                report.issues.append("Speech Recognition permission request was not attempted because \(permissionRequestBlockedReason). Use Diagnostics Request Once in MeetingVault.app, then rerun this smoke with --require-pass.")
            } else if requestPermission {
                report.issues.append("Speech Recognition is \(authorizationState) after an explicit permission request. The smoke did not open the microphone.")
            } else {
                report.issues.append("Speech Recognition is \(authorizationState). The smoke did not request permission or open the microphone. Use script/apple_speech_permission_smoke.swift to verify the app-owned permission path, then rerun this smoke only after provider authorization is available to this executable.")
            }
            write(report: report, to: outputURL)
            finish(report: report, requirePass: requirePass)
        }

        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultAppleSpeechFixtureSmoke-\(UUID().uuidString)", isDirectory: true)
        let fixtureURL = tempDirectory.appendingPathComponent("synthetic-fixture.aiff")

        do {
            try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
            try generateSyntheticSpeech(phrase: phrase, outputURL: fixtureURL)
            report.fixtureAudioGenerated = true

            let locale = Locale(identifier: localeIdentifier)
            let final = try await recognizeURLFixture(at: fixtureURL, locale: locale, label: "final Apple Speech fixture recognition")
            report.finalStatus = "pass"
            report.finalTranscriptText = final.text
            report.finalConfidence = final.confidence
            report.finalContainsExpectedKeywords = containsExpectedKeywords(final.text)

            let live = try await recognizeBufferedFixture(at: fixtureURL, locale: locale)
            report.liveStatus = "pass"
            report.liveTranscriptText = live.text
            report.livePartialEventCount = live.partialEventCount
            report.liveContainsExpectedKeywords = containsExpectedKeywords(live.text)

            if report.finalContainsExpectedKeywords && report.liveContainsExpectedKeywords {
                report.status = "pass"
            } else {
                report.status = "fail"
                report.issues.append("Apple Speech completed but did not recognize all expected synthetic keywords.")
            }
        } catch {
            report.status = "fail"
            if report.finalStatus == "not-run" {
                report.finalStatus = "fail"
            }
            if report.liveStatus == "not-run", report.finalStatus == "pass" {
                report.liveStatus = "fail"
            }
            report.issues.append(error.localizedDescription)
        }

        try? FileManager.default.removeItem(at: tempDirectory)
        report.fixtureAudioDeleted = !FileManager.default.fileExists(atPath: fixtureURL.path)
        write(report: report, to: outputURL)
        finish(report: report, requirePass: requirePass)
    }

    static func speechAuthorizationState() -> String {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return "authorized"
        case .denied:
            return "denied"
        case .restricted:
            return "restricted"
        case .notDetermined:
            return "notDetermined"
        @unknown default:
            return "unknown"
        }
    }

    static func requestSpeechAuthorizationState() async -> String {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                switch status {
                case .authorized:
                    continuation.resume(returning: "authorized")
                case .denied:
                    continuation.resume(returning: "denied")
                case .restricted:
                    continuation.resume(returning: "restricted")
                case .notDetermined:
                    continuation.resume(returning: "notDetermined")
                @unknown default:
                    continuation.resume(returning: "unknown")
                }
            }
        }
    }

    static func canRequestSpeechAuthorizationFromCurrentExecutable() -> Bool {
        guard let usageDescription = Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") as? String else {
            return false
        }
        return !usageDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
            throw SmokeError.fixtureGenerationFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    static func recognizeURLFixture(
        at url: URL,
        locale: Locale,
        label: String
    ) async throws -> RecognitionOutput {
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            throw SmokeError.recognizerUnavailable(locale.identifier)
        }
        guard recognizer.isAvailable else {
            throw SmokeError.recognizerNotReady(locale.identifier)
        }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false

        let result = try await recognitionTask(label: label) { state, continuation in
            let task = recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    state.resume(continuation, result: .success(result))
                    return
                }
                if let error {
                    state.resume(continuation, result: .failure(SmokeError.recognitionFailed(error.localizedDescription)))
                }
            }
            state.setTask(task)
        }

        return output(from: result, partialEventCount: 0)
    }

    static func recognizeBufferedFixture(
        at url: URL,
        locale: Locale
    ) async throws -> RecognitionOutput {
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            throw SmokeError.recognizerUnavailable(locale.identifier)
        }
        guard recognizer.isAvailable else {
            throw SmokeError.recognizerNotReady(locale.identifier)
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true

        let box = BufferedRecognitionBox()
        async let recognition = recognitionTask(label: "buffer-fed live Apple Speech fixture recognition") { state, continuation in
            let task = recognizer.recognitionTask(with: request) { result, error in
                if let result {
                    box.record(result)
                    if result.isFinal {
                        state.resume(continuation, result: .success(result))
                        return
                    }
                }
                if let error {
                    state.resume(continuation, result: .failure(SmokeError.recognitionFailed(error.localizedDescription)))
                }
            }
            state.setTask(task)
        }

        try appendAudioFile(at: url, to: request)
        request.endAudio()

        let result = try await recognition
        return output(from: result, partialEventCount: box.partialEventCount)
    }

    static func appendAudioFile(
        at url: URL,
        to request: SFSpeechAudioBufferRecognitionRequest
    ) throws {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let chunkSize: AVAudioFrameCount = 4_096
        while file.framePosition < file.length {
            let remaining = AVAudioFrameCount(file.length - file.framePosition)
            let framesToRead = min(chunkSize, remaining)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: framesToRead) else {
                throw SmokeError.recognitionFailed("Could not allocate audio buffer")
            }
            try file.read(into: buffer, frameCount: framesToRead)
            if buffer.frameLength > 0 {
                request.append(buffer)
            }
        }
    }

    fileprivate static func recognitionTask(
        label: String,
        start: @escaping (RecognitionState, CheckedContinuation<SFSpeechRecognitionResult, Error>) -> Void
    ) async throws -> SFSpeechRecognitionResult {
        try await withCheckedThrowingContinuation { continuation in
            let state = RecognitionState()
            start(state, continuation)
            Task {
                try? await Task.sleep(nanoseconds: 25_000_000_000)
                state.resume(continuation, result: .failure(SmokeError.timeout(label)))
            }
        }
    }

    static func output(
        from result: SFSpeechRecognitionResult,
        partialEventCount: Int
    ) -> RecognitionOutput {
        let transcription = result.bestTranscription
        let confidences = transcription.segments.map(\.confidence)
        let confidence = confidences.isEmpty
            ? nil
            : Double(confidences.reduce(0, +) / Float(confidences.count))
        return RecognitionOutput(
            text: transcription.formattedString,
            confidence: confidence,
            partialEventCount: partialEventCount
        )
    }

    static func containsExpectedKeywords(_ text: String) -> Bool {
        let normalized = text.lowercased()
        return defaultKeywords.allSatisfy { normalized.contains($0) }
    }

    static func write(report: SmokeReport, to outputURL: URL) {
        do {
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(report)
            try data.write(to: outputURL, options: [.atomic])
            print("[OK] Apple Speech fixture smoke wrote \(outputURL.path) status=\(report.status)")
        } catch {
            fputs("failed to write smoke report: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    static func finish(report: SmokeReport, requirePass: Bool) -> Never {
        if report.status == "pass" || !requirePass {
            exit(0)
        }
        exit(1)
    }
}

private final class BufferedRecognitionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var partials = 0

    var partialEventCount: Int {
        lock.withLock { partials }
    }

    func record(_ result: SFSpeechRecognitionResult) {
        guard !result.isFinal else { return }
        lock.withLock {
            partials += 1
        }
    }
}

Task {
    await AppleSpeechFixtureSmoke.run()
}
dispatchMain()
