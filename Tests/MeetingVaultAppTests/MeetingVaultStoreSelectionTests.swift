import XCTest
import AppKit
import Combine
import Contacts
import EventKit
import Security
@testable import MeetingVault
@testable import MeetingVaultCore

@MainActor
final class MeetingVaultStoreSelectionTests: XCTestCase {
    func testRecordingLevelPublicationRejectsDelayedSnapshotFromPriorSession() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultRecordingLevelGeneration-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingVaultStore(
            libraryRoot: root,
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 0x53, count: 32)),
            includeSampleData: false
        )
        store.recordingState = .recording
        store.resetRecordingLevelSession()
        let priorSessionHandler = store.recordingLevelHandler()

        store.resetRecordingLevelSession()
        let currentSnapshot = RecordingLevelSnapshot(
            microphone: 0.25,
            systemAudio: 0.5,
            lastMicrophoneFrameAt: ContinuousClock().now,
            lastSystemFrameAt: ContinuousClock().now
        )
        await store.recordingLevelHandler()(currentSnapshot)
        try await waitUntil("current recording level snapshot reaches the store") {
            store.recordingLevelSnapshot == currentSnapshot
        }

        let staleSnapshot = RecordingLevelSnapshot(
            microphone: 0.9,
            systemAudio: 0.8,
            lastMicrophoneFrameAt: ContinuousClock().now,
            lastSystemFrameAt: ContinuousClock().now
        )
        await priorSessionHandler(staleSnapshot)

        XCTAssertEqual(store.recordingLevelSnapshot, currentSnapshot)
        XCTAssertEqual(store.liveInputLevel, currentSnapshot.microphone)
    }

    func testPreviewDropTelemetryPublishesIntoStoreDiagnosticsWithoutFailingRecordingState() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultPreviewDropTelemetry-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingVaultStore(
            libraryRoot: root,
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 0x52, count: 32)),
            includeSampleData: false
        )
        store.recordingState = .recording
        let handler = store.recordingPreviewDropHandler()

        await Task.detached {
            handler(7)
        }.value

        try await waitUntil("preview drop telemetry reaches the main-actor store") {
            store.recordingPreviewDropCount == 7
        }
        XCTAssertEqual(
            store.recordingPreviewDropStatus,
            "Live preview skipped 7 replaceable frames; encrypted recording continues."
        )
        XCTAssertEqual(store.recordingState, .recording)
    }

    func testWorkspaceNavigationRequestsUnifiedMeetingsFocusSections() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultStoreWorkspaceNavigation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = MeetingVaultStore(
            libraryRoot: root,
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 126, count: 32))
        )

        store.showWorkspace(.recorder)
        XCTAssertEqual(store.requestedWorkspaceFocus, MeetingsWorkspaceFocus.record.rawValue)

        store.showWorkspace(.intelligence)
        XCTAssertEqual(store.requestedWorkspaceFocus, MeetingsWorkspaceFocus.understand.rawValue)

        store.showWorkspace(.diagnostics)
        XCTAssertEqual(store.healthRecoveryPresentationEvent?.revision, 1)
        XCTAssertNotEqual(store.requestedWorkspaceFocus, MeetingsWorkspaceFocus.recover.rawValue)

        store.showWorkspace(.diagnostics)
        XCTAssertEqual(store.healthRecoveryPresentationEvent?.revision, 2)

        store.clearRequestedWorkspaceFocus()
        XCTAssertNil(store.requestedWorkspaceFocus)
    }

    func testMeetingsAndLibraryCommandsRequestDistinctWorkspaceSurfaces() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultStoreDistinctWorkspaceCommands-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = MeetingVaultStore(
            libraryRoot: root,
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 71, count: 32))
        )

        store.showWorkspace(.meetings)
        XCTAssertEqual(store.requestedSidebarItem, SidebarItem.meetings.rawValue)
        XCTAssertEqual(store.requestedWorkspaceFocus, MeetingsWorkspaceFocus.understand.rawValue)
        XCTAssertNotEqual(store.requestedWorkspaceFocus, MeetingsWorkspaceFocus.find.rawValue)

        store.showWorkspace(.library)
        XCTAssertEqual(store.requestedSidebarItem, SidebarItem.meetings.rawValue)
        XCTAssertEqual(store.requestedWorkspaceFocus, MeetingsWorkspaceFocus.find.rawValue)
    }

    func testAppIntentHandoffRoutesIntoUnifiedMeetingsFocusSections() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultAppIntentHandoff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = MeetingVaultStore(
            libraryRoot: root,
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 111, count: 32))
        )
        MeetingVaultAppHandoffCenter.shared.register(store: store)

        MeetingVaultAppHandoffCenter.shared.route(.openRecorder)
        XCTAssertEqual(store.requestedWorkspaceFocus, MeetingsWorkspaceFocus.record.rawValue)

        MeetingVaultAppHandoffCenter.shared.route(.prepareShare)
        XCTAssertEqual(store.requestedWorkspaceFocus, MeetingsWorkspaceFocus.export.rawValue)
        XCTAssertEqual(store.shareStatus, "Review the selected meeting export, then choose Prepare Local Share.")

        MeetingVaultAppHandoffCenter.shared.route(.sendWebhook)
        XCTAssertEqual(store.healthRecoveryPresentationEvent?.revision, 1)
        XCTAssertNotEqual(store.requestedWorkspaceFocus, MeetingsWorkspaceFocus.recover.rawValue)
    }

    func testStoreLoadsAndRefreshesReleaseBlockerSummary() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultReleaseBlockerStore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let reportURL = root.appendingPathComponent("release-blocker-doctor.json")
        try releaseBlockerReportJSON(blockedGateCount: 11, totalActionCount: 16)
            .write(to: reportURL, atomically: true, encoding: .utf8)

        let store = MeetingVaultStore(
            libraryRoot: root,
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 82, count: 32)),
            releaseBlockerReportURL: reportURL,
            includeSampleData: false
        )

        XCTAssertEqual(store.releaseBlockerSummary.releaseBlockerStatus, "blocked")
        XCTAssertEqual(store.releaseBlockerSummary.blockedGateCount, 11)
        XCTAssertEqual(store.releaseBlockerSummary.totalActionCount, 16)
        XCTAssertEqual(store.releaseBlockerSummary.operatorBlockers, ["Workspace headroom is blocked."])
        XCTAssertEqual(store.releaseBlockerSummary.workspaceCleanupCandidates.map(\.name), ["User cache"])
        XCTAssertEqual(
            store.releaseBlockerStatus,
            "11 release-candidate gates blocked; 16 clearance actions queued; 1 approval-gated; 1 operator blocker"
        )

        try releaseBlockerReportJSON(blockedGateCount: 10, totalActionCount: 14)
            .write(to: reportURL, atomically: true, encoding: .utf8)
        store.refreshReleaseBlockerSummary()

        XCTAssertEqual(store.releaseBlockerSummary.blockedGateCount, 10)
        XCTAssertEqual(store.releaseBlockerSummary.totalActionCount, 14)
        XCTAssertEqual(store.releaseBlockerSummary.operatorBlockers, ["Workspace headroom is blocked."])
        XCTAssertEqual(store.releaseBlockerSummary.workspaceCleanupCandidates.map(\.pathHint), ["~/.cache"])
        XCTAssertEqual(
            store.releaseBlockerStatus,
            "10 release-candidate gates blocked; 14 clearance actions queued; 1 approval-gated; 1 operator blocker"
        )
    }

    func testWorkspaceLaunchArgumentParsesUnifiedMeetingsAndCompatibilityAliases() {
        XCTAssertEqual(
            SidebarItem.launchWorkspace(from: ["MeetingVault", "--workspace", "meetings"]),
            .meetings
        )
        XCTAssertEqual(
            MeetingsWorkspaceFocus.launchFocus(from: ["MeetingVault", "--workspace", "recorder"]),
            .record
        )
        XCTAssertEqual(
            MeetingsWorkspaceFocus.launchFocus(from: ["MeetingVault", "--workspace", "Intelligence"]),
            .understand
        )
        XCTAssertEqual(
            MeetingsWorkspaceFocus.launchFocus(from: ["MeetingVault", "--workspace", "diagnostics"]),
            .recover
        )
        XCTAssertEqual(
            MeetingsWorkspaceFocus.launchFocus(from: ["MeetingVault", "--workspace", "meetings", "--intelligence-tab", "editor"]),
            .review
        )
        XCTAssertEqual(
            IntelligenceWorkspaceTab.launchTab(from: ["MeetingVault", "--intelligence-tab", "editor"]),
            .editor
        )
        XCTAssertEqual(
            IntelligenceWorkspaceTab.launchTab(from: ["MeetingVault", "--intelligence-tab", "Exports"]),
            .exports
        )
        XCTAssertNil(SidebarItem.launchWorkspace(from: ["MeetingVault", "--workspace", "unknown"]))
        XCTAssertNil(SidebarItem.launchWorkspace(from: ["MeetingVault"]))
        XCTAssertNil(IntelligenceWorkspaceTab.launchTab(from: ["MeetingVault", "--intelligence-tab", "unknown"]))
    }

    private func releaseBlockerReportJSON(blockedGateCount: Int, totalActionCount: Int) -> String {
        """
        {
          "status": "pass",
          "releaseBlockerStatus": "blocked",
          "evidenceDate": "2026-07-01",
          "readinessLabel": "local app ready; release candidate blocked",
          "localReady": true,
          "releaseCandidateReady": false,
          "sourceCommit": "abc123",
          "cleanCheckoutSourceCommit": "abc123",
          "blockedGateCount": \(blockedGateCount),
          "totalActionCount": \(totalActionCount),
          "blockedGates": [
            {
              "id": "distribution-release",
              "title": "distribution release gate",
              "path": "docs/evidence/distribution-release-gate-2026-07-01.json",
              "status": "blocked",
              "requiredForReleaseCandidate": true,
              "passedScenarioCount": 0,
              "requiredScenarioCount": 6,
              "issueCount": 1
            }
          ],
          "approvalQueue": [
            {
              "id": "clear-distribution-release",
              "title": "Clear distribution release gate",
              "category": "distribution",
              "blockedGateID": "distribution-release",
              "commands": ["script/distribution_release_gate.swift --write-template template.json"],
              "manualStep": "Verify distribution signing and notarization.",
              "approvalRequired": true
            }
          ],
          "operatorBlockers": [
            "Workspace headroom is blocked."
          ],
          "workspaceCleanupCandidates": [
            {
              "name": "User cache",
              "pathHint": "~/.cache",
              "bytes": 3099508736,
              "safetyClass": "generatedCache",
              "cleanupAction": "Review contents first; remove only tool caches you recognize as safe to rebuild.",
              "requiresManualReview": true,
              "exists": true
            }
          ],
          "privateAudioRecorded": false,
          "microphoneOpened": false,
          "externalNetworkRequested": false,
          "downloadRequested": false,
          "externalUploadAttempted": false,
          "notarizationSubmitted": false,
          "rawTranscriptStored": false,
          "rawAudioStored": false,
          "rawModelOutputStored": false,
          "rawLogsStored": false,
          "rawUITextStored": false,
          "rawCredentialStored": false,
          "rawSigningOutputStored": false,
          "rawNotarizationOutputStored": false,
          "issues": []
        }
        """
    }

    func testAppearanceLaunchArgumentParsesVisualModes() {
        XCTAssertEqual(
            MeetingVaultAppearanceResolution.launchOverride(from: ["MeetingVault", "--appearance", "light"]),
            .light
        )
        XCTAssertEqual(
            MeetingVaultAppearanceResolution.launchOverride(from: ["MeetingVault", "--appearance", "Dark"]),
            .dark
        )
        XCTAssertNil(MeetingVaultAppearanceResolution.launchOverride(
            from: ["MeetingVault", "--appearance", "unknown"]
        ))
        XCTAssertNil(MeetingVaultAppearanceResolution.launchOverride(from: ["MeetingVault"]))
    }

    func testAccessibilityLaunchArgumentsParseMotionAndContrastOverrides() {
        XCTAssertEqual(
            MeetingVaultLaunchAccessibilityTraits.fromArguments([
                "MeetingVault",
                "--reduce-motion",
                "on",
                "--contrast",
                "increased"
            ]),
            MeetingVaultLaunchAccessibilityTraits(reduceMotion: true, increasedContrast: true)
        )
        XCTAssertEqual(
            MeetingVaultLaunchAccessibilityTraits.fromArguments([
                "MeetingVault",
                "--reduce-motion",
                "off",
                "--contrast",
                "normal"
            ]),
            MeetingVaultLaunchAccessibilityTraits(reduceMotion: false, increasedContrast: false)
        )
        XCTAssertEqual(
            MeetingVaultLaunchAccessibilityTraits.fromArguments([
                "MeetingVault",
                "--reduce-motion",
                "system",
                "--contrast",
                "system"
            ]),
            MeetingVaultLaunchAccessibilityTraits()
        )
        XCTAssertEqual(MeetingVaultLaunchAccessibilityTraits.fromArguments(["MeetingVault"]), MeetingVaultLaunchAccessibilityTraits())
    }

    func testUISmokeLaunchStoreUsesIsolatedStorageAndRetentionOverride() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultUISmokeLaunch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = MeetingVaultLaunchStoreFactory.makeStore(arguments: [
            "MeetingVault",
            "--ui-smoke-library-root",
            root.path,
            "--ui-smoke-retention-days",
            "1",
            "--ui-smoke-meeting-context"
        ])

        XCTAssertEqual(store.retentionDays, 1)
        XCTAssertNotEqual(store.exportStatus, "Export unavailable")
        XCTAssertNotEqual(store.shareStatus, "Share unavailable")
        XCTAssertNotEqual(store.retentionCleanupStatus, "Retention review unavailable")
        XCTAssertFalse(store.meetings.isEmpty)
        XCTAssertEqual(store.meetingContextDraft.participantNames, ["synthetic-private-participant"])
        XCTAssertEqual(store.meetingContextDraft.vocabulary, ["synthetic-private-vocabulary"])

        try store.refreshRetentionCleanupPlan()

        XCTAssertFalse(store.retentionCleanupPlan?.candidates.isEmpty ?? true)
    }

    func testUISmokeLaunchUsesSyntheticAudioInputOnly() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultUISmokeAudio-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = MeetingVaultLaunchStoreFactory.makeStore(arguments: [
            "MeetingVault",
            "--ui-smoke-library-root",
            root.path
        ])
        await store.refreshAudioInputDevices()

        XCTAssertEqual(store.audioInputDevices.map(\.id), ["ui-smoke-studio-microphone"])
        XCTAssertEqual(store.audioInputDevices.map(\.displayName), ["Studio Microphone"])
        XCTAssertEqual(store.audioInputDevices.map(\.transportLabel), ["Synthetic Input"])
        XCTAssertEqual(store.selectedAudioInputDeviceID, "ui-smoke-studio-microphone")
    }

    func testUISmokeLaunchSeedsOnlySmokeRootLocalRecordingPaths() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultUISmokeImport-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = MeetingVaultLaunchStoreFactory.makeStore(arguments: [
            "MeetingVault",
            "--ui-smoke-library-root",
            root.path
        ])
        let standardizedRoot = root.standardizedFileURL.path + "/"
        let candidates = store.localRecordingSamples

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.title, "Synthetic Planning Session")
        for candidate in candidates {
            XCTAssertTrue(candidate.transcriptURL.standardizedFileURL.path.hasPrefix(standardizedRoot))
            XCTAssertTrue(candidate.audioURL.standardizedFileURL.path.hasPrefix(standardizedRoot))
            XCTAssertTrue(FileManager.default.fileExists(atPath: candidate.transcriptURL.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: candidate.audioURL.path))
        }
        XCTAssertTrue(store.localRecordingTranscriptPath.hasPrefix(standardizedRoot))
        XCTAssertTrue(store.localRecordingAudioPath.hasPrefix(standardizedRoot))
    }

    func testProductionLaunchRuntimeDefaultsToRealProviders() {
        let profile = MeetingVaultLaunchRuntimeProfile.from(
            arguments: ["MeetingVault"],
            environment: [:]
        )
        let runtime = MeetingVaultLaunchRuntimeConfiguration.resolve(
            profile: profile,
            environment: [:]
        )

        XCTAssertEqual(profile, .production)
        XCTAssertEqual(runtime.capture, .systemAndMicrophone)
        XCTAssertEqual(runtime.liveTranscription, .local)
        XCTAssertEqual(runtime.finalTranscription, .local)
        XCTAssertEqual(runtime.intelligence, .foundationModels)
        XCTAssertEqual(runtime.transcriptQuestion, .foundationModels)
    }

    func testProductionRuntimeConfigurationRejectsInvalidOrDemoProviderValues() throws {
        XCTAssertThrowsError(
            try MeetingVaultLaunchRuntimeConfiguration.validateProductionEnvironment([
                "MEETINGVAULT_CAPTURE_RUNTIME": "mock"
            ])
        ) { error in
            XCTAssertEqual(
                error as? MeetingVaultLaunchConfigurationError,
                .invalidProductionRuntime(key: "MEETINGVAULT_CAPTURE_RUNTIME", value: "mock")
            )
        }
        XCTAssertNoThrow(
            try MeetingVaultLaunchRuntimeConfiguration.validateProductionEnvironment([
                "MEETINGVAULT_CAPTURE_RUNTIME": "selected-microphone",
                "MEETINGVAULT_LIVE_TRANSCRIPTION": "local",
                "MEETINGVAULT_FINAL_TRANSCRIPTION": "local-only",
                "MEETINGVAULT_INTELLIGENCE_RUNTIME": "foundation-models",
                "MEETINGVAULT_TRANSCRIPT_QA_RUNTIME": "foundation-models"
            ])
        )
    }

    func testLaunchKeyProviderDefaultsToLocalFileToAvoidRepeatedKeychainPrompts() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultLaunchLocalKey-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let mode = MeetingVaultLaunchKeyProviderMode.from(
            arguments: ["MeetingVault"],
            environment: [:]
        )
        let keyURL = MeetingVaultLaunchStoreFactory.localFileKeyURL(libraryRoot: root)
        let store = MeetingVaultLaunchStoreFactory.makeStore(
            arguments: ["MeetingVault", "--library-root", root.path],
            environment: [:]
        )
        let keyProvider = MeetingVaultLaunchStoreFactory.makeKeyProvider(
            mode: mode,
            libraryRoot: root
        )

        XCTAssertEqual(mode, .localFile)
        XCTAssertFalse(FileManager.default.fileExists(atPath: keyURL.path))
        _ = try keyProvider.loadKey()
        XCTAssertTrue(FileManager.default.fileExists(atPath: keyURL.path))
        XCTAssertTrue(store.meetings.isEmpty)
        XCTAssertNotEqual(store.exportStatus, "Export unavailable")
    }

    func testStoreDefaultKeyProviderUsesLocalFileInsteadOfKeychain() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultStoreDefaultLocalKey-\(UUID().uuidString)", isDirectory: true)
        let keyURL = root
            .appendingPathComponent(".meetingvault", isDirectory: true)
            .appendingPathComponent("local-master-key.bin")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertFalse(FileManager.default.fileExists(atPath: keyURL.path))
        let store = MeetingVaultStore(libraryRoot: root, includeSampleData: true)

        XCTAssertTrue(FileManager.default.fileExists(atPath: keyURL.path))
        XCTAssertFalse(store.meetings.isEmpty)
        XCTAssertEqual(store.recordingState, .ready)
        XCTAssertNotEqual(store.exportStatus, "Export unavailable")
    }

    func testUISmokeLaunchCanOverrideStorageCapacityForRecoveryProof() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultLaunchLowStorageSmoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = MeetingVaultLaunchStoreFactory.makeStore(
            arguments: [
                "MeetingVault",
                "--ui-smoke-library-root",
                root.path,
                "--ui-smoke-storage-bytes",
                "1"
            ],
            environment: [:]
        )

        let result = await store.refreshPermissions()

        XCTAssertEqual(result.storageEstimate?.availableBytes, 1)
        XCTAssertTrue(result.issues.contains(.diskSpaceLow))
    }

    func testUISmokeLaunchCanOverridePermissionsForRecoveryProof() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultLaunchPermissionSmoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = MeetingVaultLaunchStoreFactory.makeStore(
            arguments: [
                "MeetingVault",
                "--ui-smoke-library-root",
                root.path,
                "--ui-smoke-permissions",
                "denied"
            ],
            environment: [:]
        )

        let result = await store.refreshPermissions()

        XCTAssertEqual(store.microphoneAuthorizationState, .denied)
        XCTAssertEqual(store.appleSpeechAuthorizationState, .denied)
        XCTAssertTrue(result.issues.contains(.audioPermissionMissing))
        XCTAssertTrue(result.issues.contains(.microphonePermissionMissing))
        XCTAssertFalse(result.issues.contains(.speechPermissionMissing))
        XCTAssertEqual(
            result.recoveryActions.map(\.title),
            [
                "Allow Screen & System Audio Recording",
                "Allow Microphone"
            ]
        )
    }

    func testLaunchKeyProviderCanUseKeychainOnlyWhenExplicit() {
        XCTAssertEqual(
            MeetingVaultLaunchKeyProviderMode.from(
                arguments: ["MeetingVault", "--key-provider", "keychain"],
                environment: [:]
            ),
            .keychain
        )
        XCTAssertEqual(
            MeetingVaultLaunchKeyProviderMode.from(
                arguments: ["MeetingVault"],
                environment: ["MEETINGVAULT_KEY_PROVIDER": "keychain"]
            ),
            .keychain
        )
        XCTAssertEqual(
            MeetingVaultLaunchKeyProviderMode.from(
                arguments: ["MeetingVault", "--key-provider", "local-file"],
                environment: ["MEETINGVAULT_KEY_PROVIDER": "keychain"]
            ),
            .localFile
        )
    }

    func testDemoLaunchRuntimeIsExplicitAndIsolatedFromRealProviders() {
        let profile = MeetingVaultLaunchRuntimeProfile.from(
            arguments: ["MeetingVault", "--demo-runtime"],
            environment: [
                "MEETINGVAULT_CAPTURE_RUNTIME": "selected-microphone",
                "MEETINGVAULT_FINAL_TRANSCRIPTION": "speech-analyzer",
                "MEETINGVAULT_INTELLIGENCE_RUNTIME": "foundation-models",
                "MEETINGVAULT_TRANSCRIPT_QA_RUNTIME": "foundation-models"
            ]
        )
        let runtime = MeetingVaultLaunchRuntimeConfiguration.resolve(
            profile: profile,
            environment: [:]
        )

        XCTAssertEqual(profile, .demo)
        XCTAssertEqual(runtime.capture, .mock)
        XCTAssertEqual(runtime.liveTranscription, .demo)
        XCTAssertEqual(runtime.finalTranscription, .demo)
        XCTAssertEqual(runtime.intelligence, .demo)
        XCTAssertEqual(runtime.transcriptQuestion, .deterministic)
    }

    func testProductionStoreStartsWithoutSeededLibraryOrTranscriptContent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultProductionNoSamples-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = MeetingVaultStore(
            libraryRoot: root,
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 127, count: 32)),
            captureRuntimeMode: .selectedMicrophone,
            liveTranscriptionRuntimeMode: .appleSpeech,
            finalTranscriptionRuntimeMode: .speechAnalyzer,
            intelligenceRuntimeMode: .foundationModels,
            transcriptQuestionRuntimeMode: .foundationModels,
            includeSampleData: false
        )

        XCTAssertTrue(store.meetings.isEmpty)
        XCTAssertTrue(store.transcriptEditDraft.segments.isEmpty)
        XCTAssertEqual(store.transcriptEditMeetingTitle, "Selected meeting")
        XCTAssertEqual(store.sources.map(\.id), ["selected-microphone"])
    }

    func testProductionStoreRemovesLegacyPlaintextSearchDerivative() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultLegacySearchMigration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["library.sqlite", "library.sqlite-wal", "library.sqlite-shm"] {
            try Data("sensitive transcript derivative".utf8).write(to: root.appendingPathComponent(name))
        }

        _ = MeetingVaultStore(
            libraryRoot: root,
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 126, count: 32)),
            includeSampleData: false
        )

        for name in ["library.sqlite", "library.sqlite-wal", "library.sqlite-shm"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path))
        }
    }

    func testTranscriptEditorFollowsSelectedMeetingAndKeepsSavedSessionsSeparate() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultStoreSelection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = MeetingVaultStore(
            libraryRoot: root,
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 88, count: 32))
        )
        let firstMeetingID = try XCTUnwrap(store.meetings.first?.id)
        let secondMeetingID = try XCTUnwrap(store.meetings.dropFirst().first?.id)
        let firstMeetingText = try XCTUnwrap(store.transcriptEditDraft.segments.first?.editedText)

        XCTAssertEqual(store.transcriptEditDraft.meetingID, firstMeetingID)

        store.selectedMeetingID = secondMeetingID

        XCTAssertEqual(store.transcriptEditDraft.meetingID, secondMeetingID)
        XCTAssertNotEqual(store.transcriptEditDraft.segments.first?.editedText, firstMeetingText)
        XCTAssertEqual(store.transcriptEditHistory.meetingID, secondMeetingID)

        let secondSegmentID = try XCTUnwrap(store.transcriptEditDraft.segments.first?.id)
        store.updateTranscriptDraftText(
            id: secondSegmentID,
            text: "The visual hierarchy needs one more pass before approval."
        )
        if let save = store.saveTranscriptDraft() { await save.value }

        XCTAssertEqual(store.transcriptEditDraft.meetingID, secondMeetingID)
        XCTAssertEqual(store.transcriptEditHistory.latestVersion, 1)
        XCTAssertEqual(store.transcriptEditDraft.segments.first?.originalText, "The visual hierarchy needs one more pass before approval.")

        store.selectedMeetingID = firstMeetingID

        XCTAssertEqual(store.transcriptEditDraft.meetingID, firstMeetingID)
        XCTAssertEqual(store.transcriptEditDraft.segments.first?.editedText, firstMeetingText)
        XCTAssertFalse(
            store.transcriptEditDraft.segments.contains {
                $0.editedText == "The visual hierarchy needs one more pass before approval."
            }
        )
    }

    func testTranscriptRestoreRequiresConfirmationAndReloadsLatestSavedVersion() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultStoreTranscriptRestore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = MeetingVaultStore(
            libraryRoot: root,
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 124, count: 32))
        )
        let segmentID = try XCTUnwrap(store.transcriptEditDraft.segments.first?.id)

        store.updateTranscriptDraftText(
            id: segmentID,
            text: "Saved transcript text for restore."
        )
        if let save = store.saveTranscriptDraft() { await save.value }
        let savedVersion = store.transcriptEditHistory.latestVersion
        XCTAssertGreaterThan(savedVersion, 0)
        XCTAssertEqual(store.transcriptEditDraft.segments.first?.originalText, "Saved transcript text for restore.")

        store.updateTranscriptDraftText(
            id: segmentID,
            text: "Unsaved conflicting transcript text."
        )
        store.transcriptAskAnswerDraft = "Answer based on unsaved conflicting transcript text."
        store.transcriptAskEvidence = [
            TranscriptQuestionEvidence(
                segmentID: segmentID,
                speakerName: "Speaker",
                startTime: 0,
                endTime: 1,
                quote: "Unsaved conflicting transcript text."
            )
        ]

        do {
            _ = try store.restoreTranscriptDraftFromSaved(userConfirmed: false)
            XCTFail("Expected restore to require confirmation before discarding unsaved edits")
        } catch {
            XCTAssertEqual(error as? MeetingVaultTranscriptRestoreRuntimeError, .confirmationRequired)
        }

        XCTAssertTrue(store.transcriptRestoreNeedsConfirmation)
        XCTAssertEqual(store.transcriptEditStatus, "Confirm restore before discarding unsaved transcript edits")
        XCTAssertEqual(store.transcriptEditDraft.segments.first?.editedText, "Unsaved conflicting transcript text.")

        let restored = try store.restoreTranscriptDraftFromSaved(userConfirmed: true)

        XCTAssertEqual(restored.history.latestVersion, savedVersion)
        XCTAssertFalse(store.transcriptEditDraft.hasChanges)
        XCTAssertFalse(store.transcriptRestoreNeedsConfirmation)
        XCTAssertEqual(store.transcriptEditDraft.currentVersion, savedVersion)
        XCTAssertEqual(store.transcriptEditDraft.segments.first?.editedText, "Saved transcript text for restore.")
        XCTAssertEqual(store.transcriptEditDraft.segments.first?.originalText, "Saved transcript text for restore.")
        XCTAssertEqual(store.transcriptEditStatus, "Restored latest saved transcript version \(savedVersion)")
        XCTAssertTrue(store.transcriptAskAnswerDraft.isEmpty)
        XCTAssertTrue(store.transcriptAskEvidence.isEmpty)
        XCTAssertEqual(store.transcriptAskStatus, "Visible transcript restored; ask again for an updated answer")
    }

    func testDelayedConfidenceCorrectionCannotReplaceNewMeetingReviewDraftOrPlaybackState() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultReviewCorrectionSelectionRace-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let keyProvider = InMemorySymmetricKeyProvider(keyData: Data(repeating: 0x6A, count: 32))
        let reconciliationGate = ControlledTranscriptCorrectionRegenerationGate()
        let store = MeetingVaultStore(
            libraryRoot: root,
            keyProvider: keyProvider,
            transcriptCorrectionStoreReconciliationGate: { meetingID in
                await reconciliationGate.suspend(meetingID: meetingID)
            }
        )
        let correctedMeetingID = try XCTUnwrap(store.selectedMeetingID)
        let currentMeetingID = try XCTUnwrap(store.meetings.first { $0.id != correctedMeetingID }?.id)
        let segment = try XCTUnwrap(store.transcriptEditDraft.segments.first)
        let evidence = try TranscriptSegmentEvidence(
            segmentID: segment.id,
            trackKind: segment.trackKind,
            startTime: segment.startTime,
            endTime: segment.endTime,
            confidence: 0.4,
            speakerConfidence: 0.9,
            overlapsSpeech: false,
            reconstructedFromPreviewGap: false,
            providerConfigurationVersion: store.transcriptEditDraft.providerConfigurationVersion
        )
        let bundleStore = EncryptedMeetingBundleStore(
            rootDirectory: root,
            vault: AESGCMDataVault(keyProvider: keyProvider)
        )
        let chunkWriter = EncryptedAudioChunkWriter(bundleStore: bundleStore)
        for track in TrackKind.allCases {
            _ = try chunkWriter.writeChunk(
                Data([1, 2, 3, 4]),
                meetingID: correctedMeetingID,
                track: track,
                chunkIndex: 0,
                startTime: 0,
                duration: max(1, segment.endTime + 1),
                codec: "CAF/LPCM"
            )
        }
        var transcript = try bundleStore.readJSONArtifact(
            MeetingTranscript.self,
            meetingID: correctedMeetingID,
            relativePath: MeetingTranscript.finalTranscriptRelativePath,
            purpose: MeetingTranscript.finalTranscriptPurpose
        )
        transcript.segments[0].reviewEvidence = evidence
        try bundleStore.writeJSONArtifact(
            transcript,
            meetingID: correctedMeetingID,
            relativePath: MeetingTranscript.finalTranscriptRelativePath,
            purpose: MeetingTranscript.finalTranscriptPurpose
        )
        let queue = try TranscriptConfidenceReviewService(
            now: { Date(timeIntervalSince1970: 1_805_000_000) }
        ).deriveQueue(transcript: transcript, evidence: [evidence], transcriptVersion: transcript.transcriptVersion)
        try TranscriptReviewRepository(bundleStore: bundleStore).save(queue)
        store.selectedMeetingID = currentMeetingID
        store.selectedMeetingID = correctedMeetingID
        let loadedItem = try XCTUnwrap(store.transcriptReviewQueue?.pendingItems.first)
        store.transcriptAskPrompt = "What was decided before the correction?"
        store.askSelectedTranscript()
        XCTAssertEqual(store.transcriptConversationTurns.count, 1)

        store.correctTranscriptReviewItem(
            item: loadedItem,
            replacementText: "Corrected only in the prior meeting.",
            replacementSpeakerName: segment.effectiveEditedSpeakerName
        )
        XCTAssertTrue(store.transcriptCorrectionInFlight)
        store.selectedMeetingID = currentMeetingID

        try await waitForTranscriptCorrectionGate(
            reconciliationGate,
            meetingID: correctedMeetingID
        )
        XCTAssertEqual(store.selectedMeetingID, currentMeetingID)
        XCTAssertEqual(store.transcriptEditDraft.meetingID, currentMeetingID)
        XCTAssertEqual(store.transcriptEditHistory.meetingID, currentMeetingID)
        XCTAssertEqual(store.playbackTimeline.meetingID, currentMeetingID)
        XCTAssertEqual(store.playbackSessionState.meetingID, currentMeetingID)
        XCTAssertNotEqual(store.transcriptReviewQueue?.meetingID, correctedMeetingID)
        XCTAssertFalse(store.transcriptEditDraft.segments.contains { $0.editedText == "Corrected only in the prior meeting." })

        store.playTranscriptReviewItem(loadedItem)
        XCTAssertNotEqual(store.playbackSessionState.meetingID, correctedMeetingID)
        store.setTranscriptReviewStatus(itemID: loadedItem.id, status: .resolved)
        XCTAssertNotEqual(store.transcriptReviewQueue?.meetingID, correctedMeetingID)
        let correctedTranscript = try bundleStore.readJSONArtifact(
            MeetingTranscript.self,
            meetingID: correctedMeetingID,
            relativePath: MeetingTranscript.finalTranscriptRelativePath,
            purpose: MeetingTranscript.finalTranscriptPurpose
        )

        store.selectedMeetingID = correctedMeetingID

        XCTAssertEqual(store.transcriptEditDraft.meetingID, correctedMeetingID)
        XCTAssertEqual(store.transcriptEditDraft.currentVersion, correctedTranscript.transcriptVersion)
        XCTAssertEqual(store.transcriptEditHistory.latestVersion, correctedTranscript.transcriptVersion)
        XCTAssertTrue(store.transcriptEditDraft.segments.contains {
            $0.editedText == "Corrected only in the prior meeting."
        })
        XCTAssertEqual(store.playbackTimeline.meetingID, correctedMeetingID)
        XCTAssertTrue(store.playbackTimeline.cues.contains {
            $0.text == "Corrected only in the prior meeting."
        })
        XCTAssertEqual(store.playbackSessionState.meetingID, correctedMeetingID)
        XCTAssertTrue(store.transcriptConversationTurns.isEmpty)
        XCTAssertTrue(store.transcriptAskAnswerDraft.isEmpty)
        XCTAssertTrue(store.transcriptAskEvidence.isEmpty)

        await reconciliationGate.release(meetingID: correctedMeetingID)
        try await waitUntil("prior-meeting correction reconciliation completes") {
            !store.transcriptCorrectionInFlight
        }
        let invalidatedHistory = try TranscriptQuestionHistoryService(bundleStore: bundleStore)
            .load(meetingID: correctedMeetingID)
        XCTAssertTrue(invalidatedHistory.turns.isEmpty)
        XCTAssertNotNil(invalidatedHistory.invalidatedAt)
        XCTAssertEqual(invalidatedHistory.transcriptVersion, correctedTranscript.transcriptVersion)
    }

    func testDelayedCorrectionRecoveryCannotReplaceNewMeetingVisibleState() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultReviewRecoverySelectionRace-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let keyProvider = InMemorySymmetricKeyProvider(keyData: Data(repeating: 0x6B, count: 32))
        let store = MeetingVaultStore(libraryRoot: root, keyProvider: keyProvider)
        let recoveringMeetingID = try XCTUnwrap(store.selectedMeetingID)
        let currentMeetingID = try XCTUnwrap(store.meetings.first { $0.id != recoveringMeetingID }?.id)
        let bundleStore = EncryptedMeetingBundleStore(
            rootDirectory: root,
            vault: AESGCMDataVault(keyProvider: keyProvider)
        )
        store.transcriptAskPrompt = "What was decided before recovery?"
        store.askSelectedTranscript()
        XCTAssertEqual(store.transcriptConversationTurns.count, 1)
        var transcript = try bundleStore.readJSONArtifact(
            MeetingTranscript.self,
            meetingID: recoveringMeetingID,
            relativePath: MeetingTranscript.finalTranscriptRelativePath,
            purpose: MeetingTranscript.finalTranscriptPurpose
        )
        transcript.transcriptVersion = 1
        transcript.editedAt = Date(timeIntervalSince1970: 1_805_000_100)
        transcript.segments[0].text = "Recovered only for the prior meeting."
        try bundleStore.writeJSONArtifact(
            transcript,
            meetingID: recoveringMeetingID,
            relativePath: MeetingTranscript.finalTranscriptRelativePath,
            purpose: MeetingTranscript.finalTranscriptPurpose
        )
        let marker = TranscriptCorrectionRecoveryMarker(
            meetingID: recoveringMeetingID,
            targetTranscriptVersion: 1,
            transcriptDigest: try LocalFinalTranscriptionService.transcriptDigest(transcript),
            editedSegmentIDs: [transcript.segments[0].id],
            resolvedReviewItemIDs: [],
            phase: .authoritativeCommitted,
            startedAt: Date(timeIntervalSince1970: 1_805_000_100)
        )
        try bundleStore.writeJSONArtifact(
            marker,
            meetingID: recoveringMeetingID,
            relativePath: TranscriptCorrectionRecoveryMarker.relativePath,
            purpose: TranscriptCorrectionRecoveryMarker.purpose
        )

        store.selectedMeetingID = currentMeetingID
        store.selectedMeetingID = recoveringMeetingID
        store.selectedMeetingID = currentMeetingID

        try await waitUntil("prior-meeting correction recovery completes") {
            !(try! bundleStore.artifactExists(
                meetingID: recoveringMeetingID,
                relativePath: TranscriptCorrectionRecoveryMarker.relativePath
            ))
        }
        XCTAssertEqual(store.selectedMeetingID, currentMeetingID)
        XCTAssertEqual(store.transcriptEditDraft.meetingID, currentMeetingID)
        XCTAssertEqual(store.transcriptEditHistory.meetingID, currentMeetingID)
        XCTAssertEqual(store.playbackTimeline.meetingID, currentMeetingID)
        XCTAssertEqual(store.playbackSessionState.meetingID, currentMeetingID)
        XCTAssertNotEqual(store.transcriptReviewQueue?.meetingID, recoveringMeetingID)
        XCTAssertFalse(store.transcriptEditDraft.segments.contains { $0.editedText == "Recovered only for the prior meeting." })

        store.selectedMeetingID = recoveringMeetingID

        XCTAssertEqual(store.transcriptEditDraft.meetingID, recoveringMeetingID)
        XCTAssertEqual(store.transcriptEditDraft.currentVersion, 1)
        XCTAssertEqual(store.transcriptEditHistory.latestVersion, 1)
        XCTAssertTrue(store.transcriptEditDraft.segments.contains {
            $0.editedText == "Recovered only for the prior meeting."
        })
        XCTAssertEqual(store.playbackTimeline.meetingID, recoveringMeetingID)
        XCTAssertTrue(store.playbackTimeline.cues.contains {
            $0.text == "Recovered only for the prior meeting."
        })
        XCTAssertEqual(store.playbackSessionState.meetingID, recoveringMeetingID)
        XCTAssertTrue(store.transcriptConversationTurns.isEmpty)
        XCTAssertTrue(store.transcriptAskAnswerDraft.isEmpty)
        XCTAssertTrue(store.transcriptAskEvidence.isEmpty)
        let invalidatedHistory = try TranscriptQuestionHistoryService(bundleStore: bundleStore)
            .load(meetingID: recoveringMeetingID)
        XCTAssertTrue(invalidatedHistory.turns.isEmpty)
        XCTAssertNotNil(invalidatedHistory.invalidatedAt)
        XCTAssertEqual(invalidatedHistory.transcriptVersion, 1)
    }

    func testDelayedCorrectionRemainsBusyAndPublishesWhenReturningBeforeCompletion() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultCorrectionNavigationCycle-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let keyProvider = InMemorySymmetricKeyProvider(keyData: Data(repeating: 0x79, count: 32))
        let gate = ControlledTranscriptCorrectionRegenerationGate()
        let store = MeetingVaultStore(
            libraryRoot: root,
            keyProvider: keyProvider,
            transcriptCorrectionRegenerationGate: { meetingID in
                await gate.suspend(meetingID: meetingID)
            }
        )
        let correctedMeetingID = try XCTUnwrap(store.selectedMeetingID)
        let otherMeetingID = try XCTUnwrap(store.meetings.first { $0.id != correctedMeetingID }?.id)
        let segment = try XCTUnwrap(store.transcriptEditDraft.segments.first)
        let evidence = try TranscriptSegmentEvidence(
            segmentID: segment.id,
            trackKind: segment.trackKind,
            startTime: segment.startTime,
            endTime: segment.endTime,
            confidence: 0.3,
            speakerConfidence: 0.9,
            overlapsSpeech: false,
            reconstructedFromPreviewGap: false,
            providerConfigurationVersion: store.transcriptEditDraft.providerConfigurationVersion
        )
        let bundleStore = EncryptedMeetingBundleStore(
            rootDirectory: root,
            vault: AESGCMDataVault(keyProvider: keyProvider)
        )
        let chunkWriter = EncryptedAudioChunkWriter(bundleStore: bundleStore)
        for track in TrackKind.allCases {
            _ = try chunkWriter.writeChunk(
                Data([1, 2, 3, 4]),
                meetingID: correctedMeetingID,
                track: track,
                chunkIndex: 0,
                startTime: 0,
                duration: max(1, segment.endTime + 1),
                codec: "CAF/LPCM"
            )
        }
        var transcript = try bundleStore.readJSONArtifact(
            MeetingTranscript.self,
            meetingID: correctedMeetingID,
            relativePath: MeetingTranscript.finalTranscriptRelativePath,
            purpose: MeetingTranscript.finalTranscriptPurpose
        )
        transcript.segments[0].reviewEvidence = evidence
        try bundleStore.writeJSONArtifact(
            transcript,
            meetingID: correctedMeetingID,
            relativePath: MeetingTranscript.finalTranscriptRelativePath,
            purpose: MeetingTranscript.finalTranscriptPurpose
        )
        let queue = try TranscriptConfidenceReviewService().deriveQueue(
            transcript: transcript,
            evidence: [evidence],
            transcriptVersion: transcript.transcriptVersion
        )
        try TranscriptReviewRepository(bundleStore: bundleStore).save(queue)
        store.selectedMeetingID = otherMeetingID
        store.selectedMeetingID = correctedMeetingID
        let reviewItem = try XCTUnwrap(store.transcriptReviewQueue?.pendingItems.first)
        store.transcriptAskPrompt = "What was decided before this navigation cycle?"
        store.askSelectedTranscript()
        XCTAssertEqual(store.transcriptConversationTurns.count, 1)

        store.correctTranscriptReviewItem(
            item: reviewItem,
            replacementText: "Correction survives the navigation cycle.",
            replacementSpeakerName: segment.effectiveEditedSpeakerName
        )
        try await waitForTranscriptCorrectionGate(gate, meetingID: correctedMeetingID)

        store.selectedMeetingID = otherMeetingID
        XCTAssertEqual(store.transcriptEditDraft.meetingID, otherMeetingID)
        XCTAssertFalse(store.transcriptCorrectionInFlight)
        store.selectedMeetingID = correctedMeetingID

        XCTAssertTrue(store.transcriptCorrectionInFlight)
        store.updateTranscriptDraftText(
            id: segment.id,
            text: "A second correction must remain blocked."
        )
        XCTAssertNil(store.saveTranscriptDraft())
        XCTAssertEqual(store.transcriptEditStatus, "A transcript correction is already being saved")
        store.updateTranscriptDraftText(id: segment.id, text: segment.originalText)
        XCTAssertFalse(store.transcriptEditDraft.hasChanges)
        let correctionGateEntryCount = await gate.entryCount(meetingID: correctedMeetingID)
        XCTAssertEqual(correctionGateEntryCount, 1)

        await gate.release(meetingID: correctedMeetingID)
        try await waitUntil("returned meeting publishes the completed correction") {
            !store.transcriptCorrectionInFlight
                && store.transcriptEditDraft.currentVersion > transcript.transcriptVersion
                && store.transcriptEditDraft.segments.contains {
                    $0.editedText == "Correction survives the navigation cycle."
                }
        }

        XCTAssertEqual(store.selectedMeetingID, correctedMeetingID)
        XCTAssertEqual(store.transcriptEditHistory.latestVersion, store.transcriptEditDraft.currentVersion)
        XCTAssertEqual(store.playbackTimeline.meetingID, correctedMeetingID)
        XCTAssertTrue(store.playbackTimeline.cues.contains {
            $0.text == "Correction survives the navigation cycle."
        })
        XCTAssertEqual(store.transcriptReviewQueue?.meetingID, correctedMeetingID)
        XCTAssertEqual(store.transcriptReviewQueue?.transcriptVersion, store.transcriptEditDraft.currentVersion)
        XCTAssertTrue(store.transcriptConversationTurns.isEmpty)
        XCTAssertTrue(store.transcriptAskEvidence.isEmpty)
        let completedCorrectionGateEntryCount = await gate.entryCount(meetingID: correctedMeetingID)
        XCTAssertEqual(completedCorrectionGateEntryCount, 1)
    }

    func testDelayedRecoveryRemainsBusyAndPublishesWhenReturningBeforeCompletion() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultRecoveryNavigationCycle-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let keyProvider = InMemorySymmetricKeyProvider(keyData: Data(repeating: 0x7A, count: 32))
        let gate = ControlledTranscriptCorrectionRegenerationGate()
        let store = MeetingVaultStore(
            libraryRoot: root,
            keyProvider: keyProvider,
            transcriptCorrectionRegenerationGate: { meetingID in
                await gate.suspend(meetingID: meetingID)
            }
        )
        let recoveringMeetingID = try XCTUnwrap(store.selectedMeetingID)
        let otherMeetingID = try XCTUnwrap(store.meetings.first { $0.id != recoveringMeetingID }?.id)
        let originalSegment = try XCTUnwrap(store.transcriptEditDraft.segments.first)
        let originalReviewItem = try TranscriptReviewItem(
            id: UUID(),
            segmentID: originalSegment.id,
            trackKind: originalSegment.trackKind,
            startTime: originalSegment.startTime,
            endTime: originalSegment.endTime,
            reason: .lowConfidence,
            confidence: 0.3,
            status: .needsReview,
            transcriptVersion: store.transcriptEditDraft.currentVersion,
            providerConfigurationVersion: store.transcriptEditDraft.providerConfigurationVersion
        )
        let bundleStore = EncryptedMeetingBundleStore(
            rootDirectory: root,
            vault: AESGCMDataVault(keyProvider: keyProvider)
        )
        store.transcriptAskPrompt = "What was decided before recovery?"
        store.askSelectedTranscript()
        XCTAssertEqual(store.transcriptConversationTurns.count, 1)
        var transcript = try bundleStore.readJSONArtifact(
            MeetingTranscript.self,
            meetingID: recoveringMeetingID,
            relativePath: MeetingTranscript.finalTranscriptRelativePath,
            purpose: MeetingTranscript.finalTranscriptPurpose
        )
        transcript.transcriptVersion += 1
        transcript.editedAt = Date(timeIntervalSince1970: 1_805_300_000)
        transcript.segments[0].text = "Recovery survives the navigation cycle."
        try bundleStore.writeJSONArtifact(
            transcript,
            meetingID: recoveringMeetingID,
            relativePath: MeetingTranscript.finalTranscriptRelativePath,
            purpose: MeetingTranscript.finalTranscriptPurpose
        )
        let marker = TranscriptCorrectionRecoveryMarker(
            meetingID: recoveringMeetingID,
            targetTranscriptVersion: transcript.transcriptVersion,
            transcriptDigest: try LocalFinalTranscriptionService.transcriptDigest(transcript),
            editedSegmentIDs: [transcript.segments[0].id],
            resolvedReviewItemIDs: [],
            phase: .authoritativeCommitted,
            startedAt: Date(timeIntervalSince1970: 1_805_300_000)
        )
        try bundleStore.writeJSONArtifact(
            marker,
            meetingID: recoveringMeetingID,
            relativePath: TranscriptCorrectionRecoveryMarker.relativePath,
            purpose: TranscriptCorrectionRecoveryMarker.purpose
        )

        store.selectedMeetingID = otherMeetingID
        store.selectedMeetingID = recoveringMeetingID
        try await waitForTranscriptCorrectionGate(gate, meetingID: recoveringMeetingID)
        store.selectedMeetingID = otherMeetingID
        XCTAssertFalse(store.transcriptCorrectionInFlight)
        store.selectedMeetingID = recoveringMeetingID

        XCTAssertTrue(store.transcriptCorrectionInFlight)
        store.correctTranscriptReviewItem(
            item: originalReviewItem,
            replacementText: "A second correction must remain blocked.",
            replacementSpeakerName: "Speaker"
        )
        XCTAssertEqual(store.transcriptReviewStatus, "A transcript correction is already being saved")
        let recoveryGateEntryCount = await gate.entryCount(meetingID: recoveringMeetingID)
        XCTAssertEqual(recoveryGateEntryCount, 1)

        await gate.release(meetingID: recoveringMeetingID)
        try await waitUntil("returned meeting publishes completed correction recovery") {
            !store.transcriptCorrectionInFlight
                && store.transcriptEditDraft.currentVersion == transcript.transcriptVersion
                && store.transcriptEditDraft.segments.contains {
                    $0.editedText == "Recovery survives the navigation cycle."
                }
        }

        XCTAssertEqual(store.selectedMeetingID, recoveringMeetingID)
        XCTAssertEqual(store.transcriptEditHistory.latestVersion, transcript.transcriptVersion)
        XCTAssertEqual(store.playbackTimeline.meetingID, recoveringMeetingID)
        XCTAssertTrue(store.playbackTimeline.cues.contains {
            $0.text == "Recovery survives the navigation cycle."
        })
        XCTAssertEqual(store.transcriptReviewQueue?.meetingID, recoveringMeetingID)
        XCTAssertEqual(store.transcriptReviewQueue?.transcriptVersion, transcript.transcriptVersion)
        XCTAssertTrue(store.transcriptConversationTurns.isEmpty)
        XCTAssertTrue(store.transcriptAskEvidence.isEmpty)
        let completedRecoveryGateEntryCount = await gate.entryCount(meetingID: recoveringMeetingID)
        XCTAssertEqual(completedRecoveryGateEntryCount, 1)
    }

    func testDelayedRecoveryDoesNotOverwriteUnsavedDraftAfterReturningBeforeCompletion() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultRecoveryDirtyDraftNavigationCycle-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let keyProvider = InMemorySymmetricKeyProvider(keyData: Data(repeating: 0x7B, count: 32))
        let gate = ControlledTranscriptCorrectionRegenerationGate()
        let store = MeetingVaultStore(
            libraryRoot: root,
            keyProvider: keyProvider,
            transcriptCorrectionRegenerationGate: { meetingID in
                await gate.suspend(meetingID: meetingID)
            }
        )
        let recoveringMeetingID = try XCTUnwrap(store.selectedMeetingID)
        let otherMeetingID = try XCTUnwrap(store.meetings.first { $0.id != recoveringMeetingID }?.id)
        let originalDraftVersion = store.transcriptEditDraft.currentVersion
        let originalHistoryVersion = store.transcriptEditHistory.latestVersion
        let segment = try XCTUnwrap(store.transcriptEditDraft.segments.first)
        let bundleStore = EncryptedMeetingBundleStore(
            rootDirectory: root,
            vault: AESGCMDataVault(keyProvider: keyProvider)
        )
        store.transcriptAskPrompt = "What was said about deployment Thursday and QA?"
        store.askSelectedTranscript()
        XCTAssertEqual(store.transcriptConversationTurns.count, 1)
        XCTAssertFalse(store.transcriptAskAnswerDraft.isEmpty)
        XCTAssertFalse(store.transcriptAskEvidence.isEmpty)
        var transcript = try bundleStore.readJSONArtifact(
            MeetingTranscript.self,
            meetingID: recoveringMeetingID,
            relativePath: MeetingTranscript.finalTranscriptRelativePath,
            purpose: MeetingTranscript.finalTranscriptPurpose
        )
        transcript.transcriptVersion += 1
        transcript.editedAt = Date(timeIntervalSince1970: 1_805_300_100)
        transcript.segments[0].text = "Authoritative recovery remains durable."
        try bundleStore.writeJSONArtifact(
            transcript,
            meetingID: recoveringMeetingID,
            relativePath: MeetingTranscript.finalTranscriptRelativePath,
            purpose: MeetingTranscript.finalTranscriptPurpose
        )
        let marker = TranscriptCorrectionRecoveryMarker(
            meetingID: recoveringMeetingID,
            targetTranscriptVersion: transcript.transcriptVersion,
            transcriptDigest: try LocalFinalTranscriptionService.transcriptDigest(transcript),
            editedSegmentIDs: [segment.id],
            resolvedReviewItemIDs: [],
            phase: .authoritativeCommitted,
            startedAt: Date(timeIntervalSince1970: 1_805_300_100)
        )
        try bundleStore.writeJSONArtifact(
            marker,
            meetingID: recoveringMeetingID,
            relativePath: TranscriptCorrectionRecoveryMarker.relativePath,
            purpose: TranscriptCorrectionRecoveryMarker.purpose
        )

        store.selectedMeetingID = otherMeetingID
        store.transcriptAskPrompt = "What was said about the inspector hierarchy?"
        store.askSelectedTranscript()
        let otherMeetingAnswer = store.transcriptAskAnswerDraft
        let otherMeetingTurns = store.transcriptConversationTurns
        let otherMeetingEvidence = store.transcriptAskEvidence
        XCTAssertEqual(otherMeetingTurns.count, 1)
        XCTAssertFalse(otherMeetingAnswer.isEmpty)
        XCTAssertFalse(otherMeetingEvidence.isEmpty)
        store.selectedMeetingID = recoveringMeetingID
        try await waitForTranscriptCorrectionGate(gate, meetingID: recoveringMeetingID)
        store.selectedMeetingID = otherMeetingID
        XCTAssertEqual(store.transcriptAskAnswerDraft, otherMeetingAnswer)
        XCTAssertEqual(store.transcriptConversationTurns, otherMeetingTurns)
        XCTAssertEqual(store.transcriptAskEvidence, otherMeetingEvidence)
        store.selectedMeetingID = recoveringMeetingID
        XCTAssertTrue(store.transcriptCorrectionInFlight)
        XCTAssertFalse(store.transcriptAgentCanAsk)
        XCTAssertTrue(store.transcriptConversationTurns.isEmpty)
        XCTAssertTrue(store.transcriptAskAnswerDraft.isEmpty)
        XCTAssertTrue(store.transcriptAskEvidence.isEmpty)

        store.updateTranscriptDraftText(
            id: segment.id,
            text: "Unsaved draft created while recovery is active."
        )
        XCTAssertTrue(store.transcriptEditDraft.hasChanges)
        await gate.release(meetingID: recoveringMeetingID)
        try await waitUntil("recovery finishes without replacing a returned dirty draft") {
            !(try! bundleStore.artifactExists(
                meetingID: recoveringMeetingID,
                relativePath: TranscriptCorrectionRecoveryMarker.relativePath
            )) && !store.transcriptCorrectionInFlight
        }

        XCTAssertEqual(store.transcriptEditDraft.currentVersion, originalDraftVersion)
        XCTAssertEqual(store.transcriptEditHistory.latestVersion, originalHistoryVersion)
        XCTAssertEqual(
            store.transcriptEditDraft.segments.first(where: { $0.id == segment.id })?.editedText,
            "Unsaved draft created while recovery is active."
        )
        XCTAssertTrue(store.transcriptEditDraft.hasChanges)
        let durableTranscript = try bundleStore.readJSONArtifact(
            MeetingTranscript.self,
            meetingID: recoveringMeetingID,
            relativePath: MeetingTranscript.finalTranscriptRelativePath,
            purpose: MeetingTranscript.finalTranscriptPurpose
        )
        XCTAssertEqual(durableTranscript.transcriptVersion, transcript.transcriptVersion)
        XCTAssertEqual(durableTranscript.segments[0].text, "Authoritative recovery remains durable.")
        XCTAssertTrue(store.transcriptAskAnswerDraft.isEmpty)
        XCTAssertTrue(store.transcriptConversationTurns.isEmpty)
        XCTAssertTrue(store.transcriptAskEvidence.isEmpty)
        let invalidatedHistory = try TranscriptQuestionHistoryService(bundleStore: bundleStore)
            .load(meetingID: recoveringMeetingID)
        XCTAssertTrue(invalidatedHistory.turns.isEmpty)
        XCTAssertNotNil(invalidatedHistory.invalidatedAt)
        XCTAssertEqual(invalidatedHistory.transcriptVersion, transcript.transcriptVersion)

        store.selectedMeetingID = otherMeetingID
        XCTAssertEqual(store.transcriptAskAnswerDraft, otherMeetingAnswer)
        XCTAssertEqual(store.transcriptConversationTurns, otherMeetingTurns)
        XCTAssertEqual(store.transcriptAskEvidence, otherMeetingEvidence)
        store.selectedMeetingID = recoveringMeetingID
        XCTAssertEqual(
            store.transcriptEditDraft.segments.first(where: { $0.id == segment.id })?.editedText,
            "Unsaved draft created while recovery is active."
        )
        XCTAssertTrue(store.transcriptEditDraft.hasChanges)
        XCTAssertTrue(store.transcriptAskAnswerDraft.isEmpty)
        XCTAssertTrue(store.transcriptConversationTurns.isEmpty)
        XCTAssertTrue(store.transcriptAskEvidence.isEmpty)
    }

    func testNonCooperativeAgentCannotRepersistInvalidatedHistoryDuringDelayedCorrection() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultAgentCorrectionRace-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let keyProvider = InMemorySymmetricKeyProvider(keyData: Data(repeating: 0x7C, count: 32))
        let provider = ControlledNonCooperativeTranscriptQuestionProvider()
        let regenerationGate = ControlledTranscriptCorrectionRegenerationGate()
        let reconciliationGate = ControlledTranscriptCorrectionRegenerationGate()
        let store = MeetingVaultStore(
            libraryRoot: root,
            keyProvider: keyProvider,
            transcriptQuestionRuntimeMode: .foundationModels,
            transcriptQuestionAnsweringProvider: provider,
            transcriptCorrectionRegenerationGate: { meetingID in
                await regenerationGate.suspend(meetingID: meetingID)
            },
            transcriptCorrectionStoreReconciliationGate: { meetingID in
                await reconciliationGate.suspend(meetingID: meetingID)
            }
        )
        let correctedMeetingID = try XCTUnwrap(store.selectedMeetingID)
        let otherMeetingID = try XCTUnwrap(store.meetings.first { $0.id != correctedMeetingID }?.id)
        let correctedSegment = try XCTUnwrap(store.transcriptEditDraft.segments.first)
        let bundleStore = EncryptedMeetingBundleStore(
            rootDirectory: root,
            vault: AESGCMDataVault(keyProvider: keyProvider)
        )

        store.selectedMeetingID = otherMeetingID
        store.transcriptAskPrompt = "What was said about the inspector hierarchy?"
        store.askSelectedTranscript()
        try await waitForTranscriptQuestionProvider(provider, entryCount: 1)
        await provider.releaseNext()
        try await waitUntil("other meeting Agent answer is visible") {
            store.transcriptConversationTurns.count == 1
        }
        let otherMeetingAnswer = store.transcriptAskAnswerDraft
        let otherMeetingTurns = store.transcriptConversationTurns
        let otherMeetingEvidence = store.transcriptAskEvidence

        store.selectedMeetingID = correctedMeetingID
        store.updateTranscriptDraftText(
            id: correctedSegment.id,
            text: "Corrected authority invalidates the pending Agent response."
        )
        store.transcriptAskPrompt = "What was corrected about authority?"
        store.askSelectedTranscript()
        try await waitForTranscriptQuestionProvider(provider, entryCount: 2)

        let correction = try XCTUnwrap(store.saveTranscriptDraft())
        try await waitForTranscriptCorrectionGate(regenerationGate, meetingID: correctedMeetingID)

        XCTAssertTrue(store.transcriptCorrectionInFlight)
        XCTAssertFalse(store.transcriptAgentCanAsk)
        XCTAssertEqual(
            store.transcriptAgentReadinessStatus,
            "Agent is unavailable while transcript correction is being saved or recovered."
        )
        XCTAssertTrue(store.transcriptAskAnswerDraft.isEmpty)
        XCTAssertTrue(store.transcriptConversationTurns.isEmpty)
        XCTAssertTrue(store.transcriptAskEvidence.isEmpty)

        store.askSelectedTranscript()
        try await Task.sleep(nanoseconds: 50_000_000)
        let entriesWhileCorrectionIsActive = await provider.entryCount
        XCTAssertEqual(entriesWhileCorrectionIsActive, 2)
        XCTAssertEqual(
            store.transcriptAskStatus,
            "Agent is unavailable while transcript correction is being saved or recovered."
        )

        await regenerationGate.release(meetingID: correctedMeetingID)
        try await waitForTranscriptCorrectionGate(reconciliationGate, meetingID: correctedMeetingID)
        let invalidatedBeforeStaleResponse = try TranscriptQuestionHistoryService(bundleStore: bundleStore)
            .load(meetingID: correctedMeetingID)
        XCTAssertTrue(invalidatedBeforeStaleResponse.turns.isEmpty)
        XCTAssertNotNil(invalidatedBeforeStaleResponse.invalidatedAt)

        await provider.releaseAll()
        try await waitForTranscriptQuestionProviderCompletions(provider)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(store.transcriptAskAnswerDraft.isEmpty)
        XCTAssertTrue(store.transcriptConversationTurns.isEmpty)
        XCTAssertTrue(store.transcriptAskEvidence.isEmpty)

        store.selectedMeetingID = otherMeetingID
        XCTAssertEqual(store.transcriptAskAnswerDraft, otherMeetingAnswer)
        XCTAssertEqual(store.transcriptConversationTurns, otherMeetingTurns)
        XCTAssertEqual(store.transcriptAskEvidence, otherMeetingEvidence)
        XCTAssertTrue(store.transcriptAgentCanAsk)
        store.selectedMeetingID = correctedMeetingID
        XCTAssertTrue(store.transcriptCorrectionInFlight)
        XCTAssertFalse(store.transcriptAgentCanAsk)
        XCTAssertTrue(store.transcriptAskAnswerDraft.isEmpty)
        XCTAssertTrue(store.transcriptConversationTurns.isEmpty)
        XCTAssertTrue(store.transcriptAskEvidence.isEmpty)

        await reconciliationGate.release(meetingID: correctedMeetingID)
        await correction.value
        XCTAssertFalse(store.transcriptCorrectionInFlight)
        XCTAssertTrue(store.transcriptAskAnswerDraft.isEmpty)
        XCTAssertTrue(store.transcriptConversationTurns.isEmpty)
        XCTAssertTrue(store.transcriptAskEvidence.isEmpty)
        let invalidatedAfterReconciliation = try TranscriptQuestionHistoryService(bundleStore: bundleStore)
            .load(meetingID: correctedMeetingID)
        XCTAssertTrue(invalidatedAfterReconciliation.turns.isEmpty)
        XCTAssertNotNil(invalidatedAfterReconciliation.invalidatedAt)

        store.transcriptAskPrompt = "What was corrected about authority?"
        XCTAssertTrue(store.transcriptAgentCanAsk)
        store.askSelectedTranscript()
        try await waitForTranscriptQuestionProvider(provider, entryCount: 3)
        await provider.releaseNext()
        try await waitUntil("new Agent request after correction is visible") {
            store.transcriptConversationTurns.count == 1
        }
        XCTAssertFalse(store.transcriptAskAnswerDraft.isEmpty)
        XCTAssertFalse(store.transcriptAskEvidence.isEmpty)

        store.selectedMeetingID = otherMeetingID
        XCTAssertEqual(store.transcriptAskAnswerDraft, otherMeetingAnswer)
        XCTAssertEqual(store.transcriptConversationTurns, otherMeetingTurns)
        XCTAssertEqual(store.transcriptAskEvidence, otherMeetingEvidence)
    }

    func testCorrectionEvictsCachedAgentAnswersAndReloadsEncryptedInvalidationImmediately() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultCorrectionAgentCache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let keyProvider = InMemorySymmetricKeyProvider(keyData: Data(repeating: 0x6C, count: 32))
        let store = MeetingVaultStore(libraryRoot: root, keyProvider: keyProvider)
        let meetingID = try XCTUnwrap(store.selectedMeetingID)
        store.transcriptAskPrompt = "What is the current decision?"
        store.askSelectedTranscript()
        XCTAssertEqual(store.transcriptConversationTurns.count, 1)
        let segmentID = try XCTUnwrap(store.transcriptEditDraft.segments.first?.id)
        store.updateTranscriptDraftText(id: segmentID, text: "Corrected authority invalidates every prior answer.")

        let task = try XCTUnwrap(store.saveTranscriptDraft())
        await task.value

        XCTAssertTrue(store.transcriptConversationTurns.isEmpty)
        XCTAssertTrue(store.transcriptAskAnswerDraft.isEmpty)
        XCTAssertTrue(store.transcriptAskEvidence.isEmpty)
        let history = try TranscriptQuestionHistoryService(
            bundleStore: EncryptedMeetingBundleStore(
                rootDirectory: root,
                vault: AESGCMDataVault(keyProvider: keyProvider)
            )
        ).load(meetingID: meetingID)
        XCTAssertTrue(history.turns.isEmpty)
        XCTAssertNotNil(history.invalidatedAt)
        XCTAssertEqual(history.transcriptVersion, store.transcriptEditDraft.currentVersion)
    }

    func testSelectedTranscriptReviewQueueRejectsCrossMeetingQueue() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultCrossMeetingReviewQueue-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingVaultStore(
            libraryRoot: root,
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 0x6D, count: 32))
        )
        let selectedMeetingID = try XCTUnwrap(store.selectedMeetingID)
        let otherMeetingID = try XCTUnwrap(store.meetings.first { $0.id != selectedMeetingID }?.id)
        store.transcriptReviewQueue = try TranscriptReviewQueue(
            meetingID: otherMeetingID,
            transcriptDigest: "other",
            transcriptVersion: 0,
            evidenceComplete: true,
            generatedAt: Date(timeIntervalSince1970: 1_805_000_200),
            items: []
        )

        XCTAssertNil(store.selectedTranscriptReviewQueue)
    }

    func testTranscriptAskUsesEditedTranscriptAndCopiesEditableAnswer() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultStoreAsk-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = MeetingVaultStore(
            libraryRoot: root,
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 91, count: 32))
        )
        let segmentID = try XCTUnwrap(store.transcriptEditDraft.segments.first?.id)
        store.updateTranscriptDraftText(
            id: segmentID,
            text: "Deployment moves to Friday after QA signs off."
        )
        store.transcriptAskPrompt = "What did we decide about deployment?"

        store.askSelectedTranscript()

        XCTAssertTrue(store.transcriptAskAnswerDraft.contains("Deployment moves to Friday"))
        XCTAssertTrue(store.transcriptAskEvidence.contains { $0.segmentID == segmentID })

        store.transcriptAskAnswerDraft = "Edited agent answer for the release handoff."
        store.copyTranscriptAskAnswer()

        XCTAssertEqual(
            NSPasteboard.general.string(forType: .string),
            "Edited agent answer for the release handoff."
        )
        XCTAssertEqual(store.transcriptAskStatus, "Copied answer to clipboard")
    }

    func testTranscriptAgentBlocksAskUntilTranscriptIsFinalizedOrImported() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultStoreAskNeedsTranscript-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let provider = CapturingStoreTranscriptQuestionProvider()
        let store = MeetingVaultStore(
            libraryRoot: root,
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 117, count: 32)),
            transcriptQuestionRuntimeMode: .foundationModels,
            transcriptQuestionAnsweringProvider: provider,
            includeSampleData: false
        )
        store.recordingState = .recording
        store.liveTranscriptPreviewSegments = [
            TranscriptSegment(
                speakerName: "Alex",
                trackKind: .microphone,
                startTime: 0,
                endTime: 3,
                text: "Live partial transcript is visible but not finalized.",
                confidence: 0.82,
                isFinal: false
            )
        ]
        store.transcriptAskPrompt = "What did we decide?"

        XCTAssertFalse(store.transcriptAgentHasVisibleTranscript)
        XCTAssertFalse(store.transcriptAgentCanAsk)
        XCTAssertEqual(
            store.transcriptAgentReadinessStatus,
            "Live transcript is streaming. Stop recording to finalize it before asking Agent."
        )

        store.askSelectedTranscriptFromLibrary()

        XCTAssertTrue(provider.questions.isEmpty)
        XCTAssertNil(store.requestedWorkspaceFocus)
        XCTAssertTrue(store.transcriptAskAnswerDraft.isEmpty)
        XCTAssertTrue(store.transcriptAskEvidence.isEmpty)
        XCTAssertEqual(
            store.transcriptAskStatus,
            "Live transcript is streaming. Stop recording to finalize it before asking Agent."
        )
    }

    func testCopyVisibleTranscriptIgnoresBlankTranscriptShell() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultStoreCopyBlankTranscript-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = MeetingVaultStore(
            libraryRoot: root,
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 119, count: 32)),
            includeSampleData: false
        )
        let transcript = MeetingTranscript(
            meetingID: UUID(),
            localeIdentifier: Locale.current.identifier,
            segments: [
                TranscriptSegment(
                    speakerName: "Speaker 1",
                    trackKind: .microphone,
                    startTime: 0,
                    endTime: 2,
                    text: "   ",
                    confidence: 0.4,
                    isFinal: true
                )
            ]
        )
        store.transcriptEditDraft = TranscriptEditDraft(transcript: transcript)
        store.transcriptAskPrompt = "Summarize this."
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("previous clipboard", forType: .string)

        XCTAssertFalse(store.transcriptAgentHasVisibleTranscript)
        XCTAssertFalse(store.transcriptAgentCanAsk)

        store.copyVisibleTranscript()

        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "previous clipboard")
        XCTAssertEqual(
            store.transcriptAskStatus,
            "Record or import a meeting to create a visible transcript before asking Agent."
        )
    }

    func testLibraryPromptPresetsAndCustomPromptUseSelectedTranscript() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultStoreLibraryPrompt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = MeetingVaultStore(
            libraryRoot: root,
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 109, count: 32))
        )

        store.applyTranscriptPromptPreset(.actions)
        XCTAssertEqual(
            store.transcriptAskPrompt,
            "List action items, owners, and deadlines from this transcript."
        )
        store.applyTranscriptPromptPreset(.explain)
        XCTAssertEqual(
            store.transcriptAskPrompt,
            "Explain the transcript in plain language, including context, why it matters, and the practical next step."
        )

        store.transcriptAskPrompt = "What privacy work is still open?"
        XCTAssertTrue(store.transcriptAgentCanAsk)
        store.askSelectedTranscriptFromLibrary()

        XCTAssertFalse(store.transcriptAskAnswerDraft.isEmpty)
        XCTAssertEqual(store.transcriptConversationTurns.first?.question, "What privacy work is still open?")
        XCTAssertEqual(store.requestedWorkspaceFocus, MeetingsWorkspaceFocus.understand.rawValue)
    }

    func testTranscriptAgentHistoryPersistsEditableAnswerAcrossStoreReload() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultStoreTranscriptAgentHistory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let keyData = Data(repeating: 118, count: 32)
        let store = MeetingVaultStore(
            libraryRoot: root,
            keyProvider: InMemorySymmetricKeyProvider(keyData: keyData)
        )
        let meetingID = try XCTUnwrap(store.selectedMeetingID)
        store.transcriptAskPrompt = "What privacy work is still open?"

        store.askSelectedTranscript()
        store.updateTranscriptAskAnswerDraft("Approved response: privacy review is the remaining launch blocker.")

        XCTAssertEqual(
            store.transcriptConversationTurns.first?.answerDraft,
            "Approved response: privacy review is the remaining launch blocker."
        )

        let reloadedStore = MeetingVaultStore(
            libraryRoot: root,
            keyProvider: InMemorySymmetricKeyProvider(keyData: keyData)
        )
        reloadedStore.selectedMeetingID = meetingID

        XCTAssertEqual(reloadedStore.transcriptConversationTurns.first?.question, "What privacy work is still open?")
        XCTAssertEqual(
            reloadedStore.transcriptConversationTurns.first?.answerDraft,
            "Approved response: privacy review is the remaining launch blocker."
        )
        XCTAssertEqual(
            reloadedStore.transcriptAskAnswerDraft,
            "Approved response: privacy review is the remaining launch blocker."
        )
    }

    func testTranscriptQuestionRuntimeModeParsesFoundationModelsEnvironment() {
        XCTAssertEqual(
            MeetingVaultTranscriptQuestionRuntimeMode.fromEnvironment([
                "MEETINGVAULT_TRANSCRIPT_QA_RUNTIME": "foundation-models"
            ]),
            .foundationModels
        )
        XCTAssertEqual(
            MeetingVaultTranscriptQuestionRuntimeMode.fromEnvironment([
                "MEETINGVAULT_TRANSCRIPT_QA_RUNTIME": "demo"
            ]),
            .deterministic
        )
    }

    func testFoundationTranscriptQuestionRuntimeUsesProviderForEditableAgentResponse() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultStoreFoundationQA-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let provider = CapturingStoreTranscriptQuestionProvider()
        let store = MeetingVaultStore(
            libraryRoot: root,
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 116, count: 32)),
            transcriptQuestionRuntimeMode: .foundationModels,
            transcriptQuestionAnsweringProvider: provider
        )
        store.transcriptAskPrompt = "What is the current privacy decision?"

        store.askSelectedTranscript()
        try await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertEqual(provider.questions, ["What is the current privacy decision?"])
        XCTAssertEqual(provider.segmentCounts, [store.transcriptEditDraft.segments.count])
        XCTAssertEqual(store.transcriptAskAnswerDraft, "Foundation Models grounded answer.")
        XCTAssertEqual(store.transcriptConversationTurns.first?.answerDraft, "Foundation Models grounded answer.")
        XCTAssertEqual(store.transcriptAskStatus, "Answer grounded in 1 transcript segment(s)")
    }

    func testFoundationTranscriptAnswerIsDiscardedWhenSelectionChanges() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultStoreFoundationQASelection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = CapturingStoreTranscriptQuestionProvider(delayNanoseconds: 200_000_000)
        let store = MeetingVaultStore(
            libraryRoot: root,
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 117, count: 32)),
            transcriptQuestionRuntimeMode: .foundationModels,
            transcriptQuestionAnsweringProvider: provider
        )
        let secondMeetingID = try XCTUnwrap(store.meetings.dropFirst().first?.id)

        store.transcriptAskPrompt = "What is the current privacy decision?"
        store.askSelectedTranscript()
        store.selectedMeetingID = secondMeetingID
        try await Task.sleep(nanoseconds: 350_000_000)

        XCTAssertEqual(store.selectedMeetingID, secondMeetingID)
        XCTAssertTrue(store.transcriptConversationTurns.isEmpty)
        XCTAssertNotEqual(store.transcriptAskAnswerDraft, "Foundation Models grounded answer.")
    }

    func testFoundationTranscriptQuestionFailureIsSurfacedWithoutDeterministicFallback() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultStoreFoundationQAFallback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let provider = CapturingStoreTranscriptQuestionProvider(
            error: FoundationModelsTranscriptQuestionAnsweringError.generationFailed(
                "This transcript language or locale is not supported."
            )
        )
        let store = MeetingVaultStore(
            libraryRoot: root,
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 122, count: 32)),
            transcriptQuestionRuntimeMode: .foundationModels,
            transcriptQuestionAnsweringProvider: provider,
            includeSampleData: false
        )
        let transcriptURL = root.appendingPathComponent("20260703 1510 Transcription.txt")
        let audioURL = root.appendingPathComponent("Voice Chat 20260703 1510.mp3")
        try """
        [00:00:01.00] Speaker:\tThe beta candidate can ship after privacy review.

        [00:00:08.00] Speaker:\tThe transcript agent should still answer from imported text.
        """.write(to: transcriptURL, atomically: true, encoding: .utf8)
        try Data(repeating: 23, count: 128).write(to: audioURL)
        _ = try await store.importLocalRecording(
            transcriptURL: transcriptURL,
            audioURL: audioURL,
            title: "Imported provider failure smoke",
            sourceName: "Local Recording"
        )
        store.transcriptAskPrompt = "What beta candidate can ship?"

        store.askSelectedTranscript()
        try await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertEqual(provider.questions, ["What beta candidate can ship?"])
        XCTAssertTrue(store.transcriptAskAnswerDraft.isEmpty)
        XCTAssertTrue(store.transcriptAskEvidence.isEmpty)
        XCTAssertTrue(store.transcriptAskStatus.contains("Foundation Models transcript answer failed"))
        XCTAssertTrue(store.transcriptConversationTurns.isEmpty)
    }

    func testFoundationTranscriptQuestionFailureDoesNotCreateSyntheticBroadAnswer() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultStoreFoundationQABroadFallback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let provider = CapturingStoreTranscriptQuestionProvider(
            error: FoundationModelsTranscriptQuestionAnsweringError.generationFailed(
                "This transcript language or locale is not supported."
            )
        )
        let store = MeetingVaultStore(
            libraryRoot: root,
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 123, count: 32)),
            transcriptQuestionRuntimeMode: .foundationModels,
            transcriptQuestionAnsweringProvider: provider
        )
        store.transcriptAskPrompt = "ok please explain"

        store.askSelectedTranscript()
        try await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertEqual(provider.questions, ["ok please explain"])
        XCTAssertTrue(store.transcriptAskAnswerDraft.isEmpty)
        XCTAssertTrue(store.transcriptAskEvidence.isEmpty)
        XCTAssertTrue(store.transcriptAskStatus.contains("Foundation Models transcript answer failed"))
        XCTAssertTrue(store.transcriptConversationTurns.isEmpty)
    }

    func testKeychainUnavailableSurfacesInitializationFailureWithoutDemoFallback() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultStoreKeychainUnavailable-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let keyProvider = KeychainSymmetricKeyProvider(
            service: "com.andrzej.MeetingVault.tests",
            account: "blocked-key",
            keychain: FailingKeychainStore(status: errSecInteractionNotAllowed)
        )

        let store = MeetingVaultStore(
            libraryRoot: root,
            keyProvider: keyProvider
        )

        XCTAssertTrue(store.meetings.isEmpty)
        XCTAssertEqual(store.recordingState, .error)
        XCTAssertNotNil(store.runtimeInitializationError)
        XCTAssertEqual(
            store.recordingProcessingStatus,
            "Encrypted library could not be opened. Review the local key and library integrity."
        )
        XCTAssertEqual(store.transcriptEditStatus, "Encrypted transcript library unavailable")
        XCTAssertEqual(store.localRecordingImportStatus, "Local recording import unavailable")
        XCTAssertEqual(store.exportStatus, "Export unavailable")
    }

    func testReadyPreflightIsReusedUntilPermissionsAreRefreshed() async throws {
        let provider = MockPermissionProvider(
            snapshot: PermissionSnapshot(
                systemAudio: .authorized,
                microphone: .authorized,
                speechRecognition: .authorized
            )
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultStorePreflightCache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = MeetingVaultStore(
            permissionProvider: provider,
            libraryRoot: root,
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 110, count: 32)),
            storageCapacityChecker: MockRecordingStorageCapacityChecker.available,
            audioInputDeviceProvider: MockAudioInputDeviceProvider(
                devices: [
                    AudioInputDevice(
                        id: "studio",
                        displayName: "Studio Display Microphone",
                        transportLabel: "Built-in",
                        isDefault: true,
                        level: 0.58
                    )
                ]
            )
        )

        await store.refreshPermissions()
        XCTAssertEqual(provider.snapshotReadCount, 1)

        store.startRecordingIntent()
        try await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertEqual(provider.snapshotReadCount, 1)
        XCTAssertEqual(store.recordingState, .recording)
    }

    func testStartRecordingChecksGrantedPermissionsAutomaticallyWithoutManualPreflight() async throws {
        let provider = MockPermissionProvider(
            snapshot: PermissionSnapshot(
                systemAudio: .authorized,
                microphone: .authorized,
                speechRecognition: .authorized
            )
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultStoreAutomaticPreflight-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = MeetingVaultStore(
            permissionProvider: provider,
            libraryRoot: root,
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 113, count: 32)),
            storageCapacityChecker: MockRecordingStorageCapacityChecker.available,
            audioInputDeviceProvider: MockAudioInputDeviceProvider(devices: [])
        )

        store.startRecordingIntent()
        try await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertEqual(provider.snapshotReadCount, 1)
        XCTAssertEqual(store.recordingState, .recording)
    }

    func testRapidDuplicateStartCreatesOnlyOneRecordingStartFlow() async throws {
        let provider = MockPermissionProvider(
            snapshot: PermissionSnapshot(
                systemAudio: .authorized,
                microphone: .authorized,
                speechRecognition: .authorized
            )
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultStoreDuplicateStart-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingVaultStore(
            permissionProvider: provider,
            libraryRoot: root,
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 113, count: 32)),
            storageCapacityChecker: MockRecordingStorageCapacityChecker.available,
            audioInputDeviceProvider: MockAudioInputDeviceProvider(devices: [])
        )

        store.startRecordingIntent()
        store.startRecordingIntent()
        try await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertEqual(provider.snapshotReadCount, 1)
        XCTAssertEqual(store.recordingState, .recording)
        XCTAssertTrue(store.canStopRecording)
        XCTAssertFalse(store.canStartRecording)
    }

    func testStopWithoutActiveRecordingDoesNotStartOrMutateLibrary() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultStoreIdleStop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingVaultStore(
            libraryRoot: root,
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 114, count: 32))
        )
        let meetingIDs = store.meetings.map(\.id)
        let initialState = store.recordingState

        store.stopRecordingIntent()

        XCTAssertEqual(store.meetings.map(\.id), meetingIDs)
        XCTAssertEqual(store.recordingState, initialState)
        XCTAssertEqual(store.recordingProcessingStatus, "No active recording to stop")
        XCTAssertFalse(store.canStopRecording)
    }

    func testStartRecordingRefreshesMissingAndStaleDeniedPreflightAutomatically() async throws {
        let provider = MockPermissionProvider(
            snapshot: PermissionSnapshot(
                systemAudio: .notDetermined,
                microphone: .notDetermined,
                speechRecognition: .notDetermined
            )
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultStoreDeniedPreflightCache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = MeetingVaultStore(
            permissionProvider: provider,
            libraryRoot: root,
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 114, count: 32)),
            storageCapacityChecker: MockRecordingStorageCapacityChecker.available,
            audioInputDeviceProvider: MockAudioInputDeviceProvider(devices: [])
        )

        store.startRecordingIntent()
        try await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertEqual(provider.snapshotReadCount, 1)
        XCTAssertEqual(store.permissionRecoveryStatus, "Allow Screen & System Audio, Microphone.")
        XCTAssertEqual(store.recordingState, .permissionNeeded)

        provider.update(
            snapshot: PermissionSnapshot(
                systemAudio: .authorized,
                microphone: .authorized,
                speechRecognition: .authorized
            )
        )
        store.startRecordingIntent()
        try await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertEqual(provider.snapshotReadCount, 2)
        XCTAssertEqual(store.recordingState, .recording)
    }

    func testPreflightUsesRecordingConsentDefaultWhenNoMeetingIsSelected() async throws {
        let provider = MockPermissionProvider(
            snapshot: PermissionSnapshot(
                systemAudio: .authorized,
                microphone: .authorized,
                speechRecognition: .authorized
            )
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultStoreNoMeetingPermissionReady-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = MeetingVaultStore(
            permissionProvider: provider,
            libraryRoot: root,
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 119, count: 32)),
            storageCapacityChecker: MockRecordingStorageCapacityChecker.available,
            audioInputDeviceProvider: MockAudioInputDeviceProvider(devices: []),
            includeSampleData: false
        )

        XCTAssertNil(store.selectedMeeting)

        let result = await store.refreshPermissions()

        XCTAssertTrue(result.canRecord)
        XCTAssertEqual(result.issues, [])
        XCTAssertEqual(store.recordingState, .ready)
    }

    func testPermissionReadinessCopyNamesMissingSystemPermissions() async throws {
        let provider = MockPermissionProvider(
            snapshot: PermissionSnapshot(
                systemAudio: .notDetermined,
                microphone: .denied,
                speechRecognition: .restricted
            )
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultStorePermissionCopy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = MeetingVaultStore(
            permissionProvider: provider,
            libraryRoot: root,
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 120, count: 32)),
            storageCapacityChecker: MockRecordingStorageCapacityChecker.available,
            audioInputDeviceProvider: MockAudioInputDeviceProvider(devices: []),
            includeSampleData: false
        )

        let result = await store.refreshPermissions()

        XCTAssertFalse(result.canRecord)
        XCTAssertEqual(store.recordingReadinessTitle, "Permission Needed")
        XCTAssertEqual(
            store.recordingReadinessDetail,
            "Allow Screen & System Audio, Microphone."
        )
    }

    func testSpeechRecognitionPermissionStatusChecksWithoutPromptingOnStartup() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultStoreSpeechPermissionStatus-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authorization = CapturingStoreSpeechAuthorizationProvider(
            currentState: .notDetermined,
            requestedState: .authorized
        )

        let store = MeetingVaultStore(
            permissionProvider: MockPermissionProvider(
                snapshot: PermissionSnapshot(
                    systemAudio: .authorized,
                    microphone: .authorized,
                    speechRecognition: .notDetermined
                )
            ),
            libraryRoot: root,
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 126, count: 32)),
            speechRecognitionAuthorizationProvider: authorization
        )

        XCTAssertEqual(store.appleSpeechAuthorizationState, .notDetermined)
        XCTAssertEqual(store.appleSpeechAuthorizationStatus, "Speech Recognition has not been requested for MeetingVault")
        XCTAssertEqual(authorization.currentReadCount, 1)
        XCTAssertEqual(authorization.requestCount, 0)
    }

    func testSpeechRecognitionPermissionRequestIsExplicitAndRefreshesPreflight() async throws {
        let permissionProvider = MockPermissionProvider(
            snapshot: PermissionSnapshot(
                systemAudio: .authorized,
                microphone: .authorized,
                speechRecognition: .authorized
            )
        )
        let authorization = CapturingStoreSpeechAuthorizationProvider(
            currentState: .notDetermined,
            requestedState: .authorized
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultStoreSpeechPermissionRequest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingVaultStore(
            permissionProvider: permissionProvider,
            libraryRoot: root,
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 127, count: 32)),
            storageCapacityChecker: MockRecordingStorageCapacityChecker.available,
            speechRecognitionAuthorizationProvider: authorization
        )

        await store.requestAppleSpeechAuthorizationOnce()

        XCTAssertEqual(authorization.requestCount, 1)
        XCTAssertEqual(store.appleSpeechAuthorizationState, .authorized)
        XCTAssertEqual(store.appleSpeechAuthorizationStatus, "Speech Recognition is authorized")
        XCTAssertEqual(permissionProvider.snapshotReadCount, 1)
        XCTAssertEqual(store.recordingState, .ready)
    }

    func testMicrophonePermissionStatusChecksWithoutPromptingOnStartup() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultStoreMicPermissionStatus-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authorization = CapturingStoreMicrophoneAuthorizationProvider(
            currentState: .notDetermined,
            requestedState: .authorized
        )

        let store = MeetingVaultStore(
            permissionProvider: MockPermissionProvider(
                snapshot: PermissionSnapshot(
                    systemAudio: .authorized,
                    microphone: .notDetermined,
                    speechRecognition: .authorized
                )
            ),
            libraryRoot: root,
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 121, count: 32)),
            microphoneAuthorizationProvider: authorization
        )

        XCTAssertEqual(store.microphoneAuthorizationState, .notDetermined)
        XCTAssertEqual(store.microphoneAuthorizationStatus, "Microphone has not been requested for MeetingVault")
        XCTAssertEqual(authorization.currentReadCount, 1)
        XCTAssertEqual(authorization.requestCount, 0)
    }

    func testMicrophonePermissionRequestIsExplicitAndRefreshesPreflight() async throws {
        let permissionProvider = MockPermissionProvider(
            snapshot: PermissionSnapshot(
                systemAudio: .authorized,
                microphone: .authorized,
                speechRecognition: .authorized
            )
        )
        let authorization = CapturingStoreMicrophoneAuthorizationProvider(
            currentState: .notDetermined,
            requestedState: .authorized
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultStoreMicPermissionRequest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingVaultStore(
            permissionProvider: permissionProvider,
            libraryRoot: root,
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 122, count: 32)),
            storageCapacityChecker: MockRecordingStorageCapacityChecker.available,
            microphoneAuthorizationProvider: authorization
        )

        await store.requestMicrophoneAuthorizationOnce()

        XCTAssertEqual(authorization.requestCount, 1)
        XCTAssertEqual(store.microphoneAuthorizationState, .authorized)
        XCTAssertEqual(store.microphoneAuthorizationStatus, "Microphone is authorized")
        XCTAssertEqual(permissionProvider.snapshotReadCount, 1)
        XCTAssertEqual(store.recordingState, .ready)
    }

    func testStoragePreflightBlocksStartWhenLongRecordingCapacityIsUnsafe() async throws {
        let provider = MockPermissionProvider(
            snapshot: PermissionSnapshot(
                systemAudio: .authorized,
                microphone: .authorized,
                speechRecognition: .authorized
            )
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultStoreLowStoragePreflight-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = MeetingVaultStore(
            permissionProvider: provider,
            libraryRoot: root,
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 113, count: 32)),
            storageCapacityChecker: MockRecordingStorageCapacityChecker(availableBytes: 1),
            audioInputDeviceProvider: MockAudioInputDeviceProvider(devices: [])
        )

        let result = await store.refreshPermissions()
        store.startRecordingIntent()
        try await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertFalse(result.canRecord)
        XCTAssertEqual(result.issues, [.diskSpaceLow])
        XCTAssertEqual(result.storageEstimate?.availableBytes, 1)
        XCTAssertEqual(store.recordingState, .permissionNeeded)
    }

    func testStorageRecoveryRoutesToDiagnosticsRetentionReviewWithoutDeleting() async throws {
        let provider = MockPermissionProvider(
            snapshot: PermissionSnapshot(
                systemAudio: .authorized,
                microphone: .authorized,
                speechRecognition: .authorized
            )
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultStoreStorageRecovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = MeetingVaultStore(
            permissionProvider: provider,
            libraryRoot: root,
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 97, count: 32)),
            storageCapacityChecker: MockRecordingStorageCapacityChecker(availableBytes: 1),
            audioInputDeviceProvider: MockAudioInputDeviceProvider(devices: [])
        )

        await store.refreshPermissions()
        var routeSnapshot: (hasPlan: Bool, status: String)?
        let healthRouteSubscription = store.$healthRecoveryPresentationEvent
            .dropFirst()
            .sink { event in
                guard event != nil else { return }
                routeSnapshot = (
                    hasPlan: store.retentionCleanupPlan != nil,
                    status: store.storageRecoveryStatus
                )
            }
        defer { healthRouteSubscription.cancel() }
        XCTAssertNil(store.healthRecoveryPresentationEvent)
        store.reviewStoragePressure()

        XCTAssertEqual(store.healthRecoveryPresentationEvent?.revision, 1)
        XCTAssertNotEqual(store.requestedWorkspaceFocus, MeetingsWorkspaceFocus.recover.rawValue)
        XCTAssertEqual(routeSnapshot?.hasPlan, true)
        XCTAssertEqual(routeSnapshot?.status, store.storageRecoveryStatus)
        XCTAssertEqual(store.retentionCleanupPlan?.candidates, [])
        XCTAssertEqual(
            store.storageRecoveryStatus,
            "Opened Diagnostics Retention Review. No expired MeetingVault recordings are available; clear other local files, then retry Start."
        )
    }

    func testStorageRecoveryWithoutPressurePublishesNoHealthEvent() async throws {
        let provider = MockPermissionProvider(
            snapshot: PermissionSnapshot(
                systemAudio: .authorized,
                microphone: .authorized,
                speechRecognition: .authorized
            )
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultStoreStorageRecoveryNotNeeded-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = MeetingVaultStore(
            permissionProvider: provider,
            libraryRoot: root,
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 95, count: 32)),
            storageCapacityChecker: MockRecordingStorageCapacityChecker(availableBytes: Int64.max),
            audioInputDeviceProvider: MockAudioInputDeviceProvider(devices: [])
        )

        await store.refreshPermissions()
        store.reviewStoragePressure()

        XCTAssertNil(store.healthRecoveryPresentationEvent)
        XCTAssertNotEqual(store.requestedWorkspaceFocus, MeetingsWorkspaceFocus.recover.rawValue)
        XCTAssertNil(store.retentionCleanupPlan)
    }

    func testStorageRecoveryListsExpiredBundlesWithoutDeleting() async throws {
        let provider = MockPermissionProvider(
            snapshot: PermissionSnapshot(
                systemAudio: .authorized,
                microphone: .authorized,
                speechRecognition: .authorized
            )
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultStoreStorageRecoveryExpired-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let keyData = Data(repeating: 98, count: 32)
        let store = MeetingVaultStore(
            permissionProvider: provider,
            libraryRoot: root,
            keyProvider: InMemorySymmetricKeyProvider(keyData: keyData),
            storageCapacityChecker: MockRecordingStorageCapacityChecker(availableBytes: 1),
            audioInputDeviceProvider: MockAudioInputDeviceProvider(devices: [])
        )
        let bundleStore = EncryptedMeetingBundleStore(
            rootDirectory: root,
            vault: AESGCMDataVault(keyProvider: InMemorySymmetricKeyProvider(keyData: keyData))
        )
        let expiredID = UUID(uuidString: "CACACACA-CACA-CACA-CACA-CACACACACACA")!
        var manifest = MeetingBundleManifest.initialEncryptedBundle(
            meetingID: expiredID,
            title: "Expired storage recovery review"
        )
        manifest.createdAt = Date().addingTimeInterval(-91 * 86_400)
        _ = try bundleStore.createBundle(manifest)

        await store.refreshPermissions()
        store.reviewStoragePressure()

        XCTAssertEqual(store.healthRecoveryPresentationEvent?.revision, 1)
        XCTAssertNotEqual(store.requestedWorkspaceFocus, MeetingsWorkspaceFocus.recover.rawValue)
        XCTAssertEqual(store.retentionCleanupPlan?.candidates.map(\.meetingID), [expiredID])
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleStore.bundleURL(for: expiredID).path))
        XCTAssertEqual(
            store.storageRecoveryStatus,
            "Opened Diagnostics Retention Review with 1 expired recording bundle ready for review."
        )
    }

    func testPermissionRefreshDoesNotInterruptActiveRecordingState() async throws {
        let provider = MockPermissionProvider(
            snapshot: PermissionSnapshot(
                systemAudio: .authorized,
                microphone: .authorized,
                speechRecognition: .authorized
            )
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultStorePreflightDoesNotInterrupt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = MeetingVaultStore(
            permissionProvider: provider,
            libraryRoot: root,
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 124, count: 32)),
            storageCapacityChecker: MockRecordingStorageCapacityChecker.available,
            audioInputDeviceProvider: MockAudioInputDeviceProvider(
                devices: [
                    AudioInputDevice(
                        id: "airpods",
                        displayName: "Sikor AirPods Pro",
                        transportLabel: "Bluetooth",
                        isDefault: true,
                        level: 0.79
                    )
                ]
            )
        )

        await store.refreshPermissions()
        store.startRecordingIntent()
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(store.recordingState, .recording)

        provider.update(
            snapshot: PermissionSnapshot(
                systemAudio: .notDetermined,
                microphone: .notDetermined,
                speechRecognition: .notDetermined
            )
        )
        await store.refreshPermissions()

        XCTAssertEqual(provider.snapshotReadCount, 2)
        XCTAssertFalse(store.latestPreflightResult?.canRecord ?? true)
        XCTAssertEqual(store.recordingState, .recording)
    }

    func testPermissionRecoveryOpensMatchingSystemSettingsAction() async throws {
        let provider = MockPermissionProvider(
            snapshot: PermissionSnapshot(
                systemAudio: .denied,
                microphone: .notDetermined,
                speechRecognition: .authorized
            )
        )
        let opener = CapturingPermissionSettingsOpener()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultStorePermissionRecovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = MeetingVaultStore(
            permissionProvider: provider,
            libraryRoot: root,
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 116, count: 32)),
            storageCapacityChecker: MockRecordingStorageCapacityChecker.available,
            audioInputDeviceProvider: MockAudioInputDeviceProvider(devices: []),
            permissionSettingsOpener: opener
        )

        await store.refreshPermissions()

        XCTAssertEqual(store.permissionRecoveryActions.map(\.kind), [.systemAudio, .microphone])
        store.openPermissionRecoverySettings(kind: .microphone)

        XCTAssertEqual(opener.openedActions.map(\.kind), [.microphone])
        XCTAssertEqual(opener.openedActions.first?.settingsURLString, "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        XCTAssertEqual(store.permissionRecoveryStatus, "Opened System Settings for Allow Microphone. Return here; MeetingVault refreshes readiness automatically.")

        opener.shouldOpen = false
        store.openPermissionRecoverySettings(kind: .systemAudio)

        XCTAssertEqual(opener.openedActions.map(\.kind), [.microphone, .systemAudio])
        XCTAssertEqual(store.permissionRecoveryStatus, "Could not open System Settings for Allow Screen & System Audio Recording")

        store.openPermissionRecoverySettings(kind: .speechRecognition)
        XCTAssertEqual(store.permissionRecoveryStatus, "Refresh readiness to update available permission recovery actions")
    }

    func testStartRecordingAutoDetectsInputBeforeCapture() async throws {
        let permissionProvider = MockPermissionProvider(
            snapshot: PermissionSnapshot(
                systemAudio: .authorized,
                microphone: .authorized,
                speechRecognition: .authorized
            )
        )
        let audioProvider = MockAudioInputDeviceProvider(
            devices: [
                AudioInputDevice(
                    id: "airpods",
                    displayName: "Sikor AirPods Pro",
                    transportLabel: "Bluetooth",
                    isDefault: true,
                    level: 0.81
                )
            ]
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultStoreAutoDetectInput-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = MeetingVaultStore(
            permissionProvider: permissionProvider,
            libraryRoot: root,
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 115, count: 32)),
            storageCapacityChecker: MockRecordingStorageCapacityChecker.available,
            audioInputDeviceProvider: audioProvider
        )

        XCTAssertNil(store.selectedAudioInputDeviceID)

        await store.refreshPermissions()
        store.startRecordingIntent()
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(audioProvider.snapshotReadCount, 2)
        XCTAssertEqual(store.selectedAudioInputDeviceID, "airpods")
        XCTAssertEqual(store.recordingState, .recording)
        XCTAssertTrue(store.liveTranscriptPreviewSegments.isEmpty)
        XCTAssertTrue(store.liveTranscriptionStatus.contains("Install the verified local models"))
    }

    func testStartRecordingRefreshesInputsSoNewHeadsetIsPickedUp() async throws {
        let permissionProvider = MockPermissionProvider(
            snapshot: PermissionSnapshot(
                systemAudio: .authorized,
                microphone: .authorized,
                speechRecognition: .authorized
            )
        )
        let audioProvider = MockAudioInputDeviceProvider(
            devices: [
                AudioInputDevice(
                    id: "studio",
                    displayName: "Studio Display Microphone",
                    transportLabel: "Built-in",
                    isDefault: true,
                    level: 0.45
                )
            ]
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultStoreRefreshInputOnStart-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = MeetingVaultStore(
            permissionProvider: permissionProvider,
            libraryRoot: root,
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 119, count: 32)),
            storageCapacityChecker: MockRecordingStorageCapacityChecker.available,
            audioInputDeviceProvider: audioProvider
        )

        await store.refreshAudioInputDevices()
        XCTAssertEqual(store.selectedAudioInputDeviceID, "studio")

        audioProvider.update(
            devices: [
                AudioInputDevice(
                    id: "airpods",
                    displayName: "Sikor AirPods Pro",
                    transportLabel: "Bluetooth",
                    isDefault: true,
                    level: 0.82
                )
            ]
        )

        await store.refreshPermissions()
        store.startRecordingIntent()
        try await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertEqual(audioProvider.snapshotReadCount, 3)
        XCTAssertEqual(store.selectedAudioInputDeviceID, "airpods")
        XCTAssertEqual(store.recordingState, .recording)
        XCTAssertEqual(store.audioInputStatus, "Recording with Sikor AirPods Pro")
    }

    func testStartRecordingStreamsTranscriptEventsWithoutTrustingProviderInputLevel() async throws {
        let permissionProvider = MockPermissionProvider(
            snapshot: PermissionSnapshot(
                systemAudio: .authorized,
                microphone: .authorized,
                speechRecognition: .authorized
            )
        )
        let audioProvider = MockAudioInputDeviceProvider(
            devices: [
                AudioInputDevice(
                    id: "studio",
                    displayName: "Studio Display Microphone",
                    transportLabel: "Built-in",
                    isDefault: true,
                    level: 0.68
                )
            ]
        )
        let segmentID = UUID(uuidString: "51515151-5151-5151-5151-515151515151")!
        let partial = TranscriptSegment(
            id: segmentID,
            speakerName: "You",
            trackKind: .microphone,
            startTime: 0,
            endTime: 4,
            text: "Draft answer is appearing",
            confidence: 0.55,
            isFinal: false
        )
        let final = TranscriptSegment(
            id: segmentID,
            speakerName: "You",
            trackKind: .microphone,
            startTime: 0,
            endTime: 4,
            text: "Finalized live segment is visible",
            confidence: 0.91,
            isFinal: true
        )
        let liveProvider = MockLiveTranscriptionProvider(
            actions: [
                .event(.status("Speech stream connected")),
                .event(.inputLevel(0.67)),
                .event(.partial(partial)),
                .event(.final(final))
            ]
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultStoreLiveTranscript-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = MeetingVaultStore(
            permissionProvider: permissionProvider,
            libraryRoot: root,
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 117, count: 32)),
            storageCapacityChecker: MockRecordingStorageCapacityChecker.available,
            audioInputDeviceProvider: audioProvider,
            liveTranscriptionProvider: liveProvider
        )

        await store.refreshPermissions()
        store.startRecordingIntent()
        try await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertEqual(store.recordingState, .recording)
        XCTAssertEqual(store.liveInputLevel, 0, accuracy: 0.001)
        XCTAssertNil(store.recordingLevelSnapshot.lastMicrophoneFrameAt)
        XCTAssertEqual(store.liveTranscriptPreviewSegments, [final])
        XCTAssertEqual(store.liveTranscriptionStatus, "Live transcript segment finalized · final pass still runs after Stop")
        let context = try XCTUnwrap(liveProvider.contexts.first)
        XCTAssertEqual(context.microphoneDeviceID, "studio")
        XCTAssertEqual(context.microphoneDeviceName, "Studio Display Microphone")
        XCTAssertEqual(context.sourceID, store.selectedSourceID)
    }

    func testStartRecordingSurfacesLiveTranscriptProviderFailure() async throws {
        let permissionProvider = MockPermissionProvider(
            snapshot: PermissionSnapshot(
                systemAudio: .authorized,
                microphone: .authorized,
                speechRecognition: .authorized
            )
        )
        let audioProvider = MockAudioInputDeviceProvider(
            devices: [
                AudioInputDevice(
                    id: "studio",
                    displayName: "Studio Display Microphone",
                    transportLabel: "Built-in",
                    isDefault: true,
                    level: 0.68
                )
            ]
        )
        let liveProvider = MockLiveTranscriptionProvider(
            actions: [
                .event(.status("Speech stream connected")),
                .fail("Speech recognition unavailable")
            ]
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultStoreLiveTranscriptFailure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = MeetingVaultStore(
            permissionProvider: permissionProvider,
            libraryRoot: root,
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 118, count: 32)),
            storageCapacityChecker: MockRecordingStorageCapacityChecker.available,
            audioInputDeviceProvider: audioProvider,
            liveTranscriptionProvider: liveProvider
        )

        await store.refreshPermissions()
        store.startRecordingIntent()
        try await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertEqual(store.recordingState, .recording)
        XCTAssertEqual(store.liveTranscriptionStatus, "Live transcription unavailable: Speech recognition unavailable")
        XCTAssertEqual(liveProvider.contexts.count, 1)
    }

    func testAudioInputDevicesRefreshAndSelectionTracksDetectedDevices() async throws {
        let provider = MockAudioInputDeviceProvider(
            devices: [
                AudioInputDevice(
                    id: "airpods",
                    displayName: "Sikor AirPods Pro",
                    transportLabel: "Bluetooth",
                    isDefault: true,
                    level: 0.76
                ),
                AudioInputDevice(
                    id: "studio",
                    displayName: "Studio Display Microphone",
                    transportLabel: "Built-in",
                    isDefault: false,
                    level: 0.34
                )
            ]
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultStoreInputs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = MeetingVaultStore(
            libraryRoot: root,
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 111, count: 32)),
            audioInputDeviceProvider: provider
        )

        await store.refreshAudioInputDevices()

        XCTAssertEqual(store.audioInputDevices.map(\.id), ["airpods", "studio"])
        XCTAssertEqual(store.selectedAudioInputDeviceID, "airpods")
        XCTAssertEqual(store.selectedAudioInputDevice?.displayName, "Sikor AirPods Pro")

        store.selectAudioInputDevice(id: "studio")
        XCTAssertEqual(store.selectedAudioInputDevice?.displayName, "Studio Display Microphone")
    }

    func testAudioInputAutoSelectionFollowsNewDefaultDeviceWhenNotManual() async throws {
        let provider = MockAudioInputDeviceProvider(
            devices: [
                AudioInputDevice(
                    id: "studio",
                    displayName: "Studio Display Microphone",
                    transportLabel: "Built-in",
                    isDefault: true,
                    level: 0.44
                )
            ]
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultStoreAutoInputDefault-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = MeetingVaultStore(
            libraryRoot: root,
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 122, count: 32)),
            audioInputDeviceProvider: provider
        )

        await store.refreshAudioInputDevices()
        XCTAssertEqual(store.selectedAudioInputDeviceID, "studio")

        provider.update(
            devices: [
                AudioInputDevice(
                    id: "studio",
                    displayName: "Studio Display Microphone",
                    transportLabel: "Built-in",
                    isDefault: false,
                    level: 0.38
                ),
                AudioInputDevice(
                    id: "airpods",
                    displayName: "Sikor AirPods Pro",
                    transportLabel: "Bluetooth",
                    isDefault: true,
                    level: 0.83
                )
            ]
        )

        await store.refreshAudioInputDevices()

        XCTAssertEqual(store.selectedAudioInputDeviceID, "airpods")
        XCTAssertEqual(store.selectedAudioInputDevice?.transportLabel, "Bluetooth")
        XCTAssertEqual(store.audioInputStatus, "Auto-selected Sikor AirPods Pro from 2 detected input device(s)")
    }

    func testAudioInputManualSelectionSurvivesNewDefaultDevice() async throws {
        let provider = MockAudioInputDeviceProvider(
            devices: [
                AudioInputDevice(
                    id: "airpods",
                    displayName: "Sikor AirPods Pro",
                    transportLabel: "Bluetooth",
                    isDefault: true,
                    level: 0.76
                ),
                AudioInputDevice(
                    id: "studio",
                    displayName: "Studio Display Microphone",
                    transportLabel: "Built-in",
                    isDefault: false,
                    level: 0.34
                )
            ]
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultStoreManualInput-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = MeetingVaultStore(
            libraryRoot: root,
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 123, count: 32)),
            audioInputDeviceProvider: provider
        )

        await store.refreshAudioInputDevices()
        store.selectAudioInputDevice(id: "studio")
        XCTAssertEqual(store.selectedAudioInputDeviceID, "studio")

        provider.update(
            devices: [
                AudioInputDevice(
                    id: "airpods",
                    displayName: "Sikor AirPods Pro",
                    transportLabel: "Bluetooth",
                    isDefault: true,
                    level: 0.88
                ),
                AudioInputDevice(
                    id: "studio",
                    displayName: "Studio Display Microphone",
                    transportLabel: "Built-in",
                    isDefault: false,
                    level: 0.41
                )
            ]
        )

        await store.refreshAudioInputDevices()

        XCTAssertEqual(store.selectedAudioInputDeviceID, "studio")
        XCTAssertEqual(store.audioInputStatus, "Using manually selected Studio Display Microphone")
    }

    func testAudioInputMonitorPicksUpNewDefaultDevice() async throws {
        let provider = MockAudioInputDeviceProvider(
            devices: [
                AudioInputDevice(
                    id: "studio",
                    displayName: "Studio Display Microphone",
                    transportLabel: "Built-in",
                    isDefault: true,
                    level: 0.42
                )
            ]
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultStoreInputMonitor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = MeetingVaultStore(
            libraryRoot: root,
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 121, count: 32)),
            audioInputDeviceProvider: provider
        )

        let monitor = Task {
            await store.monitorAudioInputDevices(refreshIntervalNanoseconds: 10_000_000)
        }
        defer { monitor.cancel() }

        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(store.selectedAudioInputDeviceID, "studio")

        provider.update(
            devices: [
                AudioInputDevice(
                    id: "airpods",
                    displayName: "Sikor AirPods Pro",
                    transportLabel: "Bluetooth",
                    isDefault: true,
                    level: 0.88
                )
            ]
        )

        try await waitUntil("audio input monitor selects the updated default device") {
            provider.snapshotReadCount >= 2 && store.selectedAudioInputDeviceID == "airpods"
        }
        XCTAssertEqual(store.selectedAudioInputDeviceID, "airpods")
        XCTAssertEqual(store.selectedAudioInputDevice?.transportLabel, "Bluetooth")
        XCTAssertGreaterThanOrEqual(provider.snapshotReadCount, 2)
    }

    func testProcessedRecordingUsesSelectedAudioInputDevice() async throws {
        let provider = MockAudioInputDeviceProvider(
            devices: [
                AudioInputDevice(
                    id: "airpods",
                    displayName: "Sikor AirPods Pro",
                    transportLabel: "Bluetooth",
                    isDefault: true,
                    level: 0.76
                ),
                AudioInputDevice(
                    id: "studio",
                    displayName: "Studio Display Microphone",
                    transportLabel: "Built-in",
                    isDefault: false,
                    level: 0.34
                )
            ]
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultStoreSelectedInputProcessing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = MeetingVaultStore(
            libraryRoot: root,
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 112, count: 32)),
            audioInputDeviceProvider: provider
        )

        await store.refreshAudioInputDevices()
        store.selectAudioInputDevice(id: "studio")

        let result = try await store.processStoppedRecordingForSelectedSource(
            meetingID: UUID(uuidString: "12121212-1212-1212-1212-121212121212")!,
            title: "Selected input capture smoke",
            startedAt: Date(timeIntervalSince1970: 1_780_018_000)
        )

        XCTAssertEqual(result.capture.microphoneDeviceID, "studio")
        XCTAssertEqual(result.capture.microphoneDeviceName, "Studio Display Microphone")
    }

    func testStartRecordingBeginsSelectedMicrophoneCaptureBeforeStop() async throws {
        let inputProvider = MockAudioInputDeviceProvider(
            devices: [
                AudioInputDevice(
                    id: "airpods",
                    displayName: "Sikor AirPods Pro",
                    transportLabel: "Bluetooth",
                    isDefault: true,
                    level: 0.76
                )
            ]
        )
        let capturer = CapturingStoreSelectedMicrophoneCapturer(
            chunk: CapturedAudioChunk(
                track: .microphone,
                data: Data("live microphone pcm".utf8),
                startTime: 0,
                duration: 4,
                codec: "AVFoundation/PCM"
            )
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultStoreStartBeginsCapture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = MeetingVaultStore(
            permissionProvider: MockPermissionProvider(
                snapshot: PermissionSnapshot(
                    systemAudio: .authorized,
                    microphone: .authorized,
                    speechRecognition: .authorized
                )
            ),
            libraryRoot: root,
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 115, count: 32)),
            storageCapacityChecker: MockRecordingStorageCapacityChecker.available,
            audioInputDeviceProvider: inputProvider,
            captureRuntimeMode: .selectedMicrophone,
            selectedMicrophoneCapturer: capturer
        )

        await store.refreshAudioInputDevices()
        _ = await store.refreshPermissions()
        store.startRecordingIntent()
        try await waitUntil("selected microphone capture starts") {
            !capturer.requests.isEmpty
        }

        XCTAssertEqual(store.recordingState, RecordingState.recording)
        XCTAssertEqual(capturer.requests.map(\.deviceID), ["airpods"])
        XCTAssertEqual(capturer.requests.map(\.maximumDuration), [10_800])
    }

    func testStopRecordingRequestsActiveCaptureToFinishBeforeProcessingLibraryMeeting() async throws {
        let inputProvider = MockAudioInputDeviceProvider(
            devices: [
                AudioInputDevice(
                    id: "airpods",
                    displayName: "Sikor AirPods Pro",
                    transportLabel: "Bluetooth",
                    isDefault: true,
                    level: 0.76
                )
            ]
        )
        let capturer = StopControlledStoreSelectedMicrophoneCapturer(
            chunk: CapturedAudioChunk(
                track: .microphone,
                data: Data("stopped live microphone pcm".utf8),
                startTime: 0,
                duration: 6,
                codec: "AVFoundation/PCM"
            )
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultStoreStopActiveCapture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = MeetingVaultStore(
            permissionProvider: MockPermissionProvider(
                snapshot: PermissionSnapshot(
                    systemAudio: .authorized,
                    microphone: .authorized,
                    speechRecognition: .authorized
                )
            ),
            libraryRoot: root,
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 116, count: 32)),
            storageCapacityChecker: MockRecordingStorageCapacityChecker.available,
            audioInputDeviceProvider: inputProvider,
            captureRuntimeMode: .selectedMicrophone,
            selectedMicrophoneCapturer: capturer
        )

        await store.refreshAudioInputDevices()
        _ = await store.refreshPermissions()
        store.startRecordingIntent()
        try await waitUntil("active capture request starts") {
            !capturer.requests.isEmpty
        }

        XCTAssertFalse(capturer.stopObserved)
        XCTAssertNotNil(store.activeRecordingPresentation)
        store.stopRecordingIntent()
        try await waitUntil("active capture stop signal is observed") {
            capturer.stopObserved
        }
        try await waitUntil("active recording is processed into the library") {
            store.recordingState == .ready
                && store.transcriptEditMeetingTitle == "Will Prepare The Notarized Build Checklist And"
                && store.recordingProcessingStatus == "Processing complete"
        }

        XCTAssertEqual(capturer.requests.map(\.deviceID), ["airpods"])
        XCTAssertEqual(capturer.requests.map(\.maximumDuration), [10_800])
        XCTAssertEqual(store.selectedMeeting?.title, "Will Prepare The Notarized Build Checklist And")
        XCTAssertEqual(store.liveTranscriptionStatus, "Final transcript saved")
        XCTAssertEqual(store.liveTranscriptPreviewSegments, [])
        XCTAssertNil(store.activeRecordingPresentation)
        XCTAssertTrue(
            store.transcriptEditDraft.segments.contains {
                $0.trackKind == .microphone
                    && $0.trimmedEditedText.contains("notarized build checklist")
            }
        )
    }

    func testActiveRecordingOutputBuildsPlayableEncryptedTimeline() async throws {
        let inputProvider = MockAudioInputDeviceProvider(
            devices: [
                AudioInputDevice(
                    id: "airpods",
                    displayName: "Sikor AirPods Pro",
                    transportLabel: "Bluetooth",
                    isDefault: true,
                    level: 0.76
                )
            ]
        )
        let capturedAudioData = Data("active recording microphone pcm for playback".utf8)
        let capturer = StopControlledStoreSelectedMicrophoneCapturer(
            chunk: CapturedAudioChunk(
                track: .microphone,
                data: capturedAudioData,
                startTime: 0,
                duration: 30,
                codec: "AVFoundation/PCM"
            )
        )
        let audioEngine = CapturingStorePlaybackEngine()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultStoreActivePlayback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = MeetingVaultStore(
            permissionProvider: MockPermissionProvider(
                snapshot: PermissionSnapshot(
                    systemAudio: .authorized,
                    microphone: .authorized,
                    speechRecognition: .authorized
                )
            ),
            libraryRoot: root,
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 119, count: 32)),
            storageCapacityChecker: MockRecordingStorageCapacityChecker.available,
            playbackAudioEngine: audioEngine,
            audioInputDeviceProvider: inputProvider,
            captureRuntimeMode: .selectedMicrophone,
            selectedMicrophoneCapturer: capturer
        )

        await store.refreshAudioInputDevices()
        _ = await store.refreshPermissions()
        store.startRecordingIntent()
        try await waitUntil("active capture request starts for playback proof") {
            !capturer.requests.isEmpty
        }

        store.stopRecordingIntent()
        try await waitUntil("active recording is processed into playable timeline") {
            store.recordingState == .ready
                && store.recordingProcessingStatus == "Processing complete"
                && store.playbackTimeline.isPlayable
        }

        let cue = try XCTUnwrap(
            store.playbackTimeline.cues.first {
                $0.isPlayable
                    && $0.trackKind == .microphone
                    && $0.text.contains("notarized build checklist")
            }
        )

        store.playTranscriptCue(cue.segmentID)

        XCTAssertEqual(store.playbackSessionState.transportState, .playing)
        XCTAssertEqual(store.playbackSessionState.selectedCueID, cue.segmentID)
        XCTAssertEqual(store.playbackSessionState.currentTime, cue.startTime)
        XCTAssertEqual(audioEngine.playedCueIDs, [cue.segmentID])
        XCTAssertEqual(audioEngine.playedAudioData, capturedAudioData)
        XCTAssertTrue(store.playbackSessionState.statusMessage.contains("Playing"))
    }

    func testActiveRecordingSourceLossTransitionsToRecoverableErrorFromCheckpointedChunks() async throws {
        let inputProvider = MockAudioInputDeviceProvider(
            devices: [
                AudioInputDevice(
                    id: "airpods",
                    displayName: "Sikor AirPods Pro",
                    transportLabel: "Bluetooth",
                    isDefault: true,
                    level: 0.76
                )
            ]
        )
        let capturer = FailingStoreSelectedMicrophoneCapturer(
            chunk: CapturedAudioChunk(
                track: .microphone,
                data: Data("checkpointed live microphone pcm".utf8),
                startTime: 0,
                duration: 5,
                codec: "AVFoundation/PCM"
            )
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultStoreActiveSourceLoss-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = MeetingVaultStore(
            permissionProvider: MockPermissionProvider(
                snapshot: PermissionSnapshot(
                    systemAudio: .authorized,
                    microphone: .authorized,
                    speechRecognition: .authorized
                )
            ),
            libraryRoot: root,
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 117, count: 32)),
            storageCapacityChecker: MockRecordingStorageCapacityChecker.available,
            audioInputDeviceProvider: inputProvider,
            captureRuntimeMode: .selectedMicrophone,
            selectedMicrophoneCapturer: capturer
        )
        let originalIDs = Set(store.meetings.map(\.id))

        await store.refreshAudioInputDevices()
        _ = await store.refreshPermissions()
        store.startRecordingIntent()
        try await waitUntil("active capture writes checkpoint before source loss") {
            !capturer.requests.isEmpty
        }
        let failedMeetingID = try XCTUnwrap(capturer.requests.first?.meetingID)

        try await waitUntil("active source loss becomes a recoverable recording error") {
            store.recordingState == .error
                && store.activeRecordingPresentation == nil
        }

        let newIDs = Set(store.meetings.map(\.id)).subtracting(originalIDs)
        XCTAssertEqual(newIDs, [])
        XCTAssertEqual(store.recordingProcessingFailureStage, .recordingAudio)
        XCTAssertTrue(store.hasRecordingCaptureRecoveryActions)
        XCTAssertTrue(store.recordingProcessingStatus.contains("Selected microphone disconnected during capture"))
        let recoveryReport = try XCTUnwrap(
            store.recoveredRecordings.first { $0.meetingID == failedMeetingID }
        )
        XCTAssertEqual(
            recoveryReport.trackReports.first { $0.track == .microphone }?.chunkCount,
            1
        )
        XCTAssertTrue(recoveryReport.warnings.contains(.finalTranscriptMissing))
        XCTAssertTrue(recoveryReport.warnings.contains(.summaryMissing))
    }

    func testSystemSleepDuringActiveRecordingPreservesCheckpointedBundleForRecovery() async throws {
        let inputProvider = MockAudioInputDeviceProvider(
            devices: [
                AudioInputDevice(
                    id: "airpods",
                    displayName: "Sikor AirPods Pro",
                    transportLabel: "Bluetooth",
                    isDefault: true,
                    level: 0.76
                )
            ]
        )
        let capturer = CheckpointThenWaitStoreSelectedMicrophoneCapturer(
            chunk: CapturedAudioChunk(
                track: .microphone,
                data: Data("checkpoint before sleep".utf8),
                startTime: 0,
                duration: 4,
                codec: "AVFoundation/PCM"
            )
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultStoreSleepInterruption-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = MeetingVaultStore(
            permissionProvider: MockPermissionProvider(
                snapshot: PermissionSnapshot(
                    systemAudio: .authorized,
                    microphone: .authorized,
                    speechRecognition: .authorized
                )
            ),
            libraryRoot: root,
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 118, count: 32)),
            storageCapacityChecker: MockRecordingStorageCapacityChecker.available,
            audioInputDeviceProvider: inputProvider,
            captureRuntimeMode: .selectedMicrophone,
            selectedMicrophoneCapturer: capturer
        )
        let originalIDs = Set(store.meetings.map(\.id))

        await store.refreshAudioInputDevices()
        _ = await store.refreshPermissions()
        store.startRecordingIntent()
        try await waitUntil("active capture writes checkpoint before simulated sleep") {
            capturer.checkpointWritten
        }

        XCTAssertNotNil(store.activeRecordingPresentation)
        await store.handleSystemSleepInterruption()

        XCTAssertEqual(store.recordingState, .error)
        XCTAssertEqual(store.recordingProcessingFailureStage, .recordingAudio)
        XCTAssertEqual(Set(store.meetings.map(\.id)), originalIDs)
        XCTAssertTrue(store.recordingProcessingStatus.contains("macOS is going to sleep"))
        XCTAssertTrue(store.recordingProcessingStatus.contains("checkpointed encrypted audio is preserved"))
        XCTAssertTrue(store.hasRecordingCaptureRecoveryActions)
        XCTAssertNil(store.activeRecordingPresentation)
        XCTAssertEqual(store.healthRecoveryPresentationEvent?.revision, 1)
        XCTAssertNotEqual(store.requestedWorkspaceFocus, MeetingsWorkspaceFocus.recover.rawValue)
        try await waitUntil("sleep cancellation reaches the active capturer") {
            capturer.stopObserved
        }

        let report = try XCTUnwrap(
            store.recoveredRecordings.first {
                $0.title == "Recorded Selected Microphone"
                    && $0.trackReports.contains { $0.track == .microphone && $0.chunkCount == 1 }
            }
        )
        XCTAssertFalse(report.warnings.contains(.noAudioChunks))
        XCTAssertTrue(report.warnings.contains(.finalTranscriptMissing))
        XCTAssertTrue(report.warnings.contains(.summaryMissing))
    }

    func testSystemSleepPersistsDroppedPreviewEvidenceBeforeCoordinatorTeardown() async throws {
        let inputProvider = MockAudioInputDeviceProvider(
            devices: [
                AudioInputDevice(
                    id: "studio-mic",
                    displayName: "Studio Microphone",
                    transportLabel: "Built-in",
                    isDefault: true,
                    level: 0.7
                )
            ]
        )
        let capturer = PreviewDropThenWaitStoreSelectedMicrophoneCapturer()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultStoreSleepPreviewEvidence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let keyProvider = InMemorySymmetricKeyProvider(keyData: Data(repeating: 0x77, count: 32))
        let store = MeetingVaultStore(
            permissionProvider: MockPermissionProvider(
                snapshot: PermissionSnapshot(
                    systemAudio: .authorized,
                    microphone: .authorized,
                    speechRecognition: .authorized
                )
            ),
            libraryRoot: root,
            keyProvider: keyProvider,
            storageCapacityChecker: MockRecordingStorageCapacityChecker.available,
            audioInputDeviceProvider: inputProvider,
            captureRuntimeMode: .selectedMicrophone,
            selectedMicrophoneCapturer: capturer,
            localTranscriptionProvider: SlowStoreLocalTranscriptionProvider()
        )

        await store.refreshAudioInputDevices()
        _ = await store.refreshPermissions()
        store.startRecordingIntent()
        try await waitUntil("preview backpressure drops frames before sleep") {
            store.recordingPreviewDropCount > 0
                && store.activeRecordingPresentation != nil
        }
        let meetingID = try XCTUnwrap(store.activeRecordingPresentation?.meetingID)

        await store.handleSystemSleepInterruption()

        let bundleStore = EncryptedMeetingBundleStore(
            rootDirectory: root,
            vault: AESGCMDataVault(keyProvider: keyProvider)
        )
        let metadata: RecordingSessionMetadata = try bundleStore.readJSONArtifact(
            RecordingSessionMetadata.self,
            meetingID: meetingID,
            relativePath: RecordingSessionMetadata.relativePath,
            purpose: RecordingSessionMetadata.purpose
        )
        XCTAssertFalse(metadata.previewEvidence.gaps.isEmpty)
        XCTAssertTrue(metadata.previewEvidence.gaps.allSatisfy { $0.track == .microphone })
        XCTAssertNil(store.activeRecordingPresentation)
        XCTAssertEqual(store.recordingState, .error)
    }

    func testCaptureFailurePersistsDroppedPreviewEvidenceBeforeCoordinatorTeardown() async throws {
        let inputProvider = MockAudioInputDeviceProvider(
            devices: [
                AudioInputDevice(
                    id: "studio-mic",
                    displayName: "Studio Microphone",
                    transportLabel: "Built-in",
                    isDefault: true,
                    level: 0.7
                )
            ]
        )
        let capturer = PreviewDropThenFailStoreSelectedMicrophoneCapturer()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultStoreCaptureFailurePreviewEvidence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let keyProvider = InMemorySymmetricKeyProvider(keyData: Data(repeating: 0x78, count: 32))
        let store = MeetingVaultStore(
            permissionProvider: MockPermissionProvider(
                snapshot: PermissionSnapshot(
                    systemAudio: .authorized,
                    microphone: .authorized,
                    speechRecognition: .authorized
                )
            ),
            libraryRoot: root,
            keyProvider: keyProvider,
            storageCapacityChecker: MockRecordingStorageCapacityChecker.available,
            audioInputDeviceProvider: inputProvider,
            captureRuntimeMode: .selectedMicrophone,
            selectedMicrophoneCapturer: capturer,
            localTranscriptionProvider: SlowStoreLocalTranscriptionProvider(
                submissionDelay: .milliseconds(20)
            )
        )

        await store.refreshAudioInputDevices()
        _ = await store.refreshPermissions()
        store.startRecordingIntent()
        try await waitUntil(
            "capture failure persists preview evidence and clears the active session",
            timeoutNanoseconds: 3_000_000_000
        ) {
            store.recordingState == .error
                && store.activeRecordingPresentation == nil
                && !capturer.requests.isEmpty
        }
        let meetingID = try XCTUnwrap(capturer.requests.first?.meetingID)
        let bundleStore = EncryptedMeetingBundleStore(
            rootDirectory: root,
            vault: AESGCMDataVault(keyProvider: keyProvider)
        )
        let metadata: RecordingSessionMetadata = try bundleStore.readJSONArtifact(
            RecordingSessionMetadata.self,
            meetingID: meetingID,
            relativePath: RecordingSessionMetadata.relativePath,
            purpose: RecordingSessionMetadata.purpose
        )

        XCTAssertFalse(metadata.previewEvidence.gaps.isEmpty)
        XCTAssertTrue(metadata.previewEvidence.gaps.allSatisfy { $0.track == .microphone })
        XCTAssertEqual(store.recordingProcessingFailureStage, .recordingAudio)
    }

    func testCaptureRuntimeModeParsesSelectedMicrophoneEnvironment() {
        XCTAssertEqual(
            MeetingVaultCaptureRuntimeMode.fromEnvironment(["MEETINGVAULT_CAPTURE_RUNTIME": "core-audio"]),
            .coreAudio
        )
        XCTAssertEqual(
            MeetingVaultCaptureRuntimeMode.fromEnvironment(["MEETINGVAULT_CAPTURE_RUNTIME": "process-tap"]),
            .coreAudio
        )
        XCTAssertEqual(
            MeetingVaultCaptureRuntimeMode.fromEnvironment(["MEETINGVAULT_CAPTURE_RUNTIME": "selected-microphone"]),
            .selectedMicrophone
        )
        XCTAssertEqual(
            MeetingVaultCaptureRuntimeMode.fromEnvironment(["MEETINGVAULT_CAPTURE_RUNTIME": "avfoundation"]),
            .selectedMicrophone
        )
        XCTAssertEqual(MeetingVaultCaptureRuntimeMode.fromEnvironment([:]), .mock)
        XCTAssertEqual(
            MeetingVaultCaptureRuntimeMode.fromEnvironment(["MEETINGVAULT_CAPTURE_RUNTIME": "mock"]),
            .mock
        )
        XCTAssertEqual(
            MeetingVaultCaptureRuntimeMode.fromEnvironment(["MEETINGVAULT_CAPTURE_RUNTIME": "screen-capture-kit"]),
            .screenCaptureKit
        )
        XCTAssertEqual(
            MeetingVaultCaptureRuntimeMode.fromEnvironment(["MEETINGVAULT_CAPTURE_RUNTIME": "system-audio"]),
            .screenCaptureKit
        )
    }

    func testCoreAudioRuntimeUsesInjectedTapAdapter() async throws {
        let capturer = CapturingStoreCoreAudioTapCapturer(
            chunk: CapturedAudioChunk(
                track: .remoteSystem,
                data: Data("core audio runtime system audio".utf8),
                startTime: 0,
                duration: 10,
                codec: "CoreAudioTap/PCM"
            )
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultStoreCoreAudio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = MeetingVaultStore(
            libraryRoot: root,
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 124, count: 32)),
            captureRuntimeMode: .coreAudio,
            coreAudioTapCapturer: capturer
        )

        XCTAssertEqual(store.sources.map(\.id), ["coreaudio-system-audio"])
        XCTAssertEqual(store.selectedSourceID, "coreaudio-system-audio")

        let result = try await store.processStoppedRecordingForSelectedSource(
            meetingID: UUID(uuidString: "56565656-5656-5656-5656-565656565656")!,
            title: "Core Audio tap smoke",
            startedAt: Date(timeIntervalSince1970: 1_780_020_000)
        )

        XCTAssertEqual(result.capture.records.map(\.track), [.remoteSystem])
        XCTAssertEqual(result.capture.healthReport.remoteDropouts, 0)
        XCTAssertNil(result.capture.microphoneDeviceID)
        XCTAssertEqual(capturer.requests.map(\.sourceID), ["coreaudio-system-audio"])
        XCTAssertEqual(capturer.requests.map(\.maximumDuration), [30])
        XCTAssertEqual(store.captureHealthReport.transcriptionEngine, "pending")
    }

    func testScreenCaptureKitRuntimeUsesInjectedSystemAudioAdapter() async throws {
        let capturer = CapturingStoreScreenCaptureKitSystemAudioCapturer(
            chunk: CapturedAudioChunk(
                track: .remoteSystem,
                data: Data("screen capture system audio".utf8),
                startTime: 0,
                duration: 10,
                codec: "ScreenCaptureKit/CMSampleBuffer"
            )
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultStoreScreenCaptureKit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = MeetingVaultStore(
            libraryRoot: root,
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 122, count: 32)),
            captureRuntimeMode: .screenCaptureKit,
            screenCaptureKitCapturer: capturer
        )

        XCTAssertEqual(store.sources.map(\.id), ["screencapturekit-system-audio"])
        XCTAssertEqual(store.selectedSourceID, "screencapturekit-system-audio")

        let result = try await store.processStoppedRecordingForSelectedSource(
            meetingID: UUID(uuidString: "34343434-3434-3434-3434-343434343434")!,
            title: "ScreenCaptureKit fallback smoke",
            startedAt: Date(timeIntervalSince1970: 1_780_019_000)
        )

        XCTAssertEqual(result.capture.records.map(\.track), [.remoteSystem])
        XCTAssertEqual(result.capture.healthReport.remoteDropouts, 0)
        XCTAssertNil(result.capture.microphoneDeviceID)
        XCTAssertEqual(capturer.requests.map(\.sourceID), ["screencapturekit-system-audio"])
        XCTAssertEqual(capturer.requests.map(\.maximumDuration), [30])
        XCTAssertEqual(store.captureHealthReport.transcriptionEngine, "pending")
    }

    func testLiveTranscriptionRuntimeModeParsesAppleSpeechEnvironment() {
        XCTAssertEqual(
            MeetingVaultLiveTranscriptionRuntimeMode.fromEnvironment(["MEETINGVAULT_LIVE_TRANSCRIPTION": "apple-speech"]),
            .appleSpeech
        )
        XCTAssertEqual(
            MeetingVaultLiveTranscriptionRuntimeMode.fromEnvironment(["MEETINGVAULT_LIVE_TRANSCRIPTION": "sfspeech"]),
            .appleSpeech
        )
        XCTAssertEqual(MeetingVaultLiveTranscriptionRuntimeMode.fromEnvironment([:]), .local)
        XCTAssertEqual(
            MeetingVaultLiveTranscriptionRuntimeMode.fromEnvironment(["MEETINGVAULT_LIVE_TRANSCRIPTION": "demo"]),
            .demo
        )
    }

    func testFinalTranscriptionRuntimeModeParsesAppleSpeechEnvironment() {
        XCTAssertEqual(
            MeetingVaultFinalTranscriptionRuntimeMode.fromEnvironment(["MEETINGVAULT_FINAL_TRANSCRIPTION": "apple-speech"]),
            .appleSpeech
        )
        XCTAssertEqual(
            MeetingVaultFinalTranscriptionRuntimeMode.fromEnvironment(["MEETINGVAULT_FINAL_TRANSCRIPTION": "sfspeech"]),
            .appleSpeech
        )
        XCTAssertEqual(MeetingVaultFinalTranscriptionRuntimeMode.fromEnvironment([:]), .local)
        XCTAssertEqual(
            MeetingVaultFinalTranscriptionRuntimeMode.fromEnvironment(["MEETINGVAULT_FINAL_TRANSCRIPTION": "demo"]),
            .demo
        )
    }

    func testFinalTranscriptionRuntimeModeParsesSpeechAnalyzerEnvironment() {
        XCTAssertEqual(
            MeetingVaultFinalTranscriptionRuntimeMode.fromEnvironment(["MEETINGVAULT_FINAL_TRANSCRIPTION": "speech-analyzer"]),
            .speechAnalyzer
        )
        XCTAssertEqual(
            MeetingVaultFinalTranscriptionRuntimeMode.fromEnvironment(["MEETINGVAULT_FINAL_TRANSCRIPTION": "speech_analyzer"]),
            .speechAnalyzer
        )
        XCTAssertEqual(
            MeetingVaultFinalTranscriptionRuntimeMode.fromEnvironment(["MEETINGVAULT_FINAL_TRANSCRIPTION": "speechanalyzer"]),
            .speechAnalyzer
        )
    }

    func testIntelligenceRuntimeModeParsesFoundationModelsEnvironment() {
        XCTAssertEqual(
            MeetingVaultIntelligenceRuntimeMode.fromEnvironment(["MEETINGVAULT_INTELLIGENCE_RUNTIME": "foundation-models"]),
            .foundationModels
        )
        XCTAssertEqual(
            MeetingVaultIntelligenceRuntimeMode.fromEnvironment(["MEETINGVAULT_INTELLIGENCE_RUNTIME": "apple-intelligence"]),
            .foundationModels
        )
        XCTAssertEqual(MeetingVaultIntelligenceRuntimeMode.fromEnvironment([:]), .demo)
        XCTAssertEqual(
            MeetingVaultIntelligenceRuntimeMode.fromEnvironment(["MEETINGVAULT_INTELLIGENCE_RUNTIME": "demo"]),
            .demo
        )
    }

    func testSelectedMicrophoneRuntimeUsesInjectedAVFoundationAdapter() async throws {
        let provider = MockAudioInputDeviceProvider(
            devices: [
                AudioInputDevice(
                    id: "studio",
                    displayName: "Studio Display Microphone",
                    transportLabel: "Built-in",
                    isDefault: true,
                    level: 0.68
                )
            ]
        )
        let capturer = CapturingStoreSelectedMicrophoneCapturer(
            chunk: CapturedAudioChunk(
                track: .microphone,
                data: Data("selected mic runtime pcm".utf8),
                startTime: 0,
                duration: 8,
                codec: "AVCaptureAudio/CMSampleBuffer"
            )
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultStoreSelectedMicrophoneRuntime-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = MeetingVaultStore(
            libraryRoot: root,
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 116, count: 32)),
            audioInputDeviceProvider: provider,
            captureRuntimeMode: .selectedMicrophone,
            selectedMicrophoneCapturer: capturer
        )

        XCTAssertEqual(store.sources.map(\.id), ["selected-microphone"])
        XCTAssertEqual(store.selectedSourceID, "selected-microphone")

        await store.refreshAudioInputDevices()

        let result = try await store.processStoppedRecordingForSelectedSource(
            meetingID: UUID(uuidString: "56565656-5656-5656-5656-565656565656")!,
            title: "Selected microphone runtime smoke",
            startedAt: Date(timeIntervalSince1970: 1_780_020_000)
        )

        XCTAssertEqual(capturer.requests.map(\.deviceID), ["studio"])
        XCTAssertEqual(capturer.requests.map(\.deviceName), ["Studio Display Microphone"])
        XCTAssertEqual(result.capture.records.map(\.track), [.microphone])
        XCTAssertEqual(result.capture.microphoneDeviceID, "studio")
        XCTAssertEqual(result.record.sourceName, "Selected Microphone")
        XCTAssertEqual(store.selectedMeetingID, result.record.id)
        XCTAssertTrue(
            store.transcriptEditDraft.segments.contains {
                $0.trackKind == .microphone
                    && $0.trimmedEditedText.contains("notarized build checklist")
            }
        )
    }

    func testProcessingFailsClosedWhenSelectedAudioInputDisconnects() async throws {
        let provider = MockAudioInputDeviceProvider(
            devices: [
                AudioInputDevice(
                    id: "airpods",
                    displayName: "Sikor AirPods Pro",
                    transportLabel: "Bluetooth",
                    isDefault: true,
                    level: 0.76
                )
            ]
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultStoreDisconnectedInput-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = MeetingVaultStore(
            libraryRoot: root,
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 113, count: 32)),
            audioInputDeviceProvider: provider
        )
        let originalIDs = Set(store.meetings.map(\.id))

        await store.refreshAudioInputDevices()
        XCTAssertEqual(store.selectedAudioInputDeviceID, "airpods")

        provider.update(devices: [])

        do {
            _ = try await store.processStoppedRecordingForSelectedSource(
                meetingID: UUID(uuidString: "34343434-3434-3434-3434-343434343434")!,
                title: "Disconnected input smoke",
                startedAt: Date(timeIntervalSince1970: 1_780_019_000)
            )
            XCTFail("Expected selected input disconnect to fail closed")
        } catch {
            XCTAssertEqual(
                error as? RecordingProcessingError,
                .failed(
                    stage: .recordingAudio,
                    message: "Selected microphone Sikor AirPods Pro is unavailable. Re-detect inputs before recording."
                )
            )
        }

        XCTAssertEqual(Set(store.meetings.map(\.id)), originalIDs)
        XCTAssertEqual(store.recordingState, .error)
        XCTAssertEqual(store.recordingProcessingFailureStage, .recordingAudio)
        XCTAssertTrue(store.recordingProcessingStatus.contains("Selected microphone Sikor AirPods Pro is unavailable"))
        XCTAssertTrue(store.hasRecordingCaptureRecoveryActions)
        XCTAssertEqual(
            store.recordingProcessingRecoveryStatus,
            "Capture stopped before completion. Detect inputs or choose another source, then retry. Any checkpointed audio is listed in Health & Recovery."
        )

        provider.update(devices: [
            AudioInputDevice(
                id: "studio",
                displayName: "Studio Display Microphone",
                transportLabel: "Built-in",
                isDefault: true,
                level: 0.62
            )
        ])
        await store.refreshInputsForRecordingRecovery()

        XCTAssertEqual(store.selectedAudioInputDeviceID, "studio")
        XCTAssertEqual(
            store.recordingProcessingRecoveryStatus,
            "Detected 1 input device. Choose the intended input, then retry recording."
        )
    }

    func testProcessedRecordingPromotesVisibleTranscriptAgentWorkflow() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultStoreTranscriptAgent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = MeetingVaultStore(
            libraryRoot: root,
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 92, count: 32))
        )

        try await store.processStoppedRecordingForSelectedSource(
            meetingID: UUID(uuidString: "99999999-9999-9999-9999-999999999999")!,
            title: "Transcript agent smoke",
            startedAt: Date(timeIntervalSince1970: 1_780_001_200)
        )

        XCTAssertEqual(store.requestedSidebarItem, SidebarItem.meetings.rawValue)
        XCTAssertEqual(store.requestedWorkspaceFocus, MeetingsWorkspaceFocus.understand.rawValue)
        XCTAssertEqual(store.transcriptEditMeetingTitle, "Release readiness sync")
        XCTAssertTrue(
            store.transcriptEditDraft.segments.contains {
                $0.trimmedEditedText.contains("beta candidate can ship")
            }
        )

        store.transcriptAskPrompt = "What did Anna say about the beta candidate?"
        store.askSelectedTranscript()

        XCTAssertEqual(store.transcriptConversationTurns.count, 1)
        let turn = try XCTUnwrap(store.transcriptConversationTurns.first)
        XCTAssertEqual(turn.question, "What did Anna say about the beta candidate?")
        XCTAssertTrue(turn.answerDraft.contains("beta candidate can ship"))
        XCTAssertFalse(turn.evidence.isEmpty)

        store.updateTranscriptAskAnswerDraft("Edited answer ready for the release handoff.")
        XCTAssertEqual(
            store.transcriptConversationTurns.first?.answerDraft,
            "Edited answer ready for the release handoff."
        )

        store.copyTranscriptAskAnswer()
        XCTAssertEqual(
            NSPasteboard.general.string(forType: .string),
            "Edited answer ready for the release handoff."
        )

        store.copyVisibleTranscript()
        let copiedTranscript = try XCTUnwrap(NSPasteboard.general.string(forType: .string))
        XCTAssertTrue(copiedTranscript.contains("Anna"))
        XCTAssertTrue(copiedTranscript.contains("beta candidate can ship"))
    }

    func testSelectedMeetingExportCreatesLocalPackageAndUpdatesStatus() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultStoreExport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = MeetingVaultStore(
            libraryRoot: root,
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 120, count: 32))
        )

        let result = try await store.processStoppedRecordingForSelectedSource(
            meetingID: UUID(uuidString: "DADADADA-DADA-DADA-DADA-DADADADADADA")!,
            title: "Export workflow smoke",
            startedAt: Date(timeIntervalSince1970: 1_780_030_000)
        )

        store.exportMarkdown = true
        store.exportWebVTT = true
        store.exportPDF = true
        store.exportDOCX = true
        store.exportJSON = true
        store.exportAudioPackage = false

        let package = try store.exportSelectedMeeting()

        XCTAssertEqual(package.files.map(\.format), [.markdown, .webVTT, .pdf, .docx, .json])
        XCTAssertEqual(store.lastExportPackage?.directory, package.directory)
        XCTAssertEqual(store.exportStatus, "Exported 5 file(s) for Release readiness sync")
        XCTAssertTrue(package.directory.path.hasPrefix(root.appendingPathComponent("Exports").path))

        let markdown = try String(contentsOf: package.fileURL(for: .markdown), encoding: .utf8)
        XCTAssertTrue(markdown.contains("# Release readiness sync"))
        XCTAssertTrue(markdown.contains("## Open Questions"))
        XCTAssertTrue(markdown.contains("## Risks"))
        XCTAssertTrue(markdown.contains("beta candidate can ship"))

        let json = try Data(contentsOf: package.fileURL(for: .json))
        let decoded = try JSONDecoder.meetingVaultExport.decode(MeetingExportPayload.self, from: json)
        XCTAssertEqual(decoded.meeting.id, result.record.id)
        XCTAssertFalse(decoded.intelligence.summary.risks.isEmpty)

        XCTAssertEqual(store.privacyAuditReview.counts[.exportPackage], 2)
        XCTAssertEqual(store.privacyAuditReview.rows.first?.action, .exportPackage)
        XCTAssertEqual(store.privacyAuditReview.rows.first?.meetingID, result.record.id)
        XCTAssertEqual(store.privacyAuditReview.rows.first?.metadata["formats"], "markdown,webVTT,pdf,docx,json")
    }

    func testSeededSampleMeetingExportsLocalPackage() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultStoreSampleExport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = MeetingVaultStore(
            libraryRoot: root,
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 122, count: 32))
        )

        store.exportMarkdown = true
        store.exportWebVTT = true
        store.exportPDF = true
        store.exportDOCX = true
        store.exportJSON = true
        store.exportAudioPackage = false

        let package = try store.exportSelectedMeeting()

        XCTAssertEqual(package.files.map(\.format), [.markdown, .webVTT, .pdf, .docx, .json])
        XCTAssertEqual(store.lastExportPackage?.directory, package.directory)
        XCTAssertEqual(store.exportStatus, "Exported 5 file(s) for Project weekly sync")
        XCTAssertTrue(package.directory.path.hasPrefix(root.appendingPathComponent("Exports").path))

        let markdown = try String(contentsOf: package.fileURL(for: .markdown), encoding: .utf8)
        XCTAssertTrue(markdown.contains("# Project weekly sync"))
        XCTAssertTrue(markdown.contains("## Risks"))
        XCTAssertTrue(markdown.contains("Deployment timing depends on QA sign-off."))

        let json = try Data(contentsOf: package.fileURL(for: .json))
        let decoded = try JSONDecoder.meetingVaultExport.decode(MeetingExportPayload.self, from: json)
        XCTAssertEqual(decoded.meeting.title, "Project weekly sync")
        XCTAssertEqual(decoded.intelligence.summary.title, "Project weekly sync")
        XCTAssertFalse(decoded.intelligence.summary.risks.isEmpty)
    }

    func testChangingSelectionInvalidatesPreviousMeetingExportAndShare() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultStoreExportSelection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingVaultStore(
            libraryRoot: root,
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 123, count: 32))
        )
        let firstMeetingID = try XCTUnwrap(store.selectedMeetingID)
        let secondMeetingID = try XCTUnwrap(store.meetings.first { $0.id != firstMeetingID }?.id)

        let package = try store.exportSelectedMeeting()
        XCTAssertEqual(package.meetingID, firstMeetingID)

        store.selectedMeetingID = secondMeetingID

        XCTAssertNil(store.lastExportPackage)
        XCTAssertNil(store.lastShareManifest)
        XCTAssertThrowsError(try store.prepareShareForLatestExportPackage())
        XCTAssertEqual(store.shareStatus, "Export a package before sharing")
    }

    func testSelectedMeetingSharePreparationUsesLatestExportPackageAndUpdatesAuditReview() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultStoreShare-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = MeetingVaultStore(
            libraryRoot: root,
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 121, count: 32))
        )

        let result = try await store.processStoppedRecordingForSelectedSource(
            meetingID: UUID(uuidString: "EAEAEAEA-EAEA-EAEA-EAEA-EAEAEAEAEAEA")!,
            title: "Share workflow smoke",
            startedAt: Date(timeIntervalSince1970: 1_780_040_000)
        )

        _ = try store.exportSelectedMeeting()
        store.shareDestination = .finderReveal

        let manifest = try store.prepareShareForLatestExportPackage()

        XCTAssertEqual(manifest.meetingID, result.record.id)
        XCTAssertEqual(manifest.destination, .finderReveal)
        XCTAssertTrue(manifest.requiresUserConfirmation)
        XCTAssertEqual(manifest.files.map(\.format), [.markdown, .webVTT, .pdf, .docx, .json])
        XCTAssertEqual(store.lastShareManifest, manifest)
        XCTAssertEqual(store.shareStatus, "Prepared Finder reveal share for 5 file(s)")

        XCTAssertEqual(store.privacyAuditReview.counts[.sharePrepare], 2)
        XCTAssertEqual(store.privacyAuditReview.rows.first?.action, .sharePrepare)
        XCTAssertEqual(store.privacyAuditReview.rows.first?.meetingID, result.record.id)
        XCTAssertEqual(store.privacyAuditReview.rows.first?.metadata["destination"], "finderReveal")
        XCTAssertEqual(store.privacyAuditReview.rows.first?.metadata["formats"], "markdown,webVTT,pdf,docx,json")
        XCTAssertEqual(store.privacyAuditReview.rows.first?.metadata["fileCount"], "5")
        XCTAssertFalse(store.privacyAuditReview.rows.first?.metadata.values.contains { $0.contains("Share workflow smoke") } ?? true)
        XCTAssertFalse(store.privacyAuditReview.rows.first?.metadata.values.contains { $0.contains(root.path) } ?? true)
    }

    func testSelectedMeetingSystemIntegrationReviewPreparesLocalOnlyProposalsAndAuditMetadata() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultStoreSystemIntegration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = MeetingVaultStore(
            libraryRoot: root,
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 122, count: 32))
        )

        let review = try store.prepareSystemIntegrationReview()

        XCTAssertEqual(review.proposals.map(\.kind), [.calendarEvent, .reminder, .contactReview])
        XCTAssertFalse(review.externalWritePrepared)
        XCTAssertTrue(review.proposals.allSatisfy { $0.executionMode == .reviewOnly })
        XCTAssertEqual(store.systemIntegrationReview, review)
        XCTAssertEqual(
            store.systemIntegrationStatus,
            "Prepared 3 local review proposal(s). No Calendar, Contacts, or Reminders changes were written."
        )

        XCTAssertEqual(store.privacyAuditReview.counts[.systemIntegrationPrepare], 1)
        let row = try XCTUnwrap(store.privacyAuditReview.rows.first)
        XCTAssertEqual(row.action, .systemIntegrationPrepare)
        XCTAssertEqual(row.meetingID, review.meetingID)
        XCTAssertEqual(row.metadata["proposalCount"], "3")
        XCTAssertEqual(row.metadata["calendarEventCount"], "1")
        XCTAssertEqual(row.metadata["reminderCount"], "1")
        XCTAssertEqual(row.metadata["contactReviewCount"], "1")
        XCTAssertEqual(row.metadata["externalWritePrepared"], "false")
        XCTAssertFalse(row.metadata.values.contains { $0.contains("Confirm QA") })
        XCTAssertFalse(row.metadata.values.contains { $0.contains("You") })
        XCTAssertFalse(row.metadata.values.contains { $0.contains("sign-off") })
    }

    func testSystemIntegrationConfirmFailsClosedWithoutExecutor() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultStoreSystemIntegrationNoExecutor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = MeetingVaultStore(
            libraryRoot: root,
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 123, count: 32)),
            systemIntegrationExecutor: nil
        )
        _ = try store.prepareSystemIntegrationReview()

        XCTAssertThrowsError(try store.confirmSystemIntegrationWrites()) { error in
            XCTAssertEqual(error as? MeetingSystemIntegrationExecutionError, .executorUnavailable)
        }
        XCTAssertNil(store.lastSystemIntegrationExecutionResult)
        XCTAssertEqual(
            store.systemIntegrationStatus,
            "System write adapters are unavailable in this build. Review the proposals locally or configure an approved executor."
        )
        XCTAssertNil(store.privacyAuditReview.counts[.systemIntegrationConfirm])
    }

    func testSystemIntegrationConfirmUsesInjectedExecutorAndWritesRedactedAuditMetadata() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultStoreSystemIntegrationExecutor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let executor = CapturingStoreSystemIntegrationExecutor()
        let store = MeetingVaultStore(
            libraryRoot: root,
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 124, count: 32)),
            systemIntegrationExecutor: executor
        )

        let review = try store.prepareSystemIntegrationReview()
        let result = try store.confirmSystemIntegrationWrites()

        XCTAssertEqual(result.meetingID, review.meetingID)
        XCTAssertEqual(result.receipts.count, 3)
        XCTAssertTrue(result.externalWriteExecuted)
        XCTAssertEqual(store.lastSystemIntegrationExecutionResult, result)
        XCTAssertEqual(store.systemIntegrationStatus, "Confirmed 3 Calendar, Contacts, or Reminders write(s).")
        XCTAssertEqual(executor.executedProposals.map(\.executionMode), [.readyForConfirmedWrite, .readyForConfirmedWrite, .readyForConfirmedWrite])

        XCTAssertEqual(store.privacyAuditReview.counts[.systemIntegrationPrepare], 1)
        XCTAssertEqual(store.privacyAuditReview.counts[.systemIntegrationConfirm], 1)
        let row = try XCTUnwrap(store.privacyAuditReview.rows.first)
        XCTAssertEqual(row.action, .systemIntegrationConfirm)
        XCTAssertEqual(row.meetingID, review.meetingID)
        XCTAssertEqual(row.metadata["proposalCount"], "3")
        XCTAssertEqual(row.metadata["receiptCount"], "3")
        XCTAssertEqual(row.metadata["calendarEventCount"], "1")
        XCTAssertEqual(row.metadata["reminderCount"], "1")
        XCTAssertEqual(row.metadata["contactReviewCount"], "1")
        XCTAssertEqual(row.metadata["externalWritePrepared"], "true")
        XCTAssertEqual(row.metadata["externalWriteExecuted"], "true")
        XCTAssertFalse(row.metadata.values.contains { $0.contains("Confirm QA") })
        XCTAssertFalse(row.metadata.values.contains { $0.contains("You") })
        XCTAssertFalse(row.metadata.values.contains { $0.contains("sign-off") })
    }

    func testSystemIntegrationOSExecutorWritesThroughGrantedAdaptersWithBoundedReceipts() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultStoreSystemIntegrationOSExecutor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = MeetingVaultStore(
            libraryRoot: root,
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 125, count: 32)),
            systemIntegrationExecutor: nil
        )
        let review = try store.prepareSystemIntegrationReview()
        let calendarWriter = FakeCalendarReminderWriter(
            eventAuthorizationStatus: .fullAccess,
            reminderAuthorizationStatus: .fullAccess
        )
        let contactWriter = FakeContactReviewWriter(contactAuthorizationStatus: .authorized)
        let executor = MeetingVaultSystemIntegrationExecutor(
            calendarReminderWriter: calendarWriter,
            contactWriter: contactWriter
        )

        let receipts = try executor.executeSystemIntegration(
            proposals: review.proposals,
            executedAt: Date(timeIntervalSince1970: 1_800_004_000)
        )

        XCTAssertEqual(receipts.map(\.kind), [.calendarEvent, .reminder, .contactReview])
        XCTAssertEqual(calendarWriter.savedEvents.count, 1)
        XCTAssertEqual(calendarWriter.savedReminders.count, 1)
        XCTAssertEqual(contactWriter.savedContacts.count, 1)
        XCTAssertEqual(contactWriter.savedContacts.first?.displayName, "You")
        XCTAssertFalse(receipts.map(\.id.uuidString).joined().contains("Confirm QA"))
        XCTAssertFalse(receipts.map(\.id.uuidString).joined().contains(root.path))
    }

    func testSystemIntegrationOSExecutorPreflightsPermissionsBeforeAnyWrite() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultStoreSystemIntegrationOSPermission-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = MeetingVaultStore(
            libraryRoot: root,
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 126, count: 32)),
            systemIntegrationExecutor: nil
        )
        let review = try store.prepareSystemIntegrationReview()
        let calendarWriter = FakeCalendarReminderWriter(
            eventAuthorizationStatus: .denied,
            reminderAuthorizationStatus: .fullAccess
        )
        let contactWriter = FakeContactReviewWriter(contactAuthorizationStatus: .authorized)
        let executor = MeetingVaultSystemIntegrationExecutor(
            calendarReminderWriter: calendarWriter,
            contactWriter: contactWriter
        )

        XCTAssertThrowsError(
            try executor.executeSystemIntegration(
                proposals: review.proposals,
                executedAt: Date(timeIntervalSince1970: 1_800_004_100)
            )
        ) { error in
            XCTAssertEqual(error as? MeetingSystemIntegrationExecutionError, .calendarPermissionRequired)
        }
        XCTAssertTrue(calendarWriter.savedEvents.isEmpty)
        XCTAssertTrue(calendarWriter.savedReminders.isEmpty)
        XCTAssertTrue(contactWriter.savedContacts.isEmpty)
    }

    func testSystemIntegrationPartialFailureKeepsReceiptsAndRemovesCompletedProposalFromRetry() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultStoreSystemIntegrationPartial-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let calendarWriter = FakeCalendarReminderWriter(
            eventAuthorizationStatus: .fullAccess,
            reminderAuthorizationStatus: .fullAccess
        )
        calendarWriter.reminderError = TestSystemWriteError.failed
        let executor = MeetingVaultSystemIntegrationExecutor(
            calendarReminderWriter: calendarWriter,
            contactWriter: FakeContactReviewWriter(contactAuthorizationStatus: .authorized)
        )
        let store = MeetingVaultStore(
            libraryRoot: root,
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 127, count: 32)),
            systemIntegrationExecutor: executor
        )
        let review = try store.prepareSystemIntegrationReview()
        let completedProposalID = try XCTUnwrap(review.proposals.first?.id)

        XCTAssertThrowsError(try store.confirmSystemIntegrationWrites()) { error in
            XCTAssertEqual((error as? MeetingSystemIntegrationPartialWriteError)?.receipts.count, 1)
        }

        XCTAssertEqual(store.lastSystemIntegrationExecutionResult?.receipts.map(\.proposalID), [completedProposalID])
        XCTAssertTrue(store.lastSystemIntegrationExecutionResult?.externalWriteExecuted == true)
        XCTAssertFalse(store.systemIntegrationReview?.proposals.contains { $0.id == completedProposalID } ?? true)
        XCTAssertEqual(store.systemIntegrationReview?.proposals.count, 2)
        XCTAssertEqual(store.privacyAuditReview.rows.first?.metadata["partialFailure"], "true")
    }

    func testSpeechAnalyzerEvaluationUpdatesDiagnosticsStatusWithoutRecordingAudio() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultStoreSpeechAnalyzer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let report = SpeechAnalyzerEvaluationReport(
            generatedAt: Date(timeIntervalSince1970: 1_804_000_100),
            requestedLocaleIdentifier: "en_US",
            resolvedLocaleIdentifier: "en-US",
            sdkAvailable: true,
            transcriberAvailable: true,
            assetStatus: "supported",
            compatibleAudioFormatDescription: "48000 Hz, 1 channel(s), pcmFormatFloat32",
            status: .assetsNeeded,
            notes: [
                "Evaluation did not open a microphone, read a private recording, request permission, or start transcription.",
                "Speech assets are supported but not proven installed."
            ]
        )
        let store = MeetingVaultStore(
            libraryRoot: root,
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 124, count: 32)),
            speechAnalyzerCapabilityProvider: MockSpeechAnalyzerCapabilityProvider(report: report)
        )

        await store.refreshSpeechAnalyzerEvaluation(localeIdentifier: "en_US")

        XCTAssertEqual(store.speechAnalyzerEvaluationReport, report)
        XCTAssertEqual(
            store.speechAnalyzerEvaluationStatus,
            "SpeechAnalyzer supported for en-US, but speech assets are not proven installed"
        )
    }

    func testSpeechAnalyzerAssetPreparationUpdatesDiagnosticsStatusWithoutRecordingAudio() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultStoreSpeechAnalyzerPrepare-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let beforeReport = SpeechAnalyzerEvaluationReport(
            generatedAt: Date(timeIntervalSince1970: 1_804_000_100),
            requestedLocaleIdentifier: "en_US",
            resolvedLocaleIdentifier: "en-US",
            sdkAvailable: true,
            transcriberAvailable: true,
            assetStatus: "supported",
            compatibleAudioFormatDescription: "16000 Hz, 1 channel(s), 16-bit integer PCM",
            status: .assetsNeeded,
            notes: [
                "Evaluation did not open a microphone, read a private recording, request permission, or start transcription.",
                "Speech assets are supported but not proven installed."
            ]
        )
        let preparedReport = SpeechAnalyzerEvaluationReport(
            generatedAt: Date(timeIntervalSince1970: 1_804_000_200),
            requestedLocaleIdentifier: "en_US",
            resolvedLocaleIdentifier: "en-US",
            sdkAvailable: true,
            transcriberAvailable: true,
            assetStatus: "installed",
            compatibleAudioFormatDescription: "16000 Hz, 1 channel(s), 16-bit integer PCM",
            status: .available,
            notes: [
                "SpeechAnalyzer asset preparation was explicitly requested by the user.",
                "Asset preparation did not open the microphone or read private recordings."
            ]
        )
        let store = MeetingVaultStore(
            libraryRoot: root,
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 125, count: 32)),
            speechAnalyzerCapabilityProvider: MockSpeechAnalyzerCapabilityProvider(
                report: beforeReport,
                prepareReport: preparedReport
            )
        )

        await store.prepareSpeechAnalyzerAssets(localeIdentifier: "en_US")

        XCTAssertEqual(store.speechAnalyzerEvaluationReport, preparedReport)
        XCTAssertEqual(
            store.speechAnalyzerEvaluationStatus,
            "SpeechAnalyzer available for en-US; real non-private audio smoke still required"
        )
    }

    func testFilteredPrivacyAuditReviewExportsRedactedLocalFiles() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultStoreAuditExport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = MeetingVaultStore(
            libraryRoot: root,
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 123, count: 32))
        )

        _ = try await store.processStoppedRecordingForSelectedSource(
            meetingID: UUID(uuidString: "CDCDCDCD-CDCD-CDCD-CDCD-CDCDCDCDCDCD")!,
            title: "Private audit export workflow",
            startedAt: Date(timeIntervalSince1970: 1_780_070_000)
        )
        _ = try store.exportSelectedMeeting()
        store.shareDestination = .manualCopy
        _ = try store.prepareShareForLatestExportPackage()
        store.privacyAuditActionFilter = .sharePrepare

        XCTAssertFalse(store.filteredPrivacyAuditRows.isEmpty)
        XCTAssertTrue(store.filteredPrivacyAuditRows.allSatisfy { $0.action == .sharePrepare })

        let export = try store.exportFilteredPrivacyAuditReview()

        XCTAssertEqual(export.actionFilter, .sharePrepare)
        XCTAssertEqual(export.rowCount, store.filteredPrivacyAuditRows.count)
        XCTAssertTrue(export.directory.path.hasPrefix(root.appendingPathComponent("Exports").path))
        XCTAssertEqual(store.lastPrivacyAuditExport, export)
        XCTAssertEqual(store.privacyAuditExportStatus, "Exported \(export.rowCount) redacted audit row(s)")

        let exportedText = try export.files
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")

        XCTAssertTrue(exportedText.contains("share.prepare"))
        XCTAssertFalse(exportedText.contains("export.package"))
        XCTAssertFalse(exportedText.contains("Private audit export workflow"))
        XCTAssertFalse(exportedText.contains(root.path))
        XCTAssertFalse(exportedText.contains(".meetingvault"))
    }

    func testConfirmedShareExecutionUsesPreparedManifestAndRequiresExplicitConfirmation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultStoreShareExecution-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let shareExecutor = CapturingStoreShareExecutor()
        let store = MeetingVaultStore(
            libraryRoot: root,
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 122, count: 32)),
            meetingShareExecutor: shareExecutor
        )

        _ = try await store.processStoppedRecordingForSelectedSource(
            meetingID: UUID(uuidString: "FAFAFAFA-FAFA-FAFA-FAFA-FAFAFAFAFAFA")!,
            title: "Confirmed share workflow smoke",
            startedAt: Date(timeIntervalSince1970: 1_780_050_000)
        )
        _ = try store.exportSelectedMeeting()
        store.shareDestination = .manualCopy
        let manifest = try store.prepareShareForLatestExportPackage()

        do {
            _ = try store.executePreparedShare(userConfirmed: false)
            XCTFail("Expected share execution to require explicit confirmation")
        } catch {
            XCTAssertEqual(error as? MeetingVaultShareExecutionError, .confirmationRequired)
        }

        XCTAssertTrue(shareExecutor.executedManifests.isEmpty)
        XCTAssertEqual(store.shareStatus, "Confirm share before opening a destination")

        let result = try store.executePreparedShare(userConfirmed: true)

        XCTAssertEqual(shareExecutor.executedManifests, [manifest])
        XCTAssertEqual(result.destination, .manualCopy)
        XCTAssertEqual(result.fileCount, 5)
        XCTAssertEqual(store.lastShareExecutionResult, result)
        XCTAssertEqual(store.shareStatus, "Manual copy share opened for 5 file(s)")
    }

    func testPreparedShareIsRejectedBeforeExecutionWhileDelayedCorrectionIsInProgress() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultStoreShareExecutionGate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let keyProvider = InMemorySymmetricKeyProvider(keyData: Data(repeating: 123, count: 32))
        let shareExecutor = CapturingStoreShareExecutor()
        let store = MeetingVaultStore(
            libraryRoot: root,
            keyProvider: keyProvider,
            meetingShareExecutor: shareExecutor
        )
        let meetingID = UUID(uuidString: "FBFBFBFB-FBFB-FBFB-FBFB-FBFBFBFBFBFB")!
        _ = try await store.processStoppedRecordingForSelectedSource(
            meetingID: meetingID,
            title: "Share execution version gate",
            startedAt: Date(timeIntervalSince1970: 1_780_050_100)
        )
        _ = try store.exportSelectedMeeting()
        store.shareDestination = .manualCopy
        _ = try store.prepareShareForLatestExportPackage()

        let segment = try XCTUnwrap(store.transcriptEditDraft.segments.first)
        store.updateTranscriptDraftText(id: segment.id, text: "Corrected after share preparation")
        let correction = try XCTUnwrap(store.saveTranscriptDraft())
        XCTAssertTrue(store.transcriptCorrectionInFlight)

        XCTAssertThrowsError(try store.executePreparedShare(userConfirmed: true)) { error in
            XCTAssertEqual(error as? TranscriptArtifactVersionError, .correctionInProgress)
        }
        XCTAssertTrue(shareExecutor.executedManifests.isEmpty)
        XCTAssertNil(store.lastShareExecutionResult)
        await correction.value
    }

    func testProcessedRecordingPlaybackControlsUsePlayableCueState() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultStorePlayback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let audioEngine = CapturingStorePlaybackEngine()
        let store = MeetingVaultStore(
            libraryRoot: root,
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 106, count: 32)),
            playbackAudioEngine: audioEngine
        )

        try await store.processStoppedRecordingForSelectedSource(
            meetingID: UUID(uuidString: "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE")!,
            title: "Playback controls smoke",
            startedAt: Date(timeIntervalSince1970: 1_780_014_000)
        )

        let cue = try XCTUnwrap(store.playbackTimeline.cues.first(where: \.isPlayable))

        store.playTranscriptCue(cue.segmentID)

        XCTAssertEqual(store.playbackSessionState.transportState, .playing)
        XCTAssertEqual(store.playbackSessionState.selectedCueID, cue.segmentID)
        XCTAssertEqual(store.playbackSessionState.currentTime, cue.startTime)
        XCTAssertTrue(store.playbackSessionState.statusMessage.contains("Playing"))
        XCTAssertEqual(audioEngine.playedCueIDs, [cue.segmentID])
        XCTAssertNotNil(audioEngine.playedAudioData)

        store.pauseTranscriptPlayback()
        XCTAssertEqual(store.playbackSessionState.transportState, .paused)
        XCTAssertEqual(audioEngine.pauseCount, 1)

        store.stopTranscriptPlayback()
        XCTAssertEqual(store.playbackSessionState.transportState, .stopped)
        XCTAssertNil(store.playbackSessionState.selectedCueID)
        XCTAssertEqual(audioEngine.stopCount, 1)
    }

    func testSelectingAnotherMeetingStopsAndRejectsPreviousMeetingPlaybackActions() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultStorePlaybackSelectionScope-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let firstMeetingID = UUID(uuidString: "12121212-1212-1212-1212-121212121212")!
        let secondMeetingID = UUID(uuidString: "34343434-3434-3434-3434-343434343434")!
        let audioEngine = CapturingStorePlaybackEngine()
        let store = MeetingVaultStore(
            libraryRoot: root,
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 108, count: 32)),
            playbackAudioEngine: audioEngine
        )

        try await store.processStoppedRecordingForSelectedSource(
            meetingID: firstMeetingID,
            title: "First scoped playback meeting",
            startedAt: Date(timeIntervalSince1970: 1_780_016_000)
        )
        try await store.processStoppedRecordingForSelectedSource(
            meetingID: secondMeetingID,
            title: "Second scoped playback meeting",
            startedAt: Date(timeIntervalSince1970: 1_780_017_000)
        )

        let secondMeetingCue = try XCTUnwrap(store.playbackTimeline.cues.first(where: \.isPlayable))
        store.playTranscriptCue(secondMeetingCue.segmentID)
        XCTAssertEqual(store.playbackSessionState.transportState, .playing)
        XCTAssertEqual(audioEngine.playedCueIDs, [secondMeetingCue.segmentID])

        store.selectedMeetingID = firstMeetingID

        XCTAssertEqual(store.playbackTimeline.meetingID, firstMeetingID)
        XCTAssertEqual(store.playbackSessionState.meetingID, firstMeetingID)
        XCTAssertEqual(store.playbackSessionState.transportState, .idle)
        XCTAssertEqual(audioEngine.stopCount, 1)

        let firstMeetingCue = try XCTUnwrap(store.playbackTimeline.cues.first(where: \.isPlayable))
        store.playTranscriptCue(firstMeetingCue.segmentID)
        store.seekTranscriptPlayback(to: 12)

        XCTAssertEqual(audioEngine.playedCueIDs, [secondMeetingCue.segmentID, firstMeetingCue.segmentID])
        XCTAssertEqual(store.playbackSessionState.currentTime, 12)
        XCTAssertEqual(store.playbackSessionState.transportState, .playing)
    }

    func testNilSelectionClearsPreviousPlaybackTimelineSessionAndBookmarkStatus() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultNilPlaybackSelection-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingVaultStore(
            libraryRoot: root,
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 109, count: 32))
        )
        try await store.processStoppedRecordingForSelectedSource(
            meetingID: UUID(),
            title: "Previous playback",
            startedAt: Date(timeIntervalSince1970: 1_780_030_000)
        )
        XCTAssertFalse(store.playbackTimeline.cues.isEmpty)

        store.selectedMeetingID = nil

        XCTAssertTrue(store.playbackTimeline.cues.isEmpty)
        XCTAssertTrue(store.playbackTimeline.bookmarks.isEmpty)
        XCTAssertEqual(store.playbackSessionState.meetingID, store.playbackTimeline.meetingID)
        XCTAssertEqual(store.playbackSessionState.transportState, .idle)
        XCTAssertEqual(store.selectedBookmarkStatus, "No marked moments loaded: no meeting selected")
    }

    func testMissingTranscriptSelectionRebindsEmptyPlaybackToSelectedMeeting() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultMissingTranscriptSelection-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingVaultStore(
            libraryRoot: root,
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 110, count: 32))
        )
        let missingMeetingID = UUID()

        store.selectedMeetingID = missingMeetingID

        XCTAssertEqual(store.playbackTimeline.meetingID, missingMeetingID)
        XCTAssertTrue(store.playbackTimeline.cues.isEmpty)
        XCTAssertTrue(store.playbackTimeline.bookmarks.isEmpty)
        XCTAssertEqual(store.playbackSessionState.meetingID, missingMeetingID)
        XCTAssertEqual(store.playbackSessionState.transportState, .idle)
        XCTAssertEqual(
            store.selectedBookmarkStatus,
            "Marked moments unavailable: selected transcript is unavailable"
        )
    }

    func testSelectionClearsBookmarksAndReportsPreciseStatusForCorruptOrMismatchedMetadata() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultStoreBookmarkSelectionIdentity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let keyProvider = InMemorySymmetricKeyProvider(keyData: Data(repeating: 121, count: 32))
        let store = MeetingVaultStore(libraryRoot: root, keyProvider: keyProvider)
        let firstMeetingID = UUID()
        let secondMeetingID = UUID()
        try await store.processStoppedRecordingForSelectedSource(
            meetingID: firstMeetingID,
            title: "First bookmark selection",
            startedAt: Date(timeIntervalSince1970: 1_780_020_000)
        )
        try await store.processStoppedRecordingForSelectedSource(
            meetingID: secondMeetingID,
            title: "Second bookmark selection",
            startedAt: Date(timeIntervalSince1970: 1_780_021_000)
        )
        let bundleStore = EncryptedMeetingBundleStore(
            rootDirectory: root,
            vault: AESGCMDataVault(keyProvider: keyProvider)
        )
        let secondBookmark = MeetingBookmark(
            meetingID: secondMeetingID,
            timestamp: 2,
            createdAt: Date(timeIntervalSince1970: 1_780_021_002),
            note: "Second only"
        )
        var secondMetadata = try bundleStore.readJSONArtifact(
            RecordingSessionMetadata.self,
            meetingID: secondMeetingID,
            relativePath: RecordingSessionMetadata.relativePath,
            purpose: RecordingSessionMetadata.purpose
        )
        secondMetadata.bookmarks = [secondBookmark]
        try bundleStore.writeJSONArtifact(
            secondMetadata,
            meetingID: secondMeetingID,
            relativePath: RecordingSessionMetadata.relativePath,
            purpose: RecordingSessionMetadata.purpose
        )
        store.selectedMeetingID = firstMeetingID
        store.selectedMeetingID = secondMeetingID
        XCTAssertEqual(store.playbackTimeline.bookmarks, [secondBookmark])

        let firstArtifact = bundleStore.bundleURL(for: firstMeetingID)
            .appendingPathComponent(RecordingSessionMetadata.relativePath)
        try Data("corrupt".utf8).write(to: firstArtifact, options: .atomic)
        store.selectedMeetingID = firstMeetingID

        XCTAssertEqual(store.playbackTimeline.meetingID, firstMeetingID)
        XCTAssertEqual(store.playbackTimeline.bookmarks, [])
        XCTAssertEqual(store.selectedBookmarkStatus, "Marked moments unavailable: encrypted metadata is corrupt")
        XCTAssertFalse(store.playbackTimeline.bookmarks.contains(secondBookmark))

        try bundleStore.writeJSONArtifact(
            RecordingSessionMetadata(
                meetingID: secondMeetingID,
                startedAt: Date(timeIntervalSince1970: 1_780_020_000),
                context: MeetingContext(),
                bookmarks: [secondBookmark],
                isFinalized: true
            ),
            meetingID: firstMeetingID,
            relativePath: RecordingSessionMetadata.relativePath,
            purpose: RecordingSessionMetadata.purpose
        )
        store.selectedMeetingID = secondMeetingID
        store.selectedMeetingID = firstMeetingID

        XCTAssertEqual(store.playbackTimeline.bookmarks, [])
        XCTAssertEqual(store.selectedBookmarkStatus, "Marked moments unavailable: metadata belongs to another meeting")
    }

    func testProcessedRecordingDefaultPlaybackUsesDecodableLocalAudio() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultStoreDefaultPlayback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = MeetingVaultStore(
            libraryRoot: root,
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 107, count: 32))
        )

        try await store.processStoppedRecordingForSelectedSource(
            meetingID: UUID(uuidString: "FAFAFAFA-FAFA-FAFA-FAFA-FAFAFAFAFAFA")!,
            title: "Default playback smoke",
            startedAt: Date(timeIntervalSince1970: 1_780_015_000)
        )

        let cue = try XCTUnwrap(store.playbackTimeline.cues.first(where: \.isPlayable))

        store.playTranscriptCue(cue.segmentID)

        XCTAssertEqual(store.playbackSessionState.transportState, .playing)
        XCTAssertEqual(store.playbackSessionState.selectedCueID, cue.segmentID)
        XCTAssertTrue(store.playbackSessionState.statusMessage.contains("Playing"))

        store.stopTranscriptPlayback()
        XCTAssertEqual(store.playbackSessionState.transportState, .stopped)
    }

    func testLocalRecordingImportLoadsTranscriptAgentWorkflow() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultStoreLocalRecording-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let transcriptURL = root.appendingPathComponent("20250718 1457 Transcription.txt")
        let audioURL = root.appendingPathComponent("Voice Chat 20250718 1457.mp3")
        try """
        [00:00:00.34] Microsoft Teams:\tSo you want to talk about the migration task.

        [00:00:30.58] Microsoft Teams:\tYesterday I sent you an email with a query.
        """.write(to: transcriptURL, atomically: true, encoding: .utf8)
        try Data(repeating: 3, count: 128).write(to: audioURL)

        let audioEngine = CapturingStorePlaybackEngine()
        let store = MeetingVaultStore(
            libraryRoot: root.appendingPathComponent("Library"),
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 101, count: 32)),
            playbackAudioEngine: audioEngine
        )
        let originalIDs = Set(store.meetings.map(\.id))

        let result = try await store.importLocalRecording(
            transcriptURL: transcriptURL,
            audioURL: audioURL,
            title: "Imported real local recording sample",
            sourceName: "Microsoft Teams"
        )

        XCTAssertFalse(originalIDs.contains(result.record.id))
        XCTAssertEqual(store.meetings.first?.id, result.record.id)
        XCTAssertTrue(store.meetings.contains { $0.id == result.record.id && $0.title == "Migration Task Yesterday I Sent You An" })
        XCTAssertEqual(store.selectedMeetingID, result.record.id)
        XCTAssertEqual(store.requestedSidebarItem, SidebarItem.meetings.rawValue)
        XCTAssertEqual(store.requestedWorkspaceFocus, MeetingsWorkspaceFocus.understand.rawValue)
        XCTAssertEqual(store.transcriptEditMeetingTitle, "Migration Task Yesterday I Sent You An")
        XCTAssertEqual(result.record.summary?.title, "Migration Task Yesterday I Sent You An")
        XCTAssertEqual(store.localRecordingImportStatus, "Imported 2 transcript segments and generated the meeting title")
        XCTAssertTrue(store.playbackTimeline.isPlayable)
        XCTAssertEqual(store.playbackTimeline.warnings, [])
        let cue = try XCTUnwrap(store.playbackTimeline.cues.first(where: \.isPlayable))
        store.playTranscriptCue(cue.segmentID)
        XCTAssertEqual(store.playbackSessionState.transportState, .playing)
        XCTAssertEqual(audioEngine.playedAudioData, Data(repeating: 3, count: 128))
        store.stopTranscriptPlayback()
        XCTAssertEqual(store.playbackSessionState.transportState, .stopped)
        XCTAssertTrue(
            store.transcriptEditDraft.segments.contains {
                $0.trimmedEditedText.contains("migration task")
            }
        )

        store.transcriptAskPrompt = "What migration work was discussed?"
        store.askSelectedTranscript()

        XCTAssertTrue(store.transcriptAskAnswerDraft.contains("migration task"))
        XCTAssertEqual(store.transcriptConversationTurns.count, 1)
    }

    func testLocalRecordingImportReportsUnsupportedExternalFileTypes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultStoreUnsupportedLocalRecording-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let transcriptURL = root.appendingPathComponent("20260703 1200 Transcription.txt")
        let audioURL = root.appendingPathComponent("Voice Chat 20260703 1200.flac")
        try "[00:00:01.00] Anna:\tThis import should explain unsupported audio.".write(
            to: transcriptURL,
            atomically: true,
            encoding: .utf8
        )
        try Data(repeating: 4, count: 32).write(to: audioURL)

        let store = MeetingVaultStore(
            libraryRoot: root.appendingPathComponent("Library"),
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 112, count: 32))
        )
        let originalMeetingIDs = Set(store.meetings.map(\.id))

        do {
            _ = try await store.importLocalRecording(
                transcriptURL: transcriptURL,
                audioURL: audioURL,
                sourceName: "External recording"
            )
            XCTFail("Expected unsupported audio import to fail")
        } catch {
            XCTAssertEqual(error as? LocalRecordingImportError, .unsupportedAudioExtension("flac"))
        }

        XCTAssertEqual(
            store.localRecordingImportStatus,
            "Unsupported recording type .flac. Use MP3, M4A, AAC, WAV, AIF, AIFF, AIFC, or CAF."
        )
        XCTAssertEqual(Set(store.meetings.map(\.id)), originalMeetingIDs)
    }

    func testLocalRecordingPlainEnglishTranscriptImportsFromSelectedFiles() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultStorePlainEnglishLocalRecording-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let transcriptURL = root.appendingPathComponent("Customer Followup 20260703 1230.txt")
        let audioURL = root.appendingPathComponent("Voice Chat 20260703 1230.mp3")
        try """
        We discussed the onboarding call, the duplicate controls in the recording UI, and the need
        to finish final transcription from the saved audio after Stop.
        """.write(to: transcriptURL, atomically: true, encoding: .utf8)
        try Data(repeating: 7, count: 96).write(to: audioURL)

        let store = MeetingVaultStore(
            libraryRoot: root.appendingPathComponent("Library"),
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 113, count: 32))
        )

        let results = try await store.importLocalRecordingSelection(urls: [audioURL, transcriptURL])

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(store.localRecordingImportStatus, "Imported 1 local recording into library")
        XCTAssertEqual(store.localRecordingTranscriptPath, transcriptURL.path)
        XCTAssertEqual(store.localRecordingAudioPath, audioURL.path)
        XCTAssertEqual(store.meetings.first?.id, results[0].record.id)
        XCTAssertTrue(store.meetings.contains { $0.id == results[0].record.id && $0.title == "Onboarding Call The Duplicate Controls In The" })
        XCTAssertEqual(store.selectedMeetingID, results[0].record.id)
        XCTAssertEqual(results[0].record.summary?.title, "Onboarding Call The Duplicate Controls In The")
        XCTAssertTrue(store.transcriptAgentHasVisibleTranscript)
        XCTAssertTrue(
            store.transcriptEditDraft.segments.first?.trimmedEditedText.contains("duplicate controls in the recording UI") == true
        )
        XCTAssertEqual(store.requestedWorkspaceFocus, MeetingsWorkspaceFocus.understand.rawValue)
    }

    func testLocalRecordingSelectionImportsMultipleTimestampMatchedFilePairs() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultStoreMultiFileLocalRecording-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let firstTranscriptURL = root.appendingPathComponent("Roadmap 20260703 0900 Transcription.txt")
        let firstAudioURL = root.appendingPathComponent("Voice Chat 20260703 0900.mp3")
        let secondTranscriptURL = root.appendingPathComponent("Design Review 20260703 1000 Transcription.txt")
        let secondAudioURL = root.appendingPathComponent("Voice Chat 20260703 1000.m4a")
        try "[00:00:01.00] Anna:\tThe roadmap import should create a library record.".write(
            to: firstTranscriptURL,
            atomically: true,
            encoding: .utf8
        )
        try "[00:00:01.00] Ben:\tThe design review import should also create a library record.".write(
            to: secondTranscriptURL,
            atomically: true,
            encoding: .utf8
        )
        try Data(repeating: 8, count: 64).write(to: firstAudioURL)
        try Data(repeating: 9, count: 64).write(to: secondAudioURL)

        let store = MeetingVaultStore(
            libraryRoot: root.appendingPathComponent("Library"),
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 114, count: 32))
        )
        let originalIDs = Set(store.meetings.map(\.id))

        let results = try await store.importLocalRecordingSelection(
            urls: [secondAudioURL, firstTranscriptURL, firstAudioURL, secondTranscriptURL]
        )

        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(store.localRecordingImportStatus, "Imported 2 local recordings into library")
        XCTAssertEqual(Set(store.meetings.map(\.id)).subtracting(originalIDs).count, 2)
        XCTAssertTrue(results.allSatisfy { result in store.meetings.contains { $0.id == result.record.id } })
        XCTAssertEqual(store.selectedMeetingID, results.last?.record.id)
        XCTAssertTrue(store.meetings.contains { $0.title == "Roadmap Import Should Create A Library Record" })
        XCTAssertTrue(store.meetings.contains { $0.title == "Design Review Import Should Also Create A" })
    }

    func testLocalRecordingFolderImportImportsMatchedFilesIntoLibrary() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultStoreFolderLocalRecording-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let transcriptURL = root.appendingPathComponent("Folder Import 20260703 1330 Transcription.txt")
        let audioURL = root.appendingPathComponent("Voice Chat 20260703 1330.mp3")
        try "[00:00:01.00] Anna:\tThe folder import should create a recording automatically.".write(
            to: transcriptURL,
            atomically: true,
            encoding: .utf8
        )
        try Data(repeating: 10, count: 64).write(to: audioURL)

        let store = MeetingVaultStore(
            libraryRoot: root.appendingPathComponent("Library"),
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 115, count: 32))
        )
        let originalIDs = Set(store.meetings.map(\.id))

        let results = try await store.importLocalRecordingFolder(in: root)

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(store.localRecordingImportStatus, "Imported 1 local recording into library")
        XCTAssertEqual(Set(store.meetings.map(\.id)).subtracting(originalIDs), [results[0].record.id])
        XCTAssertEqual(store.meetings.first?.title, "Folder Import Should Create A Recording Automatically")
        XCTAssertEqual(store.selectedMeetingID, results[0].record.id)
        XCTAssertEqual(store.requestedWorkspaceFocus, MeetingsWorkspaceFocus.understand.rawValue)
    }

    func testLocalRecordingSampleSelectionImportsIntoTranscriptAgentWorkflow() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultStoreLocalRecordingSample-\(UUID().uuidString)", isDirectory: true)
        let transcriptDirectory = root.appendingPathComponent("Transcript Captures", isDirectory: true)
        let audioDirectory = root.appendingPathComponent("Local Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: transcriptDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let transcriptURL = transcriptDirectory.appendingPathComponent("20260226 1207 Transcription.txt")
        let audioURL = audioDirectory.appendingPathComponent("Voice Chat 20260226 1207.mp3")
        try """
        [00:00:01.00] Microsoft Teams:\tWe need the transcript agent visible after import.

        [00:00:20.00] Microsoft Teams:\tThe editable response should be copied only after review.
        """.write(to: transcriptURL, atomically: true, encoding: .utf8)
        try Data(repeating: 5, count: 512).write(to: audioURL)

        let store = MeetingVaultStore(
            libraryRoot: root.appendingPathComponent("Library"),
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 108, count: 32))
        )

        store.refreshLocalRecordingSamples(
            transcriptDirectory: transcriptDirectory,
            audioDirectory: audioDirectory
        )

        XCTAssertEqual(store.localRecordingSamples.map(\.timestampKey), ["20260226 1207"])
        XCTAssertEqual(
            URL(fileURLWithPath: store.localRecordingTranscriptPath).resolvingSymlinksInPath().path,
            transcriptURL.resolvingSymlinksInPath().path
        )
        XCTAssertEqual(
            URL(fileURLWithPath: store.localRecordingAudioPath).resolvingSymlinksInPath().path,
            audioURL.resolvingSymlinksInPath().path
        )

        let result = try await store.importSelectedLocalRecordingSample()

        XCTAssertEqual(store.selectedMeetingID, result.record.id)
        XCTAssertEqual(store.requestedSidebarItem, SidebarItem.meetings.rawValue)
        XCTAssertEqual(store.requestedWorkspaceFocus, MeetingsWorkspaceFocus.understand.rawValue)
        XCTAssertEqual(store.transcriptEditMeetingTitle, "Need The Transcript Agent Visible After Import")
        XCTAssertEqual(result.record.summary?.title, "Need The Transcript Agent Visible After Import")
        XCTAssertEqual(result.record.sourceName, "Imported recording / Local Recording")
        XCTAssertEqual(result.searchMeeting.sourceApp, "Imported recording / Local Recording")
        XCTAssertTrue(store.localRecordingImportStatus.contains("2 transcript segments"))
        XCTAssertTrue(
            store.transcriptEditDraft.segments.contains {
                $0.trimmedEditedText.contains("transcript agent visible")
            }
        )

        store.transcriptAskPrompt = "What should be visible after import?"
        store.askSelectedTranscript()

        XCTAssertTrue(store.transcriptAskAnswerDraft.contains("transcript agent visible"))
        store.updateTranscriptAskAnswerDraft("Reviewed response for the imported local recording sample.")
        store.copyTranscriptAskAnswer()
        XCTAssertEqual(
            NSPasteboard.general.string(forType: .string),
            "Reviewed response for the imported local recording sample."
        )
    }

    func testRecoveredRecordingImportLoadsTranscriptAgentWorkflow() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultStoreRecoveredImport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let keyProvider = InMemorySymmetricKeyProvider(keyData: Data(repeating: 103, count: 32))
        let vault = AESGCMDataVault(keyProvider: keyProvider)
        let bundleStore = EncryptedMeetingBundleStore(rootDirectory: root, vault: vault)
        let chunkWriter = EncryptedAudioChunkWriter(bundleStore: bundleStore)
        let recoveredMeetingID = UUID(uuidString: "ABABABAB-ABAB-ABAB-ABAB-ABABABABABAB")!
        var manifest = MeetingBundleManifest.initialEncryptedBundle(
            meetingID: recoveredMeetingID,
            title: "Recovered app smoke"
        )
        manifest.createdAt = Date(timeIntervalSince1970: 1_780_013_000)
        _ = try bundleStore.createBundle(manifest)
        _ = try chunkWriter.writeChunk(
            Data("remote recovered app audio".utf8),
            meetingID: recoveredMeetingID,
            track: .remoteSystem,
            chunkIndex: 0,
            startTime: 0,
            duration: 30,
            codec: "CAF/LPCM"
        )
        _ = try chunkWriter.writeChunk(
            Data("mic recovered app audio".utf8),
            meetingID: recoveredMeetingID,
            track: .microphone,
            chunkIndex: 0,
            startTime: 30,
            duration: 20,
            codec: "CAF/LPCM"
        )

        let store = MeetingVaultStore(libraryRoot: root, keyProvider: keyProvider)
        let originalIDs = Set(store.meetings.map(\.id))
        XCTAssertTrue(store.recoveredRecordings.contains { $0.meetingID == recoveredMeetingID })

        let result = try await store.importRecoveredRecording(meetingID: recoveredMeetingID)

        XCTAssertFalse(originalIDs.contains(result.record.id))
        XCTAssertEqual(result.record.state, .recovered)
        XCTAssertEqual(store.selectedMeetingID, recoveredMeetingID)
        XCTAssertEqual(store.requestedSidebarItem, SidebarItem.meetings.rawValue)
        XCTAssertEqual(store.requestedWorkspaceFocus, MeetingsWorkspaceFocus.understand.rawValue)
        XCTAssertEqual(store.recoveredRecordingImportStatus, "Recovered recording imported with 2 transcript segments")
        XCTAssertFalse(store.recoveredRecordings.contains { $0.meetingID == recoveredMeetingID && !$0.warnings.isEmpty })
        XCTAssertEqual(store.transcriptEditMeetingTitle, "Release readiness sync")
        XCTAssertTrue(
            store.transcriptEditDraft.segments.contains {
                $0.trimmedEditedText.contains("beta candidate can ship")
            }
        )
    }

    func testProcessingStoppedRecordingInsertsAndSelectsDurableMeeting() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultStoreProcessing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = MeetingVaultStore(
            libraryRoot: root,
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 93, count: 32))
        )
        let originalIDs = Set(store.meetings.map(\.id))

        try await store.processStoppedRecordingForSelectedSource(
            meetingID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            title: "Processed recording smoke",
            startedAt: Date(timeIntervalSince1970: 1_780_002_000)
        )

        let processed = try XCTUnwrap(
            store.meetings.first { !originalIDs.contains($0.id) }
        )
        XCTAssertEqual(processed.title, "Release readiness sync")
        XCTAssertEqual(processed.state, .ready)
        XCTAssertEqual(processed.summary?.decisions.first?.title, "Ship after privacy review")
        XCTAssertEqual(store.selectedMeetingID, processed.id)
        XCTAssertEqual(store.transcriptEditDraft.meetingID, processed.id)
        XCTAssertEqual(store.recordingProcessingProgress?.stage, .finished)
        XCTAssertEqual(store.recordingProcessingStatus, "Processing complete")
        XCTAssertTrue(
            store.transcriptEditDraft.segments.contains {
                $0.editedText.contains("beta candidate can ship")
            }
        )
        XCTAssertEqual(store.recordingState, .ready)
        XCTAssertTrue(store.transcriptEditStatus.contains("Loaded Release readiness sync"))
    }

    func testCancellationOutsideProcessingDoesNotPoisonTheNextProcessingJob() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultStoreCancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = MeetingVaultStore(
            libraryRoot: root,
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 94, count: 32))
        )
        let originalIDs = Set(store.meetings.map(\.id))
        await store.cancelRecordingProcessing()
        XCTAssertEqual(store.recordingProcessingStatus, "No recording processing to cancel")

        _ = try await store.processStoppedRecordingForSelectedSource(
            meetingID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
            title: "Cancellation rejection smoke",
            startedAt: Date(timeIntervalSince1970: 1_780_002_400)
        )

        XCTAssertEqual(Set(store.meetings.map(\.id)).subtracting(originalIDs).count, 1)
        XCTAssertEqual(store.recordingState, .ready)
        XCTAssertEqual(store.recordingProcessingStatus, "Processing complete")
        XCTAssertEqual(store.recordingProcessingProgress?.stage, .finished)
    }

    func testFailedRecordingProcessingCanRetryAfterSelectingAvailableSource() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultStoreRetry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = MeetingVaultStore(
            libraryRoot: root,
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 95, count: 32))
        )
        let originalIDs = Set(store.meetings.map(\.id))
        store.selectedSourceID = "missing-source"

        do {
            _ = try await store.processStoppedRecordingForSelectedSource(
                meetingID: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!,
                title: "Retry recording smoke",
                startedAt: Date(timeIntervalSince1970: 1_780_002_800)
            )
            XCTFail("Expected source failure to throw")
        } catch {
            XCTAssertEqual(
                error as? RecordingProcessingError,
                .failed(stage: .recordingAudio, message: "sourceUnavailable(\"missing-source\")")
            )
        }

        XCTAssertEqual(Set(store.meetings.map(\.id)), originalIDs)
        XCTAssertEqual(store.recordingState, .error)
        XCTAssertEqual(store.recordingProcessingFailureStage, .recordingAudio)
        XCTAssertTrue(store.recordingProcessingStatus.contains("Capture failed"))

        store.selectedSourceID = "teams"
        try await store.retryRecordingProcessing()

        let processed = try XCTUnwrap(
            store.meetings.first { !originalIDs.contains($0.id) }
        )
        XCTAssertEqual(processed.title, "Release readiness sync")
        XCTAssertEqual(store.selectedMeetingID, processed.id)
        XCTAssertEqual(store.recordingState, .ready)
        XCTAssertEqual(store.recordingProcessingStatus, "Processing complete")
    }

    func testFailedRecordingProcessingAppearsInRecoverableRecordings() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultStoreRecovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = MeetingVaultStore(
            libraryRoot: root,
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 96, count: 32))
        )
        let originalIDs = Set(store.meetings.map(\.id))
        let failedMeetingID = UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!
        store.selectedSourceID = "missing-source"

        do {
            _ = try await store.processStoppedRecordingForSelectedSource(
                meetingID: failedMeetingID,
                title: "Recoverable failed recording",
                startedAt: Date(timeIntervalSince1970: 1_780_003_000)
            )
            XCTFail("Expected source failure to throw")
        } catch {
            XCTAssertEqual(
                error as? RecordingProcessingError,
                .failed(stage: .recordingAudio, message: "sourceUnavailable(\"missing-source\")")
            )
        }

        XCTAssertEqual(Set(store.meetings.map(\.id)), originalIDs)
        let report = try XCTUnwrap(store.recoveredRecordings.first { $0.meetingID == failedMeetingID })
        XCTAssertEqual(report.title, "Recoverable failed recording")
        XCTAssertTrue(report.warnings.contains(.noAudioChunks))
        XCTAssertTrue(report.warnings.contains(.finalTranscriptMissing))
        XCTAssertTrue(report.warnings.contains(.summaryMissing))
        XCTAssertTrue(store.hasRecordingCaptureRecoveryActions)

        store.openRecordingRecoveryReview()

        XCTAssertEqual(store.healthRecoveryPresentationEvent?.revision, 1)
        XCTAssertNotEqual(store.requestedWorkspaceFocus, MeetingsWorkspaceFocus.recover.rawValue)
        XCTAssertTrue(store.recoveredRecordings.contains { $0.meetingID == failedMeetingID })
        XCTAssertTrue(store.recordingProcessingRecoveryStatus.hasPrefix("Opened Health & Recovery with "))
        XCTAssertTrue(store.recordingProcessingRecoveryStatus.hasSuffix(" incomplete recording bundles ready for review."))
    }

    func testRetentionReviewRequiresConfirmationBeforeDeletingExpiredBundles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultStoreRetention-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let keyData = Data(repeating: 123, count: 32)
        let store = MeetingVaultStore(
            libraryRoot: root,
            keyProvider: InMemorySymmetricKeyProvider(keyData: keyData)
        )
        let bundleStore = EncryptedMeetingBundleStore(
            rootDirectory: root,
            vault: AESGCMDataVault(keyProvider: InMemorySymmetricKeyProvider(keyData: keyData))
        )
        let now = Date(timeIntervalSince1970: 1_780_060_000)
        let expiredID = UUID(uuidString: "ABABABAB-ABAB-ABAB-ABAB-ABABABABABAB")!
        var expired = MeetingBundleManifest.initialEncryptedBundle(
            meetingID: expiredID,
            title: "Expired retention review smoke"
        )
        expired.createdAt = now.addingTimeInterval(-91 * 86_400)
        _ = try bundleStore.createBundle(expired)

        try store.refreshRetentionCleanupPlan(now: now)

        XCTAssertEqual(store.retentionCleanupStatus, "1 expired recording bundle ready for review")
        XCTAssertEqual(store.retentionCleanupPlan?.policy.retentionDays, 30)
        XCTAssertEqual(store.retentionCleanupPlan?.candidates.map(\.meetingID), [expiredID])
        XCTAssertEqual(store.retentionCleanupPlan?.candidates.first?.ageDays, 91)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleStore.bundleURL(for: expiredID).path))

        do {
            _ = try store.applyRetentionCleanup(userConfirmed: false)
            XCTFail("Expected retention cleanup to require explicit confirmation")
        } catch {
            XCTAssertEqual(error as? MeetingVaultRetentionRuntimeError, .confirmationRequired)
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleStore.bundleURL(for: expiredID).path))
        XCTAssertEqual(store.retentionCleanupStatus, "Confirm retention cleanup before deleting expired recordings")

        let result = try store.applyRetentionCleanup(userConfirmed: true)

        XCTAssertEqual(result.deletedMeetingIDs, [expiredID])
        XCTAssertFalse(FileManager.default.fileExists(atPath: bundleStore.bundleURL(for: expiredID).path))
        XCTAssertEqual(store.retentionCleanupPlan?.candidates, [])
        XCTAssertEqual(store.retentionCleanupStatus, "Deleted 1 expired recording bundle")
        XCTAssertEqual(store.privacyAuditReview.rows.first?.action, .retentionDelete)
        XCTAssertEqual(store.privacyAuditReview.rows.first?.meetingID, expiredID)
        XCTAssertEqual(store.privacyAuditReview.rows.first?.metadata["retentionDays"], "30")
        XCTAssertEqual(store.privacyAuditReview.rows.first?.metadata["ageDays"], "91")
        XCTAssertFalse(store.privacyAuditReview.rows.first?.metadata.values.contains { $0.contains("Expired retention") } ?? true)
    }

    func testLibraryDeleteRemovesSelectedRecordingAndPrivacyAuditsReason() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultStoreLibraryDelete-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let keyData = Data(repeating: 124, count: 32)
        let keyProvider = InMemorySymmetricKeyProvider(keyData: keyData)
        let store = MeetingVaultStore(libraryRoot: root, keyProvider: keyProvider)
        let bundleStore = EncryptedMeetingBundleStore(
            rootDirectory: root,
            vault: AESGCMDataVault(keyProvider: InMemorySymmetricKeyProvider(keyData: keyData))
        )
        let deletedID = try XCTUnwrap(store.selectedMeetingID)
        let originalCount = store.meetings.count

        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleStore.bundleURL(for: deletedID).path))

        let result = try store.deleteSelectedMeetingFromLibrary()

        XCTAssertEqual(result.meetingID, deletedID)
        XCTAssertEqual(result.reason, .userRequested)
        XCTAssertEqual(store.meetings.count, originalCount - 1)
        XCTAssertFalse(store.meetings.contains { $0.id == deletedID })
        XCTAssertNotEqual(store.selectedMeetingID, deletedID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bundleStore.bundleURL(for: deletedID).path))
        XCTAssertEqual(store.libraryDeleteStatus, "Deleted recording from local library")
        XCTAssertEqual(store.privacyAuditReview.rows.first?.action, .meetingDelete)
        XCTAssertEqual(store.privacyAuditReview.rows.first?.meetingID, deletedID)
        XCTAssertEqual(store.privacyAuditReview.rows.first?.metadata["reason"], "userRequested")
    }
}

