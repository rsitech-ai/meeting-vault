import AppKit
import Foundation
import MeetingVaultCore

@MainActor
protocol PermissionSettingsOpening {
    func openSettings(for action: PermissionRecoveryAction) -> Bool
}

struct SystemPermissionSettingsOpener: PermissionSettingsOpening {
    func openSettings(for action: PermissionRecoveryAction) -> Bool {
        guard let url = URL(string: action.settingsURLString) else {
            return false
        }
        return NSWorkspace.shared.open(url)
    }
}
