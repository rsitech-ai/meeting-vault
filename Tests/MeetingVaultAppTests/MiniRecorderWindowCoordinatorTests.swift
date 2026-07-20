import AppKit
import MeetingVaultCore
import SwiftUI
import XCTest
@testable import MeetingVault

@MainActor
final class MiniRecorderWindowCoordinatorTests: XCTestCase {
    func testPresentationPreferenceDefaultsEnabledAndPersistsOverride() {
        let defaults = isolatedDefaults()
        let preferences = MiniRecorderPresentationPreferences(userDefaults: defaults)

        XCTAssertTrue(preferences.automaticallyShowMiniRecorder)

        preferences.automaticallyShowMiniRecorder = false
        XCTAssertFalse(
            MiniRecorderPresentationPreferences(userDefaults: defaults)
                .automaticallyShowMiniRecorder
        )
    }

    func testPolicyAutoShowsOnlyForRealStartWithValidUndismissedSession() {
        let sessionID = UUID()

        for previous in [
            RecordingState.idle,
            .ready,
            .permissionNeeded,
            .error,
            .recovered
        ] {
            XCTAssertTrue(MiniRecorderWindowPolicy.shouldAutoShow(
                previous: previous,
                current: .recording,
                enabled: true,
                dismissedSessionID: nil,
                activeSessionID: sessionID
            ))
        }

        for previous in [RecordingState.recording, .paused, .processing] {
            XCTAssertFalse(MiniRecorderWindowPolicy.shouldAutoShow(
                previous: previous,
                current: .recording,
                enabled: true,
                dismissedSessionID: nil,
                activeSessionID: sessionID
            ))
        }

        XCTAssertFalse(MiniRecorderWindowPolicy.shouldAutoShow(
            previous: .ready,
            current: .recording,
            enabled: false,
            dismissedSessionID: nil,
            activeSessionID: sessionID
        ))
        XCTAssertFalse(MiniRecorderWindowPolicy.shouldAutoShow(
            previous: .ready,
            current: .recording,
            enabled: true,
            dismissedSessionID: nil,
            activeSessionID: nil
        ))
        XCTAssertFalse(MiniRecorderWindowPolicy.shouldAutoShow(
            previous: .ready,
            current: .recording,
            enabled: true,
            dismissedSessionID: sessionID,
            activeSessionID: sessionID
        ))
    }

    func testRepeatedShowAndRepeatedRecordingEventsReuseOnePanel() {
        let fixture = makeFixture()
        fixture.coordinator.show()
        fixture.coordinator.show()
        fixture.coordinator.recordingStateDidChange(from: .ready, to: .recording)
        fixture.coordinator.recordingStateDidChange(from: .ready, to: .recording)

        XCTAssertEqual(fixture.factory.makeCount, 1)
        XCTAssertEqual(fixture.panel.showCount, 4)
        XCTAssertTrue(fixture.panel.isVisible)
    }

    func testNonactivatingShowOrdersFrontWithoutApplicationActivationOrKeyFocus() {
        let fixture = makeFixture()

        fixture.coordinator.show(activate: false)

        XCTAssertEqual(fixture.panel.showCount, 1)
        XCTAssertEqual(fixture.activation.count, 0)
        XCTAssertEqual(fixture.panel.makeKeyCount, 0)
    }

    func testExplicitActivatingShowActivatesOnlyAfterUserRequestsIt() {
        let fixture = makeFixture()

        fixture.coordinator.show(activate: true)

        XCTAssertEqual(fixture.activation.count, 1)
        XCTAssertEqual(fixture.panel.showCount, 1)
        XCTAssertEqual(fixture.panel.makeKeyCount, 0)
    }

    func testCloseOrdersOutRecordsCurrentSessionAndNeverRunsTransportAction() {
        let fixture = makeFixture()
        fixture.coordinator.recordingStateDidChange(from: .ready, to: .recording)

        let shouldClose = fixture.coordinator.windowShouldClose(NSWindow())

        XCTAssertFalse(shouldClose)
        XCTAssertFalse(fixture.panel.isVisible)
        XCTAssertEqual(fixture.panel.hideCount, 1)
        XCTAssertEqual(fixture.coordinator.dismissedSessionID, fixture.session.id)
        XCTAssertEqual(fixture.transport.stopCount, 0)
        XCTAssertEqual(fixture.transport.markCount, 0)
    }

