#!/usr/bin/env swift
import Foundation

struct SleepWakeReleaseGateReport: Codable {
    var timestamp: String
    var status: String
    var requirePass: Bool
    var approvedReportPath: String?
    var readinessTarget: String
    var requiredScenarioCount: Int
    var passedScenarioCount: Int
    var requiredScenarios: [SleepWakeScenario]
    var validatedReport: SleepWakeApprovedReport?
    var nonPrivateAudioConfirmed: Bool
    var privateAudioRecorded: Bool
    var microphoneOpened: Bool
    var systemAudioCaptureAttempted: Bool
    var systemSleepTriggered: Bool
    var systemWakeObserved: Bool
    var checkpointPreserved: Bool
    var recoveryVerified: Bool
    var completedMeetingInsertedBeforeRecovery: Bool
    var externalNetworkRequested: Bool
    var externalUploadAttempted: Bool
    var destructiveActionExecuted: Bool
    var rawUITextStored: Bool
    var rawTranscriptStored: Bool
    var rawAudioStored: Bool
    var rawLogsStored: Bool
    var issues: [String]
}

struct SleepWakeScenario: Codable {
    var id: String
    var title: String
    var requiredEvidence: [String]
    var status: String
}

struct SleepWakeApprovedReport: Codable {
    var status: String
    var sourceCommit: String?
    var appVersion: String?
    var tester: String?
    var testedAt: String?
    var machineDescription: String?
    var scenarios: [ApprovedSleepWakeScenario]
    var evidenceArtifacts: [String]
    var nonPrivateAudioConfirmed: Bool
    var privateAudioRecorded: Bool
    var microphoneOpened: Bool
    var systemAudioCaptureAttempted: Bool
    var systemSleepTriggered: Bool
    var systemWakeObserved: Bool
    var checkpointPreserved: Bool
    var recoveryVerified: Bool
    var completedMeetingInsertedBeforeRecovery: Bool
    var externalNetworkRequested: Bool
    var externalUploadAttempted: Bool
    var destructiveActionExecuted: Bool
    var rawUITextStored: Bool
    var rawTranscriptStored: Bool
    var rawAudioStored: Bool
    var rawLogsStored: Bool
    var notes: [String]?
}

struct ApprovedSleepWakeScenario: Codable {
    var id: String
    var status: String
    var evidence: [String]
}

enum SleepWakeReleaseGate {
    static func main() {
        let rootURL = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let date = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
        var outputURL = rootURL
            .appendingPathComponent("docs", isDirectory: true)
            .appendingPathComponent("evidence", isDirectory: true)
            .appendingPathComponent("sleep-wake-release-gate-\(date).json")
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
                usage: script/sleep_wake_release_gate.swift [--output PATH] [--approved-report PATH] [--write-template PATH] [--require-pass]

                Writes the release-candidate sleep/wake recovery gate. Default
                behavior is blocked and does not sleep the Mac, open capture,
                upload, share, delete, or record anything.

                To pass, provide a bounded approved-report JSON from a real macOS
                sleep/wake run over explicitly confirmed non-private audio. The
                report must prove checkpoint preservation, visible recovery after
                wake, no premature completed meeting insert, and no raw private
                content in evidence.
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
            return SleepWakeScenario(
                id: scenario.id,
                title: scenario.title,
                requiredEvidence: scenario.requiredEvidence,
                status: approved?.status ?? "blocked"
            )
        }
        let report = SleepWakeReleaseGateReport(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            status: status,
            requirePass: requirePass,
            approvedReportPath: approvedReportURL?.path,
            readinessTarget: "release-candidate",
            requiredScenarioCount: requiredScenarios.count,
            passedScenarioCount: passedScenarioCount,
            requiredScenarios: scenarios,
            validatedReport: validation.report,
            nonPrivateAudioConfirmed: validation.report?.nonPrivateAudioConfirmed ?? false,
            privateAudioRecorded: validation.report?.privateAudioRecorded ?? false,
            microphoneOpened: validation.report?.microphoneOpened ?? false,
            systemAudioCaptureAttempted: validation.report?.systemAudioCaptureAttempted ?? false,
            systemSleepTriggered: validation.report?.systemSleepTriggered ?? false,
            systemWakeObserved: validation.report?.systemWakeObserved ?? false,
            checkpointPreserved: validation.report?.checkpointPreserved ?? false,
            recoveryVerified: validation.report?.recoveryVerified ?? false,
            completedMeetingInsertedBeforeRecovery: validation.report?.completedMeetingInsertedBeforeRecovery ?? false,
            externalNetworkRequested: validation.report?.externalNetworkRequested ?? false,
            externalUploadAttempted: validation.report?.externalUploadAttempted ?? false,
            destructiveActionExecuted: validation.report?.destructiveActionExecuted ?? false,
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
            fputs("failed to write sleep/wake release gate: \(error.localizedDescription)\n", stderr)
            exit(1)
        }