private final class CapturingStorePlaybackEngine: TranscriptAudioEngine, @unchecked Sendable {
    private(set) var playedAudioData: Data?
    private(set) var playedCueIDs: [UUID] = []
    private(set) var pauseCount = 0
    private(set) var stopCount = 0

    func play(audioFragments: [TranscriptPlaybackAudioDataFragment], cue: TranscriptPlaybackCue) throws {
        playedAudioData = audioFragments.first?.audioData
        playedCueIDs.append(cue.segmentID)
    }

    func playRange(audioFragments: [TranscriptPlaybackAudioDataFragment], range _: TranscriptPlaybackRange) throws {
        playedAudioData = audioFragments.first?.audioData
    }

    func pause() throws {
        pauseCount += 1
    }

    func stop() throws {
        stopCount += 1
    }
}

@MainActor
private func waitUntil(
    _ description: String,
    timeoutNanoseconds: UInt64 = 1_000_000_000,
    pollNanoseconds: UInt64 = 20_000_000,
    condition: () -> Bool
) async throws {
    var elapsed: UInt64 = 0
    while !condition() && elapsed < timeoutNanoseconds {
        try await Task.sleep(nanoseconds: pollNanoseconds)
        elapsed += pollNanoseconds
    }
    XCTAssertTrue(condition(), "Timed out waiting for \(description)")
}

