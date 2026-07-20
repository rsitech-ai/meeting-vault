import Foundation
import MeetingVaultCore
import XCTest
@testable import MeetingVault

@MainActor
final class RecordingTransportPresentationTests: XCTestCase {
    func testTranscriptionSetupSeparatesCaptureFromMissingLocalModels() {
        let presentation = TranscriptionSetupPresentation(
            mode: .localOnly,
            provider: UnavailableLocalTranscriptionProvider(reason: "Install models").descriptor,
            localeIdentifier: "pl-PL",
            localModelStates: [],
            applePermissionGranted: false
        )

        XCTAssertEqual(presentation.provider, "Local transcription")
        XCTAssertEqual(presentation.locale, "Polish (Poland)")
        XCTAssertEqual(presentation.readiness, "Models required · recording stays available")
        XCTAssertEqual(presentation.recoveryTitle, "Open Local Models & Privacy")
    }

    func testTranscriptionSetupStatesAppleNetworkTruthAndUnsupportedLocale() {
        let presentation = TranscriptionSetupPresentation(
            mode: .appleMayUseNetwork,
            provider: ProviderDescriptor(
                id: "apple-speech-frame-compatibility",
                modelVersion: "Apple Speech",
                supportedLocaleIdentifiers: ["pl-PL", "en-US"],
                audioInputStrategy: .authoritativeCaptureFrames,
                supportsRemoteSpeakerDiarization: false,
                maximumRemoteSpeakerCount: 1
            ),
            localeIdentifier: "de-DE",
            localModelStates: [],
            applePermissionGranted: true
        )

        XCTAssertEqual(presentation.privacy, "Apple compatibility · network may be used")
        XCTAssertEqual(presentation.readiness, "Unsupported language")
        XCTAssertEqual(presentation.recoveryTitle, "Choose Automatic, Polish, or English")
    }

    func testTranscriptionSetupRequiresAllActualLiveAndFinalUnitsAndReflectsRepair() {
        let ready = TranscriptionSetupPresentation.requiredLocalUnitIDs.map {
            LocalModelAssetState(id: $0, status: .ready, completedBytes: 1, totalBytes: 1)
        }
        let presentation = TranscriptionSetupPresentation(
            mode: .localOnly,
            provider: ProviderDescriptor(
                id: "arbitrary-provider-id",
                modelVersion: "fixture",
                supportedLocaleIdentifiers: ["pl-PL", "en-US"]
            ),
            localeIdentifier: nil,
            localModelStates: ready,
            applePermissionGranted: false
        )
        XCTAssertEqual(presentation.readiness, "Ready for both-side transcription")

        var repairing = ready
        repairing[0].status = .repairNeeded
        let degraded = TranscriptionSetupPresentation(
            mode: .localOnly,
            provider: ProviderDescriptor(
                id: "fluidaudio-local",
                modelVersion: "fixture",
                supportedLocaleIdentifiers: ["pl-PL", "en-US"]
            ),
            localeIdentifier: nil,
            localModelStates: repairing,
            applePermissionGranted: false
        )
        XCTAssertEqual(degraded.readiness, "Model repair required · recording stays available")
    }
    func testRecordingVoiceSignalDistinguishesActiveSilenceAndMissingInputFromFrameTimestamps() {
        let clock = ContinuousClock()
        let now = clock.now
        let missing = RecordingVoiceSignalPresentation.resolve(
            snapshot: RecordingLevelSnapshot(),
            now: now
        )
        let silent = RecordingVoiceSignalPresentation.resolve(
            snapshot: RecordingLevelSnapshot(
                microphone: 0,
                systemAudio: 0,
                lastMicrophoneFrameAt: now,
                lastSystemFrameAt: now
            ),
            now: now
        )
        let active = RecordingVoiceSignalPresentation.resolve(
            snapshot: RecordingLevelSnapshot(
                microphone: 0.62,
                systemAudio: 0.41,
                lastMicrophoneFrameAt: now,
                lastSystemFrameAt: now
            ),
            now: now
        )
        let stale = RecordingVoiceSignalPresentation.resolve(
            snapshot: RecordingLevelSnapshot(
                microphone: 0.8,
                systemAudio: 0.7,
                lastMicrophoneFrameAt: now.advanced(by: .seconds(-3)),
                lastSystemFrameAt: now.advanced(by: .seconds(-3))
            ),
            now: now
        )

        XCTAssertEqual(missing.microphone.state, .missing)
        XCTAssertEqual(missing.systemAudio.state, .missing)
        XCTAssertEqual(silent.microphone.state, .silent)
        XCTAssertEqual(silent.systemAudio.state, .silent)
        XCTAssertEqual(active.microphone.state, .active)
        XCTAssertEqual(active.systemAudio.state, .active)
        XCTAssertEqual(stale.microphone.state, .missing)
        XCTAssertEqual(stale.systemAudio.state, .missing)
    }