    func testDismissalAppliesOnlyToCurrentSessionAndNextSessionAutoShows() {
        let fixture = makeFixture()
        let firstSession = fixture.session.id
        fixture.coordinator.recordingStateDidChange(from: .ready, to: .recording)
        fixture.coordinator.hide()

        fixture.coordinator.recordingStateDidChange(from: .ready, to: .recording)
        XCTAssertEqual(fixture.panel.showCount, 1)

        fixture.session.id = UUID()
        fixture.coordinator.recordingStateDidChange(from: .ready, to: .recording)

        XCTAssertNotEqual(fixture.session.id, firstSession)
        XCTAssertEqual(fixture.panel.showCount, 2)
        XCTAssertTrue(fixture.panel.isVisible)
    }

    func testManualReopenClearsDismissalAndReusesSamePanel() {
        let fixture = makeFixture()
        fixture.coordinator.recordingStateDidChange(from: .ready, to: .recording)
        fixture.coordinator.hide()

        fixture.coordinator.show()

        XCTAssertNil(fixture.coordinator.dismissedSessionID)
        XCTAssertEqual(fixture.factory.makeCount, 1)
        XCTAssertEqual(fixture.panel.showCount, 2)
        XCTAssertTrue(fixture.panel.isVisible)
    }

    func testProcessingKeepsPanelVisibleUntilRecordingWorkflowEnds() {
        let fixture = makeFixture()
        fixture.coordinator.recordingStateDidChange(from: .ready, to: .recording)

        fixture.coordinator.recordingStateDidChange(from: .recording, to: .processing)
        XCTAssertTrue(fixture.panel.isVisible)

        fixture.coordinator.recordingStateDidChange(from: .processing, to: .ready)
        XCTAssertFalse(fixture.panel.isVisible)
        XCTAssertNil(fixture.coordinator.currentSessionID)
        XCTAssertEqual(fixture.transport.stopCount, 0)
    }

    func testDisablingAutoShowHidesWithoutMarkingSessionDismissed() {
        let fixture = makeFixture()
        fixture.coordinator.recordingStateDidChange(from: .ready, to: .recording)

        fixture.preferences.automaticallyShowMiniRecorder = false
        fixture.coordinator.presentationPreferenceDidChange()

        XCTAssertFalse(fixture.panel.isVisible)
        XCTAssertNil(fixture.coordinator.dismissedSessionID)
    }

    func testReturnToMainUsesPresenterWithoutClosingOrRecreatingPanel() {
        let fixture = makeFixture()
        fixture.coordinator.show()

        fixture.coordinator.showMainWindow()

        XCTAssertEqual(fixture.mainWindow.showCount, 1)
        XCTAssertTrue(fixture.panel.isVisible)
        XCTAssertEqual(fixture.factory.makeCount, 1)
    }

    func testMainWindowPresenterRevealsExistingWindowWithoutOpeningAnother() {
        let activation = CountProbe()
        let reveal = BooleanProbe(values: [true])
        let open = CountProbe()
        let presenter = MainWindowPresenter(
            activateApplication: activation.increment,
            revealExistingMainWindow: reveal.next,
            openMainWindow: open.increment
        )

        presenter.present()

        XCTAssertEqual(activation.count, 1)
        XCTAssertEqual(reveal.count, 1)
        XCTAssertEqual(open.count, 0)
    }

    func testMainWindowPresenterOpensMissingMainWindow() {
        let activation = CountProbe()
        let reveal = BooleanProbe(values: [false])
        let open = CountProbe()
        let presenter = MainWindowPresenter(
            activateApplication: activation.increment,
            revealExistingMainWindow: reveal.next,
            openMainWindow: open.increment
        )

        presenter.present()

        XCTAssertEqual(activation.count, 1)
        XCTAssertEqual(reveal.count, 1)
        XCTAssertEqual(open.count, 1)
    }

