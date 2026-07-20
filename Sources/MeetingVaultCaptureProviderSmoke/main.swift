import Foundation
import MeetingVaultCore

enum CaptureSmokeMode: String, Codable, CaseIterable {
    case selectedMicrophone = "selected-microphone"
    case coreAudio = "core-audio"
    case screenCaptureKit = "screen-capture-kit"
}

struct CaptureProviderSmokeReport: Codable {
    var timestamp: String
    var status: String
    var requirePass: Bool
    var approvedReportPath: String?
    var validatedReport: CaptureProviderApprovedReport?
    var requiredScenarioCount: Int
    var passedScenarioCount: Int
    var approvedRealCapture: Bool
    var nonPrivateAudioConfirmed: Bool
    var playNonPrivateAudio: Bool
    var durationSeconds: Double
    var requestedModes: [String]
    var privateAudioRecorded: Bool
    var microphoneOpened: Bool
    var systemAudioCaptureAttempted: Bool
    var selectedAudioInputVisible: Bool
    var selectedAudioInputMatchesCapture: Bool
    var primaryConsoleRecordingEvidencePassed: Bool
    var externalNetworkRequested: Bool
    var externalUploadAttempted: Bool
    var rawAudioStored: Bool
    var rawTranscriptStored: Bool
    var rawLogsStored: Bool
    var rawUITextStored: Bool
    var temporaryWorkspaceDeleted: Bool
    var results: [CaptureProviderSmokeResult]
    var issues: [String]
}

struct CaptureProviderSmokeResult: Codable {
    var mode: String
    var status: String
    var engineID: String?
    var sourceID: String?
    var microphoneDeviceName: String?
    var recordCount: Int
    var totalEncryptedBytes: Int
    var tracks: [String]
    var health: CaptureProviderSmokeHealth?
    var error: String?
    var issues: [String]
}

struct CaptureProviderSmokeHealth: Codable {
    var remoteDropouts: Int
    var microphoneDropouts: Int
    var remoteClippingPercent: Double
    var microphoneClippingPercent: Double
    var silentPeriodCount: Int
    var deviceChangeCount: Int
}

struct CaptureProviderApprovedReport: Codable {
    var status: String
    var sourceCommit: String?
    var appVersion: String?
    var tester: String?
    var testedAt: String?
    var machineDescription: String?
    var durationSeconds: Double
    var requestedModes: [String]
    var results: [ApprovedCaptureProviderResult]
    var evidenceArtifacts: [String]
    var approvedRealCapture: Bool
    var nonPrivateAudioConfirmed: Bool
    var playNonPrivateAudio: Bool
    var privateAudioRecorded: Bool
    var microphoneOpened: Bool
    var systemAudioCaptureAttempted: Bool
    var selectedAudioInputVisible: Bool
    var selectedAudioInputMatchesCapture: Bool
    var primaryConsoleRecordingEvidencePassed: Bool
    var externalNetworkRequested: Bool
    var externalUploadAttempted: Bool
    var rawAudioStored: Bool
    var rawTranscriptStored: Bool
    var rawLogsStored: Bool
    var rawUITextStored: Bool
    var temporaryWorkspaceDeleted: Bool
    var notes: [String]?
}

struct ApprovedCaptureProviderResult: Codable {
    var mode: String
    var status: String
    var evidence: [String]
    var engineID: String?
    var sourceID: String?
    var microphoneDeviceName: String?
    var recordCount: Int
    var totalEncryptedBytes: Int
    var tracks: [String]
    var health: CaptureProviderSmokeHealth?
    var error: String?
    var issues: [String]
}

struct CaptureProviderSmokeConfiguration {
    var outputURL: URL
    var approvedReportURL: URL?
    var templateURL: URL?
    var requirePass = false
    var approvedRealCapture = false
    var nonPrivateAudioConfirmed = false
    var playNonPrivateAudio = false
    var durationSeconds: TimeInterval = 1.5
    var modes: [CaptureSmokeMode] = CaptureSmokeMode.allCases
}

@main
enum MeetingVaultCaptureProviderSmoke {
    static func main() async {
        do {
            let configuration = try parseArguments()
            if let templateURL = configuration.templateURL {
                try writeTemplate(to: templateURL, modes: configuration.modes, durationSeconds: configuration.durationSeconds)
                print("Wrote template \(templateURL.path)")
                exit(0)
            }
            let report = await run(configuration)
            try write(report, to: configuration.outputURL)
            print("Wrote \(configuration.outputURL.path)")
            print("status=\(report.status) modes=\(report.requestedModes.joined(separator: ","))")
            exit(report.status == "pass" || !report.requirePass ? 0 : 1)
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            exit(2)
        }
    }

