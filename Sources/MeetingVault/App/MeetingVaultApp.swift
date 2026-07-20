import AppKit
import Foundation
import MeetingVaultCore
import SwiftUI

@main
struct MeetingVaultApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store: MeetingVaultStore
    @StateObject private var appearanceCoordinator: MeetingVaultAppearanceCoordinator
    @StateObject private var miniRecorderPreferences: MiniRecorderPresentationPreferences
    @StateObject private var miniRecorderCoordinator: MiniRecorderWindowCoordinator
    @StateObject private var localModelPrivacyCenter: LocalModelPrivacyCenterStore
    private let mainWindowPresenter: MainWindowPresenter

    @MainActor
    init() {
        let privacyPreferences = TranscriptionPrivacyModeStore()
        let privacyBoundary = TranscriptionPrivacyBoundary(modeStore: privacyPreferences)
        let privacyActivityGate = TranscriptionRuntimeActivityGate()
        let activeLibraryRoot = MeetingVaultLaunchStoreFactory.configuredLibraryRoot()
        let modelRuntime = try? LocalModelPrivacyCenterStore.makeProductionRuntime(
            libraryRoot: activeLibraryRoot
        )
        let store = MeetingVaultLaunchStoreFactory.makeStore(
            transcriptionPrivacyBoundary: privacyBoundary,
            transcriptionActivityGate: privacyActivityGate,
            localModelRuntime: modelRuntime?.service
        )
        let appearanceCoordinator = MeetingVaultAppearanceCoordinator()
        let miniRecorderPreferences = MiniRecorderPresentationPreferences()
        let mainWindowPresenter = MainWindowPresenter()
        let miniRecorderCoordinator = MiniRecorderWindowCoordinator(
            store: store,
            appearanceCoordinator: appearanceCoordinator,
            preferences: miniRecorderPreferences,
            mainWindowPresenter: mainWindowPresenter
        )
        _store = StateObject(wrappedValue: store)
        _appearanceCoordinator = StateObject(wrappedValue: appearanceCoordinator)
        _miniRecorderPreferences = StateObject(wrappedValue: miniRecorderPreferences)
        _miniRecorderCoordinator = StateObject(wrappedValue: miniRecorderCoordinator)
        let modelCenter = modelRuntime.map {
            LocalModelPrivacyCenterStore.production(
                runtime: $0,
                privacyPreferences: privacyPreferences,
                privacyBoundary: privacyBoundary,
                activityGate: privacyActivityGate,
                recordingIsActive: { store.privacyTransitionIsBlocked },
                restartProvider: { await store.restartLiveTranscriptionForPrivacyTransition() },
                modelStateDidChange: { await store.refreshTranscriptionModelReadiness() }
            )
        } ?? LocalModelPrivacyCenterStore.production(
            libraryRoot: activeLibraryRoot,
            privacyPreferences: privacyPreferences,
            privacyBoundary: privacyBoundary,
            activityGate: privacyActivityGate,
            recordingIsActive: { store.privacyTransitionIsBlocked },
            restartProvider: { await store.restartLiveTranscriptionForPrivacyTransition() },
            modelStateDidChange: { await store.refreshTranscriptionModelReadiness() }
        )
        _localModelPrivacyCenter = StateObject(wrappedValue: modelCenter)
        self.mainWindowPresenter = mainWindowPresenter
    }

    var body: some Scene {
        WindowGroup("MeetingVault", id: "main") {
            let launchAccessibilityTraits = MeetingVaultLaunchAccessibilityTraits.fromArguments()
            ContentView()
                .environmentObject(store)
                .environmentObject(appearanceCoordinator)
                .environmentObject(miniRecorderPreferences)
                .resolvedReduceMotion(launchAccessibilityTraits.reduceMotion)
                .launchIncreasedContrastOverride(launchAccessibilityTraits.increasedContrast)
                .frame(minWidth: 1180, minHeight: 640)
                .background(MainWindowPresenterConfiguration(
                    mainWindowPresenter: mainWindowPresenter
                ))
                .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in
                    Task { await store.handleSystemSleepInterruption() }
                }
        }
        .commands {
            MeetingVaultCommands(
                store: store,
                miniRecorderCoordinator: miniRecorderCoordinator
            )
        }

        Window("Health & Recovery", id: HealthRecoveryPresentation.windowID) {
            HealthRecoveryWindowView()
                .environmentObject(store)
                .environmentObject(appearanceCoordinator)
                .frame(minWidth: 720, minHeight: 560)
        }
        .defaultSize(width: 980, height: 760)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        MenuBarExtra {
            Group {
                Button {
                    performRecordingAction()
                } label: {
                    Label(transport.title, systemImage: transport.symbol)
                }
                .disabled(!transport.isEnabled)
                .accessibilityLabel(transport.accessibilityLabel)
                .accessibilityHint(transport.accessibilityHint)
                Button("Run Preflight") {
                    store.runPreflight()
                }
                Divider()
                Button("Open MeetingVault") {
                    miniRecorderCoordinator.showMainWindow()
                }
                Button("Show Mini Recorder") {
                    miniRecorderCoordinator.show(activate: false)
                }
                .disabled(!miniRecorderCanBeShown)
            }
            .environmentObject(appearanceCoordinator)
            .environmentObject(miniRecorderPreferences)
        } label: {
            Label("MeetingVault", systemImage: store.recordingState == .recording ? "record.circle.fill" : "waveform")
        }

        Settings {
            SettingsView()
                .environmentObject(store)
                .environmentObject(appearanceCoordinator)
                .environmentObject(miniRecorderPreferences)
                .environmentObject(localModelPrivacyCenter)
                .frame(minWidth: 640, minHeight: 620)
        }
    }

    private var transport: MeetingRecordingTransportPresentation {
        store.recordingTransportPresentation
    }

    private func performRecordingAction() {
        switch transport.action {
        case .start:
            store.startRecordingIntent()
        case .stop:
            store.stopRecordingIntent()
        case nil:
            break
        }
    }

    private var miniRecorderCanBeShown: Bool {
        store.recordingState == .recording || store.recordingState == .processing
    }
}