private actor ControlledTranscriptCorrectionRegenerationGate {
    private var entryCounts: [UUID: Int] = [:]
    private var continuations: [UUID: [CheckedContinuation<Void, Never>]] = [:]

    func suspend(meetingID: UUID) async {
        entryCounts[meetingID, default: 0] += 1
        await withCheckedContinuation { continuation in
            continuations[meetingID, default: []].append(continuation)
        }
    }

    func entryCount(meetingID: UUID) -> Int {
        entryCounts[meetingID, default: 0]
    }

    func release(meetingID: UUID) {
        let waiting = continuations.removeValue(forKey: meetingID) ?? []
        waiting.forEach { $0.resume() }
    }
}

private actor ControlledNonCooperativeTranscriptQuestionProvider: TranscriptQuestionAnsweringProviding {
    private var requests: [(question: String, transcript: MeetingTranscript)] = []
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private(set) var completionCount = 0

    var entryCount: Int {
        requests.count
    }

    func answer(question: String, transcript: MeetingTranscript) async throws -> TranscriptQuestionAnswer {
        requests.append((question, transcript))
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
        completionCount += 1
        let segment = transcript.segments[0]
        return TranscriptQuestionAnswer(
            meetingID: transcript.meetingID,
            transcriptVersion: transcript.transcriptVersion,
            transcriptDigest: try LocalFinalTranscriptionService.transcriptDigest(transcript),
            question: question,
            answerText: "Non-cooperative grounded answer.",
            editableText: "Non-cooperative grounded answer.",
            evidence: [
                TranscriptQuestionEvidence(
                    segmentID: segment.id,
                    speakerName: segment.speakerName,
                    startTime: segment.startTime,
                    endTime: segment.endTime,
                    quote: segment.text
                )
            ]
        )
    }

    func releaseNext() {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume()
    }

    func releaseAll() {
        let waiting = continuations
        continuations.removeAll()
        waiting.forEach { $0.resume() }
    }
}

