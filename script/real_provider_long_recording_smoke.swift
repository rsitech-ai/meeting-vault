#!/usr/bin/env swift
import Foundation

struct RealProviderLongRecordingSmokeReport: Codable {
    var timestamp: String
    var status: String
    var requirePass: Bool
    var approvedReportPath: String?
    var approvedRealCapture: Bool
    var approvedRealProviders: Bool
    var nonPrivateAudioConfirmed: Bool
    var durationSeconds: Int
    var minimumDurationSeconds: Int
    var requestedCaptureModes: [String]
    var requiredScenarioCount: Int
    var passedScenarioCount: Int
    var requiredScenarios: [RealProviderLongRecordingScenario]
    var validatedReport: RealProviderLongRecordingApprovedReport?
    var providerRequirements: [String]
    var providerMatrixPassed: Bool
    var captureModesPassed: [String]
    var appLaunchVerified: Bool
    var recordingStartStopVerified: Bool
    var selectedAudioInputVisible: Bool
    var selectedAudioInputMatchesCapture: Bool
    var speechActivityMonitorVisible: Bool
    var speechActivityMonitorResponded: Bool
    var liveTranscriptVisible: Bool
    var liveTranscriptUpdatedDuringRecording: Bool
    var liveTranscriptFirstPartialLatencySeconds: Double?
    var maximumLiveTranscriptFirstPartialLatencySeconds: Double
    var finalTranscriptPersisted: Bool
    var generatedTitleFromContentVerified: Bool
    var groundedSummaryVerified: Bool
    var libraryPersistenceVerified: Bool
    var transcriptAgentQuestionAnswered: Bool
    var transcriptAgentEvidenceCount: Int
    var agentResponseEditable: Bool
    var agentResponseCopied: Bool
    var agentResponseCopyMatchesEditedText: Bool
    var recoveryStateReviewed: Bool
    var crashLogReviewed: Bool
    var encryptedStorageVerified: Bool
    var privateAudioRecorded: Bool
    var microphoneOpened: Bool
    var systemAudioCaptureAttempted: Bool
    var externalNetworkRequested: Bool
    var downloadRequested: Bool
    var externalUploadAttempted: Bool
    var rawTranscriptStored: Bool
    var rawAudioStored: Bool
    var rawLogsStored: Bool
    var rawModelOutputStored: Bool
    var rawUITextStored: Bool
    var temporaryWorkspaceDeleted: Bool
    var nextCommands: [String]
    var issues: [String]
}

struct RealProviderLongRecordingScenario: Codable {
    var id: String
    var title: String
    var requiredEvidence: [String]
    var status: String
}

struct RealProviderLongRecordingApprovedReport: Codable {
    var status: String
    var sourceCommit: String?
    var appVersion: String?
    var tester: String?
    var testedAt: String?
    var machineDescription: String?
    var durationSeconds: Int
    var minimumDurationSeconds: Int
    var scenarios: [ApprovedRealProviderLongRecordingScenario]
    var evidenceArtifacts: [String]
    var approvedRealCapture: Bool
    var approvedRealProviders: Bool
    var nonPrivateAudioConfirmed: Bool
    var providerMatrixPassed: Bool
    var captureModesPassed: [String]
    var appLaunchVerified: Bool
    var recordingStartStopVerified: Bool
    var selectedAudioInputVisible: Bool
    var selectedAudioInputMatchesCapture: Bool
    var speechActivityMonitorVisible: Bool
    var speechActivityMonitorResponded: Bool
    var liveTranscriptVisible: Bool
    var liveTranscriptUpdatedDuringRecording: Bool
    var liveTranscriptFirstPartialLatencySeconds: Double?
    var maximumLiveTranscriptFirstPartialLatencySeconds: Double
    var finalTranscriptPersisted: Bool
    var generatedTitleFromContentVerified: Bool
    var groundedSummaryVerified: Bool
    var libraryPersistenceVerified: Bool
    var transcriptAgentQuestionAnswered: Bool
    var transcriptAgentEvidenceCount: Int
    var agentResponseEditable: Bool
    var agentResponseCopied: Bool
    var agentResponseCopyMatchesEditedText: Bool
    var recoveryStateReviewed: Bool
    var crashLogReviewed: Bool
    var encryptedStorageVerified: Bool
    var privateAudioRecorded: Bool
    var microphoneOpened: Bool
    var systemAudioCaptureAttempted: Bool
    var externalNetworkRequested: Bool
    var downloadRequested: Bool
    var externalUploadAttempted: Bool
    var rawTranscriptStored: Bool
    var rawAudioStored: Bool
    var rawLogsStored: Bool
    var rawModelOutputStored: Bool
    var rawUITextStored: Bool
    var temporaryWorkspaceDeleted: Bool
    var notes: [String]?
}

