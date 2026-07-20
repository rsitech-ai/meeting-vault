import Foundation
import MeetingVaultCore

struct AppShortcutsCatalogSmokeReport: Codable {
    var timestamp: String
    var status: String
    var coreShortcutCount: Int
    var appShortcutDefinitionCount: Int
    var matchedShortcutCount: Int
    var missingIntentCount: Int
    var mismatchedShortcutCount: Int
    var externalActionExposed: Bool
    var shortcutsInvoked: Bool
    var siriInvoked: Bool
    var captureDeviceOpened: Bool
    var externalNetworkRequested: Bool
    var externalUploadAttempted: Bool
    var rawTranscriptStored: Bool
    var rawAudioStored: Bool
    var rawLogsStored: Bool
    var rawUITextStored: Bool
    var issues: [String]
}

struct AppShortcutExpectation {
    var shortcut: MeetingAutomationShortcut
    var intentType: String
}

enum AppShortcutsCatalogSmoke {
    static func main() {
        var outputURL: URL?
        var requirePass = false
        var iterator = CommandLine.arguments.dropFirst().makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--output":
                guard let value = iterator.next(), !value.isEmpty else {
                    fputs("--output requires a path\n", stderr)
                    exit(2)
                }
                outputURL = URL(fileURLWithPath: value)
            case "--require-pass":
                requirePass = true
            case "--help", "-h":
                print("""
                usage: MeetingVaultAppShortcutsCatalogSmoke [--output PATH] [--require-pass]

                Verifies the Swift App Shortcuts source matches the tested core
                MeetingAutomationShortcutCatalog. This smoke does not invoke
                Shortcuts or Siri, launch capture devices, upload, or store raw
                transcript/audio/log/UI text.
                """)
                exit(0)
            default:
                fputs("unknown argument: \(argument)\n", stderr)
                exit(2)
            }
        }

        let rootURL = repositoryRoot()
        let appIntentsURL = rootURL
            .appendingPathComponent("Sources", isDirectory: true)
            .appendingPathComponent("MeetingVault", isDirectory: true)
            .appendingPathComponent("App", isDirectory: true)
            .appendingPathComponent("MeetingVaultAppIntents.swift")
        let report = buildReport(appIntentsURL: appIntentsURL)
        if let outputURL {
            do {
                try FileManager.default.createDirectory(
                    at: outputURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(report).write(to: outputURL, options: .atomic)
            } catch {
                fputs("failed to write app shortcuts catalog smoke: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
            print("Wrote \(outputURL.path)")
        }
        print(
            "status=\(report.status) matchedShortcutCount=\(report.matchedShortcutCount) " +
            "mismatchedShortcutCount=\(report.mismatchedShortcutCount)"
        )
        if requirePass, report.status != "pass" {
            exit(1)
        }
        exit(report.status == "pass" ? 0 : 1)
    }

    private static func repositoryRoot() -> URL {
        let cwd = FileManager.default.currentDirectoryPath
        return URL(fileURLWithPath: cwd, isDirectory: true)
    }

    private static func buildReport(appIntentsURL: URL) -> AppShortcutsCatalogSmokeReport {
        var issues: [String] = []
        let source = (try? String(contentsOf: appIntentsURL, encoding: .utf8)) ?? ""
        if source.isEmpty {
            issues.append("MeetingVaultAppIntents.swift is missing or unreadable.")
        }

        let expectations = MeetingAutomationShortcutCatalog.shortcuts.compactMap(expectation)
        let appShortcutDefinitionCount = source.components(separatedBy: "AppShortcut(").count - 1
        var matchedShortcutCount = 0
        var missingIntentCount = 0
        var mismatchedShortcutCount = 0

        if appShortcutDefinitionCount != expectations.count {
            issues.append(
                "AppShortcutsProvider defines \(appShortcutDefinitionCount) shortcuts; expected \(expectations.count)."
            )
        }

        for expectation in expectations {
            let shortcut = expectation.shortcut
            let intentType = expectation.intentType
            var localIssues: [String] = []
            if !source.contains("struct \(intentType): AppIntent") {
                localIssues.append("missing AppIntent struct \(intentType)")
                missingIntentCount += 1
            }
            if !source.contains("intent: \(intentType)()") {
                localIssues.append("missing AppShortcut entry for \(intentType)")
            }
            if !source.contains("shortTitle: \"\(shortcut.title)\"") {
                localIssues.append("shortTitle for \(intentType) does not match core title \(shortcut.title)")
            }
            if !source.contains("systemImageName: \"\(shortcut.systemImageName)\"") {
                localIssues.append("systemImageName for \(intentType) does not match \(shortcut.systemImageName)")
            }
            for phrase in shortcut.phraseTemplates.map(appShortcutPhrase) where !source.contains("\"\(phrase)\"") {
                localIssues.append("missing phrase for \(intentType): \(phrase)")
            }
            if source.contains("struct \(intentType): AppIntent"),
               !intentBlock(for: intentType, in: source).contains("static let openAppWhenRun = true") {
                localIssues.append("\(intentType) must open the app when run")
            }

            if localIssues.isEmpty {
                matchedShortcutCount += 1
            } else {
                mismatchedShortcutCount += 1
                issues.append(contentsOf: localIssues)
            }
        }

        let externalActionExposed = source.contains("sendWebhook") || source.contains("externalNetwork")
        if externalActionExposed {
            issues.append("App Shortcuts source exposes an external action.")
        }

        return AppShortcutsCatalogSmokeReport(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            status: issues.isEmpty ? "pass" : "fail",
            coreShortcutCount: MeetingAutomationShortcutCatalog.shortcuts.count,
            appShortcutDefinitionCount: appShortcutDefinitionCount,
            matchedShortcutCount: matchedShortcutCount,
            missingIntentCount: missingIntentCount,
            mismatchedShortcutCount: mismatchedShortcutCount,
            externalActionExposed: externalActionExposed,
            shortcutsInvoked: false,
            siriInvoked: false,
            captureDeviceOpened: false,
            externalNetworkRequested: false,
            externalUploadAttempted: false,
            rawTranscriptStored: false,
            rawAudioStored: false,
            rawLogsStored: false,
            rawUITextStored: false,
            issues: issues
        )
    }

    private static func expectation(for shortcut: MeetingAutomationShortcut) -> AppShortcutExpectation? {
        let intentType: String
        switch shortcut.action {
        case .openRecorder:
            intentType = "OpenMeetingVaultRecorderIntent"
        case .runPreflight:
            intentType = "CheckMeetingVaultReadinessIntent"
        case .startRecording:
            intentType = "StartMeetingVaultRecordingIntent"
        case .stopRecording:
            intentType = "StopMeetingVaultRecordingIntent"
        case .prepareShare:
            intentType = "PrepareMeetingVaultShareIntent"
        case .sendWebhook:
            return nil
        }
        return AppShortcutExpectation(shortcut: shortcut, intentType: intentType)
    }

    private static func appShortcutPhrase(_ phrase: String) -> String {
        phrase.replacingOccurrences(of: "MeetingVault", with: "\\(.applicationName)")
    }

    private static func intentBlock(for intentType: String, in source: String) -> String {
        guard let startRange = source.range(of: "struct \(intentType): AppIntent") else { return "" }
        let remainder = source[startRange.lowerBound...]
        if let nextRange = remainder.range(of: "\nstruct ", options: [], range: remainder.index(after: startRange.lowerBound)..<remainder.endIndex) {
            return String(remainder[..<nextRange.lowerBound])
        }
        return String(remainder)
    }
}

AppShortcutsCatalogSmoke.main()