struct MeetingVaultCommands: Commands {
    @ObservedObject var store: MeetingVaultStore
    @ObservedObject var miniRecorderCoordinator: MiniRecorderWindowCoordinator
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        SidebarCommands()
        InspectorCommands()

        CommandMenu("Workspace") {
            Button("Meetings") {
                store.showWorkspace(.meetings)
            }
            .keyboardShortcut("1", modifiers: [.command])

            Button("Import Recording") {
                store.showWorkspace(.find)
            }

            Button("Recording Setup") {
                store.showWorkspace(.record)
            }
            .keyboardShortcut("2", modifiers: [.command])

            Button("Agent") {
                store.showWorkspace(.understand)
            }
            .keyboardShortcut("3", modifiers: [.command])

            Button("Export Meeting") {
                store.showWorkspace(.export)
            }

            Button("Health & Diagnostics") {
                store.requestHealthRecoveryPresentation()
                openWindow(id: HealthRecoveryPresentation.windowID)
            }
            .keyboardShortcut("4", modifiers: [.command])
        }

        CommandMenu("Recording") {
            Button("Run Preflight") {
                store.runPreflight()
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])

            Button {
                performRecordingAction()
            } label: {
                Label(transport.title, systemImage: transport.symbol)
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(!transport.isEnabled)

            Button("Mark Moment") {
                store.markMomentIntent()
            }
            .keyboardShortcut("m", modifiers: [.command, .shift])
            .disabled(!store.recordingBookmarkPresentation.isEnabled)

            Button("Show Mini Recorder") {
                miniRecorderCoordinator.show(activate: false)
            }
            .keyboardShortcut("0", modifiers: [.command, .shift])
            .disabled(store.recordingState != .recording && store.recordingState != .processing)
        }
    }

    private var transport: MeetingRecordingTransportPresentation {
        store.recordingTransportPresentation
    }

    private func performRecordingAction() {
        switch transport.action {
        case .start:
            store.startRecordingIntent()
        case .stop:
            store.stopRecordingIntent()
        case nil:
            break
        }
    }
}

private struct MainWindowPresenterConfiguration: View {
    @Environment(\.openWindow) private var openWindow
    let mainWindowPresenter: MainWindowPresenter

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onAppear {
                mainWindowPresenter.configureOpenMainWindow {
                    openWindow(id: "main")
                }
            }
    }
}

enum MeetingVaultLaunchStoreFactory {
    static func configuredLibraryRoot(
        arguments: [String] = CommandLine.arguments
    ) -> URL? {
        let path = value(after: "--ui-smoke-library-root", in: arguments)
            ?? value(after: "--library-root", in: arguments)
        return path.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
    }

