#!/usr/bin/env swift
import Foundation

struct LocalRecordingImportSmokeReport: Codable {
    var timestamp: String
    var status: String
    var requireLocalSamples: Bool
    var transcriptDirectoryProvided: Bool
    var recordingDirectoryProvided: Bool
    var transcriptDirectoryExists: Bool
    var recordingDirectoryExists: Bool
    var matchedLocalSampleCount: Int
    var matchedAudioFormatCounts: [String: Int]
    var longTranscriptSampleAvailable: Bool
    var coreImportTestsExitCode: Int32
    var appWorkflowTestsExitCode: Int32
    var syntheticImportTestsPassed: Bool
    var appWorkflowTestsPassed: Bool
    var localSampleProofPassed: Bool
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

struct TestRun {
    var exitCode: Int32
}

enum LocalRecordingImportSmoke {
    static func main() {
        let rootURL = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let date = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
        var outputURL = rootURL
            .appendingPathComponent("docs", isDirectory: true)
            .appendingPathComponent("evidence", isDirectory: true)
            .appendingPathComponent("local-recording-import-smoke-\(date).json")
        var transcriptDirectory = envURL("MEETINGVAULT_LOCAL_TRANSCRIPT_SAMPLE_DIR")
        var recordingDirectory = envURL("MEETINGVAULT_LOCAL_RECORDING_DIR")
        var requireLocalSamples = false

        var iterator = CommandLine.arguments.dropFirst().makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--output":
                guard let value = iterator.next() else {
                    fputs("--output requires a path\n", stderr)
                    exit(2)
                }
                outputURL = URL(fileURLWithPath: value)
            case "--transcript-dir":
                guard let value = iterator.next() else {
                    fputs("--transcript-dir requires a path\n", stderr)
                    exit(2)
                }
                transcriptDirectory = URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
            case "--recording-dir":
                guard let value = iterator.next() else {
                    fputs("--recording-dir requires a path\n", stderr)
                    exit(2)
                }
                recordingDirectory = URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
            case "--require-local-samples":
                requireLocalSamples = true
            case "--help", "-h":
                print("""
                usage: script/local_recording_import_smoke.swift [--output PATH] [--transcript-dir PATH] [--recording-dir PATH] [--require-local-samples]

                Runs bounded local recording import verification without storing
                raw transcript, audio, UI, or log output. The smoke exercises the
                core import tests and app transcript-agent import workflow tests.
                Optional local sample directories are used only for count-based
                proof and for the existing env-configured optional import tests.
                """)
                exit(0)
            default:
                fputs("unknown argument: \(argument)\n", stderr)
                exit(2)
            }
        }

        let transcriptExists = transcriptDirectory.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        let recordingExists = recordingDirectory.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        let localSampleReport = discoverLocalSamples(
            transcriptDirectory: transcriptDirectory,
            recordingDirectory: recordingDirectory
        )
        var environment = ProcessInfo.processInfo.environment
        if let transcriptDirectory, let recordingDirectory {
            environment["MEETINGVAULT_LOCAL_TRANSCRIPT_SAMPLE_DIR"] = transcriptDirectory.path
            environment["MEETINGVAULT_LOCAL_RECORDING_DIR"] = recordingDirectory.path
        }

        let coreImportTests = runSwiftTest(
            rootURL: rootURL,
            filter: "LocalRecordingImportTests",
            environment: environment
        )
        let appWorkflowTests = runSwiftTest(
            rootURL: rootURL,
            filter: "MeetingVaultStoreSelectionTests/testLocalRecording",
            environment: environment
        )

        let localSampleProofPassed = !requireLocalSamples
            || (transcriptExists
                && recordingExists
                && localSampleReport.matchedSampleCount > 50
                && (localSampleReport.audioFormatCounts["mp3"] ?? 0) > 0
                && localSampleReport.longTranscriptSampleAvailable)
        var issues: [String] = []
        if coreImportTests.exitCode != 0 {
            issues.append("LocalRecordingImportTests failed.")
        }
        if appWorkflowTests.exitCode != 0 {
            issues.append("MeetingVaultStoreSelectionTests local recording workflow tests failed.")
        }
        if requireLocalSamples && !transcriptExists {
            issues.append("Required local transcript sample directory is missing.")
        }
        if requireLocalSamples && !recordingExists {
            issues.append("Required local recording directory is missing.")
        }
        if requireLocalSamples && localSampleReport.matchedSampleCount <= 50 {
            issues.append("Required local transcript/audio matched sample count is too low.")
        }
        if requireLocalSamples && (localSampleReport.audioFormatCounts["mp3"] ?? 0) == 0 {
            issues.append("Required local transcript/audio samples did not include a matched MP3 recording.")
        }
        if requireLocalSamples && !localSampleReport.longTranscriptSampleAvailable {
            issues.append("Required long local transcript sample was not found.")
        }

