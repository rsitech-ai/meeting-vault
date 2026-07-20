#!/usr/bin/env swift
import Foundation

struct CleanMachineReleaseGateReport: Codable {
    var timestamp: String
    var status: String
    var requirePass: Bool
    var approvedReportPath: String?
    var readinessTarget: String
    var requiredScenarioCount: Int
    var passedScenarioCount: Int
    var requiredScenarios: [CleanMachineScenario]
    var validatedReport: CleanMachineApprovedReport?
    var firstLaunchVerified: Bool
    var noKeychainPromptOnFirstLaunch: Bool
    var noPasswordPromptOnFirstLaunch: Bool
    var noPermissionPromptBeforeUserAction: Bool
    var relaunchVerified: Bool
    var noKeychainPromptOnRelaunch: Bool
    var noPasswordPromptOnRelaunch: Bool
    var noPermissionPromptOnRelaunch: Bool
    var firstLaunchObservationCount: Int?
    var relaunchObservationCount: Int?
    var keychainPromptCount: Int?
    var passwordPromptCount: Int?
    var permissionPromptCount: Int?
    var packagedAppOpened: Bool
    var offlineStartupVerified: Bool
    var crashLogReviewed: Bool
    var privateAudioRecorded: Bool
    var microphoneOpened: Bool
    var externalNetworkRequested: Bool
    var externalUploadAttempted: Bool
    var destructiveActionExecuted: Bool
    var rawUITextStored: Bool
    var rawTranscriptStored: Bool
    var rawAudioStored: Bool
    var rawLogsStored: Bool
    var issues: [String]
}

struct CleanMachineScenario: Codable {
    var id: String
    var title: String
    var requiredEvidence: [String]
    var status: String
}

struct CleanMachineApprovedReport: Codable {
    var status: String
    var sourceCommit: String?
    var appVersion: String?
    var tester: String?
    var testedAt: String?
    var machineDescription: String?
    var scenarios: [ApprovedCleanMachineScenario]
    var evidenceArtifacts: [String]
    var firstLaunchVerified: Bool
    var noKeychainPromptOnFirstLaunch: Bool
    var noPasswordPromptOnFirstLaunch: Bool
    var noPermissionPromptBeforeUserAction: Bool
    var relaunchVerified: Bool
    var noKeychainPromptOnRelaunch: Bool
    var noPasswordPromptOnRelaunch: Bool
    var noPermissionPromptOnRelaunch: Bool
    var firstLaunchObservationCount: Int?
    var relaunchObservationCount: Int?
    var keychainPromptCount: Int?
    var passwordPromptCount: Int?
    var permissionPromptCount: Int?
    var packagedAppOpened: Bool
    var offlineStartupVerified: Bool
    var crashLogReviewed: Bool
    var privateAudioRecorded: Bool
    var microphoneOpened: Bool
    var externalNetworkRequested: Bool
    var externalUploadAttempted: Bool
    var destructiveActionExecuted: Bool
    var rawUITextStored: Bool
    var rawTranscriptStored: Bool
    var rawAudioStored: Bool
    var rawLogsStored: Bool
    var notes: [String]?
}

struct ApprovedCleanMachineScenario: Codable {
    var id: String
    var status: String
    var evidence: [String]
}