    @MainActor
    static func makeStore(
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        transcriptionPrivacyBoundary: TranscriptionPrivacyBoundary? = nil,
        transcriptionActivityGate: TranscriptionRuntimeActivityGate? = nil,
        localModelRuntime: (any LocalModelRuntimeSessionProviding)? = nil
    ) -> MeetingVaultStore {
        let store: MeetingVaultStore
        if let smokeRoot = value(after: "--ui-smoke-library-root", in: arguments) {
            let runtime = MeetingVaultLaunchRuntimeConfiguration.demo
            let smokeRootURL = URL(fileURLWithPath: smokeRoot, isDirectory: true).standardizedFileURL
            store = MeetingVaultStore(
                permissionProvider: makePermissionProvider(arguments: arguments),
                libraryRoot: smokeRootURL,
                keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 0x42, count: 32)),
                storageCapacityChecker: makeStorageCapacityChecker(arguments: arguments),
                audioInputDeviceProvider: MockAudioInputDeviceProvider(
                    devices: [
                        AudioInputDevice(
                            id: "ui-smoke-studio-microphone",
                            displayName: "Studio Microphone",
                            transportLabel: "Synthetic Input",
                            isDefault: true,
                            isConnected: true,
                            level: 0.64
                        )
                    ]
                ),
                captureRuntimeMode: runtime.capture,
                liveTranscriptionRuntimeMode: runtime.liveTranscription,
                finalTranscriptionRuntimeMode: runtime.finalTranscription,
                intelligenceRuntimeMode: runtime.intelligence,
                transcriptQuestionRuntimeMode: runtime.transcriptQuestion,
                transcriptionPrivacyBoundary: transcriptionPrivacyBoundary,
                transcriptionActivityGate: transcriptionActivityGate,
                microphoneAuthorizationProvider: makeMicrophoneAuthorizationProvider(arguments: arguments),
                speechRecognitionAuthorizationProvider: makeSpeechRecognitionAuthorizationProvider(arguments: arguments),
                includeSampleData: true
            )
            seedUISmokeLocalRecordingFixture(in: smokeRootURL, store: store)
        } else {
            let profile = MeetingVaultLaunchRuntimeProfile.from(arguments: arguments, environment: environment)
            if profile == .production {
                do {
                    try MeetingVaultLaunchRuntimeConfiguration.validateProductionEnvironment(environment)
                } catch {
                    preconditionFailure(error.localizedDescription)
                }
            }
            let runtime = MeetingVaultLaunchRuntimeConfiguration.resolve(profile: profile, environment: environment)
            let libraryRoot = value(after: "--library-root", in: arguments)
                .map { URL(fileURLWithPath: $0, isDirectory: true) }
            let keyProviderMode = MeetingVaultLaunchKeyProviderMode.from(
                arguments: arguments,
                environment: environment
            )
            store = MeetingVaultStore(
                libraryRoot: libraryRoot,
                keyProvider: makeKeyProvider(mode: keyProviderMode, libraryRoot: libraryRoot),
                storageCapacityChecker: makeStorageCapacityChecker(arguments: arguments),
                captureRuntimeMode: runtime.capture,
                liveTranscriptionRuntimeMode: runtime.liveTranscription,
                finalTranscriptionRuntimeMode: runtime.finalTranscription,
                intelligenceRuntimeMode: runtime.intelligence,
                transcriptQuestionRuntimeMode: runtime.transcriptQuestion,
                localModelRuntime: localModelRuntime,
                transcriptionPrivacyBoundary: transcriptionPrivacyBoundary,
                transcriptionActivityGate: transcriptionActivityGate,
                includeSampleData: profile == .demo
            )
        }

        if let retentionDaysValue = value(after: "--ui-smoke-retention-days", in: arguments),
           let retentionDays = Int(retentionDaysValue),
           retentionDays > 0 {
            store.retentionDays = retentionDays
        }
        if arguments.contains("--ui-smoke-meeting-context") {
            store.meetingContextDraft = MeetingContext(
                participantNames: ["synthetic-private-participant"],
                vocabulary: ["synthetic-private-vocabulary"]
            )
        }

        return store
    }

    @MainActor
    static func seedUISmokeLocalRecordingFixture(
        in smokeRoot: URL,
        store: MeetingVaultStore
    ) {
        let fixtureDirectory = smokeRoot
            .appendingPathComponent("UI Smoke Fixtures", isDirectory: true)
            .standardizedFileURL
        let transcriptURL = fixtureDirectory
            .appendingPathComponent("20260716 1200 Transcription.txt")
            .standardizedFileURL
        let audioURL = fixtureDirectory
            .appendingPathComponent("20260716 1200.wav")
            .standardizedFileURL
        do {
            try FileManager.default.createDirectory(
                at: fixtureDirectory,
                withIntermediateDirectories: true
            )
            try Data("00:00 Speaker: Synthetic planning session fixture.\n".utf8)
                .write(to: transcriptURL, options: .atomic)
            try Data(repeating: 0, count: 4_096)
                .write(to: audioURL, options: .atomic)
        } catch {
            preconditionFailure("Could not create isolated UI smoke import fixture")
        }

        let candidate = LocalRecordingSampleCandidate(
            timestampKey: "20260716 1200",
            title: "Synthetic Planning Session",
            transcriptURL: transcriptURL,
            audioURL: audioURL,
            audioByteCount: 4_096
        )
        store.localRecordingSamples = [candidate]
        store.selectedLocalRecordingSampleID = candidate.id
        store.localRecordingTranscriptPath = transcriptURL.path
        store.localRecordingAudioPath = audioURL.path
        store.localRecordingSampleStatus = "Found 1 isolated synthetic recording sample"
    }

    static func makeStorageCapacityChecker(arguments: [String]) -> any RecordingStorageCapacityChecking {
        guard let bytesValue = value(after: "--ui-smoke-storage-bytes", in: arguments),
              let bytes = Int64(bytesValue) else {
            return SystemRecordingStorageCapacityChecker()
        }
        return FixedRecordingStorageCapacityChecker(availableBytes: bytes)
    }

    static func makePermissionProvider(arguments: [String]) -> any PermissionProviding {
        guard let status = uiSmokePermissionStatus(arguments: arguments) else {
            return SystemPermissionProvider()
        }
        return MockPermissionProvider(
            snapshot: PermissionSnapshot(
                systemAudio: status,
                microphone: status,
                speechRecognition: status
            )
        )
    }

    static func makeMicrophoneAuthorizationProvider(
        arguments: [String]
    ) -> any MicrophoneAuthorizationProviding {
        guard let status = uiSmokePermissionStatus(arguments: arguments) else {
            return SystemMicrophoneAuthorizationProvider()
        }
        return FixedUISmokeMicrophoneAuthorizationProvider(status: status)
    }

    static func makeSpeechRecognitionAuthorizationProvider(
        arguments: [String]
    ) -> any SpeechRecognitionAuthorizationProviding {
        guard let status = uiSmokePermissionStatus(arguments: arguments) else {
            return SystemSpeechRecognitionAuthorizationProvider()
        }
        let state: SpeechRecognitionAuthorizationState
        switch status {
        case .authorized:
            state = .authorized
        case .denied:
            state = .denied
        case .restricted:
            state = .restricted
        case .notDetermined:
            state = .notDetermined
        case .unknown:
            state = .unknown
        }
        return FixedUISmokeSpeechAuthorizationProvider(state: state)
    }

    private static func uiSmokePermissionStatus(
        arguments: [String]
    ) -> PermissionAuthorizationStatus? {
        guard let value = value(after: "--ui-smoke-permissions", in: arguments) else {
            return nil
        }
        switch value.lowercased() {
        case "authorized", "allow", "allowed", "ready":
            return .authorized
        case "restricted":
            return .restricted
        case "not-determined", "notdetermined", "prompt":
            return .notDetermined
        case "unknown":
            return .unknown
        default:
            return .denied
        }
    }

    private struct FixedUISmokeMicrophoneAuthorizationProvider: MicrophoneAuthorizationProviding {
        var status: PermissionAuthorizationStatus

        func currentAuthorizationStatus() -> PermissionAuthorizationStatus {
            status
        }

        func requestAuthorizationStatus() async -> PermissionAuthorizationStatus {
            status
        }
    }

    private struct FixedUISmokeSpeechAuthorizationProvider: SpeechRecognitionAuthorizationProviding {
        var state: SpeechRecognitionAuthorizationState

        func currentAuthorizationState() -> SpeechRecognitionAuthorizationState {
            state
        }

        func requestAuthorizationState() async -> SpeechRecognitionAuthorizationState {
            state
        }
    }

    static func localFileKeyURL(libraryRoot: URL?) -> URL {
        if let libraryRoot {
            return libraryRoot
                .appendingPathComponent(".meetingvault", isDirectory: true)
                .appendingPathComponent("local-master-key.bin")
        }

        let supportRoot = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)

        return supportRoot
            .appendingPathComponent("MeetingVault", isDirectory: true)
            .appendingPathComponent("Secrets", isDirectory: true)
            .appendingPathComponent("local-master-key.bin")
    }

    static func makeKeyProvider(
        mode: MeetingVaultLaunchKeyProviderMode,
        libraryRoot: URL?
    ) -> any SymmetricKeyProvider {
        switch mode {
        case .localFile:
            FileBackedSymmetricKeyProvider(keyFileURL: localFileKeyURL(libraryRoot: libraryRoot))
        case .keychain:
            KeychainSymmetricKeyProvider()
        }
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag),
              arguments.indices.contains(arguments.index(after: index)) else {
            return nil
        }
        return arguments[arguments.index(after: index)]
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct FixedRecordingStorageCapacityChecker: RecordingStorageCapacityChecking {
    var availableBytes: Int64

    func availableCapacityBytes(for directoryURL: URL) throws -> Int64 {
        availableBytes
    }
}

