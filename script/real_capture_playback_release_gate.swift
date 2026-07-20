#!/usr/bin/env swift
import Foundation

struct RealCapturePlaybackReleaseGateReport: Codable {
    var timestamp: String
    var status: String
    var requirePass: Bool
    var approvedReportPath: String?
    var readinessTarget: String
    var requiredScenarioCount: Int
    var passedScenarioCount: Int
    var requiredScenarios: [RealCapturePlaybackScenario]
    var validatedReport: RealCapturePlaybackApprovedReport?
    var approvedRealCapture: Bool
    var nonPrivateAudioConfirmed: Bool
    var captureEvidencePassed: Bool
    var playbackTimelineBuilt: Bool
    var playbackCueCount: Int?
    var transcriptAlignedCueCount: Int?
    var cuePlaybackActionCount: Int?
    var transportControlActionCount: Int?
    var scrubActionCount: Int?
    var encryptedAudioReadCount: Int?
    var exportedAudioFileCount: Int?
    var transcriptAlignedCuesVerified: Bool
    var cuePlaybackVerified: Bool
    var scrubVerified: Bool
    var transportControlsVerified: Bool
    var encryptedAudioReadVerified: Bool
    var audioPackageExportVerified: Bool
    var libraryRelaunchVerified: Bool
    var missingAudioRecoveryReviewed: Bool
    var crashLogReviewed: Bool
    var privateAudioRecorded: Bool
    var microphoneOpened: Bool
    var systemAudioCaptureAttempted: Bool
    var externalNetworkRequested: Bool
    var externalUploadAttempted: Bool
    var destructiveActionExecuted: Bool
    var rawUITextStored: Bool
    var rawTranscriptStored: Bool
    var rawAudioStored: Bool
    var rawLogsStored: Bool
    var temporaryWorkspaceDeleted: Bool
    var nextCommands: [String]
    var issues: [String]
}

struct RealCapturePlaybackScenario: Codable {
    var id: String
    var title: String
    var requiredEvidence: [String]
    var status: String
}

struct RealCapturePlaybackApprovedReport: Codable {
    var status: String
    var sourceCommit: String?
    var appVersion: String?
    var tester: String?
    var testedAt: String?
    var machineDescription: String?
    var scenarios: [ApprovedRealCapturePlaybackScenario]
    var evidenceArtifacts: [String]
    var approvedRealCapture: Bool
    var nonPrivateAudioConfirmed: Bool
    var captureEvidencePassed: Bool
    var playbackTimelineBuilt: Bool
    var playbackCueCount: Int?
    var transcriptAlignedCueCount: Int?
    var cuePlaybackActionCount: Int?
    var transportControlActionCount: Int?
    var scrubActionCount: Int?
    var encryptedAudioReadCount: Int?
    var exportedAudioFileCount: Int?
    var transcriptAlignedCuesVerified: Bool
    var cuePlaybackVerified: Bool
    var scrubVerified: Bool
    var transportControlsVerified: Bool
    var encryptedAudioReadVerified: Bool
    var audioPackageExportVerified: Bool
    var libraryRelaunchVerified: Bool
    var missingAudioRecoveryReviewed: Bool
    var crashLogReviewed: Bool
    var privateAudioRecorded: Bool
    var microphoneOpened: Bool
    var systemAudioCaptureAttempted: Bool
    var externalNetworkRequested: Bool
    var externalUploadAttempted: Bool
    var destructiveActionExecuted: Bool
    var rawUITextStored: Bool
    var rawTranscriptStored: Bool
    var rawAudioStored: Bool
    var rawLogsStored: Bool
    var temporaryWorkspaceDeleted: Bool
    var notes: [String]?
}

struct ApprovedRealCapturePlaybackScenario: Codable {
    var id: String
    var status: String
    var evidence: [String]
}

