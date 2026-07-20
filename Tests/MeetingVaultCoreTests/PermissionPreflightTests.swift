import XCTest
@testable import MeetingVaultCore

final class PermissionPreflightTests: XCTestCase {
    func testSystemAudioAuthorizationProviderUsesNonPromptingPreflightOnly() async throws {
        let counter = LockedPreflightCounter()
        let deniedProvider = ScreenCaptureKitSystemAudioAuthorizationProvider {
            counter.increment()
            return false
        }

        let deniedStatus = await deniedProvider.currentAuthorizationStatus()

        XCTAssertEqual(deniedStatus, .notDetermined)
        XCTAssertEqual(counter.value, 1)

        let authorizedProvider = ScreenCaptureKitSystemAudioAuthorizationProvider {
            counter.increment()
            return true
        }

        let authorizedStatus = await authorizedProvider.currentAuthorizationStatus()

        XCTAssertEqual(authorizedStatus, .authorized)
        XCTAssertEqual(counter.value, 2)
    }

    func testPermissionPreflightBlocksRecordingWithRecoveryActions() async throws {
        let provider = MockPermissionProvider(
            snapshot: PermissionSnapshot(
                systemAudio: .denied,
                microphone: .notDetermined,
                speechRecognition: .authorized
            )
        )
        let service = PermissionPreflightService(permissionProvider: provider)

        let result = await service.evaluate(
            consentStatus: .disclosed,
            freeDiskBytes: CompliancePolicy.minimumFreeDiskBytes + 1,
            requireConsentBeforeRecording: true
        )

        XCTAssertFalse(result.canRecord)
        XCTAssertEqual(result.issues, [.audioPermissionMissing, .microphonePermissionMissing])
        XCTAssertEqual(result.recoveryActions.map(\.kind), [.systemAudio, .microphone])
        XCTAssertTrue(result.recoveryActions.allSatisfy { !$0.opensExternalSettingsAutomatically })
        XCTAssertTrue(result.recoveryActions.first?.message.contains("System Settings") == true)
        XCTAssertEqual(provider.snapshotReadCount, 1)
    }

    func testPermissionPreflightAllowsReadyStateWhenPermissionsConsentAndDiskAreReady() async throws {
        let provider = MockPermissionProvider(
            snapshot: PermissionSnapshot(
                systemAudio: .authorized,
                microphone: .authorized,
                speechRecognition: .authorized
            )
        )
        let service = PermissionPreflightService(permissionProvider: provider)

        let result = await service.evaluate(
            consentStatus: .consented,
            freeDiskBytes: CompliancePolicy.minimumFreeDiskBytes + 1,
            requireConsentBeforeRecording: true
        )

        XCTAssertTrue(result.canRecord)
        XCTAssertTrue(result.issues.isEmpty)
        XCTAssertTrue(result.recoveryActions.isEmpty)
    }

    func testLocalProviderDoesNotRequireSpeechRecognitionAuthorization() async {
        let provider = MockPermissionProvider(snapshot: PermissionSnapshot(
            systemAudio: .authorized,
            microphone: .authorized,
            speechRecognition: .denied
        ))
        let result = await PermissionPreflightService(permissionProvider: provider).evaluate(
            consentStatus: .consented,
            freeDiskBytes: CompliancePolicy.minimumFreeDiskBytes + 1,
            requireConsentBeforeRecording: true,
            requireSpeechRecognitionPermission: false
        )

        XCTAssertTrue(result.canRecord)
        XCTAssertFalse(result.issues.contains(.speechPermissionMissing))
        XCTAssertFalse(result.recoveryActions.contains { $0.kind == .speechRecognition })
    }

    func testAppleCompatibilityProviderRequiresSpeechRecognitionAuthorization() async {
        let provider = MockPermissionProvider(snapshot: PermissionSnapshot(
            systemAudio: .authorized,
            microphone: .authorized,
            speechRecognition: .denied
        ))
        let result = await PermissionPreflightService(permissionProvider: provider).evaluate(
            consentStatus: .consented,
            freeDiskBytes: CompliancePolicy.minimumFreeDiskBytes + 1,
            requireConsentBeforeRecording: true,
            requireSpeechRecognitionPermission: true
        )

        XCTAssertFalse(result.canRecord)
        XCTAssertTrue(result.issues.contains(.speechPermissionMissing))
        XCTAssertTrue(result.recoveryActions.contains { $0.kind == .speechRecognition })
    }

    func testPermissionPreflightBlocksWhenLongRecordingStorageBudgetIsUnsafe() async throws {
        let provider = MockPermissionProvider(
            snapshot: PermissionSnapshot(
                systemAudio: .authorized,
                microphone: .authorized,
                speechRecognition: .authorized
            )
        )
        let budget = RecordingStorageBudget(
            estimatedDurationSeconds: 60 * 60,
            trackCount: 2,
            bytesPerSecondPerTrack: 96_000,
            artifactReserveBytes: 10,
            safetyReserveBytes: 100
        )
        let service = PermissionPreflightService(
            permissionProvider: provider,
            storageCapacityChecker: MockRecordingStorageCapacityChecker(
                availableBytes: budget.requiredFreeDiskBytes - 1
            ),
            storageBudget: budget
        )

        let result = await service.evaluate(
            consentStatus: .consented,
            storageDirectoryURL: URL(fileURLWithPath: "/tmp/MeetingVaultStorageBudget"),
            requireConsentBeforeRecording: true
        )

        XCTAssertFalse(result.canRecord)
        XCTAssertEqual(result.issues, [.diskSpaceLow])
        XCTAssertTrue(result.recoveryActions.isEmpty)
        XCTAssertEqual(result.storageEstimate?.availableBytes, budget.requiredFreeDiskBytes - 1)
        XCTAssertEqual(result.storageEstimate?.requiredFreeDiskBytes, budget.requiredFreeDiskBytes)
    }
}

private struct MockRecordingStorageCapacityChecker: RecordingStorageCapacityChecking {
    var availableBytes: Int64

    func availableCapacityBytes(for directoryURL: URL) throws -> Int64 {
        availableBytes
    }
}

private final class LockedPreflightCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock {
            count += 1
        }
    }
}