enum MeetingVaultLaunchKeyProviderMode: Equatable {
    case localFile
    case keychain

    static func from(
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> MeetingVaultLaunchKeyProviderMode {
        if let argumentValue = value(after: "--key-provider", in: arguments) {
            return parse(argumentValue)
        }
        if let environmentValue = environment["MEETINGVAULT_KEY_PROVIDER"] {
            return parse(environmentValue)
        }
        return .localFile
    }

    private static func parse(_ value: String) -> MeetingVaultLaunchKeyProviderMode {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "keychain", "system-keychain", "system":
            .keychain
        default:
            .localFile
        }
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag),
              arguments.indices.contains(arguments.index(after: index)) else {
            return nil
        }
        return arguments[arguments.index(after: index)]
    }
}

enum MeetingVaultLaunchRuntimeProfile: Equatable {
    case production
    case demo

    static func from(
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> MeetingVaultLaunchRuntimeProfile {
        if arguments.contains("--demo-runtime") {
            return .demo
        }
        if arguments.contains("--production-runtime") {
            return .production
        }
        switch environment["MEETINGVAULT_RUNTIME_PROFILE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() {
        case "demo", "sample", "smoke":
            return .demo
        default:
            return .production
        }
    }
}

struct MeetingVaultLaunchRuntimeConfiguration: Equatable {
    var capture: MeetingVaultCaptureRuntimeMode
    var liveTranscription: MeetingVaultLiveTranscriptionRuntimeMode
    var finalTranscription: MeetingVaultFinalTranscriptionRuntimeMode
    var intelligence: MeetingVaultIntelligenceRuntimeMode
    var transcriptQuestion: MeetingVaultTranscriptQuestionRuntimeMode