        print("Wrote \(outputURL.path)")
        print("status=\(report.status) passedScenarios=\(report.passedScenarioCount)/\(report.requiredScenarioCount)")
        exit(report.status == "pass" || !requirePass ? 0 : 1)
    }

    private static func validateApprovedReport(
        at url: URL?,
        requiredScenarios: [SleepWakeScenario]
    ) -> (report: SleepWakeApprovedReport?, issues: [String]) {
        guard let url else {
            return (nil, ["Sleep/wake release gate requires --approved-report with bounded real macOS sleep/wake QA evidence."])
        }
        guard let data = try? Data(contentsOf: url) else {
            return (nil, ["Approved report could not be read at \(url.path)."])
        }
        let decoder = JSONDecoder()
        guard let report = try? decoder.decode(SleepWakeApprovedReport.self, from: data) else {
            return (nil, ["Approved report is not valid SleepWakeApprovedReport JSON."])
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
            issues.append("Approved report must identify when sleep/wake QA was run.")
        }
        if report.machineDescription?.isEmpty ?? true {
            issues.append("Approved report must describe the Mac, OS build, and audio source setup.")
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

        if !report.nonPrivateAudioConfirmed { issues.append("Approved report must confirm only non-private audio was used.") }
        if report.privateAudioRecorded { issues.append("Approved report recorded private audio.") }
        if !report.systemSleepTriggered { issues.append("Approved report must prove real macOS sleep was triggered.") }
        if !report.systemWakeObserved { issues.append("Approved report must prove wake was observed.") }
        if !report.checkpointPreserved { issues.append("Approved report must prove encrypted checkpoints were preserved.") }
        if !report.recoveryVerified { issues.append("Approved report must prove Health & Recovery recovery after wake.") }
        if report.completedMeetingInsertedBeforeRecovery { issues.append("Approved report inserted a completed meeting before recovery.") }
        if report.externalNetworkRequested { issues.append("Approved report requested external network.") }
        if report.externalUploadAttempted { issues.append("Approved report attempted external upload.") }
        if report.destructiveActionExecuted { issues.append("Approved report executed a destructive final action.") }
        if report.rawUITextStored { issues.append("Approved report stored raw UI text.") }
        if report.rawTranscriptStored { issues.append("Approved report stored raw transcript text.") }
        if report.rawAudioStored { issues.append("Approved report stored raw audio.") }
        if report.rawLogsStored { issues.append("Approved report stored raw logs.") }

        return (report, issues)
    }

    private static func writeTemplate(to url: URL, requiredScenarios: [SleepWakeScenario]) {
        let report = SleepWakeApprovedReport(
            status: "draft",
            sourceCommit: "TODO: git commit tested",
            appVersion: "TODO: tested app version, for example 0.1.0",
            tester: "TODO: tester or QA role",
            testedAt: "TODO: ISO-8601 timestamp",
            machineDescription: "TODO: Mac model, macOS build, power settings, audio source, and clean/non-private fixture description",
            scenarios: requiredScenarios.map {
                ApprovedSleepWakeScenario(
                    id: $0.id,
                    status: "blocked",
                    evidence: $0.requiredEvidence.map { "TODO: \($0)" }
                )
            },
            evidenceArtifacts: [
                "TODO: bounded artifact path, for example docs/evidence/sleep-wake-release-summary-YYYY-MM-DD.json"
            ],
            nonPrivateAudioConfirmed: false,
            privateAudioRecorded: false,
            microphoneOpened: false,
            systemAudioCaptureAttempted: false,
            systemSleepTriggered: false,
            systemWakeObserved: false,
            checkpointPreserved: false,
            recoveryVerified: false,
            completedMeetingInsertedBeforeRecovery: false,
            externalNetworkRequested: false,
            externalUploadAttempted: false,
            destructiveActionExecuted: false,
            rawUITextStored: false,
            rawTranscriptStored: false,
            rawAudioStored: false,
            rawLogsStored: false,
            notes: [
                "Replace every TODO with bounded evidence references before using this report.",
                "Use only non-private audio and do not paste raw transcripts, audio, UI text, logs, account details, or private file paths."
            ]
        )

        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: url, options: .atomic)
        } catch {
            fputs("failed to write sleep/wake report template: \(error.localizedDescription)\n", stderr)
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

    private static func scenarioDefinitions() -> [SleepWakeScenario] {
        [
            SleepWakeScenario(
                id: "active-recording-before-sleep",
                title: "A visible recording over approved non-private audio reaches an encrypted checkpoint before sleep.",
                requiredEvidence: ["recording setup notes", "checkpoint count before sleep"],
                status: "blocked"
            ),
            SleepWakeScenario(
                id: "real-macos-sleep-wake",
                title: "The Mac enters real system sleep and wakes with MeetingVault still recoverable.",
                requiredEvidence: ["sleep trigger method", "wake timestamp or bounded log summary"],
                status: "blocked"
            ),
            SleepWakeScenario(
                id: "wake-recovery-state",
                title: "On wake, MeetingVault shows recovery state instead of silently completing or losing the recording.",
                requiredEvidence: ["Health & Recovery notes", "bounded screenshot or state summary"],
                status: "blocked"
            ),
            SleepWakeScenario(
                id: "checkpoint-recovery",
                title: "Checkpointed encrypted audio remains recoverable after wake without raw audio in evidence.",
                requiredEvidence: ["recovery scanner summary", "privacy flag summary"],
                status: "blocked"
            ),
            SleepWakeScenario(
                id: "post-wake-crash-log-review",
                title: "Post-wake crash/log review finds no new MeetingVault crash diagnostics or unredacted logs.",
                requiredEvidence: ["crash/log bounded summary", "raw log storage flag"],
                status: "blocked"
            )
        ]
    }
}

SleepWakeReleaseGate.main()
