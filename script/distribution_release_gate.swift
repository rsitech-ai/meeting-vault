#!/usr/bin/env swift
import Foundation

struct DistributionReleaseGateReport: Codable {
    var timestamp: String
    var status: String
    var requirePass: Bool
    var approvedReportPath: String?
    var readinessTarget: String
    var requiredScenarioCount: Int
    var passedScenarioCount: Int
    var requiredScenarios: [DistributionScenario]
    var validatedReport: DistributionApprovedReport?
    var distributionMode: String?
    var signedReleaseArtifactVerified: Bool
    var bundleSignatureVerified: Bool
    var entitlementProfileVerified: Bool
    var hardenedRuntimeVerified: Bool
    var gatekeeperAccepted: Bool
    var notarizationSubmitted: Bool
    var notarizationAccepted: Bool
    var stapleVerified: Bool
    var appStoreProvisioningVerified: Bool
    var appStoreUploadReady: Bool
    var appStoreConnectUploadAttempted: Bool
    var externalUploadAttempted: Bool
    var destructiveActionExecuted: Bool
    var rawSigningOutputStored: Bool
    var rawNotarizationOutputStored: Bool
    var rawCredentialStored: Bool
    var privateAudioRecorded: Bool
    var microphoneOpened: Bool
    var rawUITextStored: Bool
    var rawTranscriptStored: Bool
    var rawAudioStored: Bool
    var rawLogsStored: Bool
    var issues: [String]
}

struct DistributionScenario: Codable {
    var id: String
    var title: String
    var requiredEvidence: [String]
    var status: String
}

struct DistributionApprovedReport: Codable {
    var status: String
    var sourceCommit: String?
    var appVersion: String?
    var tester: String?
    var testedAt: String?
    var machineDescription: String?
    var distributionMode: String
    var scenarios: [ApprovedDistributionScenario]
    var evidenceArtifacts: [String]
    var signedReleaseArtifactVerified: Bool
    var bundleSignatureVerified: Bool
    var entitlementProfileVerified: Bool
    var hardenedRuntimeVerified: Bool
    var gatekeeperAccepted: Bool
    var notarizationSubmitted: Bool
    var notarizationAccepted: Bool
    var stapleVerified: Bool
    var appStoreProvisioningVerified: Bool
    var appStoreUploadReady: Bool
    var appStoreConnectUploadAttempted: Bool
    var externalUploadAttempted: Bool
    var destructiveActionExecuted: Bool
    var rawSigningOutputStored: Bool
    var rawNotarizationOutputStored: Bool
    var rawCredentialStored: Bool
    var privateAudioRecorded: Bool
    var microphoneOpened: Bool
    var rawUITextStored: Bool
    var rawTranscriptStored: Bool
    var rawAudioStored: Bool
    var rawLogsStored: Bool
    var notes: [String]?
}

struct ApprovedDistributionScenario: Codable {
    var id: String
    var status: String
    var evidence: [String]
}

enum DistributionReleaseGate {
    static func main() {
        let rootURL = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let date = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
        var outputURL = rootURL
            .appendingPathComponent("docs", isDirectory: true)
            .appendingPathComponent("evidence", isDirectory: true)
            .appendingPathComponent("distribution-release-gate-\(date).json")
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
                usage: script/distribution_release_gate.swift [--output PATH] [--approved-report PATH] [--write-template PATH] [--require-pass]

                Writes the release-candidate distribution gate for signed,
                notarized, or App Store-ready MeetingVault builds. Default
                behavior is blocked and does not sign, notarize, upload, open
                capture devices, delete data, or store raw signing/notary output.

                To pass, provide a bounded approved-report JSON proving either a
                direct Developer ID path with notarization accepted and stapled,
                or an App Store path with signed distribution packaging and a
                valid embedded provisioning profile. Evidence must omit raw
                credentials, raw signing output, raw notarization logs, private
                audio, transcripts, and raw app logs.
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
            return DistributionScenario(
                id: scenario.id,
                title: scenario.title,
                requiredEvidence: scenario.requiredEvidence,
                status: approved?.status ?? "blocked"
            )
        }