    func testAppearanceChangesApplyToExistingPanel() {
        let appearance = AppearanceBox(.system)
        let fixture = makeFixture(appearance: appearance)
        fixture.coordinator.show()

        appearance.preference = .dark
        fixture.coordinator.appearanceDidChange()

        XCTAssertEqual(fixture.factory.makeCount, 1)
        XCTAssertEqual(fixture.panel.appearanceNames.last, .darkAqua)
    }

    func testFramePolicyClampsRestoredFrameFullyInsideNearestVisibleScreen() {
        let screens = [
            CGRect(x: 0, y: 0, width: 1_440, height: 900),
            CGRect(x: 1_440, y: 80, width: 1_920, height: 1_080)
        ]
        let restored = CGRect(x: 3_250, y: 1_020, width: 420, height: 300)

        let result = MiniRecorderWindowPolicy.clampedFrame(
            restored,
            visibleFrames: screens,
            idealSize: CGSize(width: 390, height: 330),
            minimumSize: CGSize(width: 340, height: 280)
        )

        XCTAssertTrue(screens[1].contains(result))
        XCTAssertEqual(result.maxX, screens[1].maxX, accuracy: 0.001)
        XCTAssertEqual(result.maxY, screens[1].maxY, accuracy: 0.001)
    }

    func testFramePolicyShrinksOversizedFrameAndHandlesNoScreenFallback() {
        let smallScreen = CGRect(x: 20, y: 40, width: 320, height: 240)
        let oversized = CGRect(x: -10_000, y: 20_000, width: 900, height: 700)

        let clamped = MiniRecorderWindowPolicy.clampedFrame(
            oversized,
            visibleFrames: [smallScreen],
            idealSize: MiniRecorderWindowPolicy.idealSize,
            minimumSize: MiniRecorderWindowPolicy.minimumSize
        )
        XCTAssertEqual(clamped, smallScreen)

        let fallback = MiniRecorderWindowPolicy.clampedFrame(
            CGRect(x: CGFloat.nan, y: CGFloat.infinity, width: -1, height: 0),
            visibleFrames: [],
            idealSize: CGSize(width: 390, height: 330),
            minimumSize: CGSize(width: 340, height: 280)
        )
        XCTAssertEqual(fallback, CGRect(x: 0, y: 0, width: 390, height: 330))
    }

    func testDefaultFrameUsesCalmUpperTrailingPlacementInsideVisibleScreen() {
        let screen = CGRect(x: -1_920, y: 24, width: 1_920, height: 1_056)

        let frame = MiniRecorderWindowPolicy.defaultFrame(
            visibleFrame: screen,
            idealSize: CGSize(width: 390, height: 330),
            edgeInset: 24
        )

        XCTAssertTrue(screen.contains(frame))
        XCTAssertEqual(frame.maxX, screen.maxX - 24, accuracy: 0.001)
        XCTAssertEqual(frame.maxY, screen.maxY - 24, accuracy: 0.001)
    }

    func testScreenConfigurationChangeReclampsExistingPanelWithoutRecreation() {
        let screens = ScreenBox([CGRect(x: 0, y: 0, width: 1_440, height: 900)])
        let fixture = makeFixture(screens: screens)
        fixture.panel.frame = CGRect(x: 1_000, y: 600, width: 390, height: 330)
        fixture.coordinator.show()

        screens.frames = [CGRect(x: 0, y: 0, width: 800, height: 600)]
        fixture.coordinator.screenConfigurationDidChange()

        XCTAssertTrue(screens.frames[0].contains(fixture.panel.frame))
        XCTAssertEqual(fixture.factory.makeCount, 1)
    }

    func testRealPanelHasRequiredNonactivatingUtilityConfiguration() {
        let adapter = AppKitMiniRecorderPanel(rootView: AnyView(EmptyView()))
        let panel = adapter.nativePanel

        XCTAssertTrue(panel.styleMask.contains(.titled))
        XCTAssertTrue(panel.styleMask.contains(.closable))
        XCTAssertTrue(panel.styleMask.contains(.utilityWindow))
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(panel.isFloatingPanel)
        XCTAssertEqual(panel.level, .floating)
        XCTAssertFalse(panel.hidesOnDeactivate)
        XCTAssertTrue(panel.becomesKeyOnlyIfNeeded)
        XCTAssertFalse(panel.isReleasedWhenClosed)
        XCTAssertEqual(panel.title, "MeetingVault Mini Recorder")
        XCTAssertEqual(panel.frameAutosaveName, MiniRecorderWindowPolicy.frameAutosaveName)
    }

