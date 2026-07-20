import AppKit
import Combine
import Foundation

enum MeetingVaultAppearancePreference: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system:
            nil
        case .light:
            NSAppearance(named: .aqua)
        case .dark:
            NSAppearance(named: .darkAqua)
        }
    }
}

enum MeetingVaultAppearanceResolution {
    static func launchOverride(
        from arguments: [String]
    ) -> MeetingVaultAppearancePreference? {
        guard let flagIndex = arguments.firstIndex(of: "--appearance"),
              arguments.indices.contains(arguments.index(after: flagIndex)) else {
            return nil
        }

        let value = arguments[arguments.index(after: flagIndex)]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return MeetingVaultAppearancePreference(rawValue: value)
    }

    static func effective(
        saved: MeetingVaultAppearancePreference,
        launchOverride: MeetingVaultAppearancePreference?
    ) -> MeetingVaultAppearancePreference {
        launchOverride ?? saved
    }
}

@MainActor
final class MeetingVaultAppearanceCoordinator: ObservableObject {
    static let defaultsKey = "MeetingVault.appearance"

    @Published private(set) var savedPreference: MeetingVaultAppearancePreference
    let launchOverride: MeetingVaultAppearancePreference?

    private let userDefaults: UserDefaults
    private let applyAppearance: @MainActor (NSAppearance?) -> Void

    var effectivePreference: MeetingVaultAppearancePreference {
        MeetingVaultAppearanceResolution.effective(
            saved: savedPreference,
            launchOverride: launchOverride
        )
    }

    init(
        userDefaults: UserDefaults = .standard,
        arguments: [String] = CommandLine.arguments,
        applyAppearance: @escaping @MainActor (NSAppearance?) -> Void = {
            NSApplication.shared.appearance = $0
        }
    ) {
        self.userDefaults = userDefaults
        self.savedPreference = userDefaults.string(forKey: Self.defaultsKey)
            .flatMap(MeetingVaultAppearancePreference.init(rawValue:)) ?? .system
        self.launchOverride = MeetingVaultAppearanceResolution.launchOverride(from: arguments)
        self.applyAppearance = applyAppearance
        apply()
    }

    func setSavedPreference(_ preference: MeetingVaultAppearancePreference) {
        savedPreference = preference
        userDefaults.set(preference.rawValue, forKey: Self.defaultsKey)
        apply()
    }

    func apply() {
        applyAppearance(effectivePreference.nsAppearance)
    }
}