        let report = LocalRecordingImportSmokeReport(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            status: issues.isEmpty ? "pass" : "blocked",
            requireLocalSamples: requireLocalSamples,
            transcriptDirectoryProvided: transcriptDirectory != nil,
            recordingDirectoryProvided: recordingDirectory != nil,
            transcriptDirectoryExists: transcriptExists,
            recordingDirectoryExists: recordingExists,
            matchedLocalSampleCount: localSampleReport.matchedSampleCount,
            matchedAudioFormatCounts: localSampleReport.audioFormatCounts,
            longTranscriptSampleAvailable: localSampleReport.longTranscriptSampleAvailable,
            coreImportTestsExitCode: coreImportTests.exitCode,
            appWorkflowTestsExitCode: appWorkflowTests.exitCode,
            syntheticImportTestsPassed: coreImportTests.exitCode == 0,
            appWorkflowTestsPassed: appWorkflowTests.exitCode == 0,
            localSampleProofPassed: localSampleProofPassed,
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

        do {
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: outputURL, options: .atomic)
        } catch {
            fputs("failed to write local recording import smoke report: \(error.localizedDescription)\n", stderr)
            exit(1)
        }

        print("Wrote \(outputURL.path)")
        print("status=\(report.status) matchedLocalSampleCount=\(report.matchedLocalSampleCount) requireLocalSamples=\(report.requireLocalSamples)")
        exit(report.status == "pass" ? 0 : 1)
    }

    private static func runSwiftTest(
        rootURL: URL,
        filter: String,
        environment: [String: String]
    ) -> TestRun {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        process.arguments = ["test", "--filter", filter]
        process.currentDirectoryURL = rootURL
        process.environment = environment
        let sink = Pipe()
        process.standardOutput = sink
        process.standardError = sink
        do {
            try process.run()
            sink.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return TestRun(exitCode: process.terminationStatus)
        } catch {
            return TestRun(exitCode: 127)
        }
    }

    private static func envURL(_ key: String) -> URL? {
        guard let value = ProcessInfo.processInfo.environment[key],
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
    }

    private static func discoverLocalSamples(
        transcriptDirectory: URL?,
        recordingDirectory: URL?
    ) -> (
        matchedSampleCount: Int,
        audioFormatCounts: [String: Int],
        longTranscriptSampleAvailable: Bool
    ) {
        guard let transcriptDirectory,
              let recordingDirectory,
              FileManager.default.fileExists(atPath: transcriptDirectory.path),
              FileManager.default.fileExists(atPath: recordingDirectory.path) else {
            return (0, [:], false)
        }

        let transcriptURLs = listFiles(in: transcriptDirectory)
            .filter { $0.pathExtension.lowercased() == "txt" }
        let audioURLsByKey = Dictionary(
            grouping: listFiles(in: recordingDirectory)
                .filter { ["mp3", "m4a", "wav", "aif", "aiff", "caf"].contains($0.pathExtension.lowercased()) },
            by: { timestampKey($0) ?? "" }
        )
            .filter { !$0.key.isEmpty }
        var matchedCount = 0
        var audioFormatCounts: [String: Int] = [:]
        var longTranscript = false
        for transcriptURL in transcriptURLs {
            guard let key = timestampKey(transcriptURL),
                  let audioURLs = audioURLsByKey[key],
                  let selectedAudioURL = audioURLs.sorted(by: preferredAudioOrder).first else {
                continue
            }
            matchedCount += 1
            audioFormatCounts[selectedAudioURL.pathExtension.lowercased(), default: 0] += 1
            if transcriptLineCount(at: transcriptURL) > 50 {
                longTranscript = true
            }
        }
        return (matchedCount, audioFormatCounts, longTranscript)
    }

    private static func preferredAudioOrder(_ lhs: URL, _ rhs: URL) -> Bool {
        let supportedOrder = ["mp3", "m4a", "wav", "aif", "aiff", "caf"]
        let lhsRank = supportedOrder.firstIndex(of: lhs.pathExtension.lowercased()) ?? supportedOrder.count
        let rhsRank = supportedOrder.firstIndex(of: rhs.pathExtension.lowercased()) ?? supportedOrder.count
        if lhsRank != rhsRank { return lhsRank < rhsRank }
        return lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
    }

    private static func listFiles(in directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return enumerator.compactMap { item in
            guard let url = item as? URL else { return nil }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            return values?.isRegularFile == true ? url : nil
        }
    }

    private static func timestampKey(_ url: URL) -> String? {
        let name = url.deletingPathExtension().lastPathComponent
        let pattern = #"(\d{8})[ _-]?(\d{4})"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
              let dateRange = Range(match.range(at: 1), in: name),
              let timeRange = Range(match.range(at: 2), in: name) else {
            return nil
        }
        return "\(name[dateRange]) \(name[timeRange])"
    }

    private static func transcriptLineCount(at url: URL) -> Int {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return 0
        }
        return text
            .components(separatedBy: .newlines)
            .filter { $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[") }
            .count
    }
}

LocalRecordingImportSmoke.main()