    func testCoordinatorAndPanelReleaseWithoutRetainCycle() {
        let preferences = MiniRecorderPresentationPreferences(userDefaults: isolatedDefaults())
        let factory = EphemeralPanelFactory()
        weak var weakCoordinator: MiniRecorderWindowCoordinator?
        weak var weakPanel: EphemeralPanel?

        autoreleasepool {
            var coordinator: MiniRecorderWindowCoordinator? = MiniRecorderWindowCoordinator(
                preferences: preferences,
                panelFactory: factory,
                screenVisibleFrames: { [CGRect(x: 0, y: 0, width: 1_440, height: 900)] },
                activeSessionID: { UUID() },
                currentAppearance: { .system },
                mainWindowPresenter: FakeMainWindowPresenter(),
                activateApplication: {},
                rootView: AnyView(EmptyView())
            )
            coordinator?.show()
            weakCoordinator = coordinator
            weakPanel = factory.lastPanel
            coordinator = nil
        }

        XCTAssertNil(weakCoordinator)
        XCTAssertNil(weakPanel)
    }

    func testSpeakerPresentationIsUnavailableWithoutCurrentTranscriptEvidence() {
        XCTAssertEqual(
            MiniRecorderSpeakerPresentation.resolve(segments: [], elapsedTime: 12),
            MiniRecorderSpeakerPresentation(
                title: "Speaker unavailable",
                systemImage: "person.crop.circle.badge.questionmark",
                isOverlap: false
            )
        )

        let stale = TranscriptSegment(
            speakerName: "You",
            trackKind: .microphone,
            startTime: 1,
            endTime: 2,
            text: "Earlier words",
            confidence: 0.9,
            isFinal: true
        )
        XCTAssertEqual(
            MiniRecorderSpeakerPresentation.resolve(segments: [stale], elapsedTime: 12).title,
            "Speaker unavailable"
        )
    }

    func testSpeakerPresentationUsesCurrentEvidenceAndNamesOverlapExplicitly() {
        let you = TranscriptSegment(
            speakerName: "You",
            trackKind: .microphone,
            startTime: 9,
            endTime: 11,
            text: "Current words",
            confidence: 0.9,
            isFinal: false
        )
        let remote = TranscriptSegment(
            speakerName: "Speaker 2",
            trackKind: .remoteSystem,
            startTime: 10,
            endTime: 12,
            text: "Overlapping words",
            confidence: 0.8,
            isFinal: false
        )

        XCTAssertEqual(
            MiniRecorderSpeakerPresentation.resolve(segments: [you], elapsedTime: 10).title,
            "You speaking"
        )
        XCTAssertEqual(
            MiniRecorderSpeakerPresentation.resolve(segments: [you, remote], elapsedTime: 10),
            MiniRecorderSpeakerPresentation(
                title: "Overlapping speakers",
                systemImage: "person.2.wave.2",
                isOverlap: true
            )
        )
    }

    func testSpeakerPresentationDoesNotInventOverlapFromSequentialGraceWindows() {
        let first = TranscriptSegment(
            speakerName: "You",
            trackKind: .microphone,
            startTime: 8,
            endTime: 10,
            text: "First",
            confidence: 0.9,
            isFinal: true
        )
        let second = TranscriptSegment(
            speakerName: "Speaker 2",
            trackKind: .remoteSystem,
            startTime: 10.1,
            endTime: 12,
            text: "Second",
            confidence: 0.9,
            isFinal: false
        )

        let result = MiniRecorderSpeakerPresentation.resolve(
            segments: [first, second],
            elapsedTime: 10.2
        )

        XCTAssertEqual(result.title, "Speaker 2 speaking")
        XCTAssertFalse(result.isOverlap)
    }

