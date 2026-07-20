import AppKit
import Combine
import Foundation
import MeetingVaultCore
import SwiftUI

enum MiniRecorderWindowPolicy {
    static let frameAutosaveName = "MeetingVaultMiniRecorderWindow"
    static let idealSize = CGSize(width: 390, height: 330)
    static let minimumSize = CGSize(width: 340, height: 280)

    static func shouldAutoShow(
        previous: RecordingState,
        current: RecordingState,
        enabled: Bool,
        dismissedSessionID: UUID?,
        activeSessionID: UUID?
    ) -> Bool {
        guard enabled,
              current == .recording,
              let activeSessionID,
              dismissedSessionID != activeSessionID
        else {
            return false
        }
        switch previous {
        case .idle, .ready, .permissionNeeded, .error, .recovered:
            return true
        case .recording, .paused, .processing:
            return false
        }
    }

    static func clampedFrame(
        _ restoredFrame: CGRect,
        visibleFrames: [CGRect],
        idealSize: CGSize = idealSize,
        minimumSize: CGSize = minimumSize
    ) -> CGRect {
        let safeIdeal = CGSize(
            width: finitePositive(idealSize.width) ?? Self.idealSize.width,
            height: finitePositive(idealSize.height) ?? Self.idealSize.height
        )
        guard let targetScreen = targetVisibleFrame(for: restoredFrame, in: visibleFrames) else {
            return CGRect(origin: .zero, size: safeIdeal)
        }

        let requestedWidth = finitePositive(restoredFrame.width) ?? safeIdeal.width
        let requestedHeight = finitePositive(restoredFrame.height) ?? safeIdeal.height
        let minimumWidth = min(
            targetScreen.width,
            finitePositive(minimumSize.width) ?? Self.minimumSize.width
        )
        let minimumHeight = min(
            targetScreen.height,
            finitePositive(minimumSize.height) ?? Self.minimumSize.height
        )
        let width = min(targetScreen.width, max(minimumWidth, requestedWidth))
        let height = min(targetScreen.height, max(minimumHeight, requestedHeight))
        let requestedX = restoredFrame.minX.isFinite
            ? restoredFrame.minX
            : targetScreen.midX - width / 2
        let requestedY = restoredFrame.minY.isFinite
            ? restoredFrame.minY
            : targetScreen.midY - height / 2
        let x = min(max(requestedX, targetScreen.minX), targetScreen.maxX - width)
        let y = min(max(requestedY, targetScreen.minY), targetScreen.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    static func defaultFrame(
        visibleFrame: CGRect?,
        idealSize: CGSize = idealSize,
        edgeInset: CGFloat = 24
    ) -> CGRect {
        let safeSize = CGSize(
            width: finitePositive(idealSize.width) ?? Self.idealSize.width,
            height: finitePositive(idealSize.height) ?? Self.idealSize.height
        )
        guard let visibleFrame,
              visibleFrame.width.isFinite,
              visibleFrame.height.isFinite,
              visibleFrame.width > 0,
              visibleFrame.height > 0 else {
            return CGRect(origin: .zero, size: safeSize)
        }
        let width = min(safeSize.width, visibleFrame.width)
        let height = min(safeSize.height, visibleFrame.height)
        let inset = max(0, edgeInset.isFinite ? edgeInset : 0)
        let x = max(visibleFrame.minX, visibleFrame.maxX - width - inset)
        let y = max(visibleFrame.minY, visibleFrame.maxY - height - inset)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static func targetVisibleFrame(
        for restoredFrame: CGRect,
        in visibleFrames: [CGRect]
    ) -> CGRect? {
        let validFrames = visibleFrames.filter {
            $0.width.isFinite && $0.height.isFinite && $0.width > 0 && $0.height > 0
        }
        guard !validFrames.isEmpty else { return nil }

        let intersecting = validFrames.max { lhs, rhs in
            lhs.intersection(restoredFrame).area < rhs.intersection(restoredFrame).area
        }
        if let intersecting,
           intersecting.intersection(restoredFrame).area > 0 {
            return intersecting
        }

        let restoredCenter: CGPoint
        if restoredFrame.midX.isFinite && restoredFrame.midY.isFinite {
            restoredCenter = CGPoint(x: restoredFrame.midX, y: restoredFrame.midY)
        } else {
            return validFrames[0]
        }
        return validFrames.min { lhs, rhs in
            lhs.center.squaredDistance(to: restoredCenter)
                < rhs.center.squaredDistance(to: restoredCenter)
        }
    }

    private static func finitePositive(_ value: CGFloat) -> CGFloat? {
        value.isFinite && value > 0 ? value : nil
    }
}

private extension CGRect {
    var area: CGFloat {
        guard !isNull, !isInfinite else { return 0 }
        return max(0, width) * max(0, height)
    }

    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}

private extension CGPoint {
    func squaredDistance(to other: CGPoint) -> CGFloat {
        let dx = x - other.x
        let dy = y - other.y
        return dx * dx + dy * dy
    }
}

@MainActor
final class MiniRecorderPresentationPreferences: ObservableObject {
    static let automaticallyShowKey = "MeetingVault.miniRecorder.automaticallyShow"

    @Published var automaticallyShowMiniRecorder: Bool {
        didSet {
            userDefaults.set(automaticallyShowMiniRecorder, forKey: Self.automaticallyShowKey)
        }
    }

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        automaticallyShowMiniRecorder = userDefaults.object(forKey: Self.automaticallyShowKey) as? Bool ?? true
    }
}

@MainActor
protocol MiniRecorderPaneling: AnyObject {
    var windowDelegate: NSWindowDelegate? { get set }
    var frame: CGRect { get }
    var isVisible: Bool { get }

    func showWithoutActivation()
    func hide()
    func setFrame(_ frame: CGRect)
    func applyAppearance(_ appearance: NSAppearance?)
}

@MainActor
protocol MiniRecorderPanelCreating: AnyObject {
    func makePanel(rootView: AnyView) -> any MiniRecorderPaneling
}

@MainActor
final class AppKitMiniRecorderPanel: MiniRecorderPaneling {
    let nativePanel: NSPanel

    var windowDelegate: NSWindowDelegate? {
        get { nativePanel.delegate }
        set { nativePanel.delegate = newValue }
    }

    var frame: CGRect { nativePanel.frame }
    var isVisible: Bool { nativePanel.isVisible }

    init(rootView: AnyView) {
        let panel = NSPanel(
            contentRect: MiniRecorderWindowPolicy.defaultFrame(
                visibleFrame: NSScreen.main?.visibleFrame
            ),
            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "MeetingVault Mini Recorder"
        panel.setAccessibilityLabel("MeetingVault Mini Recorder")
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.minSize = MiniRecorderWindowPolicy.minimumSize
        panel.contentMinSize = MiniRecorderWindowPolicy.minimumSize
        panel.contentView = NSHostingView(rootView: rootView)
        panel.setFrameAutosaveName(MiniRecorderWindowPolicy.frameAutosaveName)
        nativePanel = panel
    }

    func showWithoutActivation() {
        nativePanel.orderFrontRegardless()
    }

    func hide() {
        nativePanel.orderOut(nil)
    }

    func setFrame(_ frame: CGRect) {
        nativePanel.setFrame(frame, display: true)
    }

    func applyAppearance(_ appearance: NSAppearance?) {
        nativePanel.appearance = appearance
    }
}

@MainActor
final class AppKitMiniRecorderPanelFactory: MiniRecorderPanelCreating {
    func makePanel(rootView: AnyView) -> any MiniRecorderPaneling {
        AppKitMiniRecorderPanel(rootView: rootView)
    }
}

@MainActor
final class MiniRecorderWindowCoordinator: NSObject, ObservableObject, NSWindowDelegate {
    private let preferences: MiniRecorderPresentationPreferences
    private let panelFactory: any MiniRecorderPanelCreating
    private let screenVisibleFrames: () -> [CGRect]
    private let activeSessionID: () -> UUID?
    private let currentAppearance: () -> MeetingVaultAppearancePreference
    private let mainWindowPresenter: any MainWindowPresenting
    private let activateApplication: () -> Void
    private let rootView: AnyView
    private var panel: (any MiniRecorderPaneling)?
    private var subscriptions: Set<AnyCancellable> = []
    private var lastObservedRecordingState: RecordingState?

    private(set) var dismissedSessionID: UUID?
    private(set) var currentSessionID: UUID?

    init(
        preferences: MiniRecorderPresentationPreferences,
        panelFactory: any MiniRecorderPanelCreating,
        screenVisibleFrames: @escaping () -> [CGRect],
        activeSessionID: @escaping () -> UUID?,
        currentAppearance: @escaping () -> MeetingVaultAppearancePreference,
        mainWindowPresenter: any MainWindowPresenting,
        activateApplication: @escaping () -> Void,
        rootView: AnyView
    ) {
        self.preferences = preferences
        self.panelFactory = panelFactory
        self.screenVisibleFrames = screenVisibleFrames
        self.activeSessionID = activeSessionID
        self.currentAppearance = currentAppearance
        self.mainWindowPresenter = mainWindowPresenter
        self.activateApplication = activateApplication
        self.rootView = rootView
        super.init()
    }

    convenience init(
        store: MeetingVaultStore,
        appearanceCoordinator: MeetingVaultAppearanceCoordinator,
        preferences: MiniRecorderPresentationPreferences,
        mainWindowPresenter: MainWindowPresenter,
        panelFactory: any MiniRecorderPanelCreating = AppKitMiniRecorderPanelFactory(),
        screenVisibleFrames: @escaping () -> [CGRect] = { NSScreen.screens.map(\.visibleFrame) },
        activateApplication: @escaping () -> Void = {
            NSApp.activate(ignoringOtherApps: true)
        }
    ) {
        let rootView = AnyView(
            MiniRecorderView(returnToMeetingVault: mainWindowPresenter.present)
                .environmentObject(store)
                .environmentObject(appearanceCoordinator)
                .resolvedReduceMotion(
                    MeetingVaultLaunchAccessibilityTraits.fromArguments().reduceMotion
                )
        )
        self.init(
            preferences: preferences,
            panelFactory: panelFactory,
            screenVisibleFrames: screenVisibleFrames,
            activeSessionID: { [weak store] in store?.activeRecordingPresentation?.meetingID },
            currentAppearance: { [weak appearanceCoordinator] in
                appearanceCoordinator?.effectivePreference ?? .system
            },
            mainWindowPresenter: mainWindowPresenter,
            activateApplication: activateApplication,
            rootView: rootView
        )
        observe(
            store: store,
            appearanceCoordinator: appearanceCoordinator,
            preferences: preferences
        )
    }

    func show(activate: Bool = false) {
        let panel = panelInstance()
        if let activeSessionID = activeSessionID() {
            currentSessionID = activeSessionID
            if dismissedSessionID == activeSessionID {
                dismissedSessionID = nil
            }
        }
        restoreVisibleFrame(for: panel)
        panel.applyAppearance(currentAppearance().nsAppearance)
        panel.showWithoutActivation()
        if activate {
            activateApplication()
        }
    }

    func hide() {
        orderOut(recordDismissal: true, clearSession: false)
    }

    func recordingStateDidChange(from previous: RecordingState, to current: RecordingState) {
        if MiniRecorderWindowPolicy.shouldAutoShow(
            previous: previous,
            current: current,
            enabled: preferences.automaticallyShowMiniRecorder,
            dismissedSessionID: dismissedSessionID,
            activeSessionID: activeSessionID()
        ) {
            show(activate: false)
            return
        }

        if previous == .recording, current == .processing {
            return
        }
        if previous == .recording || previous == .processing,
           current != .recording,
           current != .processing {
            orderOut(recordDismissal: false, clearSession: true)
        }
    }

    func presentationPreferenceDidChange() {
        guard !preferences.automaticallyShowMiniRecorder else { return }
        orderOut(recordDismissal: false, clearSession: false)
    }

    func appearanceDidChange() {
        panel?.applyAppearance(currentAppearance().nsAppearance)
    }

    func screenConfigurationDidChange() {
        guard let panel else { return }
        restoreVisibleFrame(for: panel)
    }

    func showMainWindow() {
        mainWindowPresenter.present()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        _ = sender
        hide()
        return false
    }

    private func panelInstance() -> any MiniRecorderPaneling {
        if let panel { return panel }
        let created = panelFactory.makePanel(rootView: rootView)
        created.windowDelegate = self
        panel = created
        return created
    }

    private func restoreVisibleFrame(for panel: any MiniRecorderPaneling) {
        panel.setFrame(MiniRecorderWindowPolicy.clampedFrame(
            panel.frame,
            visibleFrames: screenVisibleFrames()
        ))
    }

    private func orderOut(recordDismissal: Bool, clearSession: Bool) {
        if recordDismissal, let currentSessionID {
            dismissedSessionID = currentSessionID
        }
        panel?.hide()
        if clearSession {
            currentSessionID = nil
        }
    }

    private func observe(
        store: MeetingVaultStore,
        appearanceCoordinator: MeetingVaultAppearanceCoordinator,
        preferences: MiniRecorderPresentationPreferences
    ) {
        lastObservedRecordingState = store.recordingState
        store.$recordingState
            .removeDuplicates()
            .sink { [weak self] current in
                guard let self else { return }
                let previous = self.lastObservedRecordingState
                self.lastObservedRecordingState = current
                guard let previous, previous != current else { return }
                self.recordingStateDidChange(from: previous, to: current)
            }
            .store(in: &subscriptions)

        appearanceCoordinator.$savedPreference
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.appearanceDidChange()
                }
            }
            .store(in: &subscriptions)

        preferences.$automaticallyShowMiniRecorder
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.presentationPreferenceDidChange()
                }
            }
            .store(in: &subscriptions)

        NotificationCenter.default.publisher(
            for: NSApplication.didChangeScreenParametersNotification
        )
        .sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.screenConfigurationDidChange()
            }
        }
        .store(in: &subscriptions)
    }
}