    private static func parseArguments() throws -> CaptureProviderSmokeConfiguration {
        let rootURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let date = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
        var configuration = CaptureProviderSmokeConfiguration(
            outputURL: rootURL
                .appendingPathComponent("docs", isDirectory: true)
                .appendingPathComponent("evidence", isDirectory: true)
                .appendingPathComponent("capture-provider-smoke-\(date).json")
        )
        var requestedModes: [CaptureSmokeMode] = []

        var iterator = CommandLine.arguments.dropFirst().makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--output":
                guard let value = iterator.next() else {
                    throw SmokeArgumentError.message("--output requires a path")
                }
                configuration.outputURL = URL(fileURLWithPath: value)
            case "--approved-report":
                guard let value = iterator.next() else {
                    throw SmokeArgumentError.message("--approved-report requires a path")
                }
                configuration.approvedReportURL = URL(fileURLWithPath: value)
            case "--write-template":
                guard let value = iterator.next() else {
                    throw SmokeArgumentError.message("--write-template requires a path")
                }
                configuration.templateURL = URL(fileURLWithPath: value)
            case "--require-pass":
                configuration.requirePass = true
            case "--approve-real-capture":
                configuration.approvedRealCapture = true
            case "--non-private-audio-confirmed":
                configuration.nonPrivateAudioConfirmed = true
            case "--play-non-private-audio":
                configuration.playNonPrivateAudio = true
            case "--duration":
                guard let value = iterator.next(), let duration = TimeInterval(value), duration > 0 else {
                    throw SmokeArgumentError.message("--duration requires a positive number of seconds")
                }
                configuration.durationSeconds = min(duration, 10)
            case "--mode":
                guard let value = iterator.next(), let mode = CaptureSmokeMode(rawValue: value) else {
                    throw SmokeArgumentError.message("--mode requires selected-microphone, core-audio, or screen-capture-kit")
                }
                requestedModes.append(mode)
            case "--help", "-h":
                print("""
                usage: swift run MeetingVaultCaptureProviderSmoke [--output PATH] [--mode selected-microphone|core-audio|screen-capture-kit] [--duration SECONDS] [--approve-real-capture --non-private-audio-confirmed] [--play-non-private-audio] [--approved-report PATH] [--write-template PATH] [--require-pass]

                Default behavior writes blocked evidence and does not open the
                microphone, start system audio capture, store raw audio, or
                request permissions. Real capture requires both approval flags.
                Use only with non-private audio in a prepared test environment.
                Release-candidate pass claims should start from --write-template
                and provide --approved-report with bounded evidence and no raw
                audio, transcript, UI, or log content.
                """)
                exit(0)
            default:
                throw SmokeArgumentError.message("unknown argument: \(argument)")
            }
        }

        if !requestedModes.isEmpty {
            configuration.modes = requestedModes
        }
        return configuration
    }

    private static func run(_ configuration: CaptureProviderSmokeConfiguration) async -> CaptureProviderSmokeReport {
        if configuration.approvedReportURL != nil {
            return runApprovedReportGate(configuration)
        }

        let approved = configuration.approvedRealCapture && configuration.nonPrivateAudioConfirmed
        let results: [CaptureProviderSmokeResult]
        var temporaryWorkspaceDeleted = true

        if approved {
            var approvedResults: [CaptureProviderSmokeResult] = []
            for mode in configuration.modes {
                approvedResults.append(
                    await runApproved(
                        mode: mode,
                        configuration: configuration,
                        temporaryWorkspaceDeleted: &temporaryWorkspaceDeleted
                    )
                )
            }
            results = approvedResults
        } else {
            results = configuration.modes.map { mode in
                CaptureProviderSmokeResult(
                    mode: mode.rawValue,
                    status: "blocked",
                    engineID: nil,
                    sourceID: nil,
                    microphoneDeviceName: nil,
                    recordCount: 0,
                    totalEncryptedBytes: 0,
                    tracks: [],
                    health: nil,
                    error: nil,
                    issues: [
                        "Real capture smoke requires --approve-real-capture and --non-private-audio-confirmed."
                    ]
                )
            }
        }

        let failCount = results.filter { $0.status == "fail" }.count
        let blockedCount = results.filter { $0.status == "blocked" }.count
        let status: String
        if failCount > 0 {
            status = "fail"
        } else if blockedCount > 0 {
            status = "blocked"
        } else {
            status = "pass"
        }

        let issues = results.flatMap { result in
            result.issues.map { "\(result.mode): \($0)" }
        }
        let microphoneOpened = approved && configuration.modes.contains(.selectedMicrophone)
        let systemAudioCaptureAttempted = approved && configuration.modes.contains { $0 != .selectedMicrophone }

        return CaptureProviderSmokeReport(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            status: status,
            requirePass: configuration.requirePass,
            approvedReportPath: nil,
            validatedReport: nil,
            requiredScenarioCount: configuration.modes.count,
            passedScenarioCount: results.filter { $0.status == "pass" }.count,
            approvedRealCapture: configuration.approvedRealCapture,
            nonPrivateAudioConfirmed: configuration.nonPrivateAudioConfirmed,
            playNonPrivateAudio: configuration.playNonPrivateAudio,
            durationSeconds: configuration.durationSeconds,
            requestedModes: configuration.modes.map(\.rawValue),
            privateAudioRecorded: false,
            microphoneOpened: microphoneOpened,
            systemAudioCaptureAttempted: systemAudioCaptureAttempted,
            selectedAudioInputVisible: false,
            selectedAudioInputMatchesCapture: false,
            primaryConsoleRecordingEvidencePassed: false,
            externalNetworkRequested: false,
            externalUploadAttempted: false,
            rawAudioStored: false,
            rawTranscriptStored: false,
            rawLogsStored: false,
            rawUITextStored: false,
            temporaryWorkspaceDeleted: temporaryWorkspaceDeleted,
            results: results,
            issues: issues
        )
    }

    private static func runApprovedReportGate(_ configuration: CaptureProviderSmokeConfiguration) -> CaptureProviderSmokeReport {
        let validation = validateApprovedReport(configuration)
        let approved = validation.report
        var issues = validation.issues
        if !configuration.approvedRealCapture {
            issues.append("Real capture approval is required: add --approve-real-capture only for prepared non-private audio QA.")
        }
        if !configuration.nonPrivateAudioConfirmed {
            issues.append("Non-private audio confirmation is required: add --non-private-audio-confirmed only when the test input contains no private meeting content.")
        }

        let requiredModes = configuration.modes.map(\.rawValue)
        let approvedResults = approved?.results ?? []
        let results = requiredModes.map { mode in
            if let approvedResult = approvedResults.first(where: { $0.mode == mode }) {
                return CaptureProviderSmokeResult(approvedResult)
            }
            return CaptureProviderSmokeResult(
                mode: mode,
                status: "blocked",
                engineID: nil,
                sourceID: nil,
                microphoneDeviceName: nil,
                recordCount: 0,
                totalEncryptedBytes: 0,
                tracks: [],
                health: nil,
                error: nil,
                issues: ["Approved report is missing capture mode \(mode)."]
            )
        }
        let passedScenarioCount = results.filter { $0.status == "pass" }.count
        let status = issues.isEmpty ? "pass" : "blocked"

        return CaptureProviderSmokeReport(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            status: status,
            requirePass: configuration.requirePass,
            approvedReportPath: configuration.approvedReportURL?.path,
            validatedReport: approved,
            requiredScenarioCount: requiredModes.count,
            passedScenarioCount: passedScenarioCount,
            approvedRealCapture: approved?.approvedRealCapture ?? configuration.approvedRealCapture,
            nonPrivateAudioConfirmed: approved?.nonPrivateAudioConfirmed ?? configuration.nonPrivateAudioConfirmed,
            playNonPrivateAudio: approved?.playNonPrivateAudio ?? configuration.playNonPrivateAudio,
            durationSeconds: approved?.durationSeconds ?? configuration.durationSeconds,
            requestedModes: requiredModes,
            privateAudioRecorded: approved?.privateAudioRecorded ?? false,
            microphoneOpened: approved?.microphoneOpened ?? false,
            systemAudioCaptureAttempted: approved?.systemAudioCaptureAttempted ?? false,
            selectedAudioInputVisible: approved?.selectedAudioInputVisible ?? false,
            selectedAudioInputMatchesCapture: approved?.selectedAudioInputMatchesCapture ?? false,
            primaryConsoleRecordingEvidencePassed: approved?.primaryConsoleRecordingEvidencePassed ?? false,
            externalNetworkRequested: approved?.externalNetworkRequested ?? false,
            externalUploadAttempted: approved?.externalUploadAttempted ?? false,
            rawAudioStored: approved?.rawAudioStored ?? false,
            rawTranscriptStored: approved?.rawTranscriptStored ?? false,
            rawLogsStored: approved?.rawLogsStored ?? false,
            rawUITextStored: approved?.rawUITextStored ?? false,
            temporaryWorkspaceDeleted: approved?.temporaryWorkspaceDeleted ?? true,
            results: results,
            issues: issues
        )
    }

    private static func runApproved(
        mode: CaptureSmokeMode,
        configuration: CaptureProviderSmokeConfiguration,
        temporaryWorkspaceDeleted: inout Bool
    ) async -> CaptureProviderSmokeResult {
        let workspaceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultCaptureProviderSmoke-\(mode.rawValue)-\(UUID().uuidString)", isDirectory: true)
        defer {
            do {
                try FileManager.default.removeItem(at: workspaceURL)
            } catch {
                temporaryWorkspaceDeleted = false
            }
        }

        do {
            try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
            let meetingID = UUID()
            let bundleStore = EncryptedMeetingBundleStore(
                rootDirectory: workspaceURL,
                vault: AESGCMDataVault(
                    keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 0x5A, count: 32))
                )
            )
            _ = try bundleStore.createBundle(.initialEncryptedBundle(meetingID: meetingID, title: "Non-private capture smoke"))
            let chunkWriter = EncryptedAudioChunkWriter(bundleStore: bundleStore)
            let provider = SystemAudioInputDeviceProvider()
            let engine = try await engineAndRequest(
                for: mode,
                meetingID: meetingID,
                duration: configuration.durationSeconds,
                provider: provider
            )

            let playback = configuration.playNonPrivateAudio && mode != .selectedMicrophone
                ? NonPrivateAudioPlayback(delay: 0.2)
                : nil
            playback?.start()
            defer {
                playback?.stop()
            }

            let service = CaptureRecordingService(
                engine: engine.engine,
                chunkWriter: chunkWriter,
                audioInputDeviceProvider: mode == .selectedMicrophone ? provider : nil
            )
            let result = try await service.record(engine.request)
            let totalBytes = result.records.reduce(0) { $0 + $1.byteCount }
            let tracks = Array(Set(result.records.map { $0.track.rawValue })).sorted()
            let status = result.records.isEmpty || totalBytes <= 0 ? "fail" : "pass"
            return CaptureProviderSmokeResult(
                mode: mode.rawValue,
                status: status,
                engineID: engine.engine.id,
                sourceID: engine.request.sourceID,
                microphoneDeviceName: result.microphoneDeviceName,
                recordCount: result.records.count,
                totalEncryptedBytes: totalBytes,
                tracks: tracks,
                health: CaptureProviderSmokeHealth(result.healthReport),
                error: nil,
                issues: status == "pass" ? [] : ["Capture produced no encrypted audio records."]
            )
        } catch {
            return CaptureProviderSmokeResult(
                mode: mode.rawValue,
                status: "fail",
                engineID: nil,
                sourceID: nil,
                microphoneDeviceName: nil,
                recordCount: 0,
                totalEncryptedBytes: 0,
                tracks: [],
                health: nil,
                error: error.localizedDescription,
                issues: [error.localizedDescription]
            )
        }
    }

    private static func engineAndRequest(
        for mode: CaptureSmokeMode,
        meetingID: UUID,
        duration: TimeInterval,
        provider: SystemAudioInputDeviceProvider
    ) async throws -> (engine: any CaptureRecordingEngine, request: CaptureRecordingRequest) {
        switch mode {
        case .selectedMicrophone:
            let devices = await provider.snapshot()
            guard let device = devices.first(where: \.isDefault) ?? devices.first else {
                throw SmokeArgumentError.message("No microphone input device is visible to AVFoundation.")
            }
            return (
                AVFoundationSelectedMicrophoneCaptureEngine(),
                CaptureRecordingRequest(
                    meetingID: meetingID,
                    sourceID: "selected-microphone",
                    includeMicrophone: true,
                    microphoneDeviceID: device.id,
                    microphoneDeviceName: device.displayName,
                    maximumDuration: duration
                )
            )
        case .coreAudio:
            return (
                CoreAudioTapCaptureEngine(),
                CaptureRecordingRequest(
                    meetingID: meetingID,
                    sourceID: "coreaudio-system-audio",
                    includeMicrophone: false,
                    maximumDuration: duration
                )
            )
        case .screenCaptureKit:
            return (
                ScreenCaptureKitSystemAudioCaptureEngine(),
                CaptureRecordingRequest(
                    meetingID: meetingID,
                    sourceID: "screencapturekit-system-audio",
                    includeMicrophone: false,
                    maximumDuration: duration
                )
            )
        }
    }

    private static func validateApprovedReport(
        _ configuration: CaptureProviderSmokeConfiguration
    ) -> (report: CaptureProviderApprovedReport?, issues: [String]) {
        guard let url = configuration.approvedReportURL else {
            return (nil, ["Capture provider smoke requires --approved-report with bounded non-private capture evidence."])
        }
        guard let data = try? Data(contentsOf: url) else {
            return (nil, ["Approved report could not be read at \(url.path)."])
        }
        let decoder = JSONDecoder()
        guard let report = try? decoder.decode(CaptureProviderApprovedReport.self, from: data) else {
            return (nil, ["Approved report is not valid CaptureProviderApprovedReport JSON."])
        }

        var issues: [String] = []
        if report.status != "pass" {
            issues.append("Approved report status is \(report.status); expected pass.")
        }
        if report.sourceCommit?.isEmpty ?? true {
            issues.append("Approved report must identify the tested source commit.")
        }
        if report.appVersion?.isEmpty ?? true {
            issues.append("Approved report must identify the tested app version.")
        }
        if report.tester?.isEmpty ?? true {
            issues.append("Approved report must identify the tester or QA role.")
        }
        if report.testedAt?.isEmpty ?? true {
            issues.append("Approved report must identify when the capture QA was run.")
        }
        if report.machineDescription?.isEmpty ?? true {
            issues.append("Approved report must identify the tested machine and audio setup.")
        }
        if report.durationSeconds < configuration.durationSeconds {
            issues.append("Approved report duration \(report.durationSeconds)s is shorter than requested duration \(configuration.durationSeconds)s.")
        }
        if report.evidenceArtifacts.isEmpty {
            issues.append("Approved report must list bounded evidence artifacts.")
        }
        appendPlaceholderIssues(
            values: report.evidenceArtifacts,
            label: "Approved report evidence artifact",
            to: &issues
        )

        let requiredModes = Set(configuration.modes.map(\.rawValue))
        let suppliedModes = Set(report.requestedModes)
        if suppliedModes != requiredModes {
            issues.append("Approved report requested modes \(report.requestedModes.sorted()) do not match required modes \(requiredModes.sorted()).")
        }

        let results = Dictionary(grouping: report.results, by: \.mode)
        for mode in configuration.modes {
            let modeID = mode.rawValue
            guard let entries = results[modeID], let result = entries.first else {
                issues.append("Approved report is missing capture mode \(modeID).")
                continue
            }
            if entries.count > 1 {
                issues.append("Approved report contains duplicate capture mode \(modeID).")
            }
            if result.status != "pass" {
                issues.append("Capture mode \(modeID) is \(result.status); expected pass.")
            }
            if result.evidence.isEmpty {
                issues.append("Capture mode \(modeID) must list bounded evidence.")
            }
            appendPlaceholderIssues(
                values: result.evidence,
                label: "Capture mode \(modeID) evidence",
                to: &issues
            )
            if result.recordCount <= 0 {
                issues.append("Capture mode \(modeID) produced no encrypted chunk records.")
            }
            if result.totalEncryptedBytes <= 0 {
                issues.append("Capture mode \(modeID) produced no encrypted audio bytes.")
            }
            if result.tracks.isEmpty {
                issues.append("Capture mode \(modeID) must list captured tracks.")
            }
            switch mode {
            case .selectedMicrophone:
                if result.engineID != "avfoundation-selected-microphone" {
                    issues.append("selected-microphone proof must identify AVFoundation selected microphone engine.")
                }
                if result.sourceID != "selected-microphone" {
                    issues.append("selected-microphone proof must use sourceID selected-microphone.")
                }
                if result.microphoneDeviceName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                    issues.append("selected-microphone proof must name the selected microphone device.")
                }
                if !result.tracks.contains(TrackKind.microphone.rawValue) {
                    issues.append("Selected microphone proof must include the microphone track.")
                }
            case .coreAudio:
                if result.engineID != "core-audio-process-tap" {
                    issues.append("core-audio proof must identify Core Audio tap engine.")
                }
                if result.sourceID != "coreaudio-system-audio" {
                    issues.append("core-audio proof must use sourceID coreaudio-system-audio.")
                }
            case .screenCaptureKit:
                if result.engineID != "screencapturekit-system-audio" {
                    issues.append("screen-capture-kit proof must identify ScreenCaptureKit system audio engine.")
                }
                if result.sourceID != "screencapturekit-system-audio" {
                    issues.append("screen-capture-kit proof must use sourceID screencapturekit-system-audio.")
                }
            }
            if mode != .selectedMicrophone
                && !result.tracks.contains(TrackKind.remoteSystem.rawValue)
                && !result.tracks.contains(TrackKind.mixedPlayback.rawValue) {
                issues.append("System audio proof for \(modeID) must include a remoteSystem or mixedPlayback track.")
            }
        }
        for extraMode in results.keys where !requiredModes.contains(extraMode) {
            issues.append("Approved report contains unknown capture mode \(extraMode).")
        }

        if !report.approvedRealCapture {
            issues.append("Approved report did not confirm real capture approval.")
        }
        if !report.nonPrivateAudioConfirmed {
            issues.append("Approved report did not confirm non-private audio.")
        }
        if !report.primaryConsoleRecordingEvidencePassed {
            issues.append("Approved report must prove the primary console recording command bar, selected input, activity monitor, live transcript, and generated-title status were visible before capture.")
        }
        if !report.selectedAudioInputVisible {
            issues.append("Approved report must prove the selected audio input was visible before capture.")
        }
        if requiredModes.contains(CaptureSmokeMode.selectedMicrophone.rawValue), !report.selectedAudioInputMatchesCapture {
            issues.append("Approved selected-microphone proof must show the visible selected input matches the captured microphone device.")
        }
        if requiredModes.contains(CaptureSmokeMode.selectedMicrophone.rawValue), !report.microphoneOpened {
            issues.append("Approved selected-microphone proof must open the microphone in the prepared non-private environment.")
        }
        if requiredModes.contains(CaptureSmokeMode.coreAudio.rawValue)
            || requiredModes.contains(CaptureSmokeMode.screenCaptureKit.rawValue),
            !report.systemAudioCaptureAttempted {
            issues.append("Approved system-audio proof must attempt system audio capture in the prepared non-private environment.")
        }
        if report.privateAudioRecorded {
            issues.append("Approved report recorded private audio.")
        }
        if report.externalNetworkRequested {
            issues.append("Approved report requested external network.")
        }
        if report.externalUploadAttempted {
            issues.append("Approved report attempted external upload.")
        }
        if report.rawAudioStored {
            issues.append("Approved report stored raw audio.")
        }
        if report.rawTranscriptStored {
            issues.append("Approved report stored raw transcript text.")
        }
        if report.rawLogsStored {
            issues.append("Approved report stored raw logs.")
        }
        if report.rawUITextStored {
            issues.append("Approved report stored raw UI text.")
        }
        if !report.temporaryWorkspaceDeleted {
            issues.append("Approved report did not confirm temporary QA workspace cleanup.")
        }
        if let notes = report.notes {
            appendPlaceholderIssues(values: notes, label: "Approved report note", to: &issues)
        }

        return (report, issues)
    }

    private static func writeTemplate(to outputURL: URL, modes: [CaptureSmokeMode], durationSeconds: Double) throws {
        let requestedModes = modes.map(\.rawValue)
        let report = CaptureProviderApprovedReport(
            status: "draft",
            sourceCommit: "REPLACE_WITH_TESTED_SOURCE_COMMIT",
            appVersion: "REPLACE_WITH_TESTED_APP_VERSION",
            tester: "REPLACE_WITH_TESTER_OR_QA_ROLE",
            testedAt: "REPLACE_WITH_ISO8601_TEST_TIME",
            machineDescription: "REPLACE_WITH_MACHINE_MACOS_AUDIO_INPUT_AND_OUTPUT_SETUP",
            durationSeconds: durationSeconds,
            requestedModes: requestedModes,
            results: modes.map { mode in
                ApprovedCaptureProviderResult(
                    mode: mode.rawValue,
                    status: "draft",
                    evidence: [
                        "REPLACE_WITH_BOUNDED_\(mode.rawValue)_CAPTURE_EVIDENCE_PATH"
                    ],
                    engineID: nil,
                    sourceID: nil,
                    microphoneDeviceName: mode == .selectedMicrophone ? "REPLACE_WITH_SELECTED_INPUT_DISPLAY_NAME" : nil,
                    recordCount: 0,
                    totalEncryptedBytes: 0,
                    tracks: [],
                    health: nil,
                    error: nil,
                    issues: []
                )
            },
            evidenceArtifacts: [
                "REPLACE_WITH_BOUNDED_CAPTURE_PROVIDER_SUMMARY_PATH"
            ],
            approvedRealCapture: false,
            nonPrivateAudioConfirmed: false,
            playNonPrivateAudio: false,
            privateAudioRecorded: false,
            microphoneOpened: false,
            systemAudioCaptureAttempted: false,
            selectedAudioInputVisible: false,
            selectedAudioInputMatchesCapture: false,
            primaryConsoleRecordingEvidencePassed: false,
            externalNetworkRequested: false,
            externalUploadAttempted: false,
            rawAudioStored: false,
            rawTranscriptStored: false,
            rawLogsStored: false,
            rawUITextStored: false,
            temporaryWorkspaceDeleted: false,
            notes: [
                "REPLACE_WITH_BOUNDED_CAPTURE_QA_NOTES_NO_RAW_PRIVATE_CONTENT"
            ]
        )
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: outputURL, options: .atomic)
    }

    private static func appendPlaceholderIssues(values: [String], label: String, to issues: inout [String]) {
        for value in values {
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalized.isEmpty {
                issues.append("\(label) is empty.")
            } else if normalized.contains("replace_with")
                || normalized.contains("placeholder")
                || normalized.contains("todo")
                || normalized.contains("<") {
                issues.append("\(label) contains a template placeholder: \(value)")
            }
        }
    }

    private static func write(_ report: CaptureProviderSmokeReport, to outputURL: URL) throws {
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: outputURL, options: .atomic)
    }
}

