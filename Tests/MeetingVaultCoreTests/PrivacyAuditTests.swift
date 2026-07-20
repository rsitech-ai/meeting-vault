import Foundation
import XCTest
@testable import MeetingVaultCore

final class PrivacyAuditTests: XCTestCase {
    func testPendingPrivacyAuditLosesToConcurrentRecordingStartBeforeCommit() async throws {
        let suite = "MeetingVault.PrivacyRace.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = TranscriptionPrivacyModeStore(userDefaults: defaults)
        let boundary = TranscriptionPrivacyBoundary(modeStore: preferences)
        let gate = TranscriptionRuntimeActivityGate()
        let audit = SuspendedPrivacyAudit()
        let restarts = LockedInteger()
        let coordinator = TranscriptionPrivacyModeTransitionCoordinator(
            preferences: preferences,
            boundary: boundary,
            activityGate: gate,
            audit: { _, metadata in
                if metadata["code"] == "pending" { try await audit.suspend() }
            }
        )

        let transition = Task {
            try await coordinator.apply(
                .appleOnDeviceOnly,
                recordingIsActive: false,
                restartProvider: { restarts.increment() }
            )
        }
        await audit.waitUntilSuspended()
        let recording = try await gate.beginRecordingActivity()
        await audit.resume()

        do {
            try await transition.value
            XCTFail("Expected the concurrent recording start to win")
        } catch {
            XCTAssertEqual(error as? TranscriptionPrivacyModeTransitionError, .recordingActive)
        }
        XCTAssertEqual(preferences.mode, .localOnly)
        let finalBoundaryMode = await boundary.mode()
        XCTAssertEqual(finalBoundaryMode, .localOnly)
        XCTAssertEqual(restarts.value, 0)
        await recording.release()
    }

    func testConcurrentWritersToSameCanonicalLogProduceWholeDecodableEvents() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVault-Audit-Concurrency-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let logURL = root.appendingPathComponent("privacy-audit.jsonl")
        let writers = (0..<8).map { index in
            PrivacyAuditLogWriter(
                logURL: logURL,
                now: { Date(timeIntervalSince1970: TimeInterval(index)) }
            )
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<200 {
                group.addTask {
                    try writers[index % writers.count].append(
                        action: .privacyModeChange,
                        meetingID: nil,
                        metadata: ["code": "event-\(index)"]
                    )
                }
            }
            try await group.waitForAll()
        }

