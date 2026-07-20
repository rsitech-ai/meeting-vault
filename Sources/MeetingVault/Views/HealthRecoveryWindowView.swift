import SwiftUI

struct HealthRecoveryWindowView: View {
    @EnvironmentObject private var store: MeetingVaultStore

    var body: some View {
        OperationalHealthPane()
            .accessibilityIdentifier("meetings-section-recover-content")
            .overlay(alignment: .topLeading) {
                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityElement()
                    .accessibilityLabel("Health & Recovery window")
                    .accessibilityIdentifier("health-recovery-window")
            }
            .background(
                VaultSceneBackground(
                    tint: store.captureHealthReport.severity == .healthy ? .green : .orange
                )
            )
            .navigationTitle("Health & Recovery")
    }
}
