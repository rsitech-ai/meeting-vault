import SwiftUI

@MainActor
struct AppearancePickerSelection {
    private let coordinator: MeetingVaultAppearanceCoordinator

    init(coordinator: MeetingVaultAppearanceCoordinator) {
        self.coordinator = coordinator
    }

    var binding: Binding<MeetingVaultAppearancePreference> {
        Binding(
            get: { coordinator.savedPreference },
            set: { coordinator.setSavedPreference($0) }
        )
    }

    var accessibilityValue: String {
        coordinator.savedPreference.title
    }
}

struct AppearancePicker: View {
    @EnvironmentObject private var appearance: MeetingVaultAppearanceCoordinator

    var body: some View {
        Picker("Appearance", selection: selection.binding) {
            ForEach(MeetingVaultAppearancePreference.allCases) { preference in
                Text(preference.title)
                    .tag(preference)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("appearance-picker")
        .accessibilityLabel("Appearance")
        .accessibilityValue(selection.accessibilityValue)
    }

    private var selection: AppearancePickerSelection {
        AppearancePickerSelection(coordinator: appearance)
    }
}