enum CleanMachineReleaseGate {
    static func main() {
        let rootURL = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let date = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
        var outputURL = rootURL
            .appendingPathComponent("docs", isDirectory: true)
            .appendingPathComponent("evidence", isDirectory: true)
            .appendingPathComponent("clean-machine-release-gate-\(date).json")
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
                usage: script/clean_machine_release_gate.swift [--output PATH] [--approved-report PATH] [--write-template PATH] [--require-pass]

                Writes the release-candidate clean-machine gate. Default
                behavior is blocked and does not create users, alter system
                settings, open capture devices, upload, or delete app data.

                To pass, provide a bounded approved-report JSON that proves
                install, first launch, relaunch without repeated Keychain,
                password, or permission prompts, first-launch prompt behavior,
                crash-log/package-open behavior, and offline-safe startup on a
                clean machine or clean user account without private content or
                external side effects.
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

        let validation = validateApprovedReport(
            at: approvedReportURL,
            requiredScenarios: requiredScenarios
        )
        let passedScenarioCount = validation.report?.scenarios
            .filter { $0.status == "pass" }
            .count ?? 0
        let status = validation.issues.isEmpty ? "pass" : "blocked"
        let scenarios = requiredScenarios.map { scenario in
            let approved = validation.report?.scenarios.first { $0.id == scenario.id }
            return CleanMachineScenario(
                id: scenario.id,
                title: scenario.title,
                requiredEvidence: scenario.requiredEvidence,
                status: approved?.status ?? "blocked"
            )
        }
        let report = CleanMachineReleaseGateReport(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            status: status,
            requirePass: requirePass,
            approvedReportPath: approvedReportURL?.path,
            readinessTarget: "release-candidate",
            requiredScenarioCount: requiredScenarios.count,
            passedScenarioCount: passedScenarioCount,
            requiredScenarios: scenarios,
            validatedReport: validation.report,
            firstLaunchVerified: validation.report?.firstLaunchVerified ?? false,
            noKeychainPromptOnFirstLaunch: validation.report?.noKeychainPromptOnFirstLaunch ?? false,
            noPasswordPromptOnFirstLaunch: validation.report?.noPasswordPromptOnFirstLaunch ?? false,
            noPermissionPromptBeforeUserAction: validation.report?.noPermissionPromptBeforeUserAction ?? false,
            relaunchVerified: validation.report?.relaunchVerified ?? false,
            noKeychainPromptOnRelaunch: validation.report?.noKeychainPromptOnRelaunch ?? false,
            noPasswordPromptOnRelaunch: validation.report?.noPasswordPromptOnRelaunch ?? false,
            noPermissionPromptOnRelaunch: validation.report?.noPermissionPromptOnRelaunch ?? false,
            firstLaunchObservationCount: validation.report?.firstLaunchObservationCount,
            relaunchObservationCount: validation.report?.relaunchObservationCount,
            keychainPromptCount: validation.report?.keychainPromptCount,
            passwordPromptCount: validation.report?.passwordPromptCount,
            permissionPromptCount: validation.report?.permissionPromptCount,
            packagedAppOpened: validation.report?.packagedAppOpened ?? false,
            offlineStartupVerified: validation.report?.offlineStartupVerified ?? false,
            crashLogReviewed: validation.report?.crashLogReviewed ?? false,
            privateAudioRecorded: validation.report?.privateAudioRecorded ?? false,
            microphoneOpened: validation.report?.microphoneOpened ?? false,
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
            fputs("failed to write clean-machine release gate: \(error.localizedDescription)\n", stderr)
            exit(1)
        }

        print("Wrote \(outputURL.path)")
        print("status=\(report.status) passedScenarios=\(report.passedScenarioCount)/\(report.requiredScenarioCount)")
        exit(report.status == "pass" || !requirePass ? 0 : 1)
    }

    private static func validateApprovedReport(
        at url: URL?,
        requiredScenarios: [CleanMachineScenario]
    ) -> (report: CleanMachineApprovedReport?, issues: [String]) {
        guard let url else {
            return (nil, ["Clean-machine release gate requires --approved-report with bounded clean-machine QA evidence."])
        }
        guard let data = try? Data(contentsOf: url) else {
            return (nil, ["Approved report could not be read at \(url.path)."])
        }
        let decoder = JSONDecoder()
        guard let report = try? decoder.decode(CleanMachineApprovedReport.self, from: data) else {
            return (nil, ["Approved report is not valid CleanMachineApprovedReport JSON."])
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
            issues.append("Approved report must identify when clean-machine QA was run.")
        }
        if report.evidenceArtifacts.isEmpty {
            issues.append("Approved report must list bounded evidence artifacts.")
        }
        appendPlaceholderIssues(
            values: report.evidenceArtifacts,
            label: "Approved report evidence artifact",
            to: &issues
        )
        if report.machineDescription?.isEmpty ?? true {
            issues.append("Approved report must describe the clean machine or clean user account used.")
        } else if containsPlaceholder(report.machineDescription ?? "") {
            issues.append("Approved report machine description contains a template placeholder.")
        }

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
            appendPlaceholderIssues(
                values: scenario.evidence,
                label: "Scenario \(required.id) evidence",
                to: &issues
            )
        }
        for extra in supplied.keys where !requiredIDs.contains(extra) {
            issues.append("Approved report contains unknown scenario \(extra).")
        }