private func waitForTranscriptCorrectionGate(
    _ gate: ControlledTranscriptCorrectionRegenerationGate,
    meetingID: UUID
) async throws {
    for _ in 0..<100 {
        if await gate.entryCount(meetingID: meetingID) > 0 {
            return
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("Timed out waiting for transcript correction regeneration gate")
}

private func waitForTranscriptQuestionProvider(
    _ provider: ControlledNonCooperativeTranscriptQuestionProvider,
    entryCount: Int
) async throws {
    for _ in 0..<100 {
        if await provider.entryCount >= entryCount {
            return
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("Timed out waiting for non-cooperative transcript question provider")
}

private func waitForTranscriptQuestionProviderCompletions(
    _ provider: ControlledNonCooperativeTranscriptQuestionProvider
) async throws {
    for _ in 0..<100 {
        let completionCount = await provider.completionCount
        let entryCount = await provider.entryCount
        if completionCount == entryCount {
            return
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("Timed out waiting for non-cooperative transcript question provider completion")
}

private final class CapturingStoreSelectedMicrophoneCapturer: SelectedMicrophoneAudioCapturing, @unchecked Sendable {
    private let lock = NSLock()
    private let chunk: CapturedAudioChunk
    private var storage: [SelectedMicrophoneCaptureRequest] = []

    var requests: [SelectedMicrophoneCaptureRequest] {
        lock.withLock { storage }
    }

    init(chunk: CapturedAudioChunk) {
        self.chunk = chunk
    }

    func capture(_ request: SelectedMicrophoneCaptureRequest) async throws -> CapturedAudioChunk {
        lock.withLock {
            storage.append(request)
        }
        return chunk
    }
}

private final class StopControlledStoreSelectedMicrophoneCapturer: SelectedMicrophoneAudioCapturing, @unchecked Sendable {
    private let lock = NSLock()
    private let chunk: CapturedAudioChunk
    private var storage: [SelectedMicrophoneCaptureRequest] = []
    private var didObserveStop = false

    var requests: [SelectedMicrophoneCaptureRequest] {
        lock.withLock { storage }
    }

    var stopObserved: Bool {
        lock.withLock { didObserveStop }
    }

    init(chunk: CapturedAudioChunk) {
        self.chunk = chunk
    }

    func capture(_ request: SelectedMicrophoneCaptureRequest) async throws -> CapturedAudioChunk {
        lock.withLock {
            storage.append(request)
        }
        await request.stopSignal?.waitUntilStopped()
        lock.withLock {
            didObserveStop = true
        }
        return chunk
    }
}

private final class CheckpointThenWaitStoreSelectedMicrophoneCapturer: SelectedMicrophoneAudioCapturing, @unchecked Sendable {
    private let lock = NSLock()
    private let chunk: CapturedAudioChunk
    private var storage: [SelectedMicrophoneCaptureRequest] = []
    private var didWriteCheckpoint = false
    private var didObserveStop = false

    var requests: [SelectedMicrophoneCaptureRequest] {
        lock.withLock { storage }
    }

    var checkpointWritten: Bool {
        lock.withLock { didWriteCheckpoint }
    }

    var stopObserved: Bool {
        lock.withLock { didObserveStop }
    }

    init(chunk: CapturedAudioChunk) {
        self.chunk = chunk
    }

    func capture(_ request: SelectedMicrophoneCaptureRequest) async throws -> CapturedAudioChunk {
        lock.withLock {
            storage.append(request)
        }
        try request.chunkSink?.write(chunk)
        lock.withLock {
            didWriteCheckpoint = true
        }
        await request.stopSignal?.waitUntilStopped()
        lock.withLock {
            didObserveStop = true
        }
        return chunk
    }
}

private final class PreviewDropThenWaitStoreSelectedMicrophoneCapturer: SelectedMicrophoneAudioCapturing, @unchecked Sendable {
    func capture(_ request: SelectedMicrophoneCaptureRequest) async throws -> CapturedAudioChunk {
        let chunk = CapturedAudioChunk(
            track: .microphone,
            data: Data(repeating: 0, count: 128),
            startTime: 0,
            duration: 1,
            codec: "AVFoundation/PCM"
        )
        try request.chunkSink?.write(chunk)
        for _ in 0..<64 {
            _ = try request.frameEmitter?.emitCanonicalPCM(
                Data(repeating: 0, count: 128),
                sampleRate: 16_000,
                channelCount: 1,
                frameCount: 32,
                track: .microphone
            )
        }
        await request.stopSignal?.waitUntilStopped()
        return chunk
    }
}

private final class PreviewDropThenFailStoreSelectedMicrophoneCapturer: SelectedMicrophoneAudioCapturing, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [SelectedMicrophoneCaptureRequest] = []

    var requests: [SelectedMicrophoneCaptureRequest] {
        lock.withLock { storage }
    }

    func capture(_ request: SelectedMicrophoneCaptureRequest) async throws -> CapturedAudioChunk {
        lock.withLock { storage.append(request) }
        let chunk = CapturedAudioChunk(
            track: .microphone,
            data: Data(repeating: 0, count: 128),
            startTime: 0,
            duration: 1,
            codec: "AVFoundation/PCM"
        )
        try request.chunkSink?.write(chunk)
        for _ in 0..<64 {
            _ = try request.frameEmitter?.emitCanonicalPCM(
                Data(repeating: 0, count: 128),
                sampleRate: 16_000,
                channelCount: 1,
                frameCount: 32,
                track: .microphone
            )
        }
        throw StoreInterruptedCaptureFixtureError.disconnected
    }
}

private struct SlowStoreLocalTranscriptionProvider: LocalTranscriptionProviding {
    let submissionDelay: Duration
    let descriptor = ProviderDescriptor(
        id: "slow-store-preview-fixture",
        modelVersion: "1",
        supportedLocaleIdentifiers: ["en-US", "pl-PL"]
    )

    init(submissionDelay: Duration = .seconds(5)) {
        self.submissionDelay = submissionDelay
    }

    func makeSession(_ configuration: TranscriptionSessionConfiguration) async throws
        -> any LocalTranscriptionSession {
        SlowStoreLocalTranscriptionSession(submissionDelay: submissionDelay)
    }
}

private final class SlowStoreLocalTranscriptionSession: LocalTranscriptionSession, @unchecked Sendable {
    let events: AsyncThrowingStream<LocalTranscriptionEvent, Error>
    private let continuation: AsyncThrowingStream<LocalTranscriptionEvent, Error>.Continuation
    private let submissionDelay: Duration

    init(submissionDelay: Duration) {
        let pair = AsyncThrowingStream<LocalTranscriptionEvent, Error>.makeStream()
        events = pair.stream
        continuation = pair.continuation
        self.submissionDelay = submissionDelay
    }

    func submit(_ frame: CapturedPCMFrame) async throws {
        try await Task.sleep(for: submissionDelay)
    }

    func finish() async throws {
        continuation.finish()
    }

    func cancel() async {
        continuation.finish()
    }
}

private enum StoreInterruptedCaptureFixtureError: Error, LocalizedError {
    case disconnected

    var errorDescription: String? {
        "Selected microphone disconnected during capture"
    }
}

private final class FailingStoreSelectedMicrophoneCapturer: SelectedMicrophoneAudioCapturing, @unchecked Sendable {
    private let lock = NSLock()
    private let chunk: CapturedAudioChunk
    private var storage: [SelectedMicrophoneCaptureRequest] = []

    var requests: [SelectedMicrophoneCaptureRequest] {
        lock.withLock { storage }
    }

    init(chunk: CapturedAudioChunk) {
        self.chunk = chunk
    }

    func capture(_ request: SelectedMicrophoneCaptureRequest) async throws -> CapturedAudioChunk {
        lock.withLock {
            storage.append(request)
        }
        try request.chunkSink?.write(chunk)
        throw StoreInterruptedCaptureFixtureError.disconnected
    }
}

private final class CapturingStoreCoreAudioTapCapturer: CoreAudioTapCapturing, @unchecked Sendable {
    private let lock = NSLock()
    private let chunk: CapturedAudioChunk
    private var storage: [CoreAudioTapCaptureRequest] = []

    var requests: [CoreAudioTapCaptureRequest] {
        lock.withLock { storage }
    }

    init(chunk: CapturedAudioChunk) {
        self.chunk = chunk
    }

    func capture(_ request: CoreAudioTapCaptureRequest) async throws -> CapturedAudioChunk {
        lock.withLock {
            storage.append(request)
        }
        return chunk
    }
}

private final class CapturingStoreScreenCaptureKitSystemAudioCapturer: ScreenCaptureKitSystemAudioCapturing, @unchecked Sendable {
    private let lock = NSLock()
    private let chunk: CapturedAudioChunk
    private var storage: [ScreenCaptureKitAudioCaptureRequest] = []

    var requests: [ScreenCaptureKitAudioCaptureRequest] {
        lock.withLock { storage }
    }

    init(chunk: CapturedAudioChunk) {
        self.chunk = chunk
    }

    func capture(_ request: ScreenCaptureKitAudioCaptureRequest) async throws -> CapturedAudioChunk {
        lock.withLock {
            storage.append(request)
        }
        return chunk
    }
}

private final class CapturingStoreTranscriptQuestionProvider: TranscriptQuestionAnsweringProviding, @unchecked Sendable {
    private let lock = NSLock()
    private let error: Error?
    private let delayNanoseconds: UInt64
    private var storedQuestions: [String] = []
    private var storedSegmentCounts: [Int] = []

    init(error: Error? = nil, delayNanoseconds: UInt64 = 0) {
        self.error = error
        self.delayNanoseconds = delayNanoseconds
    }

    var questions: [String] {
        lock.withLock { storedQuestions }
    }

    var segmentCounts: [Int] {
        lock.withLock { storedSegmentCounts }
    }

    func answer(question: String, transcript: MeetingTranscript) async throws -> TranscriptQuestionAnswer {
        lock.withLock {
            storedQuestions.append(question)
            storedSegmentCounts.append(transcript.segments.count)
        }
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        if let error {
            throw error
        }
        let segment = transcript.segments[0]
        return TranscriptQuestionAnswer(
            meetingID: transcript.meetingID,
            transcriptVersion: transcript.transcriptVersion,
            transcriptDigest: try LocalFinalTranscriptionService.transcriptDigest(transcript),
            question: question,
            answerText: "Foundation Models grounded answer.",
            editableText: "Foundation Models grounded answer.",
            evidence: [
                TranscriptQuestionEvidence(
                    segmentID: segment.id,
                    speakerName: segment.speakerName,
                    startTime: segment.startTime,
                    endTime: segment.endTime,
                    quote: segment.text
                )
            ]
        )
    }
}

private final class CapturingStoreShareExecutor: MeetingShareExecuting {
    private(set) var executedManifests: [MeetingShareManifest] = []

    func execute(_ manifest: MeetingShareManifest) throws -> MeetingShareExecutionResult {
        executedManifests.append(manifest)
        return MeetingShareExecutionResult(
            destination: manifest.destination,
            fileCount: manifest.files.count
        )
    }
}

private final class CapturingStoreSystemIntegrationExecutor: MeetingSystemIntegrationExecuting, @unchecked Sendable {
    private(set) var executedProposals: [MeetingSystemIntegrationProposal] = []

    func executeSystemIntegration(
        proposals: [MeetingSystemIntegrationProposal],
        executedAt: Date
    ) throws -> [MeetingSystemIntegrationWriteReceipt] {
        executedProposals = proposals
        return proposals.map { proposal in
            MeetingSystemIntegrationWriteReceipt(
                proposalID: proposal.id,
                kind: proposal.kind,
                executedAt: executedAt
            )
        }
    }
}

private final class FakeCalendarReminderWriter: CalendarReminderWriting {
    struct SavedEvent: Equatable {
        var title: String
        var notes: String
        var scheduledAt: Date
    }

    struct SavedReminder: Equatable {
        var title: String
        var notes: String
        var dueDate: Date?
    }

    var eventAuthorizationStatus: EKAuthorizationStatus
    var reminderAuthorizationStatus: EKAuthorizationStatus
    var reminderError: Error?
    private(set) var savedEvents: [SavedEvent] = []
    private(set) var savedReminders: [SavedReminder] = []

    init(
        eventAuthorizationStatus: EKAuthorizationStatus,
        reminderAuthorizationStatus: EKAuthorizationStatus
    ) {
        self.eventAuthorizationStatus = eventAuthorizationStatus
        self.reminderAuthorizationStatus = reminderAuthorizationStatus
    }

    func saveCalendarEvent(
        title: String,
        notes: String,
        scheduledAt: Date
    ) throws {
        savedEvents.append(
            SavedEvent(title: title, notes: notes, scheduledAt: scheduledAt)
        )
    }

    func saveReminder(
        title: String,
        notes: String,
        dueDate: Date?
    ) throws {
        if let reminderError { throw reminderError }
        savedReminders.append(
            SavedReminder(title: title, notes: notes, dueDate: dueDate)
        )
    }
}

private enum TestSystemWriteError: Error {
    case failed
}

private final class FakeContactReviewWriter: ContactReviewWriting {
    struct SavedContact: Equatable {
        var displayName: String
        var note: String
    }

    var contactAuthorizationStatus: CNAuthorizationStatus
    private(set) var savedContacts: [SavedContact] = []

    init(contactAuthorizationStatus: CNAuthorizationStatus) {
        self.contactAuthorizationStatus = contactAuthorizationStatus
    }

    func saveContactReview(
        displayName: String,
        note: String
    ) throws {
        savedContacts.append(SavedContact(displayName: displayName, note: note))
    }
}

private final class CapturingPermissionSettingsOpener: PermissionSettingsOpening {
    private(set) var openedActions: [PermissionRecoveryAction] = []
    var shouldOpen = true

    func openSettings(for action: PermissionRecoveryAction) -> Bool {
        openedActions.append(action)
        return shouldOpen
    }
}

private final class CapturingStoreSpeechAuthorizationProvider: SpeechRecognitionAuthorizationProviding, @unchecked Sendable {
    private let lock = NSLock()
    private let requestedState: SpeechRecognitionAuthorizationState
    private var currentState: SpeechRecognitionAuthorizationState
    private var currentReads = 0
    private var requests = 0

    init(
        currentState: SpeechRecognitionAuthorizationState,
        requestedState: SpeechRecognitionAuthorizationState
    ) {
        self.currentState = currentState
        self.requestedState = requestedState
    }

    var currentReadCount: Int {
        lock.withLock { currentReads }
    }

    var requestCount: Int {
        lock.withLock { requests }
    }

    func currentAuthorizationState() -> SpeechRecognitionAuthorizationState {
        lock.withLock {
            currentReads += 1
            return currentState
        }
    }

    func requestAuthorizationState() async -> SpeechRecognitionAuthorizationState {
        lock.withLock {
            requests += 1
            currentState = requestedState
            return requestedState
        }
    }
}

private final class CapturingStoreMicrophoneAuthorizationProvider: MicrophoneAuthorizationProviding, @unchecked Sendable {
    private let lock = NSLock()
    private let requestedState: PermissionAuthorizationStatus
    private var currentState: PermissionAuthorizationStatus
    private var currentReads = 0
    private var requests = 0

    init(
        currentState: PermissionAuthorizationStatus,
        requestedState: PermissionAuthorizationStatus
    ) {
        self.currentState = currentState
        self.requestedState = requestedState
    }

    var currentReadCount: Int {
        lock.withLock { currentReads }
    }

    var requestCount: Int {
        lock.withLock { requests }
    }

    func currentAuthorizationStatus() -> PermissionAuthorizationStatus {
        lock.withLock {
            currentReads += 1
            return currentState
        }
    }

    func requestAuthorizationStatus() async -> PermissionAuthorizationStatus {
        lock.withLock {
            requests += 1
            currentState = requestedState
            return requestedState
        }
    }
}

private struct MockRecordingStorageCapacityChecker: RecordingStorageCapacityChecking {
    static let available = MockRecordingStorageCapacityChecker(availableBytes: 100 * 1_024 * 1_024 * 1_024)

    var availableBytes: Int64

    func availableCapacityBytes(for directoryURL: URL) throws -> Int64 {
        availableBytes
    }
}

private final class FailingKeychainStore: KeychainStoring, @unchecked Sendable {
    private let status: OSStatus

    init(status: OSStatus) {
        self.status = status
    }

    func load(service: String, account: String) throws -> Data? {
        throw EncryptionError.keychainReadFailed(status)
    }

    func save(_ data: Data, service: String, account: String) throws {
        throw EncryptionError.keychainWriteFailed(status)
    }
}
