import AppKit

@MainActor
protocol MainWindowPresenting: AnyObject {
    func present()
}

@MainActor
final class MainWindowPresenter: MainWindowPresenting {
    private let activateApplication: @MainActor () -> Void
    private let revealExistingMainWindow: @MainActor () -> Bool
    private var openMainWindow: @MainActor () -> Void

    init(
        activateApplication: @escaping @MainActor () -> Void = {
            NSApp.activate(ignoringOtherApps: true)
        },
        revealExistingMainWindow: @escaping @MainActor () -> Bool = MainWindowPresenter.revealExistingMeetingVaultWindow,
        openMainWindow: @escaping @MainActor () -> Void = {}
    ) {
        self.activateApplication = activateApplication
        self.revealExistingMainWindow = revealExistingMainWindow
        self.openMainWindow = openMainWindow
    }

    func configureOpenMainWindow(_ action: @escaping @MainActor () -> Void) {
        openMainWindow = action
    }

    func present() {
        activateApplication()
        guard !revealExistingMainWindow() else { return }
        openMainWindow()
        Task { @MainActor [weak self] in
            _ = self?.revealExistingMainWindow()
        }
    }

    private static func revealExistingMeetingVaultWindow() -> Bool {
        guard let window = NSApp.windows.first(where: { window in
            window.identifier?.rawValue == "main"
                || window.title == "MeetingVault"
        }) else {
            return false
        }
        window.makeKeyAndOrderFront(nil)
        return true
    }
}
