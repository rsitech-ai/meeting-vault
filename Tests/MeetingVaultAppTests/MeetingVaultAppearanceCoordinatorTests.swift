import AppKit
import XCTest
@testable import MeetingVault

@MainActor
final class MeetingVaultAppearanceCoordinatorTests: XCTestCase {
    func testMissingSavedPreferenceDefaultsToSystem() {
        let defaults = makeDefaults()

        let coordinator = MeetingVaultAppearanceCoordinator(
            userDefaults: defaults,
            arguments: ["MeetingVault"],
            applyAppearance: { _ in }
        )

        XCTAssertEqual(coordinator.savedPreference, .system)
        XCTAssertEqual(coordinator.effectivePreference, .system)
    }

    func testPersistedLightAndDarkPreferencesAreRestored() {
        let lightDefaults = makeDefaults()
        lightDefaults.set("light", forKey: "MeetingVault.appearance")
        let darkDefaults = makeDefaults()
        darkDefaults.set("dark", forKey: "MeetingVault.appearance")

        let lightCoordinator = MeetingVaultAppearanceCoordinator(
            userDefaults: lightDefaults,
            arguments: ["MeetingVault"],
            applyAppearance: { _ in }
        )
        let darkCoordinator = MeetingVaultAppearanceCoordinator(
            userDefaults: darkDefaults,
            arguments: ["MeetingVault"],
            applyAppearance: { _ in }
        )

        XCTAssertEqual(lightCoordinator.savedPreference, .light)
        XCTAssertEqual(lightCoordinator.effectivePreference, .light)
        XCTAssertEqual(darkCoordinator.savedPreference, .dark)
        XCTAssertEqual(darkCoordinator.effectivePreference, .dark)
    }

    func testInvalidOverrideLeavesSavedDarkEffective() {
        XCTAssertNil(MeetingVaultAppearanceResolution.launchOverride(
            from: ["MeetingVault", "--appearance", "sepia"]
        ))
        XCTAssertEqual(
            MeetingVaultAppearanceResolution.effective(saved: .dark, launchOverride: nil),
            .dark
        )
    }

    func testValidLaunchOverrideWinsWithoutMutatingPersistedPreference() {
        let defaults = makeDefaults()
        defaults.set("light", forKey: "MeetingVault.appearance")
        var appliedNames: [NSAppearance.Name?] = []

        let coordinator = MeetingVaultAppearanceCoordinator(
            userDefaults: defaults,
            arguments: ["MeetingVault", "--appearance", "Dark"],
            applyAppearance: { appliedNames.append($0?.name) }
        )

        XCTAssertEqual(coordinator.savedPreference, .light)
        XCTAssertEqual(coordinator.launchOverride, .dark)
        XCTAssertEqual(coordinator.effectivePreference, .dark)
        XCTAssertEqual(defaults.string(forKey: "MeetingVault.appearance"), "light")
        XCTAssertEqual(appliedNames, [.darkAqua])
    }

    func testUpdatingSharedCoordinatorPersistsAndAppliesApplicationAppearance() {
        let defaults = makeDefaults()
        var appliedNames: [NSAppearance.Name?] = []
        let coordinator = MeetingVaultAppearanceCoordinator(
            userDefaults: defaults,
            arguments: ["MeetingVault"],
            applyAppearance: { appliedNames.append($0?.name) }
        )

        coordinator.setSavedPreference(.dark)
        coordinator.setSavedPreference(.system)

        XCTAssertEqual(defaults.string(forKey: "MeetingVault.appearance"), "system")
        XCTAssertEqual(coordinator.savedPreference, .system)
        XCTAssertEqual(appliedNames, [nil, .darkAqua, nil])
    }

    func testTwoPickerConsumersReflectChangesThroughOneCoordinator() {
        let defaults = makeDefaults()
        let coordinator = MeetingVaultAppearanceCoordinator(
            userDefaults: defaults,
            arguments: ["MeetingVault"],
            applyAppearance: { _ in }
        )
        let toolbarConsumer = AppearancePickerSelection(coordinator: coordinator)
        let settingsConsumer = AppearancePickerSelection(coordinator: coordinator)

        toolbarConsumer.binding.wrappedValue = .dark

        XCTAssertEqual(toolbarConsumer.binding.wrappedValue, .dark)
        XCTAssertEqual(settingsConsumer.binding.wrappedValue, .dark)
        XCTAssertEqual(settingsConsumer.accessibilityValue, "Dark")
        XCTAssertEqual(defaults.string(forKey: MeetingVaultAppearanceCoordinator.defaultsKey), "dark")
    }

    func testOneAppearanceCoordinatorIsSharedAcrossEveryApplicationScene() throws {
        let app = try source("Sources/MeetingVault/App/MeetingVaultApp.swift")
        let toolbar = try source("Sources/MeetingVault/Views/MeetingWorkspaceToolbar.swift")
        let settings = try source("Sources/MeetingVault/Views/SettingsView.swift")
        let picker = try source("Sources/MeetingVault/Views/AppearancePicker.swift")

        XCTAssertTrue(app.contains("@StateObject private var appearanceCoordinator"))
        XCTAssertEqual(
            app.components(separatedBy: ".environmentObject(appearanceCoordinator)").count - 1,
            4
        )
        XCTAssertFalse(app.contains("NSApp.appearance = MeetingVaultLaunchAppearance"))
        XCTAssertTrue(toolbar.contains("AppearancePicker()"))
        XCTAssertTrue(settings.contains("AppearancePicker()"))
        XCTAssertTrue(picker.contains(".accessibilityIdentifier(\"appearance-picker\")"))
        XCTAssertTrue(picker.contains(".accessibilityValue(selection.accessibilityValue)"))
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "MeetingVaultAppearanceCoordinatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }

    private func source(_ relativePath: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