        let report = DistributionReleaseGateReport(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            status: status,
            requirePass: requirePass,
            approvedReportPath: approvedReportURL?.path,
            readinessTarget: "release-candidate",
            requiredScenarioCount: requiredScenarios.count,
            passedScenarioCount: passedScenarioCount,
            requiredScenarios: scenarios,
            validatedReport: validation.report,
            distributionMode: validation.report?.distributionMode,
            signedReleaseArtifactVerified: validation.report?.signedReleaseArtifactVerified ?? false,
            bundleSignatureVerified: validation.report?.bundleSignatureVerified ?? false,
            entitlementProfileVerified: validation.report?.entitlementProfileVerified ?? false,
            hardenedRuntimeVerified: validation.report?.hardenedRuntimeVerified ?? false,
            gatekeeperAccepted: validation.report?.gatekeeperAccepted ?? false,
            notarizationSubmitted: validation.report?.notarizationSubmitted ?? false,
            notarizationAccepted: validation.report?.notarizationAccepted ?? false,
            stapleVerified: validation.report?.stapleVerified ?? false,
            appStoreProvisioningVerified: validation.report?.appStoreProvisioningVerified ?? false,
            appStoreUploadReady: validation.report?.appStoreUploadReady ?? false,
            appStoreConnectUploadAttempted: validation.report?.appStoreConnectUploadAttempted ?? false,
            externalUploadAttempted: validation.report?.externalUploadAttempted ?? false,
            destructiveActionExecuted: validation.report?.destructiveActionExecuted ?? false,
            rawSigningOutputStored: validation.report?.rawSigningOutputStored ?? false,
            rawNotarizationOutputStored: validation.report?.rawNotarizationOutputStored ?? false,
            rawCredentialStored: validation.report?.rawCredentialStored ?? false,
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
            fputs("failed to write distribution release gate: \(error.localizedDescription)\n", stderr)
            exit(1)
        }