    func testReducedMotionStillRefreshesStaleInputToMissingWithoutDecorativeCadence() {
        let clock = ContinuousClock()
        let frameTime = clock.now
        let model = RecordingVoiceSignalModel(
            snapshot: RecordingLevelSnapshot(
                microphone: 0.5,
                systemAudio: 0,
                lastMicrophoneFrameAt: frameTime,
                lastSystemFrameAt: frameTime
            ),
            staleAfter: .seconds(2)
        )

        XCTAssertEqual(model.refreshInterval(reduceMotion: true), 1)
        XCTAssertEqual(model.refreshInterval(reduceMotion: false), 1.0 / 12.0, accuracy: 0.000_001)
        XCTAssertEqual(model.presentation(now: frameTime).microphone.state, .active)
        XCTAssertEqual(
            model.presentation(now: frameTime.advanced(by: .seconds(3))).microphone.state,
            .missing
        )
    }

    func testEligibleReadyAndRecordingStatesExposeExactlyOneMatchingAction() {
        let ready = MeetingWorkspacePresentation.recordingTransport(
            state: .ready,
            canStart: true,
            canStop: false,
            blockerDetail: "Ready to record"
        )
        let recording = MeetingWorkspacePresentation.recordingTransport(
            state: .recording,
            canStart: false,
            canStop: true,
            blockerDetail: "Recording with Studio Microphone"
        )
        let recovered = MeetingWorkspacePresentation.recordingTransport(
            state: .recovered,
            canStart: true,
            canStop: false,
            blockerDetail: "Recovered audio is safe"
        )

        XCTAssertEqual([ready.action, recording.action, recovered.action].compactMap { $0 }, [.start, .stop])
        XCTAssertEqual(ready.title, "Start Recording")
        XCTAssertEqual(recording.title, "Stop Recording")
        XCTAssertEqual(recovered.title, "Recovery Complete")
        XCTAssertNil(recovered.action)
    }

    func testBlockedStatesExposeNoActionAndPreserveExactBlockerDetail() {
        let permissionDetail = "Allow Screen & System Audio and Microphone."
        let errorDetail = "Capture interrupted: Studio Microphone disconnected."
        let cases: [(RecordingState, Bool, Bool, String, String)] = [
            (.permissionNeeded, true, false, permissionDetail, permissionDetail),
            (.paused, false, true, "Open Health & Recovery to recover this recording.", "Open Health & Recovery to recover this recording."),
            (.error, false, false, errorDetail, errorDetail)
        ]

        for (state, canStart, canStop, blockerDetail, expectedDetail) in cases {
            let presentation = MeetingWorkspacePresentation.recordingTransport(
                state: state,
                canStart: canStart,
                canStop: canStop,
                blockerDetail: blockerDetail
            )

            XCTAssertNil(presentation.action, "\(state) must not expose a recording action")
            XCTAssertFalse(presentation.isEnabled)
            XCTAssertEqual(presentation.detail, expectedDetail)
        }
    }

    func testProcessingIsFinalizingPresentationWithoutAction() {
        let presentation = MeetingWorkspacePresentation.recordingTransport(
            state: .processing,
            canStart: true,
            canStop: true,
            blockerDetail: "Transcribing encrypted audio"
        )

        XCTAssertEqual(presentation.title, "Finalizing…")
        XCTAssertEqual(presentation.statusTitle, "Finalizing…")
        XCTAssertEqual(presentation.accessibilityLabel, "Finalizing Recording")
        XCTAssertEqual(presentation.detail, "Transcribing encrypted audio")
        XCTAssertNil(presentation.action)
        XCTAssertFalse(presentation.isEnabled)
    }

    func testIneligibleReadyAndRecordingStatesExposeNoAction() {
        let cases: [(RecordingState, Bool, Bool)] = [
            (.idle, false, false),
            (.ready, false, false),
            (.recording, false, false),
            (.recovered, false, false)
        ]

        for (state, canStart, canStop) in cases {
            let presentation = MeetingWorkspacePresentation.recordingTransport(
                state: state,
                canStart: canStart,
                canStop: canStop,
                blockerDetail: "Not eligible"
            )
            XCTAssertNil(presentation.action, "\(state) must respect its capability flag")
        }
    }

    func testElapsedTimeUsesAuthoritativeDatesAndClampsClockSkewAtZero() {
        let startedAt = Date(timeIntervalSince1970: 2_000)

        XCTAssertEqual(
            RecordingElapsedTime.elapsed(startedAt: startedAt, now: Date(timeIntervalSince1970: 2_065.5)),
            65.5,
            accuracy: 0.001
        )
        XCTAssertEqual(
            RecordingElapsedTime.elapsed(startedAt: startedAt, now: Date(timeIntervalSince1970: 1_999)),
            0
        )
    }

    func testSuccessfulBeginPublishesExactSelectedSourceAndMicrophoneThenStopClearsPresentation() async throws {
        let fixture = try makeStoreFixture()
        defer { fixture.remove() }

        await fixture.store.refreshAudioInputDevices()
        _ = await fixture.store.refreshPermissions()
        fixture.store.startRecordingIntent()

        try await waitUntil("recording presentation is published") {
            fixture.store.activeRecordingPresentation != nil
        }
        let presentation = try XCTUnwrap(fixture.store.activeRecordingPresentation)
        XCTAssertEqual(presentation.sourceName, fixture.store.selectedSource?.displayName)
        XCTAssertEqual(presentation.microphoneDeviceName, "Studio Microphone")
        XCTAssertLessThanOrEqual(presentation.startedAt, Date())
        XCTAssertEqual(fixture.store.recordingState, .recording)

        fixture.store.stopRecordingIntent()
        try await waitUntil("successful stop clears recording presentation") {
            fixture.store.activeRecordingPresentation == nil && fixture.store.recordingState == .ready
        }
    }

