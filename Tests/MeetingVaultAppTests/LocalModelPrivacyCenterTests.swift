import Foundation
import XCTest
@testable import MeetingVault
@testable import MeetingVaultCore

@MainActor
final class LocalModelPrivacyCenterTests: XCTestCase {
    func testProductionPrivacyCenterUsesExplicitCanonicalLibraryAuditAndRejectsActiveCapture() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVault-PrivacyCenter-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "MeetingVault.PrivacyCenter.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = TranscriptionPrivacyModeStore(userDefaults: defaults)
        let boundary = TranscriptionPrivacyBoundary(modeStore: preferences)
        let store = LocalModelPrivacyCenterStore.production(
            libraryRoot: root,
            modelsRoot: root.appendingPathComponent("Models", isDirectory: true),
            privacyPreferences: preferences,
            privacyBoundary: boundary,
            recordingIsActive: { false }
        )

        try await store.setPrivacyMode(.appleOnDeviceOnly)

        let auditURL = root.appendingPathComponent("privacy-audit.jsonl")
        let events = try PrivacyAuditLogReader(logURL: auditURL).readEvents()
        XCTAssertEqual(events.map { $0.metadata["code"] }, ["pending", "committed"])
        XCTAssertEqual(events.map { $0.metadata["mode"] }, ["appleOnDeviceOnly", "appleOnDeviceOnly"])