private final class NonPrivateAudioPlayback: @unchecked Sendable {
    private let delay: TimeInterval
    private let lock = NSLock()
    private var process: Process?
    private var workItem: DispatchWorkItem?

    init(delay: TimeInterval) {
        self.delay = delay
    }

    func start() {
        let item = DispatchWorkItem { [weak self] in
            self?.run()
        }
        lock.withLock {
            workItem = item
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: item)
    }

    func stop() {
        let state = lock.withLock {
            let current = (workItem, process)
            workItem = nil
            process = nil
            return current
        }
        state.0?.cancel()
        if state.1?.isRunning == true {
            state.1?.terminate()
        }
    }

    private func run() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = [
            "MeetingVault non private capture smoke. MeetingVault non private capture smoke."
        ]

        let shouldRun = lock.withLock { () -> Bool in
            guard workItem?.isCancelled != true else {
                return false
            }
            self.process = process
            return true
        }
        guard shouldRun else { return }

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            lock.withLock {
                if self.process === process {
                    self.process = nil
                }
            }
            return
        }

        lock.withLock {
            if self.process === process {
                self.process = nil
            }
        }
    }
}

extension CaptureProviderSmokeHealth {
    init(_ report: CaptureHealthReport) {
        remoteDropouts = report.remoteDropouts
        microphoneDropouts = report.microphoneDropouts
        remoteClippingPercent = report.remoteClippingPercent
        microphoneClippingPercent = report.microphoneClippingPercent
        silentPeriodCount = report.silentPeriods.count
        deviceChangeCount = report.deviceChanges.count
    }
}

extension CaptureProviderSmokeResult {
    init(_ approved: ApprovedCaptureProviderResult) {
        mode = approved.mode
        status = approved.status
        engineID = approved.engineID
        sourceID = approved.sourceID
        microphoneDeviceName = approved.microphoneDeviceName
        recordCount = approved.recordCount
        totalEncryptedBytes = approved.totalEncryptedBytes
        tracks = approved.tracks
        health = approved.health
        error = approved.error
        issues = approved.issues
    }
}

enum SmokeArgumentError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case let .message(message):
            return message
        }
    }
}