    func testMarkMomentPersistsBeforePublishingConfirmationAndRejectsAfterStop() async throws {
        let fixture = try makeStoreFixture()
        defer { fixture.remove() }
        await fixture.store.refreshAudioInputDevices()
        _ = await fixture.store.refreshPermissions()
        fixture.store.startRecordingIntent()
        try await waitUntil("recording begins before mark") {
            fixture.store.activeRecordingPresentation != nil
        }
        let meetingID = try XCTUnwrap(fixture.store.activeRecordingPresentation?.meetingID)

        let accepted = await fixture.store.markMoment(category: .important, note: "Remember this")
        XCTAssertTrue(accepted)
        XCTAssertEqual(fixture.store.recordingBookmarkStatus, "Moment marked")
        XCTAssertEqual(fixture.store.lastMarkedMoment?.meetingID, meetingID)

        let bundleStore = EncryptedMeetingBundleStore(
            rootDirectory: fixture.root,
            vault: AESGCMDataVault(
                keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 0x72, count: 32))
            )
        )
        let metadata = try bundleStore.readJSONArtifact(
            RecordingSessionMetadata.self,
            meetingID: meetingID,
            relativePath: RecordingSessionMetadata.relativePath,
            purpose: RecordingSessionMetadata.purpose
        )
        XCTAssertEqual(metadata.bookmarks.map(\.note), ["Remember this"])

        fixture.store.stopRecordingIntent()
        let rejected = await fixture.store.markMoment()
        XCTAssertFalse(rejected)
        XCTAssertEqual(fixture.store.recordingBookmarkStatus, "Mark Moment is available only while recording")
    }

    func testMarkMomentPresentationCommandAppIntentAndLiveCardShareOneStoreAction() throws {
        let card = try source("Sources/MeetingVault/Views/LiveTransportCard.swift")
        let app = try source("Sources/MeetingVault/App/MeetingVaultApp.swift")
        let intents = try source("Sources/MeetingVault/App/MeetingVaultAppIntents.swift")
        let transcript = try source("Sources/MeetingVault/Views/MeetingTranscriptWorkspace.swift")

        XCTAssertTrue(card.contains("store.markMomentIntent()"))
        XCTAssertTrue(card.contains("mark-moment-button"))
        XCTAssertTrue(card.contains("store.recordingBookmarkPresentation"))
        XCTAssertTrue(card.contains("recording-bookmark-observation"))
        XCTAssertTrue(card.contains("store.recordingBookmarkNativeObservation"))
        XCTAssertTrue(app.contains(".keyboardShortcut(\"m\", modifiers: [.command, .shift])"))
        XCTAssertTrue(app.contains("store.markMomentIntent()"))
        XCTAssertTrue(intents.contains("struct MarkMeetingVaultMomentIntent"))
        XCTAssertTrue(intents.contains("routeMarkMoment()"))
        XCTAssertTrue(intents.contains("await operation.outcome()"))
        XCTAssertTrue(intents.contains("marked moment was saved"))
        XCTAssertTrue(intents.contains("could not be saved"))
        XCTAssertFalse(intents.contains("is saving the marked moment"))
        XCTAssertTrue(transcript.contains("playbackTimeline.bookmarks"))
        XCTAssertTrue(transcript.contains("marked-moments"))
        XCTAssertTrue(transcript.contains(#"marked-moment-\(bookmark.id.uuidString.lowercased())"#))
        XCTAssertTrue(transcript.contains("marked-moments-observation"))
    }

    func testLiveTransportShowsProviderStatusTranscriptAndActiveSpeakersInRecordingFlow() throws {
        let card = try source("Sources/MeetingVault/Views/LiveTransportCard.swift")

        XCTAssertTrue(card.contains("store.liveTranscriptionStatus"))
        XCTAssertTrue(card.contains("store.liveTranscriptPreviewSegments.last"))
        XCTAssertTrue(card.contains("store.liveActiveSpeakers"))
        XCTAssertTrue(card.contains("live-transcription-preview"))
        XCTAssertTrue(card.contains("live-transcription-observation"))
        XCTAssertTrue(card.contains("live-active-speakers"))
        XCTAssertTrue(card.contains("contentTransition(.numericText())"))
        XCTAssertTrue(card.contains("accessibilityAddTraits(.updatesFrequently)"))
    }

    func testProductionIntelligenceProvidersExplicitlyHandleBookmarkEvidenceWithoutSilentProtocolDrop() throws {
        let protocols = try source("Sources/MeetingVaultCore/Services/ProviderProtocols.swift")
        let foundation = try source("Sources/MeetingVaultCore/Services/FoundationModelsMeetingIntelligenceProvider.swift")
        let store = try source("Sources/MeetingVault/Stores/MeetingVaultStore.swift")

        XCTAssertFalse(protocols.contains("bookmarkEvidence _:"))
        XCTAssertTrue(foundation.contains("bookmarkEvidence: [MeetingIntelligenceBookmarkEvidence]"))
        XCTAssertTrue(foundation.contains("User-authored marked moments"))
        let demoRange = try XCTUnwrap(store.range(of: "private final class DemoMeetingIntelligenceProvider"))
        let demoSource = String(store[demoRange.lowerBound...])
        XCTAssertTrue(demoSource.contains("bookmarkEvidence: [MeetingIntelligenceBookmarkEvidence]"))
        XCTAssertTrue(demoSource.contains("Marked moment at"))
        XCTAssertFalse(demoSource.contains("evidence.bookmark.note"))
    }

    func testBookmarkRowAccessibilityIncludesTimestampCategoryThenSanitizedNote() {
        let bookmark = MeetingBookmark(
            meetingID: UUID(),
            timestamp: 65,
            createdAt: Date(timeIntervalSince1970: 1_780_020_000),
            category: .followUp,
            note: "  Call\nAlex\u{0001} tomorrow  "
        )

        let presentation = MeetingBookmarkAccessibilityPresentation(bookmark: bookmark)

        XCTAssertEqual(presentation.label, "Marked moment at 01:05")
        XCTAssertEqual(presentation.value, "Category followUp. Note Call Alex tomorrow.")
    }

    func testMarkUsesInjectedClockAndStopWaitsForAcceptedMarkBeforeMetadataFinalization() async throws {
        let manager = DelayedBookmarkMetadataManager()
        let dates = LockedDateSequence([
            Date(timeIntervalSince1970: 10_000),
            Date(timeIntervalSince1970: 10_002.25)
        ])
        let fixture = try makeStoreFixture(metadataCreator: manager, now: { dates.next() })
        defer { fixture.remove() }
        await fixture.store.refreshAudioInputDevices()
        _ = await fixture.store.refreshPermissions()
        fixture.store.startRecordingIntent()
        try await waitUntil("recording starts with delayed bookmark manager") {
            fixture.store.activeRecordingPresentation != nil
        }

        let mark = Task { await fixture.store.markMoment(note: "race-safe") }
        try await waitUntil("mark enters persistence actor") {
            await manager.hasPendingMark
        }
        fixture.store.stopRecordingIntent()
        XCTAssertEqual(fixture.store.recordingState, .processing)
        let beforeReleaseFinalizeCount = await manager.finalizeCount
        XCTAssertEqual(beforeReleaseFinalizeCount, 0)

        await manager.releasePendingMark()
        let accepted = await mark.value
        XCTAssertTrue(accepted)
        try await waitUntil("stop finalizes after durable mark") {
            await manager.finalizeCount == 1
        }
        let latestMetadata = await manager.latestMetadata
        let metadata = try XCTUnwrap(latestMetadata)
        XCTAssertEqual(metadata.bookmarks.map(\.timestamp), [2.25])
        XCTAssertTrue(metadata.isFinalized)
    }

    func testStopRequestsCaptureBeforeAwaitingAcceptedBookmarks() throws {
        let store = try source("Sources/MeetingVault/Stores/MeetingVaultStore.swift")
        let stopMethod = try XCTUnwrap(store.range(of: "func stopRecordingIntent()"))
        let methodTail = store[stopMethod.lowerBound...]
        let stopRequest = try XCTUnwrap(methodTail.range(of: "session.requestStop()"))
        let bookmarkAwait = try XCTUnwrap(methodTail.range(of: "await operation.outcome()"))

        XCTAssertLessThan(
            methodTail.distance(from: methodTail.startIndex, to: stopRequest.lowerBound),
            methodTail.distance(from: methodTail.startIndex, to: bookmarkAwait.lowerBound)
        )
    }

    func testLiveTransportUsesDynamicPrivacyPresentation() throws {
        let card = try source("Sources/MeetingVault/Views/LiveTransportCard.swift")
        XCTAssertFalse(card.contains("Label(\"On-device\""))
        XCTAssertTrue(card.contains("store.transcriptionPrivacyPresentation"))

        XCTAssertEqual(TranscriptionPrivacyPresentation(mode: .localOnly, providerAvailable: true).label, "Local only")
        XCTAssertEqual(TranscriptionPrivacyPresentation(mode: .appleOnDeviceOnly, providerAvailable: true).label, "Apple on-device")
        XCTAssertEqual(
            TranscriptionPrivacyPresentation(mode: .appleMayUseNetwork, providerAvailable: true).accessibilityValue,
            "Apple compatibility; network processing may occur"
        )
        XCTAssertEqual(TranscriptionPrivacyPresentation(mode: .localOnly, providerAvailable: false).label, "Transcription unavailable")
    }

    func testMarkMomentQueuesDistinctGesturesBehindPendingPersistence() async throws {
        let manager = QueuedBookmarkMetadataManager()
        let dates = LockedDateSequence([
            Date(timeIntervalSince1970: 10_000),
            Date(timeIntervalSince1970: 10_000.1),
            Date(timeIntervalSince1970: 10_001.1)
        ])
        let fixture = try makeStoreFixture(metadataCreator: manager, now: { dates.next() })
        defer { fixture.remove() }
        await fixture.store.refreshAudioInputDevices()
        _ = await fixture.store.refreshPermissions()
        fixture.store.startRecordingIntent()
        try await waitUntil("recording starts before queued marks") {
            fixture.store.activeRecordingPresentation != nil
        }

        let first = Task { await fixture.store.markMoment(note: "first") }
        try await waitUntil("first mark enters persistence") {
            await manager.invocationCount == 1
        }
        XCTAssertTrue(fixture.store.recordingBookmarkPresentation.isEnabled)
        let second = Task { await fixture.store.markMoment(note: "second") }

        await manager.releaseNextMark()
        let firstAccepted = await first.value
        XCTAssertTrue(firstAccepted)
        try await Task.sleep(for: .milliseconds(50))
        let invocationCount = await manager.invocationCount
        XCTAssertEqual(invocationCount, 2)
        if invocationCount == 2 {
            await manager.releaseNextMark()
        }
        let secondAccepted = await second.value
        XCTAssertTrue(secondAccepted)
        let timestamps = await manager.markTimestamps
        XCTAssertEqual(timestamps.count, 2)
        if timestamps.count == 2 {
            XCTAssertEqual(timestamps[0], 0.1, accuracy: 0.000_001)
            XCTAssertEqual(timestamps[1], 1.1, accuracy: 0.000_001)
        }
    }

    func testAcceptedOldSessionMarkFinishesSilentlyAfterSleepInvalidatesPublication() async throws {
        let manager = DelayedBookmarkMetadataManager()
        let dates = LockedDateSequence([
            Date(timeIntervalSince1970: 10_000),
            Date(timeIntervalSince1970: 10_001)
        ])
        let fixture = try makeStoreFixture(metadataCreator: manager, now: { dates.next() })
        defer { fixture.remove() }
        await fixture.store.refreshAudioInputDevices()
        _ = await fixture.store.refreshPermissions()
        fixture.store.startRecordingIntent()
        try await waitUntil("recording starts before session-scoped mark") {
            fixture.store.activeRecordingPresentation != nil
        }

        let operation = try XCTUnwrap(fixture.store.acceptMarkMoment(note: "old session"))
        try await waitUntil("old-session mark enters persistence") {
            await manager.hasPendingMark
        }
        await fixture.store.handleSystemSleepInterruption()
        await manager.releasePendingMark()
        let outcome = await operation.outcome()

        guard case .saved = outcome else {
            return XCTFail("Accepted old-session persistence should finish")
        }
        XCTAssertNil(fixture.store.lastMarkedMoment)
        XCTAssertEqual(fixture.store.recordingBookmarkStatus, "Mark Moment is available only while recording")
    }

    func testRecordingDetailKeepsTheAuthoritativeActiveMicrophoneWhenSetupSelectionChanges() async throws {
        let fixture = try makeStoreFixture()
        defer { fixture.remove() }

        await fixture.store.refreshAudioInputDevices()
        _ = await fixture.store.refreshPermissions()
        fixture.store.startRecordingIntent()

        try await waitUntil("recording presentation is published") {
            fixture.store.activeRecordingPresentation != nil
        }
        fixture.store.selectAudioInputDevice(id: "portable-mic")

        XCTAssertEqual(fixture.store.selectedAudioInputDevice?.displayName, "Portable Microphone")
        XCTAssertEqual(fixture.store.activeRecordingPresentation?.microphoneDeviceName, "Studio Microphone")
        XCTAssertEqual(fixture.store.recordingTransportPresentation.detail, "Recording with Studio Microphone")

        fixture.store.stopRecordingIntent()
        try await waitUntil("recording finishes after presentation assertion") {
            fixture.store.activeRecordingPresentation == nil && fixture.store.recordingState == .ready
        }
    }

    func testCancellationIsRejectedWhileRecordingWithoutBreakingTheActiveTransport() async throws {
        let cancellationFixture = try makeStoreFixture()
        defer { cancellationFixture.remove() }
        await cancellationFixture.store.refreshAudioInputDevices()
        _ = await cancellationFixture.store.refreshPermissions()
        cancellationFixture.store.startRecordingIntent()
        try await waitUntil("recording begins before cancellation") {
            cancellationFixture.store.activeRecordingPresentation != nil
        }

        await cancellationFixture.store.cancelRecordingProcessing()

        XCTAssertEqual(cancellationFixture.store.recordingState, .recording)
        XCTAssertNotNil(cancellationFixture.store.activeRecordingPresentation)
        XCTAssertTrue(cancellationFixture.store.canStopRecording)
        XCTAssertEqual(cancellationFixture.store.recordingProcessingStatus, "No recording processing to cancel")

        cancellationFixture.store.stopRecordingIntent()
        try await waitUntil("recording finishes after rejected cancellation") {
            cancellationFixture.store.activeRecordingPresentation == nil
                && cancellationFixture.store.recordingState == .ready
        }
    }

    func testCancellationDuringProcessingTransitionsToReadyAndCannotBeOverwrittenByTheFinishingTask() async throws {
        let capturer = CancellationSuspendingTransportCapturer()
        let fixture = try makeFailingStoreFixture(capturer: capturer)
        defer {
            capturer.release()
            fixture.remove()
        }
        await fixture.store.refreshAudioInputDevices()
        _ = await fixture.store.refreshPermissions()
        fixture.store.startRecordingIntent()
        try await waitUntil("capture begins before processing cancellation") {
            capturer.hasStarted && fixture.store.activeRecordingPresentation != nil
        }

        fixture.store.stopRecordingIntent()
        XCTAssertEqual(fixture.store.recordingState, .processing)
        await fixture.store.cancelRecordingProcessing()

        XCTAssertEqual(fixture.store.recordingState, .processing)
        XCTAssertNil(fixture.store.activeRecordingPresentation)
        XCTAssertFalse(fixture.store.canStopRecording)
        XCTAssertEqual(fixture.store.recordingProcessingStatus, "Cancellation requested")
        await fixture.store.cancelRecordingProcessing()
        XCTAssertEqual(fixture.store.recordingState, .processing)
        XCTAssertEqual(fixture.store.recordingProcessingStatus, "Cancellation requested")
        try await waitUntil("processing worker acknowledges cancellation") {
            fixture.store.recordingState == .ready
                && fixture.store.recordingProcessingStatus == "Processing cancelled"
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(fixture.store.recordingState, .ready)
        XCTAssertEqual(fixture.store.recordingProcessingStatus, "Processing cancelled")
    }

    func testSleepUsesTheActivePresentationCleanupBoundary() async throws {

        let sleepFixture = try makeStoreFixture()
        defer { sleepFixture.remove() }
        await sleepFixture.store.refreshAudioInputDevices()
        _ = await sleepFixture.store.refreshPermissions()
        sleepFixture.store.startRecordingIntent()
        try await waitUntil("recording begins before sleep") {
            sleepFixture.store.activeRecordingPresentation != nil
        }

        await sleepFixture.store.handleSystemSleepInterruption()
        XCTAssertNil(sleepFixture.store.activeRecordingPresentation)
    }

    func testUnsolicitedCaptureFailureWhileRecordingIsObservedAndClearsActiveTransport() async throws {
        let capturer = UnsolicitedFailingTransportCapturer()
        let fixture = try makeFailingStoreFixture(capturer: capturer)
        defer {
            capturer.fail()
            fixture.remove()
        }

        await fixture.store.refreshAudioInputDevices()
        _ = await fixture.store.refreshPermissions()
        fixture.store.startRecordingIntent()
        try await waitUntil("capture begins before unsolicited failure") {
            capturer.hasStarted && fixture.store.activeRecordingPresentation != nil
        }
        let meetingID = try XCTUnwrap(fixture.store.activeRecordingPresentation?.meetingID)

        capturer.fail()
        try await waitUntil("unsolicited capture failure clears active transport") {
            fixture.store.activeRecordingPresentation == nil && fixture.store.recordingState == .error
        }

        XCTAssertEqual(fixture.store.recordingProcessingFailureStage, .recordingAudio)
        XCTAssertFalse(fixture.store.canStopRecording)
        XCTAssertTrue(fixture.store.hasRecordingCaptureRecoveryActions)
        XCTAssertTrue(fixture.store.recordingProcessingStatus.contains("Studio Microphone disconnected"))
        XCTAssertTrue(fixture.store.recoveredRecordings.contains { $0.meetingID == meetingID })
    }

    func testProductionSetupStartsWithLiveTransportAndRemovesDuplicateRecorderPresentation() throws {
        let inspector = try source("Sources/MeetingVault/Views/MeetingWorkspaceInspector.swift")
        let setupStart = try XCTUnwrap(inspector.range(of: "private var setupContent: some View"))
        let setupEnd = try XCTUnwrap(inspector.range(of: "private var audioInputControls: some View"))
        let setup = String(inspector[setupStart.lowerBound..<setupEnd.lowerBound])

        XCTAssertTrue(setup.contains("LiveTransportCard()"))
        XCTAssertLessThan(
            try XCTUnwrap(setup.range(of: "LiveTransportCard()")?.lowerBound),
            try XCTUnwrap(setup.range(of: "audioInputControls")?.lowerBound)
        )

        let recorder = try source("Sources/MeetingVault/Views/RecorderView.swift")
        XCTAssertFalse(recorder.contains("struct RecorderView"))
        XCTAssertFalse(recorder.contains("struct RecordingControlDeck"))
        XCTAssertFalse(recorder.contains("Start Recording\",\n                subtitle:"))
        XCTAssertFalse(recorder.contains("Stop Recording\",\n                subtitle:"))
    }

    func testAllInteractiveSurfacesUseOneSharedResolverAndOneCurrentAction() throws {
        let app = try source("Sources/MeetingVault/App/MeetingVaultApp.swift")
        let toolbar = try source("Sources/MeetingVault/Views/MeetingWorkspaceToolbar.swift")
        let card = try source("Sources/MeetingVault/Views/LiveTransportCard.swift")
        let workspace = try source("Sources/MeetingVault/Views/MeetingsWorkspaceView.swift")
        let transcript = try source("Sources/MeetingVault/Views/MeetingTranscriptWorkspace.swift")
        let inspector = try source("Sources/MeetingVault/Views/MeetingWorkspaceInspector.swift")

        XCTAssertTrue(app.contains("store.recordingTransportPresentation"))
        XCTAssertTrue(toolbar.contains("store.recordingTransportPresentation"))
        XCTAssertTrue(card.contains("store.recordingTransportPresentation"))
        XCTAssertFalse(app.contains("Button(\"Start Recording\")"))
        XCTAssertFalse(app.contains("Button(\"Stop Recording\")"))
        XCTAssertTrue(app.contains("switch transport.action"))
        XCTAssertTrue(workspace.contains("onShowRecordingSetup: { route(.record) }"))
        XCTAssertFalse(workspace.contains("store.startRecordingIntent()"))
        XCTAssertTrue(transcript.contains("Button(\"Recording Setup\""))
        XCTAssertFalse(transcript.contains("Button(\"Record Meeting\""))
        XCTAssertFalse(transcript.contains("startRecordingIntent"))
        XCTAssertTrue(inspector.contains(".disabled(!captureSetupIsEditable)"))
    }

    private func makeStoreFixture(
        metadataCreator: (any RecordingSessionMetadataCreating)? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) throws -> StoreFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultTransport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = MeetingVaultStore(
            permissionProvider: MockPermissionProvider(
                snapshot: PermissionSnapshot(
                    systemAudio: .authorized,
                    microphone: .authorized,
                    speechRecognition: .authorized
                )
            ),
            libraryRoot: root,
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 0x72, count: 32)),
            storageCapacityChecker: TransportStorageCapacityChecker(),
            audioInputDeviceProvider: MockAudioInputDeviceProvider(
                devices: [
                    AudioInputDevice(
                        id: "studio-mic",
                        displayName: "Studio Microphone",
                        transportLabel: "Built-in",
                        isDefault: true,
                        isConnected: true,
                        level: 0.5
                    ),
                    AudioInputDevice(
                        id: "portable-mic",
                        displayName: "Portable Microphone",
                        transportLabel: "USB",
                        isDefault: false,
                        isConnected: true,
                        level: 0.4
                    )
                ]
            ),
            recordingSessionMetadataCreator: metadataCreator,
            includeSampleData: false,
            now: now
        )
        return StoreFixture(store: store, root: root)
    }

    private func makeFailingStoreFixture(
        capturer: any SelectedMicrophoneAudioCapturing
    ) throws -> StoreFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultTransportFailure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = MeetingVaultStore(
            permissionProvider: MockPermissionProvider(
                snapshot: PermissionSnapshot(
                    systemAudio: .authorized,
                    microphone: .authorized,
                    speechRecognition: .authorized
                )
            ),
            libraryRoot: root,
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 0x73, count: 32)),
            storageCapacityChecker: TransportStorageCapacityChecker(),
            audioInputDeviceProvider: MockAudioInputDeviceProvider(
                devices: [
                    AudioInputDevice(
                        id: "studio-mic",
                        displayName: "Studio Microphone",
                        transportLabel: "Built-in",
                        isDefault: true,
                        isConnected: true,
                        level: 0.5
                    )
                ]
            ),
            captureRuntimeMode: .selectedMicrophone,
            selectedMicrophoneCapturer: capturer,
            includeSampleData: false
        )
        return StoreFixture(store: store, root: root)
    }

    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 5,
        condition: @escaping @MainActor () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let succeeded = await condition()
        XCTAssertTrue(succeeded, "Timed out waiting for \(description)")
    }

    private func source(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repoRoot().appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

private actor DelayedBookmarkMetadataManager: RecordingSessionMetadataManaging {
    private var metadata: RecordingSessionMetadata?
    private var pending: CheckedContinuation<MeetingBookmark, Never>?
    private var pendingBookmark: MeetingBookmark?
    private(set) var finalizeCount = 0

    var hasPendingMark: Bool { pending != nil }
    var latestMetadata: RecordingSessionMetadata? { metadata }

    func create(
        meetingID: UUID,
        startedAt: Date,
        context: MeetingContext
    ) async throws -> RecordingSessionMetadata {
        let value = RecordingSessionMetadata(
            meetingID: meetingID,
            startedAt: startedAt,
            context: context
        )
        metadata = value
        return value
    }

    func markMoment(
        meetingID: UUID,
        timestamp: TimeInterval,
        category: MeetingBookmarkCategory?,
        note: String?
    ) async throws -> MeetingBookmark {
        let bookmark = MeetingBookmark(
            meetingID: meetingID,
            timestamp: timestamp,
            createdAt: Date(timeIntervalSince1970: 10_003),
            category: category,
            note: note
        )
        pendingBookmark = bookmark
        return await withCheckedContinuation { pending = $0 }
    }

    func releasePendingMark() {
        guard let bookmark = pendingBookmark, let pending else { return }
        metadata?.bookmarks.append(bookmark)
        metadata?.revision += 1
        self.pending = nil
        pendingBookmark = nil
        pending.resume(returning: bookmark)
    }

    func finalize(meetingID: UUID, duration: TimeInterval) async throws -> RecordingSessionMetadata {
        finalizeCount += 1
        guard var metadata, metadata.meetingID == meetingID else {
            throw RecordingSessionMetadataServiceError.sessionNotActive
        }
        metadata.isFinalized = true
        metadata.revision += 1
        self.metadata = metadata
        return metadata
    }
}

private actor QueuedBookmarkMetadataManager: RecordingSessionMetadataManaging {
    private var metadata: RecordingSessionMetadata?
    private var pending: [(MeetingBookmark, CheckedContinuation<MeetingBookmark, Never>)] = []
    private(set) var markTimestamps: [TimeInterval] = []

    var invocationCount: Int { markTimestamps.count }

    func create(
        meetingID: UUID,
        startedAt: Date,
        context: MeetingContext
    ) async throws -> RecordingSessionMetadata {
        let value = RecordingSessionMetadata(
            meetingID: meetingID,
            startedAt: startedAt,
            context: context
        )
        metadata = value
        return value
    }

    func markMoment(
        meetingID: UUID,
        timestamp: TimeInterval,
        category: MeetingBookmarkCategory?,
        note: String?
    ) async throws -> MeetingBookmark {
        let bookmark = MeetingBookmark(
            meetingID: meetingID,
            timestamp: timestamp,
            createdAt: Date(timeIntervalSince1970: 10_003 + timestamp),
            category: category,
            note: note
        )
        markTimestamps.append(timestamp)
        return await withCheckedContinuation { continuation in
            pending.append((bookmark, continuation))
        }
    }

    func releaseNextMark() {
        guard !pending.isEmpty else { return }
        let (bookmark, continuation) = pending.removeFirst()
        metadata?.bookmarks.append(bookmark)
        metadata?.revision += 1
        continuation.resume(returning: bookmark)
    }

    func finalize(meetingID: UUID, duration: TimeInterval) async throws -> RecordingSessionMetadata {
        guard var metadata, metadata.meetingID == meetingID else {
            throw RecordingSessionMetadataServiceError.sessionNotActive
        }
        metadata.isFinalized = true
        metadata.revision += 1
        self.metadata = metadata
        return metadata
    }
}

private final class LockedDateSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Date]

    init(_ values: [Date]) {
        self.values = values
    }

    func next() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return values.isEmpty ? Date(timeIntervalSince1970: 10_002.25) : values.removeFirst()
    }
}

