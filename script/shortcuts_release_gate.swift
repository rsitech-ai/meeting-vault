#!/usr/bin/env swift
import Foundation

struct ShortcutsReleaseGateReport: Codable {
    var timestamp: String
    var status: String
    var requirePass: Bool
    var approvedReportPath: String?
    var readinessTarget: String
    var requiredScenarioCount: Int
    var passedScenarioCount: Int
    var requiredScenarios: [ShortcutsScenario]
    var validatedReport: ShortcutsApprovedReport?
    var shortcutsInvoked: Bool
    var siriInvoked: Bool
    var nonPrivateAudioConfirmed: Bool
    var appIntentHandoffObserved: Bool
    var appLaunchedFromIntent: Bool
    var preflightGateObserved: Bool
    var startStopIntentObserved: Bool
    var shareIntentReviewOnlyObserved: Bool
    var externalWriteAttempted: Bool
    var externalNetworkRequested: Bool
    var externalUploadAttempted: Bool
    var destructiveActionExecuted: Bool
    var privateAudioRecorded: Bool
    var microphoneOpened: Bool
    var rawUITextStored: Bool
    var rawTranscriptStored: Bool
    var rawAudioStored: Bool
    var rawLogsStored: Bool
    var issues: [String]
}

struct ShortcutsScenario: Codable {
    var id: String
    var title: String
    var requiredEvidence: [String]
    var status: String
}

struct ShortcutsApprovedReport: Codable {
    var status: String
    var sourceCommit: String?
    var appVersion: String?
    var tester: String?
    var testedAt: String?
    var machineDescription: String?
    var scenarios: [ApprovedShortcutsScenario]
    var evidenceArtifacts: [String]
    var shortcutsInvoked: Bool
    var siriInvoked: Bool
    var nonPrivateAudioConfirmed: Bool
    var appIntentHandoffObserved: Bool
    var appLaunchedFromIntent: Bool
    var preflightGateObserved: Bool
    var startStopIntentObserved: Bool
    var shareIntentReviewOnlyObserved: Bool
    var externalWriteAttempted: Bool
    var externalNetworkRequested: Bool
    var externalUploadAttempted: Bool
    var destructiveActionExecuted: Bool
    var privateAudioRecorded: Bool
    var microphoneOpened: Bool
    var rawUITextStored: Bool
    var rawTranscriptStored: Bool
    var rawAudioStored: Bool
    var rawLogsStored: Bool
    var notes: [String]?
}

struct ApprovedShortcutsScenario: Codable {
    var id: String
    var status: String
    var evidence: [String]
}

