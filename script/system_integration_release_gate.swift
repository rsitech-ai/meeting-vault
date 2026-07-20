#!/usr/bin/env swift
import Foundation

struct SystemIntegrationReleaseGateReport: Codable {
    var timestamp: String
    var status: String
    var requirePass: Bool
    var approvedReportPath: String?
    var readinessTarget: String
    var requiredScenarioCount: Int
    var passedScenarioCount: Int
    var requiredScenarios: [SystemIntegrationScenario]
    var validatedReport: SystemIntegrationApprovedReport?
    var nonPrivateFixtureConfirmed: Bool
    var operatorApprovedOSWrite: Bool
    var confirmationDialogObserved: Bool
    var cancelBeforeWriteVerified: Bool
    var calendarWriteVerified: Bool
    var reminderWriteVerified: Bool
    var contactWriteVerified: Bool
    var permissionRecoveryVerified: Bool
    var permissionDeniedNoPartialWriteVerified: Bool
    var receiptsRedacted: Bool
    var auditMetadataRedacted: Bool
    var confirmedOSStoreWriteExecuted: Bool
    var externalNetworkRequested: Bool
    var externalUploadAttempted: Bool
    var destructiveActionExecuted: Bool
    var privateAudioRecorded: Bool
    var microphoneOpened: Bool
    var rawUITextStored: Bool
    var rawTranscriptStored: Bool
    var rawAudioStored: Bool
    var rawLogsStored: Bool
    var rawCalendarDataStored: Bool
    var rawReminderDataStored: Bool
    var rawContactDataStored: Bool
    var issues: [String]
}

struct SystemIntegrationScenario: Codable {
    var id: String
    var title: String
    var requiredEvidence: [String]
    var status: String
}

struct SystemIntegrationApprovedReport: Codable {
    var status: String
    var sourceCommit: String?
    var appVersion: String?
    var tester: String?
    var testedAt: String?
    var machineDescription: String?
    var scenarios: [ApprovedSystemIntegrationScenario]
    var evidenceArtifacts: [String]
    var nonPrivateFixtureConfirmed: Bool
    var operatorApprovedOSWrite: Bool
    var confirmationDialogObserved: Bool
    var cancelBeforeWriteVerified: Bool
    var calendarWriteVerified: Bool
    var reminderWriteVerified: Bool
    var contactWriteVerified: Bool
    var permissionRecoveryVerified: Bool
    var permissionDeniedNoPartialWriteVerified: Bool
    var receiptsRedacted: Bool
    var auditMetadataRedacted: Bool
    var externalNetworkRequested: Bool
    var externalUploadAttempted: Bool
    var destructiveActionExecuted: Bool
    var privateAudioRecorded: Bool
    var microphoneOpened: Bool
    var rawUITextStored: Bool
    var rawTranscriptStored: Bool
    var rawAudioStored: Bool
    var rawLogsStored: Bool
    var rawCalendarDataStored: Bool
    var rawReminderDataStored: Bool
    var rawContactDataStored: Bool
    var notes: [String]?
}

struct ApprovedSystemIntegrationScenario: Codable {
    var id: String
    var status: String
    var evidence: [String]
}

