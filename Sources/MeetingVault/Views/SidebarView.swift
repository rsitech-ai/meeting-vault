import SwiftUI

struct SidebarView: View {
    @Binding var selectedItem: String

    var body: some View {
        List(selection: $selectedItem) {
            Section {
                ForEach(SidebarItem.primaryItems) { item in
                    SidebarRow(item: item, selected: selectedItem == item.rawValue)
                        .tag(item.rawValue)
                        .help("Open \(item.title)")
                }
            } header: {
                Text("MeetingVault")
                    .padding(.leading, 42)
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 280)
        .navigationTitle("MeetingVault")
    }
}

private struct SidebarRow: View {
    @Environment(\.vaultReduceMotion) private var reduceMotion

    var item: SidebarItem
    var selected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Label(item.title, systemImage: item.symbol)
                .font(.callout.weight(selected ? .semibold : .regular))
                .symbolEffect(.bounce, options: .speed(1.8), value: !reduceMotion && selected)

            Spacer(minLength: 6)

            if selected {
                Capsule()
                    .fill(Color.accentColor.opacity(0.72))
                    .frame(width: 4, height: 18)
                    .transition(
                        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.97))
                    )
            }
        }
        .padding(.leading, 42)
        .contentShape(Rectangle())
        .animation(reduceMotion ? nil : .smooth(duration: 0.20), value: selected)
    }
}
