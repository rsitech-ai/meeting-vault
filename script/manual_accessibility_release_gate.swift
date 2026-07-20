#!/usr/bin/env swift
import Foundation

struct ManualAccessibilityReleaseGateReport: Codable {
    var timestamp: String
    var status: String
    var requirePass: Bool
    var approvedReportPath: String?
    var readinessTarget: String
    var requiredScenarioCount: Int
    var passedScenarioCount: Int
    var requiredScenarios: [ManualAccessibilityScenario]
    var validatedReport: ManualAccessibilityApprovedReport?
    var privateAudioRecorded: Bool
    var microphoneOpened: Bool
    var externalNetworkRequested: Bool
    var externalUploadAttempted: Bool
    var destructiveActionExecuted: Bool
    var externalShareOpened: Bool
    var rawUITextStored: Bool
    var rawTranscriptStored: Bool
    var rawAudioStored: Bool
    var rawLogsStored: Bool
    var issues: [String]
}

struct ManualAccessibilityScenario: Codable {
    var id: String
    var title: String
    var requiredEvidence: [String]
    var status: String
}

struct ManualAccessibilityApprovedReport: Codable {
    var status: String
    var appVersion: String?
    var sourceCommit: String?
    var tester: String?
    var testedAt: String?
    var scenarios: [ApprovedManualScenario]
    var evidenceArtifacts: [String]
    var privateAudioRecorded: Bool
    var microphoneOpened: Bool
    var externalNetworkRequested: Bool
    var externalUploadAttempted: Bool
    var destructiveActionExecuted: Bool
    var externalShareOpened: Bool
    var rawUITextStored: Bool
    var rawTranscriptStored: Bool
    var rawAudioStored: Bool
    var rawLogsStored: Bool
    var notes: [String]?
}

struct ApprovedManualScenario: Codable {
    var id: String
    var status: String
    var evidence: [String]
}

enum ManualAccessibilityReleaseGate {
    static func main() {
        let rootURL = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let date = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
        var outputURL = rootURL
            .appendingPathComponent("docs", isDirectory: true)
            .appendingPathComponent("evidence", isDirectory: true)
            .appendingPathComponent("manual-accessibility-release-gate-\(date).json")
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
                usage: script/manual_accessibility_release_gate.swift [--output PATH] [--approved-report PATH] [--write-template PATH] [--require-pass]

                Writes the release-candidate accessibility gate. Default behavior
                is blocked and does not change VoiceOver, System Settings,
                app state, permissions, sharing, deletion, or capture.

                To pass, provide a bounded approved-report JSON that records the
                required manual VoiceOver, keyboard-only, pointer, resize,
                permission-recovery, contrast, and destructive-cancel scenarios
                without raw UI text, private audio, external upload, external
                share execution, or destructive final actions.
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
            return ManualAccessibilityScenario(
                id: scenario.id,
                title: scenario.title,
                requiredEvidence: scenario.requiredEvidence,
                status: approved?.status ?? "blocked"
            )
        }
        let report = ManualAccessibilityReleaseGateReport(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            status: status,
            requirePass: requirePass,
            approvedReportPath: approvedReportURL?.path,
            readinessTarget: "release-candidate",
            requiredScenarioCount: requiredScenarios.count,
            passedScenarioCount: passedScenarioCount,
            requiredScenarios: scenarios,
            validatedReport: validation.report,
            privateAudioRecorded: validation.report?.privateAudioRecorded ?? false,
            microphoneOpened: validation.report?.microphoneOpened ?? false,
            externalNetworkRequested: validation.report?.externalNetworkRequested ?? false,
            externalUploadAttempted: validation.report?.externalUploadAttempted ?? false,
            destructiveActionExecuted: validation.report?.destructiveActionExecuted ?? false,
            externalShareOpened: validation.report?.externalShareOpened ?? false,
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
            fputs("failed to write manual accessibility release gate: \(error.localizedDescription)\n", stderr)
            exit(1)
        }

