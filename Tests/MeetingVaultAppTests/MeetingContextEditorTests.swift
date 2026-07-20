import Foundation
import MeetingVaultCore
import XCTest
@testable import MeetingVault

@MainActor
final class MeetingContextEditorTests: XCTestCase {
    func testStoreStartsWithEmptyContextAndNeverCopiesSelectedMeetingImplicitly() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let priorMeetingID = UUID()
        var prior = MeetingBundleManifest.initialEncryptedBundle(meetingID: priorMeetingID, title: "Prior")
        prior.context = MeetingContext(
            localeIdentifier: "pl-PL",
            expectedParticipantCount: 5,
            participantNames: ["Private Person"],
            vocabulary: ["Private Vocabulary"]
        )
        _ = try fixture.bundleStore.createBundle(prior)

        fixture.store.selectedMeetingID = priorMeetingID

        XCTAssertEqual(fixture.store.meetingContextDraft, MeetingContext())
        XCTAssertNil(fixture.store.meetingContextDraft.localeIdentifier)
        XCTAssertTrue(fixture.store.meetingContextDraft.participantNames.isEmpty)
        XCTAssertTrue(fixture.store.meetingContextDraft.vocabulary.isEmpty)
    }

    func testReusePreviousContextRequiresExplicitActionAndCopiesOnlyValidatedContext() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let priorMeetingID = UUID()
        var prior = MeetingBundleManifest.initialEncryptedBundle(meetingID: priorMeetingID, title: "Prior")
        prior.context = MeetingContext(
            localeIdentifier: "pl_pl",
            expectedParticipantCount: 5,
            participantNames: ["  Żaneta  ", "żaneta"],
            vocabulary: ["  Projekt Żubr  "]
        )
        _ = try fixture.bundleStore.createBundle(prior)
        fixture.store.selectedMeetingID = priorMeetingID

        fixture.store.reusePreviousMeetingContext()

        XCTAssertEqual(
            fixture.store.meetingContextDraft,
            MeetingContext(
                localeIdentifier: "pl-PL",
                expectedParticipantCount: 5,
                participantNames: ["Żaneta"],
                vocabulary: ["Projekt Żubr"]
            )
        )
        XCTAssertEqual(fixture.store.meetingContextReuseStatus, "Reused context from the selected meeting")
    }

    func testReuseWithoutValidPriorContextLeavesDraftUntouchedAndShowsNonprivateStatus() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.store.meetingContextDraft = MeetingContext(participantNames: ["Keep Me"])
        fixture.store.selectedMeetingID = UUID()

        fixture.store.reusePreviousMeetingContext()

        XCTAssertEqual(fixture.store.meetingContextDraft.participantNames, ["Keep Me"])
        XCTAssertEqual(fixture.store.meetingContextReuseStatus, "No reusable context is available for the selected meeting")
        XCTAssertFalse(fixture.store.meetingContextReuseStatus.contains("Keep Me"))
    }

    func testSuccessfulStartCapturesValidatedContextThenResetsNextRecordingDraft() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.store.meetingContextDraft = MeetingContext(
            localeIdentifier: "pl_pl",
            expectedParticipantCount: 5,
            participantNames: ["  Żaneta  "],
            vocabulary: ["  Projekt Żubr  "]
        )

        fixture.store.startRecordingIntent()
        try await waitUntil("recording starts with encrypted context metadata") {
            fixture.store.recordingState == .recording
                && fixture.store.activeRecordingPresentation != nil
        }

        let meetingID = try XCTUnwrap(fixture.store.activeRecordingPresentation?.meetingID)
        XCTAssertEqual(fixture.store.meetingContextDraft, MeetingContext())
        let manifest = try fixture.bundleStore.readManifest(meetingID: meetingID)
        XCTAssertEqual(manifest.context.localeIdentifier, "pl-PL")
        XCTAssertEqual(manifest.context.participantNames, ["Żaneta"])
        XCTAssertEqual(manifest.context.vocabulary, ["Projekt Żubr"])
        fixture.store.stopRecordingIntent()
    }

    func testStartIntentLocksEditorAndReuseThroughDelayedMetadataPreparation() async throws {
        let metadataCreator = DelayedContextMetadataCreator()
        let fixture = try makeFixture(recordingSessionMetadataCreator: metadataCreator)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let snapshottedDraft = MeetingContext(
            localeIdentifier: "pl-PL",
            participantNames: ["Start Snapshot"]
        )
        fixture.store.meetingContextDraft = snapshottedDraft
        let priorMeetingID = UUID()
        var prior = MeetingBundleManifest.initialEncryptedBundle(meetingID: priorMeetingID, title: "Prior")
        prior.context = MeetingContext(participantNames: ["Should Not Replace Snapshot"])
        _ = try fixture.bundleStore.createBundle(prior)
        fixture.store.selectedMeetingID = priorMeetingID

        fixture.store.startRecordingIntent()

        XCTAssertTrue(fixture.store.recordingStartInFlight)
        XCTAssertFalse(fixture.store.canStartRecording)
        XCTAssertFalse(
            fixture.store.mutateMeetingContextDraft { draft in
                draft.participantNames = ["Rejected Mutation"]
            }
        )
        fixture.store.reusePreviousMeetingContext()
        XCTAssertEqual(fixture.store.meetingContextDraft, snapshottedDraft)
        XCTAssertEqual(
            fixture.store.meetingContextReuseStatus,
            "Meeting context cannot change while recording is starting"
        )
        try await waitUntil("metadata preparation starts") {
            await metadataCreator.hasPendingCreation
        }
        XCTAssertTrue(fixture.store.recordingStartInFlight)

        await metadataCreator.succeed()
        try await waitUntil("recording starts after metadata preparation") {
            fixture.store.recordingState == .recording
                && !fixture.store.recordingStartInFlight
        }

        let receivedContext = await metadataCreator.receivedContext
        XCTAssertEqual(receivedContext, snapshottedDraft)
        XCTAssertEqual(fixture.store.meetingContextDraft, MeetingContext())
        fixture.store.stopRecordingIntent()
    }

    func testFailedDelayedStartReenablesEditingAndPreservesSnapshottedDraft() async throws {
        let metadataCreator = DelayedContextMetadataCreator()
        let fixture = try makeFixture(recordingSessionMetadataCreator: metadataCreator)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let draft = MeetingContext(vocabulary: ["Preserve This Draft"])
        fixture.store.meetingContextDraft = draft

        fixture.store.startRecordingIntent()
        try await waitUntil("metadata preparation starts") {
            await metadataCreator.hasPendingCreation
        }
        await metadataCreator.fail()
        try await waitUntil("failed start settles") {
            fixture.store.recordingState == .error
                && !fixture.store.recordingStartInFlight
        }

        XCTAssertEqual(fixture.store.meetingContextDraft, draft)
        XCTAssertNil(fixture.store.activeRecordingPresentation)
        XCTAssertTrue(
            fixture.store.mutateMeetingContextDraft { context in
                context.vocabulary.append("Editing Reenabled")
            }
        )
        XCTAssertEqual(
            fixture.store.meetingContextDraft.vocabulary,
            ["Preserve This Draft", "Editing Reenabled"]
        )
    }

    func testSuccessfulStartDoesNotResetANewerDraftThanTheSnapshottedContext() async throws {
        let metadataCreator = DelayedContextMetadataCreator()
        let fixture = try makeFixture(recordingSessionMetadataCreator: metadataCreator)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let snapshottedDraft = MeetingContext(participantNames: ["Recording Snapshot"])
        let newerDraft = MeetingContext(participantNames: ["Next Recording Draft"])
        fixture.store.meetingContextDraft = snapshottedDraft

        fixture.store.startRecordingIntent()
        try await waitUntil("metadata preparation starts") {
            await metadataCreator.hasPendingCreation
        }
        fixture.store.meetingContextDraft = newerDraft
        await metadataCreator.succeed()
        try await waitUntil("recording starts after metadata preparation") {
            fixture.store.recordingState == .recording
                && !fixture.store.recordingStartInFlight
        }

        let receivedContext = await metadataCreator.receivedContext
        XCTAssertEqual(receivedContext, snapshottedDraft)
        XCTAssertEqual(fixture.store.meetingContextDraft, newerDraft)
        fixture.store.stopRecordingIntent()
    }

    func testMeetingContextEditorIsImmediatelyBelowTransportAndMutationIsDisabledWhileActive() throws {
        let inspector = try source("Sources/MeetingVault/Views/MeetingWorkspaceInspector.swift")
        let editor = try source("Sources/MeetingVault/Views/MeetingContextEditor.swift")
        let setupStart = try XCTUnwrap(inspector.range(of: "private var setupContent: some View"))
        let setupEnd = try XCTUnwrap(inspector.range(of: "private var captureSetupIsEditable: Bool"))
        let setup = String(inspector[setupStart.lowerBound..<setupEnd.lowerBound])

        XCTAssertLessThan(
            try XCTUnwrap(setup.range(of: "LiveTransportCard()")?.lowerBound),
            try XCTUnwrap(setup.range(of: "MeetingContextEditor()")?.lowerBound)
        )
        XCTAssertLessThan(
            try XCTUnwrap(setup.range(of: "MeetingContextEditor()")?.lowerBound),
            try XCTUnwrap(setup.range(of: "audioInputControls")?.lowerBound)
        )
        XCTAssertTrue(setup.contains("MeetingContextEditor()\n                    .disabled(!captureSetupIsEditable)"))
        XCTAssertTrue(inspector.contains("&& !store.recordingStartInFlight"))
        XCTAssertTrue(editor.contains("meeting-context-language"))
        XCTAssertTrue(editor.contains("meeting-context-participant-count"))
        XCTAssertTrue(editor.contains("meeting-context-participant-names"))
        XCTAssertTrue(editor.contains("meeting-context-vocabulary"))
        XCTAssertTrue(editor.contains("meeting-context-reuse"))
        XCTAssertTrue(editor.contains("Automatic"))
        XCTAssertTrue(editor.contains("Polish"))
        XCTAssertTrue(editor.contains("English"))
    }

    private func makeFixture(
        recordingSessionMetadataCreator: (any RecordingSessionMetadataCreating)? = nil
    ) throws -> ContextFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultContextEditor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let keyProvider = InMemorySymmetricKeyProvider(keyData: Data(repeating: 91, count: 32))
        let store = MeetingVaultStore(
            permissionProvider: ContextPermissionProvider(),
            libraryRoot: root,
            keyProvider: keyProvider,
            storageCapacityChecker: ContextStorageCapacityChecker(),
            audioInputDeviceProvider: ContextAudioInputProvider(),
            recordingSessionMetadataCreator: recordingSessionMetadataCreator,
            captureRuntimeMode: .mock,
            includeSampleData: false
        )
        let bundleStore = EncryptedMeetingBundleStore(
            rootDirectory: root,
            vault: AESGCMDataVault(keyProvider: keyProvider)
        )
        return ContextFixture(root: root, store: store, bundleStore: bundleStore)
    }

    private func waitUntil(
        _ description: String,
        timeout: Duration = .seconds(3),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for \(description)")
    }

    private func waitUntil(
        _ description: String,
        timeout: Duration = .seconds(3),
        condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for \(description)")
    }

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }
}