private struct StoreFixture {
    let store: MeetingVaultStore
    let root: URL

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private struct TransportStorageCapacityChecker: RecordingStorageCapacityChecking {
    func availableCapacityBytes(for directoryURL: URL) throws -> Int64 {
        100 * 1_024 * 1_024 * 1_024
    }
}

private enum TransportCaptureFixtureError: Error, LocalizedError {
    case disconnected

    var errorDescription: String? {
        "Studio Microphone disconnected"
    }
}

private final class UnsolicitedFailingTransportCapturer: SelectedMicrophoneAudioCapturing, @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var failureRequested = false
    private var continuation: CheckedContinuation<CapturedAudioChunk, Error>?

    var hasStarted: Bool {
        lock.withLock { started }
    }

    func capture(_ request: SelectedMicrophoneCaptureRequest) async throws -> CapturedAudioChunk {
        try request.chunkSink?.write(
            CapturedAudioChunk(
                track: .microphone,
                data: Data("checkpoint before unsolicited failure".utf8),
                startTime: 0,
                duration: 1,
                codec: "WAV/PCM"
            )
        )
        return try await withCheckedThrowingContinuation { continuation in
            let shouldFail = lock.withLock {
                started = true
                if failureRequested {
                    return true
                }
                self.continuation = continuation
                return false
            }
            if shouldFail {
                continuation.resume(throwing: TransportCaptureFixtureError.disconnected)
            }
        }
    }