struct ApprovedRealProviderLongRecordingScenario: Codable {
    var id: String
    var status: String
    var evidence: [String]
}

enum RealProviderLongRecordingSmoke {
    static func main() {
        let rootURL = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let date = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
        var outputURL = rootURL
            .appendingPathComponent("docs", isDirectory: true)
            .appendingPathComponent("evidence", isDirectory: true)
            .appendingPathComponent("real-provider-long-recording-smoke-\(date).json")
        var approvedReportURL: URL?
        var templateURL: URL?
        var requirePass = false
        var approvedRealCapture = false
        var approvedRealProviders = false
        var nonPrivateAudioConfirmed = false
        var durationSeconds = 3_600
        var minimumDurationSeconds = 3_600
        var requestedCaptureModes = [
            "selected-microphone",
            "core-audio",
            "screen-capture-kit"
        ]

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
            case "--approve-real-capture":
                approvedRealCapture = true
            case "--approve-real-providers":
                approvedRealProviders = true
            case "--non-private-audio-confirmed":
                nonPrivateAudioConfirmed = true
            case "--duration-seconds":
                guard let value = iterator.next(), let seconds = Int(value), seconds > 0 else {
                    fputs("--duration-seconds requires a positive integer\n", stderr)
                    exit(2)
                }
                durationSeconds = seconds
            case "--minimum-duration-seconds":
                guard let value = iterator.next(), let seconds = Int(value), seconds > 0 else {
                    fputs("--minimum-duration-seconds requires a positive integer\n", stderr)
                    exit(2)
                }
                minimumDurationSeconds = seconds
            case "--mode":
                guard let value = iterator.next(),
                      Self.supportedCaptureModes.contains(value) else {
                    fputs("--mode requires selected-microphone, core-audio, or screen-capture-kit\n", stderr)
                    exit(2)
                }
                if requestedCaptureModes.count == Self.supportedCaptureModes.count {
                    requestedCaptureModes = []
                }
                requestedCaptureModes.append(value)
            case "--help", "-h":
                print("""
                usage: script/real_provider_long_recording_smoke.swift [--output PATH] [--duration-seconds N] [--minimum-duration-seconds N] [--mode selected-microphone|core-audio|screen-capture-kit] [--approve-real-capture --approve-real-providers --non-private-audio-confirmed] [--approved-report PATH] [--write-template PATH] [--require-pass]

                Writes the release-candidate gate for real-provider long-recording
                QA. Default behavior is safe and blocked: it does not open the
                microphone, start system audio capture, download assets, call
                provider APIs, or store raw audio/transcript/log text.

                To pass, provide a bounded approved-report JSON from an approved
                non-private app run long enough to exercise real capture, live
                transcription, final transcription, Core AI title/summary,
                selected input visibility, speech activity monitor motion,
                library persistence, transcript-agent Q&A, editable/copyable
                answers, recovery review, crash/log review, and redaction.
                """)
                exit(0)
            default:
                fputs("unknown argument: \(argument)\n", stderr)
                exit(2)
            }
        }

        let requiredScenarios = scenarioDefinitions()
        if let templateURL {
            writeTemplate(
                to: templateURL,
                requiredScenarios: requiredScenarios,
                durationSeconds: durationSeconds,
                minimumDurationSeconds: minimumDurationSeconds,
                requestedCaptureModes: requestedCaptureModes
            )
            print("Wrote template \(templateURL.path)")
            exit(0)
        }

        let validation = validateApprovedReport(
            at: approvedReportURL,
            requiredScenarios: requiredScenarios,
            requestedCaptureModes: requestedCaptureModes,
            minimumDurationSeconds: minimumDurationSeconds
        )
        let approved = validation.report
        let passedScenarioCount = approved?.scenarios
            .filter { $0.status == "pass" }
            .count ?? 0

        var issues = validation.issues
        if !approvedRealCapture {
            issues.append("Real capture approval is required: add --approve-real-capture only for prepared non-private audio QA.")
        }
        if !approvedRealProviders {
            issues.append("Real provider approval is required: add --approve-real-providers only after Speech Recognition, SpeechAnalyzer assets, and Foundation Models availability are intentionally prepared.")
        }
        if !nonPrivateAudioConfirmed {
            issues.append("Non-private audio confirmation is required: add --non-private-audio-confirmed only when the test input contains no private meeting content.")
        }
        if durationSeconds < minimumDurationSeconds {
            issues.append("Requested duration \(durationSeconds)s is shorter than minimum release-candidate duration \(minimumDurationSeconds)s.")
        }

        let status = issues.isEmpty ? "pass" : "blocked"
        let scenarios = requiredScenarios.map { scenario in
            let approvedScenario = approved?.scenarios.first { $0.id == scenario.id }
            return RealProviderLongRecordingScenario(
                id: scenario.id,
                title: scenario.title,
                requiredEvidence: scenario.requiredEvidence,
                status: approvedScenario?.status ?? "blocked"
            )
        }

        let report = RealProviderLongRecordingSmokeReport(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            status: status,
            requirePass: requirePass,
            approvedReportPath: approvedReportURL?.path,
            approvedRealCapture: approved?.approvedRealCapture ?? approvedRealCapture,
            approvedRealProviders: approved?.approvedRealProviders ?? approvedRealProviders,
            nonPrivateAudioConfirmed: approved?.nonPrivateAudioConfirmed ?? nonPrivateAudioConfirmed,
            durationSeconds: approved?.durationSeconds ?? durationSeconds,
            minimumDurationSeconds: max(approved?.minimumDurationSeconds ?? minimumDurationSeconds, minimumDurationSeconds),
            requestedCaptureModes: requestedCaptureModes,
            requiredScenarioCount: requiredScenarios.count,
            passedScenarioCount: passedScenarioCount,
            requiredScenarios: scenarios,
            validatedReport: approved,
            providerRequirements: providerRequirements(),
            providerMatrixPassed: approved?.providerMatrixPassed ?? false,
            captureModesPassed: approved?.captureModesPassed ?? [],
            appLaunchVerified: approved?.appLaunchVerified ?? false,
            recordingStartStopVerified: approved?.recordingStartStopVerified ?? false,
            selectedAudioInputVisible: approved?.selectedAudioInputVisible ?? false,
            selectedAudioInputMatchesCapture: approved?.selectedAudioInputMatchesCapture ?? false,
            speechActivityMonitorVisible: approved?.speechActivityMonitorVisible ?? false,
            speechActivityMonitorResponded: approved?.speechActivityMonitorResponded ?? false,
            liveTranscriptVisible: approved?.liveTranscriptVisible ?? false,
            liveTranscriptUpdatedDuringRecording: approved?.liveTranscriptUpdatedDuringRecording ?? false,
            liveTranscriptFirstPartialLatencySeconds: approved?.liveTranscriptFirstPartialLatencySeconds,
            maximumLiveTranscriptFirstPartialLatencySeconds: approved?.maximumLiveTranscriptFirstPartialLatencySeconds ?? Self.maximumLiveTranscriptFirstPartialLatencySeconds,
            finalTranscriptPersisted: approved?.finalTranscriptPersisted ?? false,
            generatedTitleFromContentVerified: approved?.generatedTitleFromContentVerified ?? false,
            groundedSummaryVerified: approved?.groundedSummaryVerified ?? false,
            libraryPersistenceVerified: approved?.libraryPersistenceVerified ?? false,
            transcriptAgentQuestionAnswered: approved?.transcriptAgentQuestionAnswered ?? false,
            transcriptAgentEvidenceCount: approved?.transcriptAgentEvidenceCount ?? 0,
            agentResponseEditable: approved?.agentResponseEditable ?? false,
            agentResponseCopied: approved?.agentResponseCopied ?? false,
            agentResponseCopyMatchesEditedText: approved?.agentResponseCopyMatchesEditedText ?? false,
            recoveryStateReviewed: approved?.recoveryStateReviewed ?? false,
            crashLogReviewed: approved?.crashLogReviewed ?? false,
            encryptedStorageVerified: approved?.encryptedStorageVerified ?? false,
            privateAudioRecorded: approved?.privateAudioRecorded ?? false,
            microphoneOpened: approved?.microphoneOpened ?? false,
            systemAudioCaptureAttempted: approved?.systemAudioCaptureAttempted ?? false,
            externalNetworkRequested: approved?.externalNetworkRequested ?? false,
            downloadRequested: approved?.downloadRequested ?? false,
            externalUploadAttempted: approved?.externalUploadAttempted ?? false,
            rawTranscriptStored: approved?.rawTranscriptStored ?? false,
            rawAudioStored: approved?.rawAudioStored ?? false,
            rawLogsStored: approved?.rawLogsStored ?? false,
            rawModelOutputStored: approved?.rawModelOutputStored ?? false,
            rawUITextStored: approved?.rawUITextStored ?? false,
            temporaryWorkspaceDeleted: approved?.temporaryWorkspaceDeleted ?? true,
            nextCommands: nextCommands(
                modes: requestedCaptureModes,
                durationSeconds: durationSeconds
            ),
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
            fputs("failed to write real-provider long-recording report: \(error.localizedDescription)\n", stderr)
            exit(1)
        }

        print("Wrote \(outputURL.path)")
        print("status=\(report.status) passedScenarios=\(report.passedScenarioCount)/\(report.requiredScenarioCount) durationSeconds=\(report.durationSeconds)")
        exit(report.status == "pass" || !requirePass ? 0 : 1)
    }

    private static let supportedCaptureModes = [
        "selected-microphone",
        "core-audio",
        "screen-capture-kit"
    ]
    private static let maximumLiveTranscriptFirstPartialLatencySeconds = 15.0

    private static func validateApprovedReport(
        at url: URL?,
        requiredScenarios: [RealProviderLongRecordingScenario],
        requestedCaptureModes: [String],
        minimumDurationSeconds: Int
    ) -> (report: RealProviderLongRecordingApprovedReport?, issues: [String]) {
        guard let url else {
            return (nil, ["Real-provider long-recording gate requires --approved-report with bounded one-hour app-run evidence."])
        }
        guard let data = try? Data(contentsOf: url) else {
            return (nil, ["Approved report could not be read at \(url.path)."])
        }
        let decoder = JSONDecoder()
        guard let report = try? decoder.decode(RealProviderLongRecordingApprovedReport.self, from: data) else {
            return (nil, ["Approved report is not valid RealProviderLongRecordingApprovedReport JSON."])
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
            issues.append("Approved report must identify when long-recording QA was run.")
        }
        if report.machineDescription?.isEmpty ?? true {
            issues.append("Approved report must describe the Mac, OS build, app install, provider setup, and non-private audio fixture.")
        } else if containsPlaceholder(report.machineDescription ?? "") {
            issues.append("Approved report machine description contains a template placeholder.")
        }
        if report.durationSeconds < minimumDurationSeconds {
            issues.append("Approved report duration \(report.durationSeconds)s is shorter than required \(minimumDurationSeconds)s.")
        }
        if report.minimumDurationSeconds < minimumDurationSeconds {
            issues.append("Approved report minimum duration \(report.minimumDurationSeconds)s is shorter than required \(minimumDurationSeconds)s.")
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

        let approvedModes = Set(report.captureModesPassed)
        for mode in report.captureModesPassed where !supportedCaptureModes.contains(mode) {
            issues.append("Approved report contains unsupported capture mode \(mode).")
        }
        for mode in requestedCaptureModes where !approvedModes.contains(mode) {
            issues.append("Approved report must prove requested capture mode \(mode).")
        }
        if approvedModes.contains("selected-microphone") && !report.microphoneOpened {
            issues.append("Approved report says selected-microphone mode passed but microphoneOpened is false.")
        }
        let approvedSystemAudioModes = approvedModes.intersection(["core-audio", "screen-capture-kit"])
        if !approvedSystemAudioModes.isEmpty && !report.systemAudioCaptureAttempted {
            issues.append("Approved report says system audio mode passed but systemAudioCaptureAttempted is false.")
        }

        if !report.approvedRealCapture { issues.append("Approved report must prove real capture was explicitly approved.") }
        if !report.approvedRealProviders { issues.append("Approved report must prove real providers were explicitly approved.") }
        if !report.nonPrivateAudioConfirmed { issues.append("Approved report must confirm only non-private audio/transcript fixtures were used.") }
        if !report.providerMatrixPassed { issues.append("Approved report must prove provider smoke matrix passed before the long run.") }
        if !report.appLaunchVerified { issues.append("Approved report must prove the app launched through the verified build/run path.") }
        if !report.recordingStartStopVerified { issues.append("Approved report must prove visible start/stop and finalization completed.") }
        if !report.selectedAudioInputVisible { issues.append("Approved report must prove the selected audio input and picker were visible before recording.") }
        if !report.selectedAudioInputMatchesCapture { issues.append("Approved report must prove the selected audio input matched the input used by the capture session.") }
        if !report.speechActivityMonitorVisible { issues.append("Approved report must prove the speech activity monitor was visible during recording.") }
        if !report.speechActivityMonitorResponded { issues.append("Approved report must prove the speech activity monitor responded to the non-private input during recording.") }
        if !report.liveTranscriptVisible { issues.append("Approved report must prove live transcript was visible during recording.") }
        if !report.liveTranscriptUpdatedDuringRecording { issues.append("Approved report must prove live transcript updated while recording, not only after Stop.") }
        if report.maximumLiveTranscriptFirstPartialLatencySeconds <= 0 {
            issues.append("Approved report maximum live transcript first-partial latency must be positive.")
        } else if report.maximumLiveTranscriptFirstPartialLatencySeconds > Self.maximumLiveTranscriptFirstPartialLatencySeconds {
            issues.append("Approved report maximum live transcript first-partial latency must be no more than \(Self.maximumLiveTranscriptFirstPartialLatencySeconds)s.")
        }
        if let firstPartialLatency = report.liveTranscriptFirstPartialLatencySeconds {
            if firstPartialLatency < 0 {
                issues.append("Approved report live transcript first-partial latency cannot be negative.")
            }
            if firstPartialLatency > report.maximumLiveTranscriptFirstPartialLatencySeconds {
                issues.append("Approved report live transcript first partial took \(firstPartialLatency)s, exceeding \(report.maximumLiveTranscriptFirstPartialLatencySeconds)s.")
            }
        } else {
            issues.append("Approved report must record bounded first live transcript partial latency.")
        }
        if !report.finalTranscriptPersisted { issues.append("Approved report must prove final transcript persisted after stop.") }
        if !report.generatedTitleFromContentVerified { issues.append("Approved report must prove Core AI generated the title from recording contents.") }
        if !report.groundedSummaryVerified { issues.append("Approved report must prove grounded summary/action intelligence generated from transcript evidence.") }
        if !report.libraryPersistenceVerified { issues.append("Approved report must prove the completed meeting persisted in the searchable library.") }
        if !report.transcriptAgentQuestionAnswered { issues.append("Approved report must prove Transcript Agent answered a question grounded in the transcript.") }
        if report.transcriptAgentEvidenceCount <= 0 { issues.append("Approved report must prove Transcript Agent answer included at least one transcript evidence segment.") }
        if !report.agentResponseEditable { issues.append("Approved report must prove the Transcript Agent response was editable.") }
        if !report.agentResponseCopied { issues.append("Approved report must prove the Transcript Agent response copy action worked.") }
        if !report.agentResponseCopyMatchesEditedText { issues.append("Approved report must prove copied Agent response matched the edited response text, not the original provider output.") }
        if !report.recoveryStateReviewed { issues.append("Approved report must prove Health & Recovery was reviewed after the long run.") }
        if !report.crashLogReviewed { issues.append("Approved report must prove crash/log review found no release-blocking errors.") }
        if !report.encryptedStorageVerified { issues.append("Approved report must prove storage remains encrypted and no raw audio/transcript files were persisted.") }
        if report.privateAudioRecorded { issues.append("Approved report recorded private audio.") }
        if report.externalNetworkRequested { issues.append("Approved report requested external network.") }
        if report.downloadRequested { issues.append("Approved report downloaded assets during the long-recording run.") }
        if report.externalUploadAttempted { issues.append("Approved report attempted external upload.") }
        if report.rawTranscriptStored { issues.append("Approved report stored raw transcript text.") }
        if report.rawAudioStored { issues.append("Approved report stored raw audio.") }
        if report.rawLogsStored { issues.append("Approved report stored raw logs.") }
        if report.rawModelOutputStored { issues.append("Approved report stored raw model output.") }
        if report.rawUITextStored { issues.append("Approved report stored raw UI text.") }
        if !report.temporaryWorkspaceDeleted { issues.append("Approved report must prove temporary QA workspace cleanup.") }

        return (report, issues)
    }

    private static func writeTemplate(
        to url: URL,
        requiredScenarios: [RealProviderLongRecordingScenario],
        durationSeconds: Int,
        minimumDurationSeconds: Int,
        requestedCaptureModes: [String]
    ) {
        let report = RealProviderLongRecordingApprovedReport(
            status: "draft",
            sourceCommit: "TODO: git commit tested",
            appVersion: "TODO: tested app version, for example 0.1.0",
            tester: "TODO: tester or QA role",
            testedAt: "TODO: ISO-8601 timestamp",
            machineDescription: "TODO: Mac model, macOS build, installed MeetingVault app, real provider setup, capture mode setup, and non-private audio fixture description",
            durationSeconds: durationSeconds,
            minimumDurationSeconds: minimumDurationSeconds,
            scenarios: requiredScenarios.map {
                ApprovedRealProviderLongRecordingScenario(
                    id: $0.id,
                    status: "blocked",
                    evidence: $0.requiredEvidence.map { "TODO: \($0)" }
                )
            },
            evidenceArtifacts: [
                "TODO: bounded artifact path, for example docs/evidence/real-provider-long-recording-run-YYYY-MM-DD.json"
            ],
            approvedRealCapture: false,
            approvedRealProviders: false,
            nonPrivateAudioConfirmed: false,
            providerMatrixPassed: false,
            captureModesPassed: requestedCaptureModes,
            appLaunchVerified: false,
            recordingStartStopVerified: false,
            selectedAudioInputVisible: false,
            selectedAudioInputMatchesCapture: false,
            speechActivityMonitorVisible: false,
            speechActivityMonitorResponded: false,
            liveTranscriptVisible: false,
            liveTranscriptUpdatedDuringRecording: false,
            liveTranscriptFirstPartialLatencySeconds: nil,
            maximumLiveTranscriptFirstPartialLatencySeconds: Self.maximumLiveTranscriptFirstPartialLatencySeconds,
            finalTranscriptPersisted: false,
            generatedTitleFromContentVerified: false,
            groundedSummaryVerified: false,
            libraryPersistenceVerified: false,
            transcriptAgentQuestionAnswered: false,
            transcriptAgentEvidenceCount: 0,
            agentResponseEditable: false,
            agentResponseCopied: false,
            agentResponseCopyMatchesEditedText: false,
            recoveryStateReviewed: false,
            crashLogReviewed: false,
            encryptedStorageVerified: false,
            privateAudioRecorded: false,
            microphoneOpened: false,
            systemAudioCaptureAttempted: false,
            externalNetworkRequested: false,
            downloadRequested: false,
            externalUploadAttempted: false,
            rawTranscriptStored: false,
            rawAudioStored: false,
            rawLogsStored: false,
            rawModelOutputStored: false,
            rawUITextStored: false,
            temporaryWorkspaceDeleted: false,
            notes: [
                "Replace every TODO with bounded evidence references before using this report.",
                "Set microphoneOpened/systemAudioCaptureAttempted truthfully if approved non-private capture required them.",
                "Do not paste raw transcripts, raw audio, UI text, model output, logs, account details, or private file paths."
            ]
        )

        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: url, options: .atomic)
        } catch {
            fputs("failed to write real-provider long-recording template: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func providerRequirements() -> [String] {
        [
            "Apple Speech live transcription authorized and passing.",
            "SpeechAnalyzer final transcription assets installed/proven and passing.",
            "Foundation Models meeting intelligence and transcript Q&A available and passing.",
            "Requested capture provider modes pass with encrypted temporary chunks and no raw audio persistence.",
            "The first screen shows the selected audio input, capture uses that selected input, the speech activity monitor visibly responds, and live transcript partials update during recording within \(Self.maximumLiveTranscriptFirstPartialLatencySeconds)s.",
            "The app completes stop, final transcription, Core AI title/summary generation, library persistence, transcript-agent prompt/response editing, grounded evidence, and copied edited response actions.",
            "Health & Recovery and crash/log review show no release-blocking errors after the long run."
        ]
    }

    private static func nextCommands(
        modes: [String],
        durationSeconds: Int
    ) -> [String] {
        var commands = [
            "script/provider_smoke_matrix.swift --require-pass"
        ]
        for mode in modes {
            var command = "script/capture_provider_smoke.swift --mode \(mode) --approve-real-capture --non-private-audio-confirmed --require-pass"
            if mode != "selected-microphone" {
                command += " --play-non-private-audio"
            }
            commands.append(command)
        }
        commands.append("./script/build_and_run.sh --verify --workspace meetings --key-provider local-file")
        commands.append("script/real_provider_long_recording_smoke.swift --write-template docs/release-gate-templates/real-provider-long-recording-approved-report-template.json")
        commands.append("Run an approved \(durationSeconds)s non-private recording in the app and verify selected input visibility, speech activity monitor response, live transcript updates within \(Self.maximumLiveTranscriptFirstPartialLatencySeconds)s, final transcript, Core AI title/summary, library persistence, grounded editable agent response, and copied edited response.")
        commands.append("script/real_provider_long_recording_smoke.swift --approve-real-capture --approve-real-providers --non-private-audio-confirmed --approved-report <bounded-report.json> --require-pass")
        return commands
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

    private static func scenarioDefinitions() -> [RealProviderLongRecordingScenario] {
        [
            RealProviderLongRecordingScenario(
                id: "provider-and-capture-preflight",
                title: "Provider matrix and requested real capture modes pass before the long app run.",
                requiredEvidence: ["provider matrix report", "capture provider report for each requested mode"],
                status: "blocked"
            ),
            RealProviderLongRecordingScenario(
                id: "one-hour-visible-recording",
                title: "The app records for at least one hour over approved non-private audio with visible recording state, selected input, speech activity, and live transcript.",
                requiredEvidence: [
                    "duration summary",
                    "selected audio input and capture input summary",
                    "speech activity monitor response summary",
                    "visible recording/live transcript update summary",
                    "first live transcript partial latency summary"
                ],
                status: "blocked"
            ),
            RealProviderLongRecordingScenario(
                id: "final-transcript-and-title",
                title: "Stop/finalization produces a persisted final transcript and Core AI title generated from recording contents.",
                requiredEvidence: ["final transcript persistence summary", "generated title evidence summary"],
                status: "blocked"
            ),
            RealProviderLongRecordingScenario(
                id: "grounded-intelligence-and-agent",
                title: "Core AI summary and Transcript Agent Q&A are grounded, editable, and copyable.",
                requiredEvidence: [
                    "grounded summary/action evidence summary",
                    "agent transcript-evidence count summary",
                    "agent edited-response copy match summary"
                ],
                status: "blocked"
            ),
            RealProviderLongRecordingScenario(
                id: "library-search-and-relaunch",
                title: "The completed meeting persists in the searchable library and survives app relaunch.",
                requiredEvidence: ["library persistence summary", "search/relaunch summary"],
                status: "blocked"
            ),
            RealProviderLongRecordingScenario(
                id: "recovery-and-crash-log-review",
                title: "Health & Recovery and crash/log review show no release-blocking errors after the long run.",
                requiredEvidence: ["recovery state summary", "crash/log review summary"],
                status: "blocked"
            ),
            RealProviderLongRecordingScenario(
                id: "redaction-and-storage",
                title: "Evidence is bounded, storage is encrypted, and no raw transcript/audio/model/UI/log payloads are persisted.",
                requiredEvidence: ["redaction checklist", "encrypted storage verification summary"],
                status: "blocked"
            )
        ]
    }
}

RealProviderLongRecordingSmoke.main()