        let events = try PrivacyAuditLogReader(logURL: logURL).readEvents()
        XCTAssertEqual(events.count, 200)
        XCTAssertEqual(Set(events.compactMap { $0.metadata["code"] }).count, 200)
    }

    func testPrivacyTransitionAuditsBeforeCommitRollsBackOnAuditOrRestartFailureAndRejectsActiveRecording() async throws {
        let suite = "MeetingVault.PrivacyTransition.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = TranscriptionPrivacyModeStore(userDefaults: defaults)
        let boundary = TranscriptionPrivacyBoundary(modeStore: preferences)
        let events = PrivacyTransitionProbe()
        let coordinator = TranscriptionPrivacyModeTransitionCoordinator(
            preferences: preferences,
            boundary: boundary,
            audit: { _, metadata in events.record("audit:\(metadata["code"] ?? "")") }
        )

        try await coordinator.apply(.appleOnDeviceOnly, recordingIsActive: false) {
            events.record("restart")
        }
        XCTAssertEqual(preferences.mode, .appleOnDeviceOnly)
        let boundaryModeAfterCommit = await boundary.mode()
        XCTAssertEqual(boundaryModeAfterCommit, .appleOnDeviceOnly)
        XCTAssertEqual(events.values, ["audit:pending", "restart", "audit:committed"])

        do {
            try await coordinator.apply(.appleMayUseNetwork, confirmsNetworkUse: true, recordingIsActive: true) {}
            XCTFail("Expected active recording rejection")
        } catch {
            XCTAssertEqual(error as? TranscriptionPrivacyModeTransitionError, .recordingActive)
        }
        XCTAssertEqual(preferences.mode, .appleOnDeviceOnly)

        let failingRestart = TranscriptionPrivacyModeTransitionCoordinator(
            preferences: preferences,
            boundary: boundary,
            audit: { _, metadata in events.record("retry:\(metadata["code"] ?? "")") }
        )
        do {
            try await failingRestart.apply(.appleMayUseNetwork, confirmsNetworkUse: true, recordingIsActive: false) {
                throw TransitionProbeError.restart
            }
            XCTFail("Expected restart rollback")
        } catch {
            XCTAssertEqual(error as? TranscriptionPrivacyModeTransitionError, .restartFailed)
        }
        XCTAssertEqual(preferences.mode, .appleOnDeviceOnly)
        let boundaryModeAfterRollback = await boundary.mode()
        XCTAssertEqual(boundaryModeAfterRollback, .appleOnDeviceOnly)

        let committedAuditFailureEvents = PrivacyTransitionProbe()
        let committedAuditFailure = TranscriptionPrivacyModeTransitionCoordinator(
            preferences: preferences,
            boundary: boundary,
            audit: { _, metadata in
                committedAuditFailureEvents.record("audit:\(metadata["code"] ?? "")")
                if metadata["code"] == "committed" { throw TransitionProbeError.audit }
            }
        )
        do {
            try await committedAuditFailure.apply(
                .appleMayUseNetwork,
                confirmsNetworkUse: true,
                recordingIsActive: false
            ) {
                committedAuditFailureEvents.record("restart")
            }
            XCTFail("Expected committed audit rollback")
        } catch {
            XCTAssertEqual(error as? TranscriptionPrivacyModeTransitionError, .auditFailed)
        }
        XCTAssertEqual(preferences.mode, .appleOnDeviceOnly)
        let boundaryModeAfterCommittedAuditFailure = await boundary.mode()
        XCTAssertEqual(boundaryModeAfterCommittedAuditFailure, .appleOnDeviceOnly)
        XCTAssertEqual(
            committedAuditFailureEvents.values,
            ["audit:pending", "restart", "audit:committed", "restart"]
        )
    }
    func testModelLifecycleAuditActionsHaveStableNonContentRawValues() {
        XCTAssertEqual(PrivacyAuditAction.modelInstall.rawValue, "modelInstall")
        XCTAssertEqual(PrivacyAuditAction.modelRepair.rawValue, "modelRepair")
        XCTAssertEqual(PrivacyAuditAction.modelPrewarm.rawValue, "modelPrewarm")
        XCTAssertEqual(PrivacyAuditAction.modelRemove.rawValue, "modelRemove")
        XCTAssertEqual(PrivacyAuditAction.privacyModeChange.rawValue, "privacyModeChange")
    }

    func testPrivacyModeDefaultsLocalRequiresSeparateNetworkConfirmationAndPersistsRedactedAudit() throws {
        let suite = "MeetingVault.PrivacyMode.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let audit = PrivacyModeAuditProbe()
        let store = TranscriptionPrivacyModeStore(userDefaults: defaults) { action, metadata in
            audit.record(action, metadata: metadata)
        }

        XCTAssertEqual(store.mode, .localOnly)
        try store.setMode(.appleOnDeviceCompatible)
        XCTAssertEqual(store.mode, .appleOnDeviceCompatible)
        XCTAssertThrowsError(try store.setMode(.appleMayUseNetwork)) {
            XCTAssertEqual($0 as? TranscriptionPrivacyModeError, .networkConfirmationRequired)
        }
        XCTAssertEqual(store.mode, .appleOnDeviceCompatible)
        try store.setMode(.appleMayUseNetwork, confirmsNetworkUse: true)

        let reloaded = TranscriptionPrivacyModeStore(userDefaults: defaults)
        XCTAssertEqual(reloaded.mode, .appleMayUseNetwork)
        XCTAssertEqual(audit.records.map(\.0), [.privacyModeChange, .privacyModeChange])
        XCTAssertEqual(audit.records.map { $0.1["mode"] }, ["appleOnDeviceOnly", "appleMayUseNetwork"])
        let serialized = audit.records.flatMap { $0.1.values }.joined(separator: " ")
        XCTAssertFalse(serialized.contains("transcript"))
        XCTAssertFalse(serialized.contains("/Users/"))
        XCTAssertFalse(serialized.contains("permission"))
    }

    func testRetentionCleanupWritesRedactedDeleteAuditEvents() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultAudit-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let vault = AESGCMDataVault(
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 71, count: 32))
        )
        let bundleStore = EncryptedMeetingBundleStore(rootDirectory: root, vault: vault)
        let now = Date(timeIntervalSince1970: 1_780_004_000)
        let meetingID = UUID()
        var manifest = MeetingBundleManifest.initialEncryptedBundle(
            meetingID: meetingID,
            title: "Sensitive acquisition transcript details"
        )
        manifest.createdAt = now.addingTimeInterval(-90 * 86_400)
        _ = try bundleStore.createBundle(manifest)

        let auditURL = root.appendingPathComponent("privacy-audit.jsonl")
        let auditWriter = PrivacyAuditLogWriter(logURL: auditURL, now: { now })
        let service = RetentionCleanupService(bundleStore: bundleStore, auditWriter: auditWriter)
        let plan = try service.planCleanup(policy: RetentionPolicy(retentionDays: 30), now: now)

        let result = try service.apply(plan)

        XCTAssertEqual(result.deletedMeetingIDs, [meetingID])

        let rawLog = try String(contentsOf: auditURL, encoding: .utf8)
        XCTAssertTrue(rawLog.contains("retention.delete"))
        XCTAssertTrue(rawLog.contains(meetingID.uuidString))
        XCTAssertFalse(rawLog.contains("Sensitive acquisition"))
        XCTAssertFalse(rawLog.contains("transcript details"))

        let events = try PrivacyAuditLogReader(logURL: auditURL).readEvents()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.action, .retentionDelete)
        XCTAssertEqual(events.first?.meetingID, meetingID)
        XCTAssertEqual(events.first?.metadata["retentionDays"], "30")
        XCTAssertEqual(events.first?.metadata["ageDays"], "90")
    }
}

private final class PrivacyModeAuditProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(PrivacyAuditAction, [String: String])] = []
    var records: [(PrivacyAuditAction, [String: String])] { lock.withLock { storage } }
    func record(_ action: PrivacyAuditAction, metadata: [String: String]) {
        lock.withLock { storage.append((action, metadata)) }
    }
}

private enum TransitionProbeError: Error { case restart, audit }

private final class PrivacyTransitionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var values: [String] { lock.withLock { storage } }
    func record(_ value: String) { lock.withLock { storage.append(value) } }
}

private actor SuspendedPrivacyAudit {
    private var suspended = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?

    func suspend() async throws {
        suspended = true
        waiter?.resume()
        waiter = nil
        await withCheckedContinuation { release = $0 }
    }

    func waitUntilSuspended() async {
        if suspended { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func resume() {
        release?.resume()
        release = nil
    }
}

private final class LockedInteger: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0
    var value: Int { lock.withLock { storage } }
    func increment() { lock.withLock { storage += 1 } }
}
