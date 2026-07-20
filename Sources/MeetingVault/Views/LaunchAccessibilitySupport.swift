import SwiftUI

private struct VaultReduceMotionKey: EnvironmentKey {
    static let defaultValue = false
}

private struct VaultIncreasedContrastOverrideKey: EnvironmentKey {
    static let defaultValue: Bool? = nil
}

extension EnvironmentValues {
    var vaultReduceMotion: Bool {
        get { self[VaultReduceMotionKey.self] }
        set { self[VaultReduceMotionKey.self] = newValue }
    }

    var vaultIncreasedContrastOverride: Bool? {
        get { self[VaultIncreasedContrastOverrideKey.self] }
        set { self[VaultIncreasedContrastOverrideKey.self] = newValue }
    }
}

private struct VaultResolvedReduceMotionModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    var override: Bool?

    func body(content: Content) -> some View {
        let resolvedReduceMotion = override ?? systemReduceMotion
        content.environment(\.vaultReduceMotion, resolvedReduceMotion)
    }
}

extension View {
    func resolvedReduceMotion(_ override: Bool?) -> some View {
        modifier(VaultResolvedReduceMotionModifier(override: override))
    }
}