        let blockedStore = LocalModelPrivacyCenterStore.production(
            libraryRoot: root,
            modelsRoot: root.appendingPathComponent("BlockedModels", isDirectory: true),
            privacyPreferences: preferences,
            privacyBoundary: boundary,
            recordingIsActive: { true }
        )
        do {
            try await blockedStore.setPrivacyMode(.localOnly)
            XCTFail("Expected starting/recording state to reject privacy transition")
        } catch {
            XCTAssertEqual(error as? TranscriptionPrivacyModeTransitionError, .recordingActive)
        }
        XCTAssertEqual(preferences.mode, .appleOnDeviceOnly)
    }

    func testLaunchFactoryResolvesTheSameCustomLibraryRootForStoreAndPrivacyCenter() {
        let smoke = MeetingVaultLaunchStoreFactory.configuredLibraryRoot(
            arguments: ["MeetingVault", "--ui-smoke-library-root", "/tmp/meetingvault-smoke"]
        )
        let custom = MeetingVaultLaunchStoreFactory.configuredLibraryRoot(
            arguments: ["MeetingVault", "--library-root", "/tmp/meetingvault-custom"]
        )

        XCTAssertEqual(smoke?.path, "/tmp/meetingvault-smoke")
        XCTAssertEqual(custom?.path, "/tmp/meetingvault-custom")
    }

    func testStoreConsumesLifecycleEventsAndPersistsExplicitPrivacyChoice() async throws {
        let unit = LocalModelInstallUnit(
            id: "automatic-speech-recognition",
            provider: "FluidAudio",
            model: "Parakeet TDT 0.6B v3",
            version: "3",
            source: "FluidInference/parakeet-tdt-0.6b-v3-coreml",
            licenseName: "CC-BY-4.0",
            licenseURL: URL(string: "https://creativecommons.org/licenses/by/4.0/")!,
            expectedBytes: 8,
            aggregateSHA256: String(repeating: "a", count: 64),
            relativeLocation: "MeetingVault/Models/automatic-speech-recognition",
            fileCount: 2
        )
        let state = LocalModelAssetState(
            id: unit.id,
            status: .notInstalled,
            completedBytes: 0,
            totalBytes: 8
        )
        let client = LocalModelPrivacyCenterClient(
            units: { [unit] },
            snapshot: { [state] },
            install: { _ in
                AsyncThrowingStream { continuation in
                    continuation.yield(.status(.downloading))
                    continuation.yield(.progress(completedBytes: 8, totalBytes: 8))
                    continuation.yield(.status(.ready))
                    continuation.finish()
                }
            },
            cancel: { _ in },
            repair: { _ in AsyncThrowingStream { $0.finish() } },
            prewarm: { id in ModelSelfCheck(assetID: id, passed: true, duration: 0.1) },
            remove: { _ in },
            lastSelfCheck: { _ in nil }
        )
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "LocalModelPrivacyCenterTests.\(UUID().uuidString)"))
        let readinessUpdates = MainActorCounter()
        let store = LocalModelPrivacyCenterStore(
            client: client,
            privacyPreferences: TranscriptionPrivacyModeStore(userDefaults: defaults),
            modelStateDidChange: { readinessUpdates.increment() }
        )

        await store.refresh()
        XCTAssertEqual(store.units.map(\.id), [unit.id])
        XCTAssertEqual(store.states[unit.id]?.status, .notInstalled)
        await store.install(unit.id)
        XCTAssertEqual(store.states[unit.id]?.status, .ready)
        XCTAssertEqual(store.states[unit.id]?.completedBytes, 8)
        XCTAssertEqual(
            readinessUpdates.value,
            3,
            "Refresh plus status transitions must refresh readiness without snapshotting every byte-progress event."
        )
        do {
            try await store.setPrivacyMode(.appleMayUseNetwork)
            XCTFail("Expected explicit confirmation")
        } catch {}
        try await store.setPrivacyMode(.appleMayUseNetwork, confirmsNetworkUse: true)
        XCTAssertEqual(store.privacyMode, .appleMayUseNetwork)
    }

    func testFirstLaunchReadinessUsesLifecycleSnapshotAndRefreshesAfterStateChanges() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVault-Readiness-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = MutableReadinessRuntime(status: .notInstalled)
        let store = MeetingVaultStore(
            libraryRoot: root,
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 0x47, count: 32)),
            liveTranscriptionRuntimeMode: .local,
            localModelRuntime: runtime,
            transcriptionPrivacyBoundary: TranscriptionPrivacyBoundary(mode: .localOnly),
            includeSampleData: false
        )

        await store.refreshTranscriptionModelReadiness()
        XCTAssertEqual(store.transcriptionSetupPresentation.readiness, "Models required · recording stays available")
        XCTAssertEqual(store.transcriptionPrivacyPresentation.label, "Transcription unavailable")

        await runtime.setStatus(.ready)
        await store.refreshTranscriptionModelReadiness()
        XCTAssertEqual(store.transcriptionSetupPresentation.readiness, "Ready for both-side transcription")
        XCTAssertEqual(store.transcriptionPrivacyPresentation.label, "Local only")

        await runtime.setStatus(.repairNeeded)
        await store.refreshTranscriptionModelReadiness()
        XCTAssertEqual(store.transcriptionSetupPresentation.readiness, "Model repair required · recording stays available")
    }

    func testPrivacyTransitionChangesProviderUsedByNextRecording() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVault-ProviderResolver-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let boundary = TranscriptionPrivacyBoundary(mode: .localOnly)
        let store = MeetingVaultStore(
            libraryRoot: root,
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 0x44, count: 32)),
            localTranscriptionProvider: ResolverFixtureProvider(),
            transcriptionPrivacyBoundary: boundary,
            includeSampleData: false
        )

        let initialProviderID = await store.resolvedTranscriptionProviderIDForNextSession()
        XCTAssertEqual(initialProviderID, "resolver-local-fixture")
        await boundary.replaceMode(.appleMayUseNetwork)
        await store.restartLiveTranscriptionForPrivacyTransition()
        let transitionedProviderID = await store.resolvedTranscriptionProviderIDForNextSession()
        XCTAssertEqual(transitionedProviderID, "apple-speech-frame-compatibility")
        XCTAssertEqual(store.transcriptionPrivacyPresentation.label, "Apple compatibility")
    }

    func testPrivacyCenterUsesThreeUnitRowsNativeActionsAndAccessibilityWithoutRawContent() throws {
        let view = try source("Sources/MeetingVault/Views/LocalModelPrivacyCenterView.swift")
        let settings = try source("Sources/MeetingVault/Views/SettingsView.swift")
        let app = try source("Sources/MeetingVault/App/MeetingVaultApp.swift")
        let combined = view + settings + app

        for required in [
            "Local Models & Privacy",
            "Install",
            "Cancel",
            "Repair",
            "Prewarm",
            "Remove",
            "Provider",
            "Model",
            "Version",
            "Source",
            "License",
            "SHA-256",
            "Location",
            "Microphone",
            "System audio",
            "Speech Recognition",
            "Local only",
            "authoritative captured audio frames",
            "verified local model leases",
            "never auto-downloads",
            "may use network",
            "accessibilityLabel",
            "accessibilityHint",
            "confirmationDialog",
        ] {
            XCTAssertTrue(combined.contains(required), "Missing Privacy Center contract: \(required)")
        }
        XCTAssertTrue(app.contains("@StateObject private var localModelPrivacyCenter"))
        XCTAssertTrue(app.contains(".environmentObject(localModelPrivacyCenter)"))
        XCTAssertTrue(settings.contains("LocalModelPrivacyCenterView("))
        XCTAssertFalse(view.contains("transcriptText"))
        XCTAssertFalse(view.contains("meeting.title"))
        XCTAssertFalse(view.contains("sourceURL.absoluteString"))
        XCTAssertFalse(view.contains("/Users/"))
    }

    private func source(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}

@MainActor
private final class MainActorCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private actor MutableReadinessRuntime: LocalModelRuntimeSessionProviding, LocalModelReadinessProviding {
    private var status: LocalModelAssetStatus

    init(status: LocalModelAssetStatus) { self.status = status }

    func setStatus(_ status: LocalModelAssetStatus) { self.status = status }

    func snapshot() -> [LocalModelAssetState] {
        TranscriptionSetupPresentation.requiredLocalUnitIDs.sorted().map {
            LocalModelAssetState(id: $0, status: status, completedBytes: status == .ready ? 1 : 0, totalBytes: 1)
        }
    }

    func withRuntimeSession(
        _ ids: Set<String>,
        _ operation: @Sendable (LocalModelRuntimeAccess) async throws -> Void
    ) async throws {
        throw LocalModelInstallationError.unitNotReady
    }
}

private struct ResolverFixtureProvider: LocalTranscriptionProviding {
    let descriptor = ProviderDescriptor(
        id: "resolver-local-fixture",
        modelVersion: "fixture",
        supportedLocaleIdentifiers: ["pl-PL", "en-US"]
    )

    func makeSession(_ configuration: TranscriptionSessionConfiguration) async throws -> any LocalTranscriptionSession {
        throw LocalTranscriptionError.providerUnavailable("not started by resolver identity test")
    }
}