        print("Wrote \(outputURL.path)")
        print("status=\(report.status) passedScenarios=\(report.passedScenarioCount)/\(report.requiredScenarioCount)")
        exit(report.status == "pass" || !requirePass ? 0 : 1)
    }

    private static func validateApprovedReport(
        at url: URL?,
        requiredScenarios: [DistributionScenario]
    ) -> (report: DistributionApprovedReport?, issues: [String]) {
        guard let url else {
            return (nil, ["Distribution release gate requires --approved-report with bounded signed/notarized or App Store-ready package evidence."])
        }
        guard let data = try? Data(contentsOf: url) else {
            return (nil, ["Approved report could not be read at \(url.path)."])
        }
        let decoder = JSONDecoder()
        guard let report = try? decoder.decode(DistributionApprovedReport.self, from: data) else {
            return (nil, ["Approved report is not valid DistributionApprovedReport JSON."])
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
            issues.append("Approved report must identify the tester or release operator.")
        }
        if report.testedAt?.isEmpty ?? true {
            issues.append("Approved report must identify when distribution QA was run.")
        }
        if report.machineDescription?.isEmpty ?? true {
            issues.append("Approved report must describe the Mac, OS build, Xcode/command line toolchain, signing account setup, and distribution mode.")
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

        if report.distributionMode != "direct" && report.distributionMode != "app-store" {
            issues.append("Approved report distributionMode must be direct or app-store.")
        }
        if !report.signedReleaseArtifactVerified { issues.append("Approved report must prove a signed Release artifact was verified.") }
        if !report.bundleSignatureVerified { issues.append("Approved report must prove codesign verification passed.") }
        if !report.entitlementProfileVerified { issues.append("Approved report must prove entitlements or provisioning profile were verified.") }

        if report.distributionMode == "direct" {
            if !report.hardenedRuntimeVerified { issues.append("Direct distribution must prove hardened runtime is enabled.") }
            if !report.notarizationSubmitted { issues.append("Direct distribution must prove notarization was submitted after approval.") }
            if !report.notarizationAccepted { issues.append("Direct distribution must prove notarization was accepted.") }
            if !report.stapleVerified { issues.append("Direct distribution must prove notarization ticket stapling was verified.") }
            if !report.gatekeeperAccepted { issues.append("Direct distribution must prove Gatekeeper accepted the stapled app.") }
        }

        if report.distributionMode == "app-store" {
            if !report.appStoreProvisioningVerified { issues.append("App Store distribution must prove the embedded provisioning profile was verified.") }
            if !report.appStoreUploadReady { issues.append("App Store distribution must prove the package is upload-ready without performing an automatic upload.") }
        }

        if report.appStoreConnectUploadAttempted { issues.append("Approved report attempted App Store Connect upload.") }
        if report.externalUploadAttempted { issues.append("Approved report attempted an external upload outside the approved distribution evidence.") }
        if report.destructiveActionExecuted { issues.append("Approved report executed a destructive final action.") }
        if report.rawSigningOutputStored { issues.append("Approved report stored raw signing output.") }
        if report.rawNotarizationOutputStored { issues.append("Approved report stored raw notarization output.") }
        if report.rawCredentialStored { issues.append("Approved report stored raw credentials.") }
        if report.privateAudioRecorded { issues.append("Approved report recorded private audio.") }
        if report.microphoneOpened { issues.append("Approved report opened the microphone; distribution QA must not capture audio.") }
        if report.rawUITextStored { issues.append("Approved report stored raw UI text.") }
        if report.rawTranscriptStored { issues.append("Approved report stored raw transcript text.") }
        if report.rawAudioStored { issues.append("Approved report stored raw audio.") }
        if report.rawLogsStored { issues.append("Approved report stored raw logs.") }

        return (report, issues)
    }

    private static func writeTemplate(to url: URL, requiredScenarios: [DistributionScenario]) {
        let report = DistributionApprovedReport(
            status: "draft",
            sourceCommit: "TODO: git commit tested",
            appVersion: "TODO: tested app version, for example 0.1.0",
            tester: "TODO: release operator or QA role",
            testedAt: "TODO: ISO-8601 timestamp",
            machineDescription: "TODO: Mac model, macOS build, Xcode/CLT version, signing identity/profile setup, and distribution mode",
            distributionMode: "TODO: direct or app-store",
            scenarios: requiredScenarios.map {
                ApprovedDistributionScenario(
                    id: $0.id,
                    status: "blocked",
                    evidence: $0.requiredEvidence.map { "TODO: \($0)" }
                )
            },
            evidenceArtifacts: [
                "TODO: bounded artifact path, for example docs/evidence/distribution-release-summary-YYYY-MM-DD.json"
            ],
            signedReleaseArtifactVerified: false,
            bundleSignatureVerified: false,
            entitlementProfileVerified: false,
            hardenedRuntimeVerified: false,
            gatekeeperAccepted: false,
            notarizationSubmitted: false,
            notarizationAccepted: false,
            stapleVerified: false,
            appStoreProvisioningVerified: false,
            appStoreUploadReady: false,
            appStoreConnectUploadAttempted: false,
            externalUploadAttempted: false,
            destructiveActionExecuted: false,
            rawSigningOutputStored: false,
            rawNotarizationOutputStored: false,
            rawCredentialStored: false,
            privateAudioRecorded: false,
            microphoneOpened: false,
            rawUITextStored: false,
            rawTranscriptStored: false,
            rawAudioStored: false,
            rawLogsStored: false,
            notes: [
                "Replace every TODO with bounded evidence references before using this report.",
                "Do not paste certificates, keychain profile names, Apple IDs, raw codesign output, raw notary logs, transcripts, audio, UI dumps, private file paths, or credentials."
            ]
        )

        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: url, options: .atomic)
        } catch {
            fputs("failed to write distribution report template: \(error.localizedDescription)\n", stderr)
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

    private static func scenarioDefinitions() -> [DistributionScenario] {
        [
            DistributionScenario(
                id: "release-artifact-built",
                title: "Release app artifact was staged from a clean committed source revision.",
                requiredEvidence: ["source commit", "Release staging summary", "artifact path hash or bounded manifest"],
                status: "blocked"
            ),
            DistributionScenario(
                id: "identity-and-signature",
                title: "The app is signed with the intended distribution identity and codesign verification passes.",
                requiredEvidence: ["identity class summary", "codesign verification summary"],
                status: "blocked"
            ),
            DistributionScenario(
                id: "entitlements-runtime-profile",
                title: "Entitlements, hardened runtime, or App Store provisioning profile match the chosen distribution mode.",
                requiredEvidence: ["entitlements summary", "runtime/profile summary"],
                status: "blocked"
            ),
            DistributionScenario(
                id: "distribution-validation",
                title: "Direct builds are notarized and stapled, or App Store builds are package/upload-ready without automatic upload.",
                requiredEvidence: ["notary or App Store package validation summary"],
                status: "blocked"
            ),
            DistributionScenario(
                id: "trust-policy-validation",
                title: "Gatekeeper or App Store transport-facing validation accepts the distribution artifact.",
                requiredEvidence: ["trust validation summary"],
                status: "blocked"
            ),
            DistributionScenario(
                id: "evidence-redaction",
                title: "Evidence stores only bounded summaries and no raw credentials, signing output, notary logs, private content, or audio.",
                requiredEvidence: ["redaction checklist", "side-effect flags"],
                status: "blocked"
            )
        ]
    }
}

DistributionReleaseGate.main()
