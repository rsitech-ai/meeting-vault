#!/usr/bin/env swift
import Foundation

struct ProviderSmokeMatrixReport: Codable {
    var timestamp: String
    var status: String
    var requirePass: Bool
    var approvedReportPath: String?
    var requiredProviderIDs: [String]
    var providerCount: Int
    var passCount: Int
    var blockedCount: Int
    var failCount: Int
    var privateAudioRecorded: Bool
    var microphoneOpened: Bool
    var externalNetworkRequested: Bool
    var downloadRequested: Bool
    var rawTranscriptTextStoredInComponents: Bool
    var rawModelOutputStoredInComponents: Bool
    var rawAudioStoredInComponents: Bool
    var rawLogsStoredInComponents: Bool
    var providers: [ProviderSmokeSummary]
    var validatedReport: ProviderSmokeMatrixApprovedReport?
    var issues: [String]
}

struct ProviderSmokeSummary: Codable {
    var id: String
    var command: [String]
    var exitCode: Int32
    var outputPath: String
    var status: String
    var detailStatus: [String: String]
    var privateAudioRecorded: Bool
    var microphoneOpened: Bool
    var externalNetworkRequested: Bool
    var downloadRequested: Bool
    var storesRawTranscriptText: Bool
    var storesRawModelOutput: Bool
    var storesRawAudio: Bool
    var storesRawLogs: Bool
    var issues: [String]
}

struct ProviderSmokeMatrixApprovedReport: Codable {
    var status: String
    var sourceCommit: String?
    var appVersion: String?
    var tester: String?
    var testedAt: String?
    var machineDescription: String?
    var providers: [ApprovedProviderSmoke]
    var evidenceArtifacts: [String]
    var privateAudioRecorded: Bool
    var microphoneOpened: Bool
    var externalNetworkRequested: Bool
    var downloadRequested: Bool
    var rawTranscriptTextStoredInComponents: Bool
    var rawModelOutputStoredInComponents: Bool
    var rawAudioStoredInComponents: Bool
    var rawLogsStoredInComponents: Bool
    var notes: [String]?
}

struct ApprovedProviderSmoke: Codable {
    var id: String
    var status: String
    var evidence: [String]
    var detailStatus: [String: String]
    var privateAudioRecorded: Bool
    var microphoneOpened: Bool
    var externalNetworkRequested: Bool
    var downloadRequested: Bool
    var storesRawTranscriptText: Bool
    var storesRawModelOutput: Bool
    var storesRawAudio: Bool
    var storesRawLogs: Bool
}

struct ProviderSmokeDefinition {
    var id: String
    var scriptRelativePath: String
    var outputFileName: String
    var requiredDetailStatus: [String: String]
}