    static let demo = MeetingVaultLaunchRuntimeConfiguration(
        capture: .mock,
        liveTranscription: .demo,
        finalTranscription: .demo,
        intelligence: .demo,
        transcriptQuestion: .deterministic
    )

    static func validateProductionEnvironment(_ environment: [String: String]) throws {
        let allowed: [String: Set<String>] = [
            "MEETINGVAULT_CAPTURE_RUNTIME": [
                "core-audio", "core_audio", "coreaudio", "tap", "process-tap", "system-tap",
                "system-and-microphone", "system_and_microphone", "meeting-audio", "meeting_audio", "combined",
                "selected-microphone", "selected_microphone", "microphone", "avfoundation",
                "screen-capture-kit", "screen_capture_kit", "screencapturekit", "screen-capture", "system-audio"
            ],
            "MEETINGVAULT_LIVE_TRANSCRIPTION": [
                "local", "local-only", "local_only", "fluidaudio",
                "apple-speech", "apple_speech", "speech", "sfspeech"
            ],
            "MEETINGVAULT_FINAL_TRANSCRIPTION": [
                "local", "local-only", "local_only", "fluidaudio",
                "apple-speech", "apple_speech", "speech", "sfspeech",
                "speech-analyzer", "speech_analyzer", "speechanalyzer"
            ],
            "MEETINGVAULT_INTELLIGENCE_RUNTIME": [
                "foundation-models", "foundation_models", "apple-intelligence", "apple_intelligence", "foundationmodels"
            ],
            "MEETINGVAULT_TRANSCRIPT_QA_RUNTIME": [
                "foundation-models", "foundation_models", "apple-intelligence", "apple_intelligence", "foundationmodels"
            ]
        ]

        for (key, values) in allowed {
            guard let rawValue = environment[key] else { continue }
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard values.contains(value) else {
                throw MeetingVaultLaunchConfigurationError.invalidProductionRuntime(key: key, value: rawValue)
            }
        }
    }