        if !report.firstLaunchVerified { issues.append("Approved report must prove first launch succeeded on the clean machine or clean user account.") }
        if !report.noKeychainPromptOnFirstLaunch { issues.append("Approved report must prove first launch did not show a Keychain access prompt.") }
        if !report.noPasswordPromptOnFirstLaunch { issues.append("Approved report must prove first launch did not show a password or Always Allow prompt.") }
        if !report.noPermissionPromptBeforeUserAction { issues.append("Approved report must prove first launch did not show microphone, Speech Recognition, or other permission prompts before explicit user action.") }
        if !report.relaunchVerified { issues.append("Approved report must prove relaunch succeeded after quitting the app.") }
        if !report.noKeychainPromptOnRelaunch { issues.append("Approved report must prove relaunch did not show a Keychain access prompt.") }
        if !report.noPasswordPromptOnRelaunch { issues.append("Approved report must prove relaunch did not show a password or Always Allow prompt.") }
        if !report.noPermissionPromptOnRelaunch { issues.append("Approved report must prove relaunch did not show repeated microphone, Speech Recognition, or other permission prompts.") }
        requirePositiveCount(
            report.firstLaunchObservationCount,
            field: "firstLaunchObservationCount",
            description: "first-launch no-prompt observation",
            to: &issues
        )
        requirePositiveCount(
            report.relaunchObservationCount,
            field: "relaunchObservationCount",
            description: "relaunch no-prompt observation",
            to: &issues
        )
        requireZeroCount(
            report.keychainPromptCount,
            field: "keychainPromptCount",
            description: "Keychain access prompts across first launch and relaunch",
            to: &issues
        )
        requireZeroCount(
            report.passwordPromptCount,
            field: "passwordPromptCount",
            description: "password or Always Allow prompts across first launch and relaunch",
            to: &issues
        )
        requireZeroCount(
            report.permissionPromptCount,
            field: "permissionPromptCount",
            description: "microphone, Speech Recognition, or other permission prompts before explicit user action and on relaunch",
            to: &issues
        )
        if !report.packagedAppOpened { issues.append("Approved report must prove the packaged app opened successfully on the clean machine or clean user account.") }
        if !report.offlineStartupVerified { issues.append("Approved report must prove offline startup stayed usable without network access.") }
        if !report.crashLogReviewed { issues.append("Approved report must prove crash/log review after first launch and relaunch found no release-blocking diagnostics.") }
        if report.privateAudioRecorded { issues.append("Approved report recorded private audio.") }
        if report.microphoneOpened { issues.append("Approved report opened the microphone.") }
        if report.externalNetworkRequested { issues.append("Approved report requested external network.") }
        if report.externalUploadAttempted { issues.append("Approved report attempted external upload.") }
        if report.destructiveActionExecuted { issues.append("Approved report executed a destructive final action.") }
        if report.rawUITextStored { issues.append("Approved report stored raw UI text.") }
        if report.rawTranscriptStored { issues.append("Approved report stored raw transcript text.") }
        if report.rawAudioStored { issues.append("Approved report stored raw audio.") }
        if report.rawLogsStored { issues.append("Approved report stored raw logs.") }

