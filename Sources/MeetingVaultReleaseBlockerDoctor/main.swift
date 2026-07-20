import Foundation

struct ReleaseBlockerDoctorReport: Codable {
    var timestamp: String
    var status: String
    var releaseBlockerStatus: String
    var evidenceDate: String
    var readinessLabel: String
    var localReady: Bool
    var releaseCandidateReady: Bool
    var sourceCommit: String
    var cleanCheckoutSourceCommit: String
    var blockedGateCount: Int
    var totalActionCount: Int
    var approvalRequiredActionCount: Int
    var localRunnableActionCount: Int
    var prerequisiteBlockedActionCount: Int
    var blockedGates: [ReleaseBlockerGate]
    var approvalQueue: [ReleaseBlockerAction]
    var operatorBlockers: [String]
    var workspaceCleanupCandidates: [WorkspaceCleanupCandidate]
    var privateAudioRecorded: Bool
    var microphoneOpened: Bool
    var externalNetworkRequested: Bool
    var downloadRequested: Bool
    var externalUploadAttempted: Bool
    var notarizationSubmitted: Bool
    var rawTranscriptStored: Bool
    var rawAudioStored: Bool
    var rawModelOutputStored: Bool
    var rawLogsStored: Bool
    var rawUITextStored: Bool
    var rawCredentialStored: Bool
    var rawSigningOutputStored: Bool
    var rawNotarizationOutputStored: Bool
    var issues: [String]
}

struct ReleaseBlockerGate: Codable {
    var id: String
    var title: String
    var path: String
    var status: String
    var requiredForReleaseCandidate: Bool
    var passedScenarioCount: Int?
    var requiredScenarioCount: Int?
    var issueCount: Int
}

struct ReleaseBlockerAction: Codable {
    var id: String
    var title: String
    var category: String
    var blockedGateID: String?
    var commands: [String]
    var manualStep: String
    var approvalRequired: Bool
    var unmetPrerequisites: [String]
}

struct WorkspaceCleanupCandidate: Codable {
    var name: String
    var pathHint: String
    var bytes: Int64
    var safetyClass: String
    var cleanupAction: String
    var requiresManualReview: Bool
    var exists: Bool
}

struct GateDefinition {
    var id: String
    var title: String
    var fileName: String
    var category: String
    var writeTemplateCommand: String?
    var approveCommand: String?
    var manualStep: String
    var approvalRequired: Bool
    var unmetPrerequisites: [String] = []
}