    static func resolve(
        profile: MeetingVaultLaunchRuntimeProfile,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> MeetingVaultLaunchRuntimeConfiguration {
        switch profile {
        case .demo:
            return .demo
        case .production:
            return MeetingVaultLaunchRuntimeConfiguration(
                capture: captureMode(environment: environment, defaultMode: .systemAndMicrophone),
                liveTranscription: liveTranscriptionMode(environment: environment, defaultMode: .local),
                finalTranscription: finalTranscriptionMode(environment: environment, defaultMode: .local),
                intelligence: intelligenceMode(environment: environment, defaultMode: .foundationModels),
                transcriptQuestion: transcriptQuestionMode(environment: environment, defaultMode: .foundationModels)
            )
        }
    }

    private static func captureMode(
        environment: [String: String],
        defaultMode: MeetingVaultCaptureRuntimeMode
    ) -> MeetingVaultCaptureRuntimeMode {
        environment.keys.contains("MEETINGVAULT_CAPTURE_RUNTIME")
            ? .fromEnvironment(environment)
            : defaultMode
    }

    private static func liveTranscriptionMode(
        environment: [String: String],
        defaultMode: MeetingVaultLiveTranscriptionRuntimeMode
    ) -> MeetingVaultLiveTranscriptionRuntimeMode {
        environment.keys.contains("MEETINGVAULT_LIVE_TRANSCRIPTION")
            ? .fromEnvironment(environment)
            : defaultMode
    }

    private static func finalTranscriptionMode(
        environment: [String: String],
        defaultMode: MeetingVaultFinalTranscriptionRuntimeMode
    ) -> MeetingVaultFinalTranscriptionRuntimeMode {
        environment.keys.contains("MEETINGVAULT_FINAL_TRANSCRIPTION")
            ? .fromEnvironment(environment)
            : defaultMode
    }

    private static func intelligenceMode(
        environment: [String: String],
        defaultMode: MeetingVaultIntelligenceRuntimeMode
    ) -> MeetingVaultIntelligenceRuntimeMode {
        environment.keys.contains("MEETINGVAULT_INTELLIGENCE_RUNTIME")
            ? .fromEnvironment(environment)
            : defaultMode
    }

    private static func transcriptQuestionMode(
        environment: [String: String],
        defaultMode: MeetingVaultTranscriptQuestionRuntimeMode
    ) -> MeetingVaultTranscriptQuestionRuntimeMode {
        environment.keys.contains("MEETINGVAULT_TRANSCRIPT_QA_RUNTIME")
            ? .fromEnvironment(environment)
            : defaultMode
    }
}

enum MeetingVaultLaunchConfigurationError: Error, Equatable, LocalizedError {
    case invalidProductionRuntime(key: String, value: String)

    var errorDescription: String? {
        switch self {
        case let .invalidProductionRuntime(key, value):
            "Invalid production runtime configuration: \(key)=\(value). Use a production provider value or launch with --demo-runtime explicitly."
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct MeetingVaultLaunchAccessibilityTraits: Equatable {
    var reduceMotion: Bool?
    var increasedContrast: Bool?

    static func fromArguments(_ arguments: [String] = CommandLine.arguments) -> MeetingVaultLaunchAccessibilityTraits {
        MeetingVaultLaunchAccessibilityTraits(
            reduceMotion: reduceMotion(from: arguments),
            increasedContrast: increasedContrast(from: arguments)
        )
    }

    private static func reduceMotion(from arguments: [String]) -> Bool? {
        guard let value = value(after: "--reduce-motion", in: arguments) else {
            return nil
        }
        switch value {
        case "on", "true", "yes", "1":
            return true
        case "off", "false", "no", "0":
            return false
        default:
            return nil
        }
    }

    private static func increasedContrast(from arguments: [String]) -> Bool? {
        guard let value = value(after: "--contrast", in: arguments) else {
            return nil
        }
        switch value {
        case "increased", "increase", "high":
            return true
        case "normal", "standard":
            return false
        default:
            return nil
        }
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag),
              arguments.indices.contains(arguments.index(after: index)) else {
            return nil
        }
        return arguments[arguments.index(after: index)]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

private extension View {
    @ViewBuilder
    func launchIncreasedContrastOverride(_ value: Bool?) -> some View {
        if let value {
            environment(\.vaultIncreasedContrastOverride, value)
        } else {
            self
        }
    }
}
