import Foundation

struct ProviderReadinessDoctorReport: Codable {
    var timestamp: String
    var status: String
    var providerReadinessStatus: String
    var providerMatrixStatus: String
    var appleSpeechPermissionStatus: String
    var appleSpeechAuthorizationAfter: String
    var speechAnalyzerStatus: String
    var speechAnalyzerAssetStatus: String
    var foundationModelsStatus: String
    var blockerCount: Int
    var nextActions: [ProviderReadinessAction]
    var privateAudioRecorded: Bool
    var microphoneOpened: Bool
    var assetPreparationRequested: Bool
    var downloadRequested: Bool
    var externalNetworkRequested: Bool
    var externalUploadAttempted: Bool
    var rawTranscriptStored: Bool
    var rawAudioStored: Bool
    var rawModelOutputStored: Bool
    var rawLogsStored: Bool
    var rawUITextStored: Bool
    var issues: [String]
}

struct ProviderReadinessAction: Codable {
    var id: String
    var title: String
    var command: String?
    var manualStep: String?
    var approvalRequired: Bool
    var unmetPrerequisites: [String]
}

enum ProviderReadinessDoctor {
    static func main() {
        var evidenceDate = "2026-07-01"
        var outputURL: URL?
        var requirePass = false

        var iterator = CommandLine.arguments.dropFirst().makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--evidence-date":
                guard let value = iterator.next(), isValidDate(value) else {
                    fputs("--evidence-date requires YYYY-MM-DD\n", stderr)
                    exit(2)
                }
                evidenceDate = value
            case "--output":
                guard let value = iterator.next(), !value.isEmpty else {
                    fputs("--output requires a path\n", stderr)
                    exit(2)
                }
                outputURL = URL(fileURLWithPath: value)
            case "--require-pass":
                requirePass = true
            case "--help", "-h":
                print("""
                usage: MeetingVaultProviderReadinessDoctor [--evidence-date YYYY-MM-DD] [--output PATH] [--require-pass]

                Reads bounded provider evidence and writes a provider readiness
                doctor report with exact next actions. This smoke does not request
                permissions, download SpeechAnalyzer assets, open microphones,
                invoke providers, upload externally, or store raw transcript,
                audio, model, log, or UI text.
                """)
                exit(0)
            default:
                fputs("unknown argument: \(argument)\n", stderr)
                exit(2)
            }
        }

        let rootURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let report = buildReport(rootURL: rootURL, evidenceDate: evidenceDate)
        if let outputURL {
            do {
                try FileManager.default.createDirectory(
                    at: outputURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(report).write(to: outputURL, options: .atomic)
            } catch {
                fputs("failed to write provider readiness doctor report: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
            print("Wrote \(outputURL.path)")
        }
        print(
            "status=\(report.status) providerReadinessStatus=\(report.providerReadinessStatus) " +
            "blockerCount=\(report.blockerCount)"
        )
        if requirePass, report.status != "pass" {
            exit(1)
        }
        exit(report.status == "pass" ? 0 : 1)
    }

    private static func buildReport(rootURL: URL, evidenceDate: String) -> ProviderReadinessDoctorReport {
        let evidenceURL = rootURL.appendingPathComponent("docs/evidence", isDirectory: true)
        let providerMatrix = readJSON(evidenceURL.appendingPathComponent("provider-smoke-matrix-\(evidenceDate).json"))
        let applePermission = readJSON(evidenceURL.appendingPathComponent("apple-speech-permission-smoke-\(evidenceDate).json"))
        let speechAnalyzer = readJSON(evidenceURL.appendingPathComponent("speech-analyzer-fixture-smoke-\(evidenceDate).json"))

        var issues: [String] = []
        if providerMatrix == nil { issues.append("Provider smoke matrix evidence is missing or unreadable.") }
        if applePermission == nil { issues.append("Apple Speech permission evidence is missing or unreadable.") }
        if speechAnalyzer == nil { issues.append("SpeechAnalyzer fixture evidence is missing or unreadable.") }

        let providerMatrixStatus = string(providerMatrix?["status"])
        let appleSpeechPermissionStatus = string(applePermission?["status"])
        let appleSpeechAuthorizationAfter = string(applePermission?["authorizationAfter"])
        let speechAnalyzerStatus = string(speechAnalyzer?["status"])
        let speechAnalyzerAssetStatus = string(speechAnalyzer?["assetStatus"])
        let foundationModelsStatus = providerStatus(providerMatrix, id: "foundation-models-intelligence-qa")

        var actions: [ProviderReadinessAction] = []
        if appleSpeechAuthorizationAfter != "authorized" {
            actions.append(
                ProviderReadinessAction(
                    id: "authorize-meetingvault-speech-recognition",
                    title: "Allow MeetingVault Speech Recognition once",
                    command: "script/apple_speech_permission_smoke.swift --approve-system-prompt --require-pass --output docs/evidence/apple-speech-permission-smoke-\(evidenceDate).json",
                    manualStep: "Open System Settings > Privacy & Security > Speech Recognition and allow MeetingVault, then rerun the app-owned permission smoke.",
                    approvalRequired: true,
                    unmetPrerequisites: []
                )
            )
        }
        if providerMatrixStatus != "pass" {
            let unmetPrerequisites = providerMatrixPrerequisites(
                appleSpeechAuthorizationAfter: appleSpeechAuthorizationAfter,
                speechAnalyzerAssetStatus: speechAnalyzerAssetStatus,
                foundationModelsStatus: foundationModelsStatus
            )
            actions.append(
                ProviderReadinessAction(
                    id: "rerun-provider-matrix-after-permissions",
                    title: "Rerun provider matrix after Apple Speech and SpeechAnalyzer are ready",
                    command: "script/provider_smoke_matrix.swift --require-pass --output docs/evidence/provider-smoke-matrix-\(evidenceDate).json",
                    manualStep: unmetPrerequisites.isEmpty
                        ? "Run after provider evidence has been refreshed and remains non-private."
                        : "Wait for the listed provider prerequisites, then rerun the matrix without opening microphones or requesting downloads from this step.",
                    approvalRequired: false,
                    unmetPrerequisites: unmetPrerequisites
                )
            )
        }
        if speechAnalyzerAssetStatus != "installed" && speechAnalyzerAssetStatus != "available" {
            actions.append(
                ProviderReadinessAction(
                    id: "prepare-speech-analyzer-assets",
                    title: "Prepare SpeechAnalyzer assets intentionally",
                    command: "script/speech_analyzer_fixture_smoke.swift --install-assets --require-pass --output docs/evidence/speech-analyzer-fixture-smoke-\(evidenceDate).json",
                    manualStep: "Run only after approving Apple's local SpeechAnalyzer asset preparation; this may download or install local speech assets.",
                    approvalRequired: true,
                    unmetPrerequisites: []
                )
            )
        }
        if foundationModelsStatus != "pass" {
            actions.append(
                ProviderReadinessAction(
                    id: "restore-foundation-models-fixture",
                    title: "Restore Foundation Models fixture pass status",
                    command: "script/foundation_models_fixture_smoke.swift --require-pass --output docs/evidence/foundation-models-fixture-smoke-\(evidenceDate).json",
                    manualStep: nil,
                    approvalRequired: false,
                    unmetPrerequisites: []
                )
            )
        }

        let privacyFlags = [
            bool(providerMatrix?["privateAudioRecorded"]),
            bool(providerMatrix?["microphoneOpened"]),
            bool(providerMatrix?["externalNetworkRequested"]),
            bool(providerMatrix?["downloadRequested"]),
            bool(applePermission?["privateAudioRecorded"]),
            bool(applePermission?["microphoneOpened"]),
            bool(applePermission?["externalNetworkRequested"]),
            bool(applePermission?["externalUploadAttempted"]),
            bool(speechAnalyzer?["privateAudioRecorded"]),
            bool(speechAnalyzer?["microphoneOpened"]),
            bool(speechAnalyzer?["assetPreparationRequested"]),
            bool(speechAnalyzer?["downloadRequested"])
        ]
        if privacyFlags.contains(true) {
            issues.append("Input evidence contains a privacy or side-effect flag that must remain false for this doctor.")
        }

        let providerReady = providerMatrixStatus == "pass"
            && appleSpeechAuthorizationAfter == "authorized"
            && (speechAnalyzerAssetStatus == "installed" || speechAnalyzerAssetStatus == "available")
            && foundationModelsStatus == "pass"

        return ProviderReadinessDoctorReport(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            status: issues.isEmpty ? "pass" : "fail",
            providerReadinessStatus: providerReady ? "ready" : "blocked",
            providerMatrixStatus: providerMatrixStatus,
            appleSpeechPermissionStatus: appleSpeechPermissionStatus,
            appleSpeechAuthorizationAfter: appleSpeechAuthorizationAfter,
            speechAnalyzerStatus: speechAnalyzerStatus,
            speechAnalyzerAssetStatus: speechAnalyzerAssetStatus,
            foundationModelsStatus: foundationModelsStatus,
            blockerCount: actions.count,
            nextActions: actions,
            privateAudioRecorded: false,
            microphoneOpened: false,
            assetPreparationRequested: false,
            downloadRequested: false,
            externalNetworkRequested: false,
            externalUploadAttempted: false,
            rawTranscriptStored: false,
            rawAudioStored: false,
            rawModelOutputStored: false,
            rawLogsStored: false,
            rawUITextStored: false,
            issues: issues
        )
    }

    private static func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private static func providerStatus(_ object: [String: Any]?, id: String) -> String {
        guard let providers = object?["providers"] as? [[String: Any]] else { return "" }
        return string(providers.first { string($0["id"]) == id }?["status"])
    }

    private static func providerMatrixPrerequisites(
        appleSpeechAuthorizationAfter: String,
        speechAnalyzerAssetStatus: String,
        foundationModelsStatus: String
    ) -> [String] {
        var prerequisites: [String] = []
        if appleSpeechAuthorizationAfter != "authorized" {
            prerequisites.append("MeetingVault Speech Recognition must be authorized through the app-owned Request Once path.")
        }
        if speechAnalyzerAssetStatus != "installed" && speechAnalyzerAssetStatus != "available" {
            prerequisites.append("SpeechAnalyzer assets must be installed or available after explicit local asset-preparation approval.")
        }
        if foundationModelsStatus != "pass" {
            prerequisites.append("Foundation Models fixture evidence must pass before rerunning the provider matrix.")
        }
        return prerequisites
    }

    private static func string(_ value: Any?) -> String {
        value as? String ?? ""
    }

    private static func bool(_ value: Any?) -> Bool {
        value as? Bool ?? false
    }

    private static func isValidDate(_ value: String) -> Bool {
        value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
    }
}

ProviderReadinessDoctor.main()