enum ProviderSmokeMatrix {
    static func main() {
        let rootURL = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let date = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
        var outputURL = rootURL
            .appendingPathComponent("docs", isDirectory: true)
            .appendingPathComponent("evidence", isDirectory: true)
            .appendingPathComponent("provider-smoke-matrix-\(date).json")
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
                usage: script/provider_smoke_matrix.swift [--output PATH] [--approved-report PATH] [--write-template PATH] [--require-pass]

                Runs or validates the non-private provider smoke matrix for the
                current production profile: Apple Speech live/final,
                SpeechAnalyzer final, and Foundation Models meeting intelligence
                plus transcript Q&A.

                Default behavior runs the component smokes and writes bounded
                blocked/pass evidence without recording private audio, opening
                the microphone, requesting downloads, or storing raw transcript
                or model output in the matrix. Approved-report mode validates a
                bounded report from a prepared real provider QA run.
                """)
                exit(0)
            default:
                fputs("unknown argument: \(argument)\n", stderr)
                exit(2)
            }
        }

        let definitions = providerDefinitions()
        if let templateURL {
            writeTemplate(to: templateURL, definitions: definitions)
            print("Wrote template \(templateURL.path)")
            exit(0)
        }

        let evidenceDate = evidenceDate(from: outputURL) ?? date
        let componentDirectory = rootURL
            .appendingPathComponent("docs", isDirectory: true)
            .appendingPathComponent("evidence", isDirectory: true)
            .appendingPathComponent("provider-smoke-matrix-\(evidenceDate)", isDirectory: true)

        let report: ProviderSmokeMatrixReport
        if approvedReportURL != nil {
            let validation = validateApprovedReport(at: approvedReportURL, definitions: definitions)
            let summaries = validation.report?.providers.map(summary(from:)) ?? []
            report = buildReport(
                summaries: summaries,
                requirePass: requirePass,
                approvedReportPath: approvedReportURL?.path,
                validatedReport: validation.report,
                validationIssues: validation.issues,
                definitions: definitions
            )
        } else {
            do {
                try FileManager.default.createDirectory(
                    at: componentDirectory,
                    withIntermediateDirectories: true
                )
            } catch {
                fputs("failed to create \(componentDirectory.path): \(error.localizedDescription)\n", stderr)
                exit(1)
            }

            let summaries = definitions.map { definition in
                run(definition: definition, rootURL: rootURL, componentDirectory: componentDirectory)
            }
            report = buildReport(
                summaries: summaries,
                requirePass: requirePass,
                approvedReportPath: nil,
                validatedReport: nil,
                validationIssues: [],
                definitions: definitions
            )
        }

        write(report: report, to: outputURL)
        print("Wrote \(outputURL.path)")
        print("status=\(report.status) pass=\(report.passCount) blocked=\(report.blockedCount) fail=\(report.failCount)")
        exit(report.status == "pass" || !requirePass ? 0 : 1)
    }

    private static func providerDefinitions() -> [ProviderSmokeDefinition] {
        [
            ProviderSmokeDefinition(
                id: "apple-speech-live-final",
                scriptRelativePath: "script/apple_speech_fixture_smoke.swift",
                outputFileName: "apple-speech.json",
                requiredDetailStatus: [
                    "authorizationState": "authorized",
                    "finalStatus": "pass",
                    "liveStatus": "pass"
                ]
            ),
            ProviderSmokeDefinition(
                id: "speech-analyzer-final",
                scriptRelativePath: "script/speech_analyzer_fixture_smoke.swift",
                outputFileName: "speech-analyzer.json",
                requiredDetailStatus: [
                    "assetStatus": "installed",
                    "transcriptionStatus": "pass"
                ]
            ),
            ProviderSmokeDefinition(
                id: "foundation-models-intelligence-qa",
                scriptRelativePath: "script/foundation_models_fixture_smoke.swift",
                outputFileName: "foundation-models.json",
                requiredDetailStatus: [
                    "availabilityStatus": "available",
                    "intelligenceStatus": "pass",
                    "transcriptQuestionAnswerStatus": "pass"
                ]
            )
        ]
    }

    private static func run(
        definition: ProviderSmokeDefinition,
        rootURL: URL,
        componentDirectory: URL
    ) -> ProviderSmokeSummary {
        let outputURL = componentDirectory.appendingPathComponent(definition.outputFileName)
        let scriptPath = rootURL.appendingPathComponent(definition.scriptRelativePath).path
        let command = [scriptPath, "--output", outputURL.path]
        let process = Process()
        process.executableURL = URL(fileURLWithPath: scriptPath)
        process.arguments = ["--output", outputURL.path]
        process.currentDirectoryURL = rootURL

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ProviderSmokeSummary(
                id: definition.id,
                command: command,
                exitCode: -1,
                outputPath: outputURL.path,
                status: "fail",
                detailStatus: [:],
                privateAudioRecorded: false,
                microphoneOpened: false,
                externalNetworkRequested: false,
                downloadRequested: false,
                storesRawTranscriptText: false,
                storesRawModelOutput: false,
                storesRawAudio: false,
                storesRawLogs: false,
                issues: ["Could not run provider smoke: \(error.localizedDescription)"]
            )
        }

        guard let json = readJSONObject(at: outputURL) else {
            return ProviderSmokeSummary(
                id: definition.id,
                command: command,
                exitCode: process.terminationStatus,
                outputPath: outputURL.path,
                status: "fail",
                detailStatus: [:],
                privateAudioRecorded: false,
                microphoneOpened: false,
                externalNetworkRequested: false,
                downloadRequested: false,
                storesRawTranscriptText: false,
                storesRawModelOutput: false,
                storesRawAudio: false,
                storesRawLogs: false,
                issues: ["Provider smoke did not write readable JSON evidence."]
            )
        }

        let status = stringValue(json["status"]) ?? "fail"
        let normalizedStatus = process.terminationStatus == 0 ? status : "fail"
        var detailStatus: [String: String] = [:]
        for key in [
            "authorizationState",
            "finalStatus",
            "liveStatus",
            "transcriptionStatus",
            "assetStatus",
            "availabilityStatus",
            "intelligenceStatus",
            "transcriptQuestionAnswerStatus"
        ] {
            if let value = stringValue(json[key]) {
                detailStatus[key] = value
            }
        }

        return ProviderSmokeSummary(
            id: definition.id,
            command: command,
            exitCode: process.terminationStatus,
            outputPath: outputURL.path,
            status: normalizedStatus,
            detailStatus: detailStatus,
            privateAudioRecorded: boolValue(json["privateAudioRecorded"]),
            microphoneOpened: boolValue(json["microphoneOpened"]),
            externalNetworkRequested: boolValue(json["externalNetworkRequested"]),
            downloadRequested: boolValue(json["downloadRequested"]),
            storesRawTranscriptText: hasRawTranscriptText(in: json),
            storesRawModelOutput: boolValue(json["rawModelOutputStored"]),
            storesRawAudio: boolValue(json["rawAudioStored"]),
            storesRawLogs: boolValue(json["rawLogsStored"]),
            issues: stringArray(json["issues"]) + (process.terminationStatus == 0 ? [] : ["Provider smoke exited \(process.terminationStatus)."])
        )
    }

    private static func validateApprovedReport(
        at url: URL?,
        definitions: [ProviderSmokeDefinition]
    ) -> (report: ProviderSmokeMatrixApprovedReport?, issues: [String]) {
        guard let url else {
            return (nil, ["Provider smoke matrix requires --approved-report with bounded real provider evidence."])
        }
        guard let data = try? Data(contentsOf: url) else {
            return (nil, ["Approved report could not be read at \(url.path)."])
        }
        let decoder = JSONDecoder()
        guard let report = try? decoder.decode(ProviderSmokeMatrixApprovedReport.self, from: data) else {
            return (nil, ["Approved report is not valid ProviderSmokeMatrixApprovedReport JSON."])
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
            issues.append("Approved report must identify when provider QA was run.")
        }
        if report.machineDescription?.isEmpty ?? true {
            issues.append("Approved report must describe the Mac, OS build, app install, provider setup, and non-private fixture.")
        } else if containsPlaceholder(report.machineDescription ?? "") {
            issues.append("Approved report machine description contains a template placeholder.")
        }
        if report.evidenceArtifacts.isEmpty {
            issues.append("Approved report must list bounded evidence artifacts.")
        }
        appendPlaceholderIssues(values: report.evidenceArtifacts, label: "Approved report evidence artifact", to: &issues)

        var supplied: [String: ApprovedProviderSmoke] = [:]
        for provider in report.providers {
            if supplied[provider.id] != nil {
                issues.append("Approved report contains duplicate provider \(provider.id).")
            }
            supplied[provider.id] = provider
        }
        let requiredIDs = Set(definitions.map(\.id))
        for definition in definitions {
            guard let provider = supplied[definition.id] else {
                issues.append("Approved report is missing provider \(definition.id).")
                continue
            }
            validate(provider: provider, definition: definition, issues: &issues)
        }
        for extra in supplied.keys where !requiredIDs.contains(extra) {
            issues.append("Approved report contains unknown provider \(extra).")
        }

        if report.privateAudioRecorded { issues.append("Approved report recorded private audio.") }
        if report.microphoneOpened { issues.append("Approved report opened the microphone; provider matrix evidence must use fixture/provider handoffs only.") }
        if report.externalNetworkRequested { issues.append("Approved report requested external network.") }
        if report.downloadRequested { issues.append("Approved report downloaded assets during provider matrix validation.") }
        if report.rawTranscriptTextStoredInComponents { issues.append("Approved report stored raw transcript text in component evidence.") }
        if report.rawModelOutputStoredInComponents { issues.append("Approved report stored raw model output in component evidence.") }
        if report.rawAudioStoredInComponents { issues.append("Approved report stored raw audio in component evidence.") }
        if report.rawLogsStoredInComponents { issues.append("Approved report stored raw logs in component evidence.") }

        return (report, issues)
    }

    private static func validate(
        provider: ApprovedProviderSmoke,
        definition: ProviderSmokeDefinition,
        issues: inout [String]
    ) {
        if provider.status != "pass" {
            issues.append("Provider \(definition.id) is \(provider.status); expected pass.")
        }
        if provider.evidence.isEmpty {
            issues.append("Provider \(definition.id) must list bounded evidence.")
        }
        appendPlaceholderIssues(values: provider.evidence, label: "Provider \(definition.id) evidence", to: &issues)
        for required in definition.requiredDetailStatus {
            let actual = provider.detailStatus[required.key]
            if actual != required.value {
                issues.append("Provider \(definition.id) detail \(required.key) is \(actual ?? "missing"); expected \(required.value).")
            }
        }
        if provider.privateAudioRecorded { issues.append("Provider \(definition.id) recorded private audio.") }
        if provider.microphoneOpened { issues.append("Provider \(definition.id) opened the microphone.") }
        if provider.externalNetworkRequested { issues.append("Provider \(definition.id) requested external network.") }
        if provider.downloadRequested { issues.append("Provider \(definition.id) requested downloads during validation.") }
        if provider.storesRawTranscriptText { issues.append("Provider \(definition.id) stored raw transcript text.") }
        if provider.storesRawModelOutput { issues.append("Provider \(definition.id) stored raw model output.") }
        if provider.storesRawAudio { issues.append("Provider \(definition.id) stored raw audio.") }
        if provider.storesRawLogs { issues.append("Provider \(definition.id) stored raw logs.") }
    }

    private static func summary(from provider: ApprovedProviderSmoke) -> ProviderSmokeSummary {
        ProviderSmokeSummary(
            id: provider.id,
            command: [],
            exitCode: 0,
            outputPath: "approved-report",
            status: provider.status,
            detailStatus: provider.detailStatus,
            privateAudioRecorded: provider.privateAudioRecorded,
            microphoneOpened: provider.microphoneOpened,
            externalNetworkRequested: provider.externalNetworkRequested,
            downloadRequested: provider.downloadRequested,
            storesRawTranscriptText: provider.storesRawTranscriptText,
            storesRawModelOutput: provider.storesRawModelOutput,
            storesRawAudio: provider.storesRawAudio,
            storesRawLogs: provider.storesRawLogs,
            issues: []
        )
    }

    private static func buildReport(
        summaries: [ProviderSmokeSummary],
        requirePass: Bool,
        approvedReportPath: String?,
        validatedReport: ProviderSmokeMatrixApprovedReport?,
        validationIssues: [String],
        definitions: [ProviderSmokeDefinition]
    ) -> ProviderSmokeMatrixReport {
        let failCount = summaries.filter { $0.status == "fail" }.count
        let blockedCount = summaries.filter { $0.status == "blocked" }.count
        let passCount = summaries.filter { $0.status == "pass" }.count
        let status: String
        if failCount > 0 {
            status = "fail"
        } else if blockedCount > 0 || !validationIssues.isEmpty || passCount != definitions.count {
            status = "blocked"
        } else {
            status = "pass"
        }

        let componentIssues = summaries.flatMap { summary in
            summary.issues.map { "\(summary.id): \($0)" }
        }
        return ProviderSmokeMatrixReport(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            status: status,
            requirePass: requirePass,
            approvedReportPath: approvedReportPath,
            requiredProviderIDs: definitions.map(\.id),
            providerCount: definitions.count,
            passCount: passCount,
            blockedCount: blockedCount,
            failCount: failCount,
            privateAudioRecorded: summaries.contains { $0.privateAudioRecorded },
            microphoneOpened: summaries.contains { $0.microphoneOpened },
            externalNetworkRequested: summaries.contains { $0.externalNetworkRequested },
            downloadRequested: summaries.contains { $0.downloadRequested },
            rawTranscriptTextStoredInComponents: summaries.contains { $0.storesRawTranscriptText },
            rawModelOutputStoredInComponents: summaries.contains { $0.storesRawModelOutput },
            rawAudioStoredInComponents: summaries.contains { $0.storesRawAudio },
            rawLogsStoredInComponents: summaries.contains { $0.storesRawLogs },
            providers: summaries,
            validatedReport: validatedReport,
            issues: componentIssues + validationIssues
        )
    }

    private static func writeTemplate(to url: URL, definitions: [ProviderSmokeDefinition]) {
        let report = ProviderSmokeMatrixApprovedReport(
            status: "draft",
            sourceCommit: "TODO: git commit tested",
            appVersion: "TODO: tested app version, for example 0.1.0",
            tester: "TODO: tester or QA role",
            testedAt: "TODO: ISO-8601 timestamp",
            machineDescription: "TODO: Mac model, macOS build, installed MeetingVault app, Speech authorization, SpeechAnalyzer assets, Foundation Models availability, and non-private fixture description",
            providers: definitions.map { definition in
                ApprovedProviderSmoke(
                    id: definition.id,
                    status: "blocked",
                    evidence: ["TODO: bounded \(definition.id) component evidence path"],
                    detailStatus: definition.requiredDetailStatus.mapValues { "TODO: expected \($0)" },
                    privateAudioRecorded: false,
                    microphoneOpened: false,
                    externalNetworkRequested: false,
                    downloadRequested: false,
                    storesRawTranscriptText: false,
                    storesRawModelOutput: false,
                    storesRawAudio: false,
                    storesRawLogs: false
                )
            },
            evidenceArtifacts: [
                "TODO: bounded artifact path, for example docs/evidence/provider-smoke-matrix-approved-YYYY-MM-DD.json"
            ],
            privateAudioRecorded: false,
            microphoneOpened: false,
            externalNetworkRequested: false,
            downloadRequested: false,
            rawTranscriptTextStoredInComponents: false,
            rawModelOutputStoredInComponents: false,
            rawAudioStoredInComponents: false,
            rawLogsStoredInComponents: false,
            notes: [
                "Replace every TODO with bounded evidence references before using this report.",
                "Do not paste raw transcripts, raw model output, raw audio, logs, account details, or private file paths.",
                "Provider matrix approval assumes SpeechAnalyzer assets were installed before the validation run, not downloaded during this matrix validation."
            ]
        )

        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: url, options: .atomic)
        } catch {
            fputs("failed to write provider matrix template: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func readJSONObject(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data),
              let json = object as? [String: Any] else {
            return nil
        }
        return json
    }

    private static func write(report: ProviderSmokeMatrixReport, to outputURL: URL) {
        do {
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: outputURL, options: .atomic)
        } catch {
            fputs("failed to write \(outputURL.path): \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func stringValue(_ value: Any?) -> String? {
        value as? String
    }

    private static func boolValue(_ value: Any?) -> Bool {
        value as? Bool ?? false
    }

    private static func stringArray(_ value: Any?) -> [String] {
        value as? [String] ?? []
    }

    private static func hasRawTranscriptText(in json: [String: Any]) -> Bool {
        for key in ["finalTranscriptText", "liveTranscriptText", "transcriptText"] {
            if let value = json[key] as? String, !value.isEmpty {
                return true
            }
        }
        return boolValue(json["rawTranscriptStored"])
    }

    private static func evidenceDate(from outputURL: URL) -> String? {
        let name = outputURL.lastPathComponent
        guard name.hasPrefix("provider-smoke-matrix-"),
              name.hasSuffix(".json") else {
            return nil
        }
        let date = String(name
            .dropFirst("provider-smoke-matrix-".count)
            .dropLast(".json".count))
        guard isValidEvidenceDate(date) else {
            return nil
        }
        return date
    }

    private static func isValidEvidenceDate(_ value: String) -> Bool {
        let parts = value.split(separator: "-")
        guard parts.count == 3,
              parts[0].count == 4,
              parts[1].count == 2,
              parts[2].count == 2 else {
            return false
        }
        return parts.allSatisfy { part in
            part.allSatisfy(\.isNumber)
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
}

ProviderSmokeMatrix.main()
