import SwiftUI
import MeetingVaultCore

enum VaultMotion {
    static let press = Animation.easeOut(duration: 0.12)
    static let selection = Animation.easeOut(duration: 0.16)
    static let reveal = Animation.smooth(duration: 0.22, extraBounce: 0)

    static func reveal(reduceMotion: Bool) -> Animation? {
        reduceMotion ? .easeOut(duration: 0.12) : reveal
    }
}

private enum VaultAnimationCadence {
    static let signal = 1.0 / 24.0
}

extension View {
    func vaultGlassPanel(
        cornerRadius: CGFloat = 18,
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        modifier(VaultGlassPanelModifier(cornerRadius: cornerRadius, tint: tint, interactive: interactive))
    }

    func vaultSurface(cornerRadius: CGFloat = 14) -> some View {
        modifier(VaultSurfaceModifier(cornerRadius: cornerRadius))
    }
}

private struct VaultGlassPanelModifier: ViewModifier {
    @Environment(\.vaultIncreasedContrastOverride) private var increasedContrastOverride

    var cornerRadius: CGFloat
    var tint: Color?
    var interactive: Bool

    func body(content: Content) -> some View {
        let prefersContrast = increasedContrastOverride ?? false

        content
            .padding(16)
            .glassEffect(
                Glass.regular.interactive(interactive),
                in: .rect(cornerRadius: cornerRadius)
            )
            .overlay {
                if prefersContrast {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.18), lineWidth: 1)
                }
            }
    }
}

private struct VaultSurfaceModifier: ViewModifier {
    @Environment(\.vaultIncreasedContrastOverride) private var increasedContrastOverride

    var cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let prefersContrast = increasedContrastOverride ?? false

        content
            .padding(14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                if prefersContrast {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.16), lineWidth: 1)
                }
            }
    }
}

struct VaultSceneBackground: View {
    var tint: Color
    var animated = false

    var body: some View {
        Color(nsColor: .windowBackgroundColor)
            .ignoresSafeArea()
    }
}

struct VaultLiveSignal: View {
    @Environment(\.vaultReduceMotion) private var reduceMotion

    var tint: Color
    var barCount: Int = 12
    var compact = false
    var animated = false
    var level: Double? = nil

    var body: some View {
        let audioActive = animated && (level ?? 0) > 0

        if reduceMotion || !audioActive {
            bars(phase: 0)
                .frame(height: compact ? 24 : 40)
                .accessibilityHidden(true)
        } else {
            TimelineView(.periodic(from: .now, by: VaultAnimationCadence.signal)) { timeline in
                bars(phase: timeline.date.timeIntervalSinceReferenceDate)
            }
            .frame(height: compact ? 24 : 40)
            .accessibilityHidden(true)
        }
    }

    private func bars(phase: TimeInterval) -> some View {
        HStack(alignment: .center, spacing: compact ? 3 : 5) {
            ForEach(0..<barCount, id: \.self) { index in
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [tint.opacity(0.38), tint],
                            startPoint: .bottom,
                            endPoint: .top
                        )
                    )
                    .frame(
                        width: compact ? 3 : 5,
                        height: height(for: index, phase: phase)
                    )
            }
        }
    }

    private func height(for index: Int, phase: TimeInterval) -> CGFloat {
        let base = compact ? 8.0 : 14.0
        let range = compact ? 14.0 : 24.0
        guard animated, (level ?? 0) > 0 else {
            return CGFloat(base + (range * 0.12))
        }
        let wave = (sin((phase * 2.1) + (Double(index) * 0.72)) + 1) / 2
        let normalizedLevel = level.map { min(1, max(0, $0)) }
        let lift = if let normalizedLevel {
            max(0.12, normalizedLevel) * (0.58 + (wave * 0.42))
        } else {
            0.30 + (wave * 0.70)
        }
        return CGFloat(base + (range * lift))
    }
}

struct VaultPulseHalo: View {
    var tint: Color
    var isActive: Bool
    var size: CGFloat = 82
    var systemImage: String

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.primary.opacity(isActive ? 0.08 : 0.05))

            Circle()
                .strokeBorder(Color.primary.opacity(isActive ? 0.18 : 0.10), lineWidth: 1)

            Image(systemName: systemImage)
                .font(.system(size: size * 0.40, weight: .semibold))
                .foregroundStyle(tint)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct VaultFlowDivider: View {
    var tint: Color
    var animated = false

    var body: some View {
        Capsule()
            .fill(Color.primary.opacity(0.12))
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}

struct VaultHeroBand<Content: View>: View {
    var tint: Color
    var animated = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(18)
            .glassEffect(Glass.regular.interactive(), in: .rect(cornerRadius: 14))
    }
}

struct VaultSectionHeader: View {
    var title: String
    var subtitle: String?
    var systemImage: String

    init(_ title: String, subtitle: String? = nil, systemImage: String) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.tint)
                .frame(width: 28, height: 28)
                .background(Color.primary.opacity(0.06), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct VaultMetricTile: View {
    var label: String
    var value: String
    var systemImage: String
    var tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
                Spacer()
            }
            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .vaultSurface(cornerRadius: 14)
        .contentTransition(.numericText())
    }
}

struct VaultStatusPill: View {
    @Environment(\.vaultReduceMotion) private var reduceMotion

    var label: String
    var systemImage: String
    var tint: Color
    var isActive: Bool = false

    var body: some View {
        Label(label, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(isActive ? 0.10 : 0.06), in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(Color.primary.opacity(isActive ? 0.18 : 0.10), lineWidth: 1)
            }
            .animation(reduceMotion ? nil : VaultMotion.selection, value: isActive)
    }
}

struct VaultAudioLevelBar: View {
    @Environment(\.vaultReduceMotion) private var reduceMotion

    var value: Double
    var tint: Color

    var body: some View {
        let normalizedLevel = max(0.02, min(max(value, 0), 1))

        ZStack(alignment: .leading) {
            Capsule()
                .fill(.quaternary)
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [tint.opacity(0.55), tint],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .scaleEffect(x: normalizedLevel, y: 1, anchor: .leading)
                .animation(reduceMotion ? nil : VaultMotion.selection, value: value)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 7)
    }
}

extension RecordingState {
    var displayTitle: String {
        switch self {
        case .idle: "Idle"
        case .ready: "Ready"
        case .recording: "Recording"
        case .paused: "Paused"
        case .processing: "Processing"
        case .permissionNeeded: "Permission Needed"
        case .error: "Error"
        case .recovered: "Recovered"
        }
    }

    var statusTint: Color {
        switch self {
        case .recording: .red
        case .ready, .recovered: .green
        case .paused, .processing, .permissionNeeded: .orange
        case .error: .red
        case .idle: .secondary
        }
    }

    var statusSymbol: String {
        switch self {
        case .recording: "record.circle.fill"
        case .ready: "checkmark.circle.fill"
        case .paused: "pause.circle.fill"
        case .processing: "gearshape.2.fill"
        case .permissionNeeded: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        case .recovered: "arrow.clockwise.circle.fill"
        case .idle: "circle"
        }
    }
}