enum SystemIntegrationReleaseGate {
    static func main() {
        let rootURL = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let date = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
        var outputURL = rootURL
            .appendingPathComponent("docs", isDirectory: true)
            .appendingPathComponent("evidence", isDirectory: true)
            .appendingPathComponent("system-integration-release-gate-\(date).json")
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
                usage: script/system_integration_release_gate.swift [--output PATH] [--approved-report PATH] [--write-template PATH] [--require-pass]

                Writes the release-candidate Calendar, Reminders, and Contacts
                handoff gate. Default behavior is blocked and does not open
                capture devices, request network access, upload externally, or
                write to Calendar, Reminders, or Contacts.

                To pass, provide a bounded approved-report JSON from real OS
                integration QA over non-private fixtures. The report must prove
                explicit confirmation, cancel safety, permission recovery,
                Calendar/Reminder/Contact write receipts, and redacted evidence.
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
            return SystemIntegrationScenario(
                id: scenario.id,
                title: scenario.title,
                requiredEvidence: scenario.requiredEvidence,
                status: approved?.status ?? "blocked"
            )
        }
        let report = SystemIntegrationReleaseGateReport(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            status: status,
            requirePass: requirePass,
            approvedReportPath: approvedReportURL?.path,
            readinessTarget: "release-candidate",
            requiredScenarioCount: requiredScenarios.count,
            passedScenarioCount: passedScenarioCount,
            requiredScenarios: scenarios,
            validatedReport: validation.report,
            nonPrivateFixtureConfirmed: validation.report?.nonPrivateFixtureConfirmed ?? false,
            operatorApprovedOSWrite: validation.report?.operatorApprovedOSWrite ?? false,
            confirmationDialogObserved: validation.report?.confirmationDialogObserved ?? false,
            cancelBeforeWriteVerified: validation.report?.cancelBeforeWriteVerified ?? false,
            calendarWriteVerified: validation.report?.calendarWriteVerified ?? false,
            reminderWriteVerified: validation.report?.reminderWriteVerified ?? false,
            contactWriteVerified: validation.report?.contactWriteVerified ?? false,
            permissionRecoveryVerified: validation.report?.permissionRecoveryVerified ?? false,
            permissionDeniedNoPartialWriteVerified: validation.report?.permissionDeniedNoPartialWriteVerified ?? false,
            receiptsRedacted: validation.report?.receiptsRedacted ?? false,
            auditMetadataRedacted: validation.report?.auditMetadataRedacted ?? false,
            confirmedOSStoreWriteExecuted: validation.report?.operatorApprovedOSWrite == true
                && validation.report?.calendarWriteVerified == true
                && validation.report?.reminderWriteVerified == true
                && validation.report?.contactWriteVerified == true,
            externalNetworkRequested: validation.report?.externalNetworkRequested ?? false,
            externalUploadAttempted: validation.report?.externalUploadAttempted ?? false,
            destructiveActionExecuted: validation.report?.destructiveActionExecuted ?? false,
            privateAudioRecorded: validation.report?.privateAudioRecorded ?? false,
            microphoneOpened: validation.report?.microphoneOpened ?? false,
            rawUITextStored: validation.report?.rawUITextStored ?? false,
            rawTranscriptStored: validation.report?.rawTranscriptStored ?? false,
            rawAudioStored: validation.report?.rawAudioStored ?? false,
            rawLogsStored: validation.report?.rawLogsStored ?? false,
            rawCalendarDataStored: validation.report?.rawCalendarDataStored ?? false,
            rawReminderDataStored: validation.report?.rawReminderDataStored ?? false,
            rawContactDataStored: validation.report?.rawContactDataStored ?? false,
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
            fputs("failed to write system integration release gate: \(error.localizedDescription)\n", stderr)
            exit(1)
        }