enum ShortcutsReleaseGate {
    static func main() {
        let rootURL = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let date = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
        var outputURL = rootURL
            .appendingPathComponent("docs", isDirectory: true)
            .appendingPathComponent("evidence", isDirectory: true)
            .appendingPathComponent("shortcuts-release-gate-\(date).json")
        var approvedReportURL: URL?
        var templateURL: URL?
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
            case "--approved-report":
                guard let value = iterator.next() else {
                    fputs("--approved-report requires a path\n", stderr)
                    exit(2)
                }
                approvedReportURL = URL(fileURLWithPath: value)
            case "--write-template":
                guard let value = iterator.next() else {
                    fputs("--write-template requires a path\n", stderr)
                    exit(2)
                }
                templateURL = URL(fileURLWithPath: value)
            case "--require-pass":
                requirePass = true
            case "--help", "-h":
                print("""
                usage: script/shortcuts_release_gate.swift [--output PATH] [--approved-report PATH] [--write-template PATH] [--require-pass]

                Writes the release-candidate Shortcuts/Siri/App Intents handoff
                gate. Default behavior is blocked and does not invoke Shortcuts,
                Siri, capture devices, sharing, network, uploads, destructive
                actions, Calendar, Contacts, Reminders, or other external stores.

                To pass, provide a bounded approved-report JSON from real OS
                Shortcuts or Siri QA. The report must prove app-intent handoff
                through MeetingVault's existing preflight, recording, and local
                share-review paths with no external side effects and no raw
                private content in evidence.
                """)
                exit(0)
            default:
                fputs("unknown argument: \(argument)\n", stderr)
                exit(2)
            }
        }

        let requiredScenarios = scenarioDefinitions()
        if let templateURL {
            writeTemplate(to: templateURL, requiredScenarios: requiredScenarios)
            print("Wrote template \(templateURL.path)")
            exit(0)
        }

        let validation = validateApprovedReport(at: approvedReportURL, requiredScenarios: requiredScenarios)
        let passedScenarioCount = validation.report?.scenarios
            .filter { $0.status == "pass" }
            .count ?? 0
        let status = validation.issues.isEmpty ? "pass" : "blocked"
        let scenarios = requiredScenarios.map { scenario in
            let approved = validation.report?.scenarios.first { $0.id == scenario.id }
            return ShortcutsScenario(
                id: scenario.id,
                title: scenario.title,
                requiredEvidence: scenario.requiredEvidence,
                status: approved?.status ?? "blocked"
            )
        }

        let report = ShortcutsReleaseGateReport(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            status: status,
            requirePass: requirePass,
            approvedReportPath: approvedReportURL?.path,
            readinessTarget: "release-candidate",
            requiredScenarioCount: requiredScenarios.count,
            passedScenarioCount: passedScenarioCount,
            requiredScenarios: scenarios,
            validatedReport: validation.report,
            shortcutsInvoked: validation.report?.shortcutsInvoked ?? false,
            siriInvoked: validation.report?.siriInvoked ?? false,
            nonPrivateAudioConfirmed: validation.report?.nonPrivateAudioConfirmed ?? false,
            appIntentHandoffObserved: validation.report?.appIntentHandoffObserved ?? false,
            appLaunchedFromIntent: validation.report?.appLaunchedFromIntent ?? false,
            preflightGateObserved: validation.report?.preflightGateObserved ?? false,
            startStopIntentObserved: validation.report?.startStopIntentObserved ?? false,
            shareIntentReviewOnlyObserved: validation.report?.shareIntentReviewOnlyObserved ?? false,
            externalWriteAttempted: validation.report?.externalWriteAttempted ?? false,
            externalNetworkRequested: validation.report?.externalNetworkRequested ?? false,
            externalUploadAttempted: validation.report?.externalUploadAttempted ?? false,
            destructiveActionExecuted: validation.report?.destructiveActionExecuted ?? false,
            privateAudioRecorded: validation.report?.privateAudioRecorded ?? false,
            microphoneOpened: validation.report?.microphoneOpened ?? false,
            rawUITextStored: validation.report?.rawUITextStored ?? false,
            rawTranscriptStored: validation.report?.rawTranscriptStored ?? false,
            rawAudioStored: validation.report?.rawAudioStored ?? false,
            rawLogsStored: validation.report?.rawLogsStored ?? false,
            issues: validation.issues
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
            fputs("failed to write Shortcuts release gate: \(error.localizedDescription)\n", stderr)
            exit(1)
        }

        print("Wrote \(outputURL.path)")
        print("status=\(report.status) passedScenarios=\(report.passedScenarioCount)/\(report.requiredScenarioCount)")
        exit(report.status == "pass" || !requirePass ? 0 : 1)
    }

    private static func validateApprovedReport(
        at url: URL?,
        requiredScenarios: [ShortcutsScenario]
    ) -> (report: ShortcutsApprovedReport?, issues: [String]) {
        guard let url else {
            return (nil, ["Shortcuts release gate requires --approved-report with bounded real OS Shortcuts/App Intents QA evidence."])
        }
        guard let data = try? Data(contentsOf: url) else {
            return (nil, ["Approved report could not be read at \(url.path)."])
        }
        let decoder = JSONDecoder()
        guard let report = try? decoder.decode(ShortcutsApprovedReport.self, from: data) else {
            return (nil, ["Approved report is not valid ShortcutsApprovedReport JSON."])
        }

        var issues: [String] = []
        if report.status != "pass" {
            issues.append("Approved report status is \(report.status); expected pass.")
        }
        if report.appVersion?.isEmpty ?? true {
            issues.append("Approved report must identify the tested app version.")
        }
        if report.sourceCommit?.isEmpty ?? true {
            issues.append("Approved report must identify the tested source commit.")
        }
        if report.tester?.isEmpty ?? true {
            issues.append("Approved report must identify the tester or QA role.")
        }
        if report.testedAt?.isEmpty ?? true {
            issues.append("Approved report must identify when Shortcuts/App Intents QA was run.")
        }
        if report.machineDescription?.isEmpty ?? true {
            issues.append("Approved report must describe the Mac, OS build, app install, and Shortcuts/Siri setup.")
        } else if containsPlaceholder(report.machineDescription ?? "") {
            issues.append("Approved report machine description contains a template placeholder.")
        }
        if report.evidenceArtifacts.isEmpty {
            issues.append("Approved report must list bounded evidence artifacts.")
        }
        appendPlaceholderIssues(values: report.evidenceArtifacts, label: "Approved report evidence artifact", to: &issues)

        let requiredIDs = Set(requiredScenarios.map(\.id))
        let supplied = Dictionary(uniqueKeysWithValues: report.scenarios.map { ($0.id, $0) })
        for required in requiredScenarios {
            guard let scenario = supplied[required.id] else {
                issues.append("Approved report is missing scenario \(required.id).")
                continue
            }
            if scenario.status != "pass" {
                issues.append("Scenario \(required.id) is \(scenario.status); expected pass.")
            }
            if scenario.evidence.isEmpty {
                issues.append("Scenario \(required.id) must list bounded evidence.")
            }
            appendPlaceholderIssues(values: scenario.evidence, label: "Scenario \(required.id) evidence", to: &issues)
        }
        for extra in supplied.keys where !requiredIDs.contains(extra) {
            issues.append("Approved report contains unknown scenario \(extra).")
        }

        if !report.shortcutsInvoked && !report.siriInvoked {
            issues.append("Approved report must prove at least one real Shortcuts or Siri invocation.")
        }
        if !report.nonPrivateAudioConfirmed {
            issues.append("Approved report must confirm only non-private audio or transcript fixtures were used.")
        }
        if !report.appIntentHandoffObserved { issues.append("Approved report must prove app-intent handoff was observed.") }
        if !report.appLaunchedFromIntent { issues.append("Approved report must prove MeetingVault launched or routed from an intent.") }
        if !report.preflightGateObserved { issues.append("Approved report must prove the readiness/preflight gate was reached through an intent.") }
        if !report.startStopIntentObserved { issues.append("Approved report must prove Start/Stop Recording intents route through visible app state.") }
        if !report.shareIntentReviewOnlyObserved { issues.append("Approved report must prove Prepare Local Share stays review-only.") }
        if report.externalWriteAttempted { issues.append("Approved report attempted an external write.") }
        if report.externalNetworkRequested { issues.append("Approved report requested external network.") }
        if report.externalUploadAttempted { issues.append("Approved report attempted external upload.") }
        if report.destructiveActionExecuted { issues.append("Approved report executed a destructive final action.") }
        if report.privateAudioRecorded { issues.append("Approved report recorded private audio.") }
        if report.rawUITextStored { issues.append("Approved report stored raw UI text.") }
        if report.rawTranscriptStored { issues.append("Approved report stored raw transcript text.") }
        if report.rawAudioStored { issues.append("Approved report stored raw audio.") }
        if report.rawLogsStored { issues.append("Approved report stored raw logs.") }

        return (report, issues)
    }

    private static func writeTemplate(to url: URL, requiredScenarios: [ShortcutsScenario]) {
        let report = ShortcutsApprovedReport(
            status: "draft",
            sourceCommit: "TODO: git commit tested",
            appVersion: "TODO: tested app version, for example 0.1.0",
            tester: "TODO: tester or QA role",
            testedAt: "TODO: ISO-8601 timestamp",
            machineDescription: "TODO: Mac model, macOS build, installed MeetingVault app, Shortcuts app/Siri setup, and non-private fixture description",
            scenarios: requiredScenarios.map {
                ApprovedShortcutsScenario(
                    id: $0.id,
                    status: "blocked",
                    evidence: $0.requiredEvidence.map { "TODO: \($0)" }
                )
            },
            evidenceArtifacts: [
                "TODO: bounded artifact path, for example docs/evidence/shortcuts-release-summary-YYYY-MM-DD.json"
            ],
            shortcutsInvoked: false,
            siriInvoked: false,
            nonPrivateAudioConfirmed: false,
            appIntentHandoffObserved: false,
            appLaunchedFromIntent: false,
            preflightGateObserved: false,
            startStopIntentObserved: false,
            shareIntentReviewOnlyObserved: false,
            externalWriteAttempted: false,
            externalNetworkRequested: false,
            externalUploadAttempted: false,
            destructiveActionExecuted: false,
            privateAudioRecorded: false,
            microphoneOpened: false,
            rawUITextStored: false,
            rawTranscriptStored: false,
            rawAudioStored: false,
            rawLogsStored: false,
            notes: [
                "Replace every TODO with bounded evidence references before using this report.",
                "Use only non-private fixtures and do not paste raw transcripts, audio, UI text, logs, account details, Shortcuts output, or private file paths."
            ]
        )

        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: url, options: .atomic)
        } catch {
            fputs("failed to write Shortcuts report template: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func appendPlaceholderIssues(values: [String], label: String, to issues: inout [String]) {
        for value in values where containsPlaceholder(value) {
            issues.append("\(label) contains a template placeholder: \(value)")
        }
    }

    private static func containsPlaceholder(_ value: String) -> Bool {
        let normalized = value.lowercased()
        return normalized.contains("todo")
            || normalized.contains("replace")
            || normalized.contains("placeholder")
            || normalized.contains("<")
            || normalized.contains(">")
    }

    private static func scenarioDefinitions() -> [ShortcutsScenario] {
        [
            ShortcutsScenario(
                id: "shortcuts-catalog-visible",
                title: "Shortcuts/App Shortcuts expose the expected MeetingVault actions without stale or duplicate actions.",
                requiredEvidence: ["Shortcuts catalog summary", "expected action list"],
                status: "blocked"
            ),
            ShortcutsScenario(
                id: "open-recorder-handoff",
                title: "Open Recorder launches or routes MeetingVault to the primary meeting console.",
                requiredEvidence: ["intent invocation path", "visible MeetingVault routing summary"],
                status: "blocked"
            ),
            ShortcutsScenario(
                id: "check-readiness-handoff",
                title: "Check Recording Readiness reaches the same explicit app preflight gate without repeated permission prompts.",
                requiredEvidence: ["preflight state summary", "permission prompt summary"],
                status: "blocked"
            ),
            ShortcutsScenario(
                id: "start-stop-recording-handoff",
                title: "Start and Stop Recording intents route through visible app recording state over a non-private fixture.",
                requiredEvidence: ["start state summary", "stop/finalization state summary", "non-private fixture confirmation"],
                status: "blocked"
            ),
            ShortcutsScenario(
                id: "prepare-local-share-review",
                title: "Prepare Local Share opens or reuses the in-app review flow and does not send externally.",
                requiredEvidence: ["share review state summary", "external side-effect flags"],
                status: "blocked"
            ),
            ShortcutsScenario(
                id: "cancel-error-safety",
                title: "Cancel and error paths leave no destructive, external, upload, or raw-content side effects.",
                requiredEvidence: ["cancel path summary", "error path summary", "privacy flag summary"],
                status: "blocked"
            )
        ]
    }
}

ShortcutsReleaseGate.main()
