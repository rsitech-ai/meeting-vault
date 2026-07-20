import Foundation
import MeetingVaultCore

struct LogRedactionSmokeReport: Codable {
    var timestamp: String
    var status: String
    var redactionStatus: String
    var loggerScanStatus: String
    var sampleCount: Int
    var redactionMarkerCount: Int
    var loggerLineCount: Int
    var unsafeLoggerLineCount: Int
    var privateAudioRecorded: Bool
    var microphoneOpened: Bool
    var externalNetworkRequested: Bool
    var externalUploadAttempted: Bool
    var rawTranscriptStored: Bool
    var rawAudioStored: Bool
    var rawLogsStored: Bool
    var rawUITextStored: Bool
    var issues: [String]
}

struct UnsafeLoggerLine {
    var path: String
    var lineNumber: Int
    var reason: String
}

@main
struct MeetingVaultLogRedactionSmoke {
    static func main() {
        let rootURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let date = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
        var outputURL = rootURL
            .appendingPathComponent("docs", isDirectory: true)
            .appendingPathComponent("evidence", isDirectory: true)
            .appendingPathComponent("log-redaction-smoke-\(date).json")
        var requirePass = false

        var iterator = CommandLine.arguments.dropFirst().makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--output":
                guard let value = iterator.next() else {
                    fputs("--output requires a path\n", stderr)
                    exit(2)
                }
                outputURL = URL(fileURLWithPath: value)
            case "--require-pass":
                requirePass = true
            case "--help", "-h":
                print("""
                usage: script/log_redaction_smoke.swift [--output PATH] [--require-pass]

                Verifies MeetingVault's log redaction boundary over synthetic
                private-looking meeting content and scans app logger call sites
                for obvious raw transcript, prompt, response, audio path, or
                evidence quote payload logging. The smoke does not open capture
                devices, record audio, upload externally, or store raw logs.
                """)
                exit(0)
            default:
                fputs("unknown argument: \(argument)\n", stderr)
                exit(2)
            }
        }

        let redaction = runRedactionChecks()
        let loggerScan = scanLoggerCallSites(rootURL: rootURL)
        var issues = redaction.issues
        issues.append(contentsOf: loggerScan.unsafeLines.map {
            "\($0.path):\($0.lineNumber) \($0.reason)"
        })

        let status = issues.isEmpty ? "pass" : "fail"
        let report = LogRedactionSmokeReport(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            status: status,
            redactionStatus: redaction.issues.isEmpty ? "pass" : "fail",
            loggerScanStatus: loggerScan.unsafeLines.isEmpty ? "pass" : "fail",
            sampleCount: redaction.sampleCount,
            redactionMarkerCount: redaction.markerCount,
            loggerLineCount: loggerScan.loggerLineCount,
            unsafeLoggerLineCount: loggerScan.unsafeLines.count,
            privateAudioRecorded: false,
            microphoneOpened: false,
            externalNetworkRequested: false,
            externalUploadAttempted: false,
            rawTranscriptStored: false,
            rawAudioStored: false,
            rawLogsStored: false,
            rawUITextStored: false,
            issues: issues
        )

        write(report: report, to: outputURL)
        print("Wrote \(outputURL.path)")
        print("status=\(report.status) loggerLineCount=\(report.loggerLineCount) unsafeLoggerLineCount=\(report.unsafeLoggerLineCount)")

        if requirePass && report.status != "pass" {
            exit(1)
        }
    }

    private static func runRedactionChecks() -> (sampleCount: Int, markerCount: Int, issues: [String]) {
        let samples: [(label: String, message: String, forbidden: [String], required: [String])] = [
            (
                "secret and email",
                "token: abc123 owner=alex@example.com",
                ["abc123", "alex@example.com"],
                ["token=[redacted]", "[redacted-email]"]
            ),
            (
                "local path",
                "audioPath=/Users/example/Music/Recorder/2026 Private Meeting.mp3",
                ["/Users/example", "Recorder", "Private Meeting.mp3"],
                ["[redacted-path]"]
            ),
            (
                "transcript",
                "transcript: private roadmap and customer pricing details",
                ["private roadmap", "customer pricing"],
                ["transcript=[redacted-content]"]
            ),
            (
                "quote",
                "quote: ship after legal reviews the private customer list",
                ["private customer list"],
                ["quote=[redacted-content]"]
            )
        ]

        var markerCount = 0
        var issues: [String] = []
        for sample in samples {
            let redacted = LogRedactor.redact(sample.message)
            markerCount += redacted.components(separatedBy: "[redacted").count - 1
            for forbidden in sample.forbidden where redacted.localizedCaseInsensitiveContains(forbidden) {
                issues.append("\(sample.label) redaction leaked forbidden token '\(forbidden)'.")
            }
            for required in sample.required where !redacted.localizedCaseInsensitiveContains(required) {
                issues.append("\(sample.label) redaction missed required marker '\(required)'.")
            }
        }
        return (samples.count, markerCount, issues)
    }

    private static func scanLoggerCallSites(rootURL: URL) -> (loggerLineCount: Int, unsafeLines: [UnsafeLoggerLine]) {
        let sourceRoots = [
            rootURL.appendingPathComponent("Sources/MeetingVault", isDirectory: true),
            rootURL.appendingPathComponent("Sources/MeetingVaultCore", isDirectory: true)
        ]
        var loggerLineCount = 0
        var unsafeLines: [UnsafeLoggerLine] = []
        for sourceRoot in sourceRoots {
            for fileURL in swiftFiles(in: sourceRoot) {
                guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
                let relativePath = fileURL.path.replacingOccurrences(of: rootURL.path + "/", with: "")
                for (offset, line) in content.components(separatedBy: .newlines).enumerated() where line.contains("logger.") {
                    loggerLineCount += 1
                    for reason in unsafeLoggerReasons(line: line) {
                        unsafeLines.append(
                            UnsafeLoggerLine(
                                path: relativePath,
                                lineNumber: offset + 1,
                                reason: reason
                            )
                        )
                    }
                }
            }
        }
        return (loggerLineCount, unsafeLines)
    }

    private static func swiftFiles(in directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return enumerator.compactMap { item -> URL? in
            guard let url = item as? URL, url.pathExtension == "swift" else { return nil }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            return values?.isRegularFile == true ? url : nil
        }
        .sorted { $0.path < $1.path }
    }

    private static func unsafeLoggerReasons(line: String) -> [String] {
        let compact = line.replacingOccurrences(of: " ", with: "")
        let suspiciousTokens: [(String, String)] = [
            ("transcriptAskPrompt", "logger references the raw transcript prompt"),
            ("segment.text", "logger references raw transcript segment text"),
            ("trimmedEditedText", "logger references edited transcript text"),
            ("editedText", "logger references edited transcript text"),
            ("answerText", "logger references generated answer text"),
            ("quote", "logger references evidence quote content"),
            ("summary.oneParagraph", "logger references raw summary prose"),
            ("audioURL.path", "logger references a raw audio file path"),
            ("transcriptURL.path", "logger references a raw transcript file path"),
            ("localRecordingTranscriptPath", "logger references local transcript path"),
            ("localRecordingAudioPath", "logger references local audio path")
        ]

        var reasons = suspiciousTokens.compactMap { token, reason in
            compact.contains(token) ? reason : nil
        }
        if compact.contains("transcriptAskAnswerDraft") && !compact.contains("transcriptAskAnswerDraft.count") {
            reasons.append("logger references the editable agent response content")
        }
        return reasons
    }

    private static func write(report: LogRedactionSmokeReport, to outputURL: URL) {
        do {
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: outputURL, options: .atomic)
        } catch {
            fputs("failed to write log redaction smoke report: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