enum RealCapturePlaybackReleaseGate {
    static func main() {
        let rootURL = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let date = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
        var outputURL = rootURL
            .appendingPathComponent("docs", isDirectory: true)
            .appendingPathComponent("evidence", isDirectory: true)
            .appendingPathComponent("real-capture-playback-release-gate-\(date).json")
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
                usage: script/real_capture_playback_release_gate.swift [--output PATH] [--approved-report PATH] [--write-template PATH] [--require-pass]

                Writes the release-candidate playback gate for approved real
                capture output. Default behavior is blocked and does not open
                capture devices, play audio, export files, upload, share, delete,
                or store raw transcript/audio/log evidence.

                To pass, provide a bounded approved-report JSON proving a
                completed non-private real recording can build transcript-aligned
                playback cues, play/pause/stop/scrub, survive relaunch, read
                audio only through encrypted storage boundaries, export an audio
                package, and pass crash/log review.
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
        let approved = validation.report
        let passedScenarioCount = approved?.scenarios
            .filter { $0.status == "pass" }
            .count ?? 0
        let status = validation.issues.isEmpty ? "pass" : "blocked"
        let scenarios = requiredScenarios.map { scenario in
            let approvedScenario = approved?.scenarios.first { $0.id == scenario.id }
            return RealCapturePlaybackScenario(
                id: scenario.id,
                title: scenario.title,
                requiredEvidence: scenario.requiredEvidence,
                status: approvedScenario?.status ?? "blocked"
            )
        }

        let report = RealCapturePlaybackReleaseGateReport(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            status: status,
            requirePass: requirePass,
            approvedReportPath: approvedReportURL?.path,
            readinessTarget: "release-candidate",
            requiredScenarioCount: requiredScenarios.count,
            passedScenarioCount: passedScenarioCount,
            requiredScenarios: scenarios,
            validatedReport: approved,
            approvedRealCapture: approved?.approvedRealCapture ?? false,
            nonPrivateAudioConfirmed: approved?.nonPrivateAudioConfirmed ?? false,
            captureEvidencePassed: approved?.captureEvidencePassed ?? false,
            playbackTimelineBuilt: approved?.playbackTimelineBuilt ?? false,
            playbackCueCount: approved?.playbackCueCount,
            transcriptAlignedCueCount: approved?.transcriptAlignedCueCount,
            cuePlaybackActionCount: approved?.cuePlaybackActionCount,
            transportControlActionCount: approved?.transportControlActionCount,
            scrubActionCount: approved?.scrubActionCount,
            encryptedAudioReadCount: approved?.encryptedAudioReadCount,
            exportedAudioFileCount: approved?.exportedAudioFileCount,
            transcriptAlignedCuesVerified: approved?.transcriptAlignedCuesVerified ?? false,
            cuePlaybackVerified: approved?.cuePlaybackVerified ?? false,
            scrubVerified: approved?.scrubVerified ?? false,
            transportControlsVerified: approved?.transportControlsVerified ?? false,
            encryptedAudioReadVerified: approved?.encryptedAudioReadVerified ?? false,
            audioPackageExportVerified: approved?.audioPackageExportVerified ?? false,
            libraryRelaunchVerified: approved?.libraryRelaunchVerified ?? false,
            missingAudioRecoveryReviewed: approved?.missingAudioRecoveryReviewed ?? false,
            crashLogReviewed: approved?.crashLogReviewed ?? false,
            privateAudioRecorded: approved?.privateAudioRecorded ?? false,
            microphoneOpened: approved?.microphoneOpened ?? false,
            systemAudioCaptureAttempted: approved?.systemAudioCaptureAttempted ?? false,
            externalNetworkRequested: approved?.externalNetworkRequested ?? false,
            externalUploadAttempted: approved?.externalUploadAttempted ?? false,
            destructiveActionExecuted: approved?.destructiveActionExecuted ?? false,
            rawUITextStored: approved?.rawUITextStored ?? false,
            rawTranscriptStored: approved?.rawTranscriptStored ?? false,
            rawAudioStored: approved?.rawAudioStored ?? false,
            rawLogsStored: approved?.rawLogsStored ?? false,
            temporaryWorkspaceDeleted: approved?.temporaryWorkspaceDeleted ?? true,
            nextCommands: nextCommands(),
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
            fputs("failed to write real capture playback gate: \(error.localizedDescription)\n", stderr)
            exit(1)
        }

        print("Wrote \(outputURL.path)")
        print("status=\(report.status) passedScenarios=\(report.passedScenarioCount)/\(report.requiredScenarioCount)")
        exit(report.status == "pass" || !requirePass ? 0 : 1)
    }