        print("Wrote \(outputURL.path)")
        print("status=\(report.status) passedScenarios=\(report.passedScenarioCount)/\(report.requiredScenarioCount)")
        exit(report.status == "pass" || !requirePass ? 0 : 1)
    }

    private static func validateApprovedReport(
        at url: URL?,
        requiredScenarios: [SystemIntegrationScenario]
    ) -> (report: SystemIntegrationApprovedReport?, issues: [String]) {
        guard let url else {
            return (nil, ["System integration release gate requires --approved-report with bounded real OS Calendar/Reminders/Contacts QA evidence."])
        }
        guard let data = try? Data(contentsOf: url) else {
            return (nil, ["Approved report could not be read at \(url.path)."])
        }
        let decoder = JSONDecoder()
        guard let report = try? decoder.decode(SystemIntegrationApprovedReport.self, from: data) else {
            return (nil, ["Approved report is not valid SystemIntegrationApprovedReport JSON."])
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
            issues.append("Approved report must identify when system integration QA was run.")
        }
        if report.machineDescription?.isEmpty ?? true {
            issues.append("Approved report must describe the Mac, OS build, app install, and Calendar/Reminders/Contacts setup.")
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

        if !report.nonPrivateFixtureConfirmed { issues.append("Approved report must confirm only non-private fixtures were used.") }
        if !report.operatorApprovedOSWrite { issues.append("Approved report must prove the operator approved the real OS write fixture.") }
        if !report.confirmationDialogObserved { issues.append("Approved report must prove the in-app confirmation dialog was observed before writing.") }
        if !report.cancelBeforeWriteVerified { issues.append("Approved report must prove cancel-before-write leaves no OS-store side effects.") }
        if !report.calendarWriteVerified { issues.append("Approved report must prove Calendar write receipt over a non-private fixture.") }
        if !report.reminderWriteVerified { issues.append("Approved report must prove Reminder write receipt over a non-private fixture.") }
        if !report.contactWriteVerified { issues.append("Approved report must prove Contacts review write receipt over a non-private fixture.") }
        if !report.permissionRecoveryVerified { issues.append("Approved report must prove OS permission recovery guidance and return-to-app behavior.") }
        if !report.permissionDeniedNoPartialWriteVerified { issues.append("Approved report must prove denied permission prevents partial Calendar/Reminders/Contacts writes.") }
        if !report.receiptsRedacted { issues.append("Approved report must prove write receipts are bounded and redacted.") }
        if !report.auditMetadataRedacted { issues.append("Approved report must prove privacy audit metadata stays count/kind-only.") }
        if report.externalNetworkRequested { issues.append("Approved report requested external network.") }
        if report.externalUploadAttempted { issues.append("Approved report attempted external upload.") }
        if report.destructiveActionExecuted { issues.append("Approved report executed a destructive action.") }
        if report.privateAudioRecorded { issues.append("Approved report recorded private audio.") }
        if report.microphoneOpened { issues.append("Approved report opened the microphone; this gate must use local non-private fixtures only.") }
        if report.rawUITextStored { issues.append("Approved report stored raw UI text.") }
        if report.rawTranscriptStored { issues.append("Approved report stored raw transcript text.") }
        if report.rawAudioStored { issues.append("Approved report stored raw audio.") }
        if report.rawLogsStored { issues.append("Approved report stored raw logs.") }
        if report.rawCalendarDataStored { issues.append("Approved report stored raw Calendar payload data.") }
        if report.rawReminderDataStored { issues.append("Approved report stored raw Reminder payload data.") }
        if report.rawContactDataStored { issues.append("Approved report stored raw Contact payload data.") }

        return (report, issues)
    }

    private static func writeTemplate(to url: URL, requiredScenarios: [SystemIntegrationScenario]) {
        let report = SystemIntegrationApprovedReport(
            status: "draft",
            sourceCommit: "TODO: git commit tested",
            appVersion: "TODO: tested app version, for example 0.1.0",
            tester: "TODO: tester or QA role",
            testedAt: "TODO: ISO-8601 timestamp",
            machineDescription: "TODO: Mac model, macOS build, installed MeetingVault app, clean Calendar/Reminders/Contacts fixture account, and non-private fixture description",
            scenarios: requiredScenarios.map {
                ApprovedSystemIntegrationScenario(
                    id: $0.id,
                    status: "blocked",
                    evidence: $0.requiredEvidence.map { "TODO: \($0)" }
                )
            },
            evidenceArtifacts: [
                "TODO: bounded artifact path, for example docs/evidence/system-integration-release-summary-YYYY-MM-DD.json"
            ],
            nonPrivateFixtureConfirmed: false,
            operatorApprovedOSWrite: false,
            confirmationDialogObserved: false,
            cancelBeforeWriteVerified: false,
            calendarWriteVerified: false,
            reminderWriteVerified: false,
            contactWriteVerified: false,
            permissionRecoveryVerified: false,
            permissionDeniedNoPartialWriteVerified: false,
            receiptsRedacted: false,
            auditMetadataRedacted: false,
            externalNetworkRequested: false,
            externalUploadAttempted: false,
            destructiveActionExecuted: false,
            privateAudioRecorded: false,
            microphoneOpened: false,
            rawUITextStored: false,
            rawTranscriptStored: false,
            rawAudioStored: false,
            rawLogsStored: false,
            rawCalendarDataStored: false,
            rawReminderDataStored: false,
            rawContactDataStored: false,
            notes: [
                "Replace every TODO with bounded evidence references before using this report.",
                "Use only non-private fixtures and do not paste raw transcripts, audio, UI text, logs, account details, Calendar/Reminder/Contact payloads, or private file paths."
            ]
        )

        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: url, options: .atomic)
        } catch {
            fputs("failed to write system integration report template: \(error.localizedDescription)\n", stderr)
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

    private static func scenarioDefinitions() -> [SystemIntegrationScenario] {
        [
            SystemIntegrationScenario(
                id: "reviewed-proposals",
                title: "MeetingVault generates review-only Calendar, Reminder, and Contact proposals before any OS write.",
                requiredEvidence: ["proposal count/kind summary", "review-only state summary"],
                status: "blocked"
            ),
            SystemIntegrationScenario(
                id: "confirmation-and-cancel",
                title: "Confirm Handoff shows an explicit confirmation dialog, and cancel writes nothing to OS stores.",
                requiredEvidence: ["confirmation dialog summary", "cancel path no-write receipt"],
                status: "blocked"
            ),
            SystemIntegrationScenario(
                id: "calendar-write",
                title: "Confirmed Calendar event write succeeds over a non-private fixture and returns a bounded receipt.",
                requiredEvidence: ["redacted Calendar receipt", "non-private event fixture summary"],
                status: "blocked"
            ),
            SystemIntegrationScenario(
                id: "reminder-write",
                title: "Confirmed Reminder write succeeds over a non-private fixture and returns a bounded receipt.",
                requiredEvidence: ["redacted Reminder receipt", "non-private reminder fixture summary"],
                status: "blocked"
            ),
            SystemIntegrationScenario(
                id: "contact-review-write",
                title: "Confirmed Contacts review write succeeds over a non-private fixture and returns a bounded receipt.",
                requiredEvidence: ["redacted Contacts receipt", "non-private contact fixture summary"],
                status: "blocked"
            ),
            SystemIntegrationScenario(
                id: "permission-recovery-no-partial-write",
                title: "Denied Calendar, Reminders, or Contacts permission routes to recovery and prevents partial writes.",
                requiredEvidence: ["denied-permission recovery summary", "no-partial-write receipt summary"],
                status: "blocked"
            ),
            SystemIntegrationScenario(
                id: "redaction-and-audit",
                title: "Evidence and privacy audit metadata stay bounded, count/kind-only, and omit raw private content.",
                requiredEvidence: ["redaction checklist", "privacy audit metadata summary"],
                status: "blocked"
            )
        ]
    }
}

SystemIntegrationReleaseGate.main()