    func testMiniRecorderViewUsesAuthoritativeSharedActionsSignalsAndAccessibility() throws {
        let source = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("Sources/MeetingVault/Views/MiniRecorderView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("store.recordingTransportPresentation"))
        XCTAssertTrue(source.contains("store.stopRecordingIntent()"))
        XCTAssertTrue(source.contains("store.markMomentIntent()"))
        XCTAssertTrue(source.contains("store.recordingBookmarkPresentation"))
        XCTAssertTrue(source.contains("store.recordingLevelSnapshot"))
        XCTAssertTrue(source.contains("store.liveTranscriptPreviewSegments"))
        XCTAssertTrue(source.contains("RecordingVoiceSignal("))
        XCTAssertTrue(source.contains("Finalizing Recording"))
        XCTAssertTrue(source.contains("Return to MeetingVault"))
        XCTAssertTrue(source.contains("accessibilitySortPriority"))
        XCTAssertTrue(source.contains("keyboardShortcut"))
        XCTAssertFalse(source.contains("Double.random"))
        XCTAssertFalse(source.contains("Timer.scheduledTimer"))

        let signal = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("Sources/MeetingVault/Views/RecordingVoiceSignal.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(signal.contains(".scaleEffect("))
        XCTAssertFalse(signal.contains(".frame(width: 34 + pulse"))
    }

    func testAppOwnsOneCoordinatorObservesStoreAndOffersManualReopen() throws {
        let app = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("Sources/MeetingVault/App/MeetingVaultApp.swift"),
            encoding: .utf8
        )
        let coordinator = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("Sources/MeetingVault/App/MiniRecorderWindowCoordinator.swift"),
            encoding: .utf8
        )
        let settings = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("Sources/MeetingVault/Views/SettingsView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(app.contains("@StateObject private var miniRecorderCoordinator"))
        XCTAssertTrue(app.contains("@StateObject private var miniRecorderPreferences"))
        XCTAssertTrue(app.contains("MiniRecorderWindowCoordinator("))
        XCTAssertTrue(app.contains("mainWindowPresenter.configureOpenMainWindow"))
        XCTAssertTrue(app.contains("openWindow(id: \"main\")"))
        XCTAssertTrue(app.contains("Button(\"Show Mini Recorder\")"))
        XCTAssertTrue(app.contains("miniRecorderCoordinator.show(activate: false)"))
        XCTAssertTrue(app.contains(".environmentObject(miniRecorderPreferences)"))

        XCTAssertTrue(coordinator.contains("store.$recordingState"))
        XCTAssertTrue(coordinator.contains("appearanceCoordinator.$savedPreference"))
        XCTAssertTrue(coordinator.contains("preferences.$automaticallyShowMiniRecorder"))
        XCTAssertTrue(coordinator.contains("NSApplication.didChangeScreenParametersNotification"))
        XCTAssertTrue(coordinator.contains(".resolvedReduceMotion("))
        let delegateStart = try XCTUnwrap(coordinator.range(of: "func windowShouldClose"))
        let delegateEnd = try XCTUnwrap(
            coordinator.range(of: "private func panelInstance", range: delegateStart.upperBound..<coordinator.endIndex)
        )
        let closeSource = coordinator[delegateStart.lowerBound..<delegateEnd.lowerBound]
        XCTAssertFalse(closeSource.contains("stopRecordingIntent"))
        XCTAssertFalse(closeSource.contains("markMoment"))

        XCTAssertTrue(settings.contains("@EnvironmentObject private var miniRecorderPreferences"))
        XCTAssertTrue(settings.contains("Show Mini Recorder when recording starts"))
        XCTAssertTrue(settings.contains("$miniRecorderPreferences.automaticallyShowMiniRecorder"))
    }

    private func makeFixture(
        appearance: AppearanceBox = AppearanceBox(.system),
        screens: ScreenBox = ScreenBox([CGRect(x: 0, y: 0, width: 1_440, height: 900)])
    ) -> CoordinatorFixture {
        let preferences = MiniRecorderPresentationPreferences(userDefaults: isolatedDefaults())
        let panel = FakeMiniRecorderPanel()
        let factory = FakeMiniRecorderPanelFactory(panel: panel)
        let session = SessionBox(UUID())
        let mainWindow = FakeMainWindowPresenter()
        let activation = CountProbe()
        let transport = TransportProbe()
        let coordinator = MiniRecorderWindowCoordinator(
            preferences: preferences,
            panelFactory: factory,
            screenVisibleFrames: { screens.frames },
            activeSessionID: { session.id },
            currentAppearance: { appearance.preference },
            mainWindowPresenter: mainWindow,
            activateApplication: activation.increment,
            rootView: AnyView(
                Button("Stop") { transport.stopCount += 1 }
                    .contextMenu {
                        Button("Mark") { transport.markCount += 1 }
                    }
            )
        )
        return CoordinatorFixture(
            coordinator: coordinator,
            preferences: preferences,
            panel: panel,
            factory: factory,
            session: session,
            mainWindow: mainWindow,
            activation: activation,
            transport: transport
        )
    }

    private func isolatedDefaults() -> UserDefaults {
        let suiteName = "MiniRecorderWindowCoordinatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

@MainActor
private struct CoordinatorFixture {
    let coordinator: MiniRecorderWindowCoordinator
    let preferences: MiniRecorderPresentationPreferences
    let panel: FakeMiniRecorderPanel
    let factory: FakeMiniRecorderPanelFactory
    let session: SessionBox
    let mainWindow: FakeMainWindowPresenter
    let activation: CountProbe
    let transport: TransportProbe
}

@MainActor
private final class FakeMiniRecorderPanel: MiniRecorderPaneling {
    weak var windowDelegate: NSWindowDelegate?
    var frame = CGRect(x: 520, y: 300, width: 390, height: 330)
    private(set) var isVisible = false
    private(set) var showCount = 0
    private(set) var hideCount = 0
    private(set) var makeKeyCount = 0
    private(set) var appearanceNames: [NSAppearance.Name?] = []

    func showWithoutActivation() {
        showCount += 1
        isVisible = true
    }

    func hide() {
        hideCount += 1
        isVisible = false
    }

    func setFrame(_ frame: CGRect) {
        self.frame = frame
    }

    func applyAppearance(_ appearance: NSAppearance?) {
        appearanceNames.append(appearance?.name)
    }
}

@MainActor
private final class FakeMiniRecorderPanelFactory: MiniRecorderPanelCreating {
    let panel: FakeMiniRecorderPanel
    private(set) var makeCount = 0

    init(panel: FakeMiniRecorderPanel) {
        self.panel = panel
    }

    func makePanel(rootView: AnyView) -> any MiniRecorderPaneling {
        _ = rootView
        makeCount += 1
        return panel
    }
}

@MainActor
private final class EphemeralPanel: MiniRecorderPaneling {
    weak var windowDelegate: NSWindowDelegate?
    var frame = CGRect(x: 0, y: 0, width: 390, height: 330)
    var isVisible = false

    func showWithoutActivation() { isVisible = true }
    func hide() { isVisible = false }
    func setFrame(_ frame: CGRect) { self.frame = frame }
    func applyAppearance(_ appearance: NSAppearance?) { _ = appearance }
}

@MainActor
private final class EphemeralPanelFactory: MiniRecorderPanelCreating {
    weak var lastPanel: EphemeralPanel?

    func makePanel(rootView: AnyView) -> any MiniRecorderPaneling {
        _ = rootView
        let panel = EphemeralPanel()
        lastPanel = panel
        return panel
    }
}

@MainActor
private final class FakeMainWindowPresenter: MainWindowPresenting {
    private(set) var showCount = 0
    func present() { showCount += 1 }
}

@MainActor
private final class CountProbe {
    private(set) var count = 0
    func increment() { count += 1 }
}

@MainActor
private final class BooleanProbe {
    private var values: [Bool]
    private(set) var count = 0

    init(values: [Bool]) {
        self.values = values
    }

    func next() -> Bool {
        count += 1
        return values.isEmpty ? false : values.removeFirst()
    }
}

@MainActor
private final class SessionBox {
    var id: UUID
    init(_ id: UUID) { self.id = id }
}

@MainActor
private final class AppearanceBox {
    var preference: MeetingVaultAppearancePreference
    init(_ preference: MeetingVaultAppearancePreference) { self.preference = preference }
}

@MainActor
private final class ScreenBox {
    var frames: [CGRect]
    init(_ frames: [CGRect]) { self.frames = frames }
}

@MainActor
private final class TransportProbe {
    var stopCount = 0
    var markCount = 0
}