        return (report, issues)
    }

    private static func writeTemplate(
        to url: URL,
        requiredScenarios: [CleanMachineScenario]
    ) {
        let report = CleanMachineApprovedReport(
            status: "draft",
            sourceCommit: "TODO: git commit tested",
            appVersion: "TODO: tested app version, for example 0.1.0",
            tester: "TODO: tester or QA role",
            testedAt: "TODO: ISO-8601 timestamp",
            machineDescription: "TODO: clean machine, VM, or clean user account description",
            scenarios: requiredScenarios.map {
                ApprovedCleanMachineScenario(
                    id: $0.id,
                    status: "blocked",
                    evidence: $0.requiredEvidence.map { "TODO: \($0)" }
                )
            },
            evidenceArtifacts: [
                "TODO: bounded artifact path, for example docs/evidence/clean-machine-release-summary-YYYY-MM-DD.json"
            ],
            firstLaunchVerified: false,
            noKeychainPromptOnFirstLaunch: false,
            noPasswordPromptOnFirstLaunch: false,
            noPermissionPromptBeforeUserAction: false,
            relaunchVerified: false,
            noKeychainPromptOnRelaunch: false,
            noPasswordPromptOnRelaunch: false,
            noPermissionPromptOnRelaunch: false,
            firstLaunchObservationCount: 0,
            relaunchObservationCount: 0,
            keychainPromptCount: 0,
            passwordPromptCount: 0,
            permissionPromptCount: 0,
            packagedAppOpened: false,
            offlineStartupVerified: false,
            crashLogReviewed: false,
            privateAudioRecorded: false,
            microphoneOpened: false,
            externalNetworkRequested: false,
            externalUploadAttempted: false,
            destructiveActionExecuted: false,
            rawUITextStored: false,
            rawTranscriptStored: false,
            rawAudioStored: false,
            rawLogsStored: false,
            notes: [
                "Replace every TODO with bounded evidence references before using this report.",
                "Do not include raw logs, private UI text, transcripts, audio, or user-specific account secrets."
            ]
        )

        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: url, options: .atomic)
        } catch {
            fputs("failed to write clean-machine report template: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func appendPlaceholderIssues(
        values: [String],
        label: String,
        to issues: inout [String]
    ) {
        for value in values where containsPlaceholder(value) {
            issues.append("\(label) contains a template placeholder: \(value)")
        }
    }

    private static func requirePositiveCount(
        _ count: Int?,
        field: String,
        description: String,
        to issues: inout [String]
    ) {
        guard let count else {
            issues.append("Approved report must include \(field) greater than 0 for \(description).")
            return
        }
        if count <= 0 {
            issues.append("Approved report \(field) is \(count); expected greater than 0 for \(description).")
        }
    }

    private static func requireZeroCount(
        _ count: Int?,
        field: String,
        description: String,
        to issues: inout [String]
    ) {
        guard let count else {
            issues.append("Approved report must include \(field) equal to 0 for \(description).")
            return
        }
        if count != 0 {
            issues.append("Approved report \(field) is \(count); expected 0 for \(description).")
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

    private static func scenarioDefinitions() -> [CleanMachineScenario] {
        [
            CleanMachineScenario(
                id: "fresh-install-first-launch",
                title: "Fresh install or clean user account launches the packaged app without stale local state or surprise access prompts.",
                requiredEvidence: [
                    "machine/account description",
                    "first-launch screenshot or bounded log summary",
                    "firstLaunchObservationCount greater than 0",
                    "no first-launch Keychain prompt evidence",
                    "no first-launch password or Always Allow prompt evidence",
                    "no automatic microphone/Speech Recognition permission prompt evidence"
                ],
                status: "blocked"
            ),
            CleanMachineScenario(
                id: "relaunch-persistence",
                title: "Quit and relaunch preserve safe local configuration without repeated Keychain or permission prompts.",
                requiredEvidence: [
                    "relaunch notes",
                    "relaunchObservationCount greater than 0",
                    "keychainPromptCount equals 0",
                    "passwordPromptCount equals 0",
                    "permissionPromptCount equals 0",
                    "no Keychain prompt evidence",
                    "no password or Always Allow prompt evidence",
                    "no repeated microphone/Speech Recognition permission prompt evidence"
                ],
                status: "blocked"
            ),
            CleanMachineScenario(
                id: "crash-log-review",
                title: "Crash/log review after first launch and relaunch finds no new MeetingVault crash diagnostics.",
                requiredEvidence: ["crash/log smoke summary", "diagnostic report count"],
                status: "blocked"
            ),
            CleanMachineScenario(
                id: "packaged-app-open",
                title: "The chosen packaged app path opens on the clean machine/account with expected bundle metadata.",
                requiredEvidence: ["bundle path/version/build", "open result"],
                status: "blocked"
            ),
            CleanMachineScenario(
                id: "offline-safe-startup",
                title: "Startup remains usable without network access and without private meeting data.",
                requiredEvidence: ["offline startup notes", "privacy flag summary"],
                status: "blocked"
            )
        ]
    }
}

CleanMachineReleaseGate.main()