        print("Wrote \(outputURL.path)")
        print("status=\(report.status) passedScenarios=\(report.passedScenarioCount)/\(report.requiredScenarioCount)")
        exit(report.status == "pass" || !requirePass ? 0 : 1)
    }

    private static func validateApprovedReport(
        at url: URL?,
        requiredScenarios: [ManualAccessibilityScenario]
    ) -> (report: ManualAccessibilityApprovedReport?, issues: [String]) {
        guard let url else {
            return (
                nil,
                ["Manual accessibility release gate requires --approved-report with bounded manual QA evidence."]
            )
        }
        guard let data = try? Data(contentsOf: url) else {
            return (nil, ["Approved report could not be read at \(url.path)."])
        }
        let decoder = JSONDecoder()
        guard let report = try? decoder.decode(ManualAccessibilityApprovedReport.self, from: data) else {
            return (nil, ["Approved report is not valid ManualAccessibilityApprovedReport JSON."])
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
            issues.append("Approved report must identify when the manual sweep was run.")
        }
        if report.evidenceArtifacts.isEmpty {
            issues.append("Approved report must list bounded evidence artifacts.")
        }
        appendPlaceholderIssues(
            values: report.evidenceArtifacts,
            label: "Approved report evidence artifact",
            to: &issues
        )

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

        if report.privateAudioRecorded {
            issues.append("Approved report recorded private audio.")
        }
        if report.microphoneOpened {
            issues.append("Approved report opened the microphone; accessibility release proof must not require capture.")
        }
        if report.externalNetworkRequested {
            issues.append("Approved report requested external network.")
        }
        if report.externalUploadAttempted {
            issues.append("Approved report attempted external upload.")
        }
        if report.destructiveActionExecuted {
            issues.append("Approved report executed a destructive final action.")
        }
        if report.externalShareOpened {
            issues.append("Approved report opened external sharing.")
        }
        if report.rawUITextStored {
            issues.append("Approved report stored raw UI text.")
        }
        if report.rawTranscriptStored {
            issues.append("Approved report stored raw transcript text.")
        }
        if report.rawAudioStored {
            issues.append("Approved report stored raw audio.")
        }
        if report.rawLogsStored {
            issues.append("Approved report stored raw logs.")
        }

        return (report, issues)
    }

    private static func writeTemplate(
        to url: URL,
        requiredScenarios: [ManualAccessibilityScenario]
    ) {
        let report = ManualAccessibilityApprovedReport(
            status: "draft",
            appVersion: "TODO: tested app version, for example 0.1.0",
            sourceCommit: "TODO: git commit tested",
            tester: "TODO: tester or QA role",
            testedAt: "TODO: ISO-8601 timestamp",
            scenarios: requiredScenarios.map {
                ApprovedManualScenario(
                    id: $0.id,
                    status: "blocked",
                    evidence: $0.requiredEvidence.map { "TODO: \($0)" }
                )
            },
            evidenceArtifacts: [
                "TODO: bounded artifact path, for example docs/evidence/manual-accessibility-release-summary-YYYY-MM-DD.json"
            ],
            privateAudioRecorded: false,
            microphoneOpened: false,
            externalNetworkRequested: false,
            externalUploadAttempted: false,
            destructiveActionExecuted: false,
            externalShareOpened: false,
            rawUITextStored: false,
            rawTranscriptStored: false,
            rawAudioStored: false,
            rawLogsStored: false,
            notes: [
                "Replace every TODO with bounded evidence references before using this report.",
                "Do not paste raw UI text, transcript text, private audio paths, logs, or screenshots containing private meeting content."
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
            fputs("failed to write manual accessibility report template: \(error.localizedDescription)\n", stderr)
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

    private static func containsPlaceholder(_ value: String) -> Bool {
        let normalized = value.lowercased()
        return normalized.contains("todo")
            || normalized.contains("replace")
            || normalized.contains("placeholder")
            || normalized.contains("<")
            || normalized.contains(">")
    }

    private static func scenarioDefinitions() -> [ManualAccessibilityScenario] {
        [
            ManualAccessibilityScenario(
                id: "primary-console-recording-agent",
                title: "Primary console exposes top recording command bar, selected audio input, live monitor, live transcript, Agent, Library, More, and accessible Agent ask/edit/copy response flow without duplicate recording controls.",
                requiredEvidence: [
                    "Primary console VoiceOver and keyboard route notes",
                    "Top command-bar Start Stop readiness check input and Agent/Library/More evidence",
                    "Agent prompt, grounded answer, editable response, and copy response accessibility evidence"
                ],
                status: "blocked"
            ),
            ManualAccessibilityScenario(
                id: "voiceover-major-workflows",
                title: "VoiceOver can navigate Meetings, Recording, Transcript Agent, Health & Recovery, Settings, and modal sheets.",
                requiredEvidence: ["Manual VoiceOver pass notes", "bounded screenshot or screen recording reference"],
                status: "blocked"
            ),
            ManualAccessibilityScenario(
                id: "keyboard-only-primary-actions",
                title: "Keyboard-only operation covers focus movement, menus, shortcuts, prompts, exports, recovery, and dialogs.",
                requiredEvidence: ["Keyboard path checklist", "menu/shortcut evidence"],
                status: "blocked"
            ),
            ManualAccessibilityScenario(
                id: "pointer-hover-context-menus",
                title: "Pointer hover help, icon affordances, context menus, and row/card actions are discoverable and not duplicated.",
                requiredEvidence: ["Hover/context-menu checklist", "bounded screenshots"],
                status: "blocked"
            ),
            ManualAccessibilityScenario(
                id: "resize-split-view-long-content",
                title: "Minimum, typical, wide, split-view, and long transcript layouts remain usable without clipped controls.",
                requiredEvidence: ["Window sizing notes", "minimum and wide screenshots"],
                status: "blocked"
            ),
            ManualAccessibilityScenario(
                id: "permission-recovery-return",
                title: "System permission recovery can open guidance, return to app, and refresh readiness without repeated prompts.",
                requiredEvidence: ["Permission recovery notes", "readiness check result"],
                status: "blocked"
            ),
            ManualAccessibilityScenario(
                id: "reduce-motion-contrast",
                title: "Reduce Motion and Increased Contrast keep recording, transcript, export, and recovery states readable.",
                requiredEvidence: ["Accessibility display variant screenshots"],
                status: "blocked"
            ),
            ManualAccessibilityScenario(
                id: "destructive-external-cancel-paths",
                title: "Delete, share, export handoff, and system-opening flows expose cancel/confirmation before side effects.",
                requiredEvidence: ["Cancel-path checklist", "confirmation screenshots"],
                status: "blocked"
            )
        ]
    }
}

ManualAccessibilityReleaseGate.main()