    func fail() {
        let continuation = lock.withLock {
            failureRequested = true
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(throwing: TransportCaptureFixtureError.disconnected)
    }
}

private final class CancellationSuspendingTransportCapturer: SelectedMicrophoneAudioCapturing, @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var cancellationRequested = false
    private var continuation: CheckedContinuation<CapturedAudioChunk, Error>?

    var hasStarted: Bool {
        lock.withLock { started }
    }

    func capture(_ request: SelectedMicrophoneCaptureRequest) async throws -> CapturedAudioChunk {
        lock.withLock { started = true }
        await request.stopSignal?.waitUntilStopped()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let shouldCancel = lock.withLock {
                    if cancellationRequested {
                        return true
                    }
                    self.continuation = continuation
                    return false
                }
                if shouldCancel {
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            self.requestCancellation()
        }
    }

    func release() {
        release(
            returning: CapturedAudioChunk(
                track: .microphone,
                data: Data("released capture".utf8),
                startTime: 0,
                duration: 1,
                codec: "WAV/PCM"
            )
        )
    }

    private func release(returning chunk: CapturedAudioChunk) {
        let continuation = lock.withLock {
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(returning: chunk)
    }

    private func release(throwing error: Error) {
        let continuation = lock.withLock {
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(throwing: error)
    }

    private func requestCancellation() {
        let continuation = lock.withLock {
            cancellationRequested = true
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(throwing: CancellationError())
    }
}