    private static func validateApprovedReport(
        at url: URL?,
        requiredScenarios: [RealCapturePlaybackScenario]
    ) -> (report: RealCapturePlaybackApprovedReport?, issues: [String]) {
        guard let url else {
            return (nil, ["Real capture playback release gate requires --approved-report with bounded playback QA evidence."])
        }
        guard let data = try? Data(contentsOf: url) else {
            return (nil, ["Approved report could not be read at \(url.path)."])
        }
        let decoder = JSONDecoder()
        guard let report = try? decoder.decode(RealCapturePlaybackApprovedReport.self, from: data) else {
            return (nil, ["Approved report is not valid RealCapturePlaybackApprovedReport JSON."])
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
            issues.append("Approved report must identify when playback QA was run.")
        }
        if report.machineDescription?.isEmpty ?? true {
            issues.append("Approved report must describe the Mac, OS build, app install, capture source, and playback setup.")
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

        if !report.approvedRealCapture { issues.append("Approved report must prove real capture output was explicitly approved.") }
        if !report.nonPrivateAudioConfirmed { issues.append("Approved report must confirm only non-private audio/transcript fixtures were used.") }
        if !report.captureEvidencePassed { issues.append("Approved report must prove the capture-provider gate passed for the source recording.") }
        if !report.playbackTimelineBuilt { issues.append("Approved report must prove playback timeline was built from the completed recording.") }
        if report.playbackCueCount ?? 0 <= 0 { issues.append("Approved report playbackCueCount must be positive.") }
        if report.transcriptAlignedCueCount ?? 0 <= 0 { issues.append("Approved report transcriptAlignedCueCount must be positive.") }
        if let cueCount = report.playbackCueCount,
           let alignedCueCount = report.transcriptAlignedCueCount,
           alignedCueCount > cueCount {
            issues.append("Approved report transcriptAlignedCueCount cannot exceed playbackCueCount.")
        }
        if !report.transcriptAlignedCuesVerified { issues.append("Approved report must prove transcript-aligned playback cues were verified.") }
        if report.cuePlaybackActionCount ?? 0 <= 0 { issues.append("Approved report cuePlaybackActionCount must be positive.") }
        if !report.cuePlaybackVerified { issues.append("Approved report must prove cue playback worked.") }
        if report.scrubActionCount ?? 0 <= 0 { issues.append("Approved report scrubActionCount must be positive.") }
        if !report.scrubVerified { issues.append("Approved report must prove scrub/seek worked.") }
        if report.transportControlActionCount ?? 0 < 3 { issues.append("Approved report transportControlActionCount must cover play, pause, and stop.") }
        if !report.transportControlsVerified { issues.append("Approved report must prove play, pause, and stop controls worked.") }
        if report.encryptedAudioReadCount ?? 0 <= 0 { issues.append("Approved report encryptedAudioReadCount must be positive.") }
        if !report.encryptedAudioReadVerified { issues.append("Approved report must prove playback read audio through encrypted storage boundaries.") }
        if report.exportedAudioFileCount ?? 0 <= 0 { issues.append("Approved report exportedAudioFileCount must be positive.") }
        if !report.audioPackageExportVerified { issues.append("Approved report must prove audio package export worked from encrypted chunks.") }
        if !report.libraryRelaunchVerified { issues.append("Approved report must prove playback still works after app relaunch and library reload.") }
        if !report.missingAudioRecoveryReviewed { issues.append("Approved report must prove missing-audio recovery or warning state was reviewed.") }
        if !report.crashLogReviewed { issues.append("Approved report must prove post-playback crash/log review found no release-blocking errors.") }
        if report.privateAudioRecorded { issues.append("Approved report recorded private audio.") }
        if (report.microphoneOpened || report.systemAudioCaptureAttempted)
            && (!report.approvedRealCapture || !report.nonPrivateAudioConfirmed) {
            issues.append("Approved report opened capture devices without approved non-private real capture proof.")
        }
        if report.externalNetworkRequested { issues.append("Approved report requested external network.") }
        if report.externalUploadAttempted { issues.append("Approved report attempted external upload.") }
        if report.destructiveActionExecuted { issues.append("Approved report executed a destructive final action.") }
        if report.rawUITextStored { issues.append("Approved report stored raw UI text.") }
        if report.rawTranscriptStored { issues.append("Approved report stored raw transcript text.") }
        if report.rawAudioStored { issues.append("Approved report stored raw audio.") }
        if report.rawLogsStored { issues.append("Approved report stored raw logs.") }
        if !report.temporaryWorkspaceDeleted { issues.append("Approved report must prove temporary QA workspace cleanup.") }

        return (report, issues)
    }

    private static func writeTemplate(
        to url: URL,
        requiredScenarios: [RealCapturePlaybackScenario]
    ) {
        let report = RealCapturePlaybackApprovedReport(
            status: "draft",
            sourceCommit: "TODO: git commit tested",
            appVersion: "TODO: tested app version, for example 0.1.0",
            tester: "TODO: tester or QA role",
            testedAt: "TODO: ISO-8601 timestamp",
            machineDescription: "TODO: Mac model, macOS build, installed MeetingVault app, source recording, selected audio output, and non-private fixture description",
            scenarios: requiredScenarios.map {
                ApprovedRealCapturePlaybackScenario(
                    id: $0.id,
                    status: "blocked",
                    evidence: $0.requiredEvidence.map { "TODO: \($0)" }
                )
            },
            evidenceArtifacts: [
                "TODO: bounded artifact path, for example docs/evidence/real-capture-playback-summary-YYYY-MM-DD.json"
            ],
            approvedRealCapture: false,
            nonPrivateAudioConfirmed: false,
            captureEvidencePassed: false,
            playbackTimelineBuilt: false,
            playbackCueCount: nil,
            transcriptAlignedCueCount: nil,
            cuePlaybackActionCount: nil,
            transportControlActionCount: nil,
            scrubActionCount: nil,
            encryptedAudioReadCount: nil,
            exportedAudioFileCount: nil,
            transcriptAlignedCuesVerified: false,
            cuePlaybackVerified: false,
            scrubVerified: false,
            transportControlsVerified: false,
            encryptedAudioReadVerified: false,
            audioPackageExportVerified: false,
            libraryRelaunchVerified: false,
            missingAudioRecoveryReviewed: false,
            crashLogReviewed: false,
            privateAudioRecorded: false,
            microphoneOpened: false,
            systemAudioCaptureAttempted: false,
            externalNetworkRequested: false,
            externalUploadAttempted: false,
            destructiveActionExecuted: false,
            rawUITextStored: false,
            rawTranscriptStored: false,
            rawAudioStored: false,
            rawLogsStored: false,
            temporaryWorkspaceDeleted: false,
            notes: [
                "Replace every TODO with bounded evidence references before using this report.",
                "Set microphoneOpened/systemAudioCaptureAttempted truthfully if approved non-private playback QA used newly captured audio.",
                "Do not paste raw transcripts, raw audio, UI text, logs, account details, or private file paths."
            ]
        )

        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: url, options: .atomic)
        } catch {
            fputs("failed to write real capture playback template: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func nextCommands() -> [String] {
        [
            "script/capture_provider_smoke.swift --approve-real-capture --non-private-audio-confirmed --approved-report <capture-report.json> --require-pass",
            "./script/build_and_run.sh --verify --workspace meetings --key-provider local-file",
            "script/real_capture_playback_release_gate.swift --write-template docs/release-gate-templates/real-capture-playback-approved-report-template.json",
            "Run approved non-private playback QA from a completed real capture meeting: verify timeline cues, play/pause/stop, scrub, relaunch, encrypted audio read, export package, and crash/log review.",
            "script/real_capture_playback_release_gate.swift --approved-report <bounded-report.json> --require-pass"
        ]
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

    private static func scenarioDefinitions() -> [RealCapturePlaybackScenario] {
        [
            RealCapturePlaybackScenario(
                id: "captured-meeting-selected",
                title: "A completed meeting from approved non-private real capture output is selected in the library.",
                requiredEvidence: ["source capture gate summary", "selected meeting and encrypted chunk metadata summary"],
                status: "blocked"
            ),
            RealCapturePlaybackScenario(
                id: "timeline-cues-built",
                title: "Playback timeline builds transcript-aligned cues from the completed recording.",
                requiredEvidence: ["cue count and timestamp summary", "transcript alignment summary"],
                status: "blocked"
            ),
            RealCapturePlaybackScenario(
                id: "transport-and-cue-playback",
                title: "Cue selection plus play, pause, and stop controls work without crash or stale state.",
                requiredEvidence: ["transport action summary", "selected cue playback summary"],
                status: "blocked"
            ),
            RealCapturePlaybackScenario(
                id: "scrub-and-relaunch",
                title: "Scrub/seek and playback selection remain usable after app relaunch and library reload.",
                requiredEvidence: ["scrub/seek summary", "relaunch playback summary"],
                status: "blocked"
            ),
            RealCapturePlaybackScenario(
                id: "encrypted-audio-boundary",
                title: "Playback reads audio only through encrypted storage boundaries and leaves no raw audio evidence.",
                requiredEvidence: ["encrypted read summary", "raw-audio evidence flag summary"],
                status: "blocked"
            ),
            RealCapturePlaybackScenario(
                id: "audio-package-export",
                title: "Audio package export works from encrypted chunks without external upload.",
                requiredEvidence: ["export package summary", "external upload flag summary"],
                status: "blocked"
            ),
            RealCapturePlaybackScenario(
                id: "recovery-and-crash-review",
                title: "Missing-audio recovery state and post-playback crash/log review have no release-blocking issues.",
                requiredEvidence: ["missing-audio recovery summary", "crash/log bounded summary"],
                status: "blocked"
            )
        ]
    }
}

RealCapturePlaybackReleaseGate.main()