enum ReleaseBlockerDoctor {
    static func main() {
        var evidenceDate = "2026-07-01"
        var outputURL: URL?
        var headroomEvidenceURL: URL?
        var headroomEvidenceProvided = false
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
            case "--headroom-evidence":
                guard let value = iterator.next(), !value.isEmpty else {
                    fputs("--headroom-evidence requires a path\n", stderr)
                    exit(2)
                }
                headroomEvidenceURL = URL(fileURLWithPath: value)
                headroomEvidenceProvided = true
            case "--require-pass":
                requirePass = true
            case "--help", "-h":
                print("""
                usage: MeetingVaultReleaseBlockerDoctor [--evidence-date YYYY-MM-DD] [--headroom-evidence PATH] [--output PATH] [--require-pass]

                Reads bounded release-readiness evidence and writes an ordered
                blocker-clearing queue. This doctor does not request system
                permissions, open capture devices, trigger downloads, submit
                notarization, upload externally, write to OS stores, execute
                destructive actions, or store raw transcript, audio, model,
                signing, log, credential, or UI text.
                """)
                exit(0)
            default:
                fputs("unknown argument: \(argument)\n", stderr)
                exit(2)
            }
        }

        let rootURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let resolvedHeadroomEvidenceURL = headroomEvidenceURL ?? defaultHeadroomEvidenceURL(
            rootURL: rootURL,
            evidenceDate: evidenceDate
        )
        let report = buildReport(
            rootURL: rootURL,
            evidenceDate: evidenceDate,
            headroomEvidenceURL: resolvedHeadroomEvidenceURL,
            headroomEvidenceRequired: headroomEvidenceProvided
        )
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
                fputs("failed to write release blocker doctor report: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
            print("Wrote \(outputURL.path)")
        }

        print(
            "status=\(report.status) releaseBlockerStatus=\(report.releaseBlockerStatus) " +
            "blockedGateCount=\(report.blockedGateCount) totalActionCount=\(report.totalActionCount)"
        )
        if requirePass, report.status != "pass" {
            exit(1)
        }
        exit(report.status == "pass" ? 0 : 1)
    }

    private static func buildReport(
        rootURL: URL,
        evidenceDate: String,
        headroomEvidenceURL: URL?,
        headroomEvidenceRequired: Bool
    ) -> ReleaseBlockerDoctorReport {
        let evidenceURL = rootURL.appendingPathComponent("docs/evidence", isDirectory: true)
        let readinessPath = "docs/evidence/release-readiness-audit-\(evidenceDate).json"
        let readiness = readJSON(rootURL.appendingPathComponent(readinessPath))
        let providerDoctor = readJSON(evidenceURL.appendingPathComponent("provider-readiness-doctor-\(evidenceDate).json"))
        let headroomDoctor = headroomEvidenceURL.flatMap(readJSON)

        var issues: [String] = []
        if readiness == nil {
            issues.append("Release readiness audit evidence is missing or unreadable at \(readinessPath).")
        }
        if providerDoctor == nil {
            issues.append("Provider readiness doctor evidence is missing or unreadable.")
        }
        if headroomEvidenceRequired, headroomDoctor == nil {
            issues.append("Workspace headroom evidence is missing or unreadable at \(headroomEvidenceURL?.path ?? "unknown").")
        }

        var actions: [ReleaseBlockerAction] = providerActions(from: providerDoctor)
        if let headroomAction = headroomAction(from: headroomDoctor, evidenceURL: headroomEvidenceURL, rootURL: rootURL) {
            actions.append(headroomAction)
        }
        var blockedGates: [ReleaseBlockerGate] = []
        let checks = readiness?["checks"] as? [[String: Any]] ?? []
        let definitions = gateDefinitions(evidenceDate: evidenceDate)
        let definitionByID = Dictionary(uniqueKeysWithValues: definitions.map { ($0.id, $0) })

        for check in checks {
            let id = string(check["id"])
            guard bool(check["requiredForReleaseCandidate"]) == true,
                  bool(check["passed"]) != true else {
                continue
            }
            guard let definition = definitionByID[id] else {
                continue
            }
            let object = readJSON(rootURL.appendingPathComponent(definition.fileName))
            blockedGates.append(
                ReleaseBlockerGate(
                    id: id,
                    title: definition.title,
                    path: definition.fileName,
                    status: string(check["actualStatus"], fallback: "missing"),
                    requiredForReleaseCandidate: true,
                    passedScenarioCount: int(object?["passedScenarioCount"]),
                    requiredScenarioCount: int(object?["requiredScenarioCount"]),
                    issueCount: stringArray(check["issues"]).count
                )
            )
            actions.append(action(for: definition))
        }

        actions.append(contentsOf: appStoreApprovalActions(rootURL: rootURL, evidenceDate: evidenceDate))

        let allObjects = [readiness, providerDoctor].compactMap { $0 }
            + [headroomDoctor].compactMap { $0 }
            + definitions.compactMap { readJSON(rootURL.appendingPathComponent($0.fileName)) }
            + [
                readJSON(evidenceURL.appendingPathComponent("app-store-assets-smoke-\(evidenceDate).json")),
                readJSON(evidenceURL.appendingPathComponent("app-store-privacy-smoke-\(evidenceDate).json"))
            ].compactMap { $0 }
        let leakingKeys = [
            "privateAudioRecorded",
            "externalUploadAttempted",
            "rawTranscriptStored",
            "rawTranscriptTextStoredInComponents",
            "rawAudioStored",
            "rawModelOutputStored",
            "rawModelOutputStoredInComponents",
            "rawLogsStored",
            "rawUITextStored",
            "rawCredentialStored",
            "rawSigningOutputStored",
            "rawNotarizationOutputStored",
            "rawCalendarDataStored",
            "rawReminderDataStored",
            "rawContactDataStored"
        ]
        let leakingEvidenceKeys = leakingKeys.filter { anyTrue(allObjects, $0) }
        if !leakingEvidenceKeys.isEmpty {
            issues.append("Input evidence contains unsafe privacy/raw-output flags: \(leakingEvidenceKeys.joined(separator: ", ")).")
        }

        let releaseCandidateReady = bool(readiness?["releaseCandidateReady"])
        let status = issues.isEmpty ? "pass" : "fail"
        let sortedActions = actions.sorted { $0.id < $1.id }
        let approvalRequiredActionCount = sortedActions.filter(\.approvalRequired).count
        let localRunnableActionCount = sortedActions.filter {
            !$0.approvalRequired && !$0.commands.isEmpty && $0.unmetPrerequisites.isEmpty
        }.count
        let prerequisiteBlockedActionCount = sortedActions.filter {
            !$0.commands.isEmpty && !$0.unmetPrerequisites.isEmpty
        }.count
        return ReleaseBlockerDoctorReport(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            status: status,
            releaseBlockerStatus: releaseCandidateReady ? "ready" : "blocked",
            evidenceDate: evidenceDate,
            readinessLabel: string(readiness?["label"]),
            localReady: bool(readiness?["localReady"]),
            releaseCandidateReady: releaseCandidateReady,
            sourceCommit: string(readiness?["sourceCommit"], fallback: "unknown"),
            cleanCheckoutSourceCommit: string(readiness?["cleanCheckoutSourceCommit"], fallback: "unknown"),
            blockedGateCount: blockedGates.count,
            totalActionCount: sortedActions.count,
            approvalRequiredActionCount: approvalRequiredActionCount,
            localRunnableActionCount: localRunnableActionCount,
            prerequisiteBlockedActionCount: prerequisiteBlockedActionCount,
            blockedGates: blockedGates.sorted { $0.id < $1.id },
            approvalQueue: sortedActions,
            operatorBlockers: stringArray(readiness?["operatorBlockers"]),
            workspaceCleanupCandidates: workspaceCleanupCandidates(from: headroomDoctor),
            privateAudioRecorded: false,
            microphoneOpened: false,
            externalNetworkRequested: false,
            downloadRequested: false,
            externalUploadAttempted: false,
            notarizationSubmitted: false,
            rawTranscriptStored: false,
            rawAudioStored: false,
            rawModelOutputStored: false,
            rawLogsStored: false,
            rawUITextStored: false,
            rawCredentialStored: false,
            rawSigningOutputStored: false,
            rawNotarizationOutputStored: false,
            issues: issues
        )
    }

    private static func defaultHeadroomEvidenceURL(rootURL: URL, evidenceDate: String) -> URL? {
        let candidate = rootURL
            .appendingPathComponent("docs/evidence", isDirectory: true)
            .appendingPathComponent("workspace-headroom-doctor-\(evidenceDate).json")
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    private static func providerActions(from object: [String: Any]?) -> [ReleaseBlockerAction] {
        guard let nextActions = object?["nextActions"] as? [[String: Any]] else { return [] }
        return nextActions.map { action in
            ReleaseBlockerAction(
                id: "provider-\(string(action["id"]))",
                title: string(action["title"]),
                category: "providers",
                blockedGateID: "provider-readiness",
                commands: [string(action["command"])].filter { !$0.isEmpty },
                manualStep: string(action["manualStep"], fallback: "Run the provider readiness step after confirming the input evidence is non-private and bounded."),
                approvalRequired: bool(action["approvalRequired"]),
                unmetPrerequisites: stringArray(action["unmetPrerequisites"])
            )
        }
    }

    private static func headroomAction(from object: [String: Any]?, evidenceURL: URL?, rootURL: URL) -> ReleaseBlockerAction? {
        guard let object else { return nil }
        let headroomStatus = string(object["headroomStatus"], fallback: "unknown")
        guard headroomStatus != "pass" else { return nil }

        let cleanupCandidateBytes = int64(object["cleanupCandidateBytes"])
        let projectedAvailableBytes = int64(object["projectedAvailableBytesAfterCleanupCandidates"])
        let recommendedVerificationBytes = int64(object["recommendedVerificationBytes"])
        let candidateCount = (object["cleanupCandidates"] as? [[String: Any]])?.count ?? 0
        let cleanupSummary = [
            candidateCount > 0 ? "\(candidateCount) manual-review cleanup candidate(s)" : "manual-review cleanup candidates",
            cleanupCandidateBytes.map { "\(decimalGigabytes($0)) candidate bytes" },
            projectedAvailableBytes.map { "\(decimalGigabytes($0)) projected available" },
            recommendedVerificationBytes.map { "\(decimalGigabytes($0)) recommended" }
        ]
        .compactMap { $0 }
        .joined(separator: "; ")
        let evidencePath = evidenceURL.map { displayPath(for: $0, rootURL: rootURL) } ?? "docs/evidence/workspace-headroom-doctor-<date>.json"

        return ReleaseBlockerAction(
            id: "review-workspace-headroom",
            title: "Review workspace headroom cleanup candidates",
            category: "workspace",
            blockedGateID: "workspace-headroom",
            commands: [
                "swift script/workspace_headroom_doctor.swift --output \(evidencePath)",
                "swift script/workspace_headroom_doctor.swift --require-pass --output \(evidencePath)"
            ],
            manualStep: "Free enough workspace volume space before clean-checkout, long-recording, or visual matrix refresh work. Review candidates manually before moving anything to Trash; current headroomStatus=\(headroomStatus) (\(cleanupSummary)).",
            approvalRequired: true,
            unmetPrerequisites: []
        )
    }

    private static func workspaceCleanupCandidates(from object: [String: Any]?) -> [WorkspaceCleanupCandidate] {
        guard let candidates = object?["cleanupCandidates"] as? [[String: Any]] else { return [] }
        return candidates.map { candidate in
            WorkspaceCleanupCandidate(
                name: string(candidate["name"], fallback: "Unknown cleanup candidate"),
                pathHint: string(candidate["pathHint"], fallback: "unknown"),
                bytes: int64(candidate["bytes"]) ?? 0,
                safetyClass: string(candidate["safetyClass"], fallback: "unknown"),
                cleanupAction: string(candidate["cleanupAction"], fallback: "Review this candidate manually before changing files."),
                requiresManualReview: bool(candidate["requiresManualReview"]),
                exists: bool(candidate["exists"])
            )
        }
    }

    private static func action(for definition: GateDefinition) -> ReleaseBlockerAction {
        ReleaseBlockerAction(
            id: "clear-\(definition.id)",
            title: "Clear \(definition.title)",
            category: definition.category,
            blockedGateID: definition.id,
            commands: [
                definition.writeTemplateCommand,
                definition.approveCommand
            ].compactMap { $0 },
            manualStep: definition.manualStep,
            approvalRequired: definition.approvalRequired,
            unmetPrerequisites: definition.unmetPrerequisites
        )
    }

    private static func appStoreApprovalActions(rootURL: URL, evidenceDate: String) -> [ReleaseBlockerAction] {
        let evidenceURL = rootURL.appendingPathComponent("docs/evidence", isDirectory: true)
        let assets = readJSON(evidenceURL.appendingPathComponent("app-store-assets-smoke-\(evidenceDate).json"))
        let privacy = readJSON(evidenceURL.appendingPathComponent("app-store-privacy-smoke-\(evidenceDate).json"))
        var actions: [ReleaseBlockerAction] = []
        if bool(assets?["finalAssetsReady"]) != true
            || bool(assets?["finalMetadataApproved"]) != true
            || bool(assets?["legalApproved"]) != true
            || bool(assets?["appStoreConnectRecordCreated"]) != true {
            actions.append(
                ReleaseBlockerAction(
                    id: "final-app-store-assets-and-metadata",
                    title: "Approve final App Store assets and metadata",
                    category: "app-store",
                    blockedGateID: "app-store-assets",
                    commands: [
                        "swift script/app_store_assets_smoke.swift --output docs/evidence/app-store-assets-smoke-\(evidenceDate).json"
                    ],
                    manualStep: "Create or confirm the App Store Connect record, final screenshots, metadata, support URL, marketing URL if used, and legal approval before treating this as release-candidate clear.",
                    approvalRequired: true,
                    unmetPrerequisites: []
                )
            )
        }
        if bool(privacy?["finalAppStoreConnectAnswersApproved"]) != true
            || bool(privacy?["privacyOwnerApproved"]) != true
            || bool(privacy?["legalApproved"]) != true
            || bool(privacy?["appStoreConnectRecordCreated"]) != true {
            actions.append(
                ReleaseBlockerAction(
                    id: "final-app-store-privacy-answers",
                    title: "Approve final App Store privacy answers",
                    category: "app-store",
                    blockedGateID: "app-store-privacy",
                    commands: [
                        "swift script/app_store_privacy_smoke.swift --output docs/evidence/app-store-privacy-smoke-\(evidenceDate).json"
                    ],
                    manualStep: "Have the privacy owner and legal reviewer approve the final App Store Connect privacy answers for the local-first data posture.",
                    approvalRequired: true,
                    unmetPrerequisites: []
                )
            )
        }
        return actions
    }

    private static func gateDefinitions(evidenceDate: String) -> [GateDefinition] {
        [
            GateDefinition(
                id: "apple-speech-permission",
                title: "Apple Speech permission",
                fileName: "docs/evidence/apple-speech-permission-smoke-\(evidenceDate).json",
                category: "providers",
                writeTemplateCommand: "script/apple_speech_permission_smoke.swift --write-template docs/evidence/apple-speech-permission-approved-template-\(evidenceDate).json",
                approveCommand: "script/apple_speech_permission_smoke.swift --approved-report docs/evidence/apple-speech-permission-approved-template-\(evidenceDate).json --require-pass --output docs/evidence/apple-speech-permission-smoke-\(evidenceDate).json",
                manualStep: "Allow MeetingVault in System Settings > Privacy & Security > Speech Recognition once, then prove the app shows Only from Request Once, recording/transcription starts do not request permission implicitly, and Request Once is not shown again after permission resolves.",
                approvalRequired: true
            ),
            GateDefinition(
                id: "provider-smoke-matrix",
                title: "provider smoke matrix",
                fileName: "docs/evidence/provider-smoke-matrix-\(evidenceDate).json",
                category: "providers",
                writeTemplateCommand: "script/provider_smoke_matrix.swift --write-template docs/evidence/provider-smoke-matrix-approved-template-\(evidenceDate).json",
                approveCommand: "script/provider_smoke_matrix.swift --approved-report docs/evidence/provider-smoke-matrix-approved-template-\(evidenceDate).json --require-pass --output docs/evidence/provider-smoke-matrix-\(evidenceDate).json",
                manualStep: "Run only after Apple Speech authorization, SpeechAnalyzer assets, and Foundation Models provider availability are intentionally confirmed on non-private input.",
                approvalRequired: true,
                unmetPrerequisites: providerPrerequisites()
            ),
            GateDefinition(
                id: "capture-provider-smoke",
                title: "real capture provider smoke",
                fileName: "docs/evidence/capture-provider-smoke-\(evidenceDate).json",
                category: "capture",
                writeTemplateCommand: "script/capture_provider_smoke.swift --write-template docs/evidence/capture-provider-approved-template-\(evidenceDate).json",
                approveCommand: "script/capture_provider_smoke.swift --approve-real-capture --non-private-audio-confirmed --approved-report docs/evidence/capture-provider-approved-template-\(evidenceDate).json --require-pass --output docs/evidence/capture-provider-smoke-\(evidenceDate).json",
                manualStep: "Approve real selected-microphone, Core Audio tap, and ScreenCaptureKit capture only over non-private audio. The bounded report must prove the selected input was visible before capture, the capture used that selected input, encrypted chunks were written for each approved mode, and no raw audio/transcript/log/UI payloads were stored.",
                approvalRequired: true
            ),
            GateDefinition(
                id: "real-provider-long-recording",
                title: "real-provider long-recording smoke",
                fileName: "docs/evidence/real-provider-long-recording-smoke-\(evidenceDate).json",
                category: "capture",
                writeTemplateCommand: "script/real_provider_long_recording_smoke.swift --write-template docs/evidence/real-provider-long-recording-approved-template-\(evidenceDate).json",
                approveCommand: "script/real_provider_long_recording_smoke.swift --approve-real-capture --approve-real-providers --non-private-audio-confirmed --approved-report docs/evidence/real-provider-long-recording-approved-template-\(evidenceDate).json --require-pass --output docs/evidence/real-provider-long-recording-smoke-\(evidenceDate).json",
                manualStep: "Prove a one-hour approved non-private recording with real capture and provider runtimes. The bounded report must show selected audio input visibility and capture match, speech activity monitor response, live transcript updates with bounded first-partial latency, Stop/final transcription, Core AI generated title from recording contents, grounded summary/actions, Library persistence/search/relaunch, Transcript Agent question answering with transcript evidence, editable response, copied edited response, recovery/crash-log review, encrypted storage, and no raw audio/transcript/model/log/UI payloads.",
                approvalRequired: true,
                unmetPrerequisites: providerPrerequisites()
            ),
            GateDefinition(
                id: "real-capture-playback-release",
                title: "real capture playback release gate",
                fileName: "docs/evidence/real-capture-playback-release-gate-\(evidenceDate).json",
                category: "playback",
                writeTemplateCommand: "swift script/real_capture_playback_release_gate.swift --write-template docs/evidence/real-capture-playback-approved-template-\(evidenceDate).json",
                approveCommand: "swift script/real_capture_playback_release_gate.swift --approved-report docs/evidence/real-capture-playback-approved-template-\(evidenceDate).json --require-pass --output docs/evidence/real-capture-playback-release-gate-\(evidenceDate).json",
                manualStep: "Validate playback, scrubbing, transcript-aligned cues, encrypted audio readback, and recovery over approved non-private real capture output.",
                approvalRequired: true
            ),
            GateDefinition(
                id: "manual-accessibility-release",
                title: "manual accessibility release gate",
                fileName: "docs/evidence/manual-accessibility-release-gate-\(evidenceDate).json",
                category: "accessibility",
                writeTemplateCommand: "script/manual_accessibility_release_gate.swift --write-template docs/evidence/manual-accessibility-approved-template-\(evidenceDate).json",
                approveCommand: "script/manual_accessibility_release_gate.swift --approved-report docs/evidence/manual-accessibility-approved-template-\(evidenceDate).json --require-pass --output docs/evidence/manual-accessibility-release-gate-\(evidenceDate).json",
                manualStep: "Complete the primary-console recording/Agent accessibility sweep, including Agent prompt, grounded answer, editable response, and copy response proof, plus VoiceOver, keyboard-only, hover/context-menu, resize, permission recovery, Reduce Motion, contrast, and cancel-path evidence.",
                approvalRequired: true
            ),
            GateDefinition(
                id: "clean-machine-release",
                title: "clean-machine release gate",
                fileName: "docs/evidence/clean-machine-release-gate-\(evidenceDate).json",
                category: "release",
                writeTemplateCommand: "script/clean_machine_release_gate.swift --write-template docs/evidence/clean-machine-approved-template-\(evidenceDate).json",
                approveCommand: "script/clean_machine_release_gate.swift --approved-report docs/evidence/clean-machine-approved-template-\(evidenceDate).json --require-pass --output docs/evidence/clean-machine-release-gate-\(evidenceDate).json",
                manualStep: "Install or open the packaged app on a clean Mac or clean user account, prove first launch has no surprise Keychain/password/permission prompts, prove relaunch has no repeated prompts, record firstLaunchObservationCount and relaunchObservationCount above zero, record keychainPromptCount, passwordPromptCount, and permissionPromptCount as zero, verify offline startup and crash-log behavior, and keep evidence bounded.",
                approvalRequired: true
            ),
            GateDefinition(
                id: "sleep-wake-release",
                title: "sleep/wake release gate",
                fileName: "docs/evidence/sleep-wake-release-gate-\(evidenceDate).json",
                category: "recovery",
                writeTemplateCommand: "swift script/sleep_wake_release_gate.swift --write-template docs/evidence/sleep-wake-approved-template-\(evidenceDate).json",
                approveCommand: "swift script/sleep_wake_release_gate.swift --approved-report docs/evidence/sleep-wake-approved-template-\(evidenceDate).json --require-pass --output docs/evidence/sleep-wake-release-gate-\(evidenceDate).json",
                manualStep: "Run real macOS sleep/wake recovery QA during approved non-private capture and verify checkpoint recovery plus crash/log review.",
                approvalRequired: true
            ),
            GateDefinition(
                id: "shortcuts-release",
                title: "Shortcuts/Siri release gate",
                fileName: "docs/evidence/shortcuts-release-gate-\(evidenceDate).json",
                category: "automation",
                writeTemplateCommand: "script/shortcuts_release_gate.swift --write-template docs/evidence/shortcuts-approved-template-\(evidenceDate).json",
                approveCommand: "script/shortcuts_release_gate.swift --approved-report docs/evidence/shortcuts-approved-template-\(evidenceDate).json --require-pass --output docs/evidence/shortcuts-release-gate-\(evidenceDate).json",
                manualStep: "Prove real OS Shortcuts/Siri/App Intents handoff through preflight, start/stop, and local share-review paths without external side effects.",
                approvalRequired: true
            ),
            GateDefinition(
                id: "system-integration-release",
                title: "system integration release gate",
                fileName: "docs/evidence/system-integration-release-gate-\(evidenceDate).json",
                category: "automation",
                writeTemplateCommand: "script/system_integration_release_gate.swift --write-template docs/evidence/system-integration-approved-template-\(evidenceDate).json",
                approveCommand: "script/system_integration_release_gate.swift --approved-report docs/evidence/system-integration-approved-template-\(evidenceDate).json --require-pass --output docs/evidence/system-integration-release-gate-\(evidenceDate).json",
                manualStep: "Approve Calendar, Reminders, and Contacts writes only over non-private fixtures, with confirmation, cancel safety, permission recovery, and redacted receipts.",
                approvalRequired: true
            ),
            GateDefinition(
                id: "distribution-release",
                title: "distribution release gate",
                fileName: "docs/evidence/distribution-release-gate-\(evidenceDate).json",
                category: "distribution",
                writeTemplateCommand: "script/distribution_release_gate.swift --write-template docs/evidence/distribution-approved-template-\(evidenceDate).json",
                approveCommand: "script/distribution_release_gate.swift --approved-report docs/evidence/distribution-approved-template-\(evidenceDate).json --require-pass --output docs/evidence/distribution-release-gate-\(evidenceDate).json",
                manualStep: "Verify the chosen Developer ID or App Store distribution path: signing identity, entitlements/profile, notarization or upload readiness, trust policy, and redacted signing evidence.",
                approvalRequired: true
            )
        ]
    }

    private static func providerPrerequisites() -> [String] {
        [
            "Apple Speech authorization must be allowed for MeetingVault and the app-owned permission smoke must pass.",
            "SpeechAnalyzer assets must be installed or available after explicit local asset-preparation approval.",
            "Foundation Models provider availability must be intentionally confirmed on non-private input."
        ]
    }

    private static func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private static func string(_ value: Any?, fallback: String = "") -> String {
        value as? String ?? fallback
    }

    private static func stringArray(_ value: Any?) -> [String] {
        value as? [String] ?? []
    }

    private static func bool(_ value: Any?) -> Bool {
        value as? Bool ?? false
    }

    private static func int(_ value: Any?) -> Int? {
        value as? Int
    }

    private static func int64(_ value: Any?) -> Int64? {
        if let value = value as? Int64 { return value }
        if let value = value as? Int { return Int64(value) }
        if let value = value as? NSNumber { return value.int64Value }
        return nil
    }

    private static func decimalGigabytes(_ bytes: Int64) -> String {
        let value = Double(bytes) / 1_000_000_000
        return String(format: "%.2f GB", value)
    }

    private static func displayPath(for url: URL, rootURL: URL) -> String {
        let rootPath = rootURL.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return path }
        return String(path.dropFirst(rootPath.count + 1))
    }

    private static func anyTrue(_ objects: [[String: Any]], _ key: String) -> Bool {
        objects.contains { bool($0[key]) }
    }

    private static func isValidDate(_ value: String) -> Bool {
        value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
    }
}

ReleaseBlockerDoctor.main()