private struct ContextFixture {
    var root: URL
    var store: MeetingVaultStore
    var bundleStore: EncryptedMeetingBundleStore
}

private struct ContextPermissionProvider: PermissionProviding {
    func snapshot() async -> PermissionSnapshot {
        PermissionSnapshot(
            systemAudio: .authorized,
            microphone: .authorized,
            speechRecognition: .authorized
        )
    }
}

private struct ContextStorageCapacityChecker: RecordingStorageCapacityChecking {
    func availableCapacityBytes(for directoryURL: URL) throws -> Int64 {
        100_000_000_000
    }
}

private struct ContextAudioInputProvider: AudioInputDeviceProviding {
    func snapshot() async -> [AudioInputDevice] { [] }
}

private actor DelayedContextMetadataCreator: RecordingSessionMetadataCreating {
    private var continuation: CheckedContinuation<RecordingSessionMetadata, Error>?
    private var receivedMeetingID: UUID?
    private var receivedStartedAt: Date?
    private(set) var receivedContext: MeetingContext?

    var hasPendingCreation: Bool { continuation != nil }

    func create(
        meetingID: UUID,
        startedAt: Date,
        context: MeetingContext
    ) async throws -> RecordingSessionMetadata {
        receivedMeetingID = meetingID
        receivedStartedAt = startedAt
        receivedContext = context
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func succeed() {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(
            returning: RecordingSessionMetadata(
                meetingID: receivedMeetingID ?? UUID(),
                startedAt: receivedStartedAt ?? Date(timeIntervalSince1970: 0),
                context: receivedContext ?? MeetingContext()
            )
        )
    }

    func fail() {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(throwing: RecordingSessionMetadataServiceError.encryptedWriteFailed)
    }
}
