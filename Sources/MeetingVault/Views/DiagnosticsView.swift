import AppKit
import SwiftUI
import MeetingVaultCore

struct DiagnosticsView: View {
    @EnvironmentObject private var store: MeetingVaultStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VaultHeroBand(tint: store.captureHealthReport.severity == .healthy ? .green : .orange) {
                    HStack(alignment: .center, spacing: 16) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Diagnostics")
                                .font(.largeTitle.weight(.semibold))
                            Text("Production telemetry for permissions, capture health, recovery, retention, export, and privacy audit trails.")
                                .foregroundStyle(.secondary)
                            VaultFlowDivider(tint: store.captureHealthReport.severity == .healthy ? .green : .orange)
                                .frame(maxWidth: 420)
                        }
                        Spacer()
                        VaultLiveSignal(
                            tint: store.captureHealthReport.severity == .healthy ? .green : .orange,
                            barCount: 10,
                            compact: true
                        )
                    }
                }

                GlassEffectContainer(spacing: 14) {
                    HStack(spacing: 14) {
                        VaultMetricTile(label: "Audit Rows", value: "\(store.privacyAuditReview.rows.count)", systemImage: "lock.doc", tint: .purple)
                        VaultMetricTile(label: "Capture State", value: store.captureHealthReport.severity.rawValue, systemImage: "waveform.path.ecg", tint: store.captureHealthReport.severity == .healthy ? .green : .orange)
                        VaultMetricTile(label: "Preview Drops", value: "\(store.recordingPreviewDropCount)", systemImage: "waveform.badge.exclamationmark", tint: store.recordingPreviewDropCount == 0 ? .green : .orange)
                        VaultMetricTile(label: "Warnings", value: "\(store.captureHealthReport.warnings.count)", systemImage: "exclamationmark.triangle", tint: store.captureHealthReport.warnings.isEmpty ? .green : .orange)
                        VaultMetricTile(label: "Retention", value: "\(store.retentionCleanupPlan?.candidates.count ?? 0)", systemImage: "calendar.badge.clock", tint: (store.retentionCleanupPlan?.candidates.isEmpty ?? true) ? .green : .orange)
                        VaultMetricTile(label: "Apple Speech", value: store.appleSpeechAuthorizationState.rawValue, systemImage: "waveform.badge.mic", tint: appleSpeechTint)
                        VaultMetricTile(label: "SpeechAnalyzer", value: store.speechAnalyzerEvaluationReport.status.displayTitle, systemImage: "captions.bubble", tint: speechAnalyzerTint)
                    }
                }

                AppleSpeechPermissionView()
                SpeechAnalyzerEvaluationView()
                ReleaseBlockerReadinessView()
                StatusMatrixView(report: store.captureHealthReport)
                AutomationReadinessView(plans: store.automationPlans)
                RetentionReviewView()
                RecordingRecoveryView(reports: store.recoveredRecordings)
                HealthWarningsView(report: store.captureHealthReport)
                PrivacyAuditReviewView(review: store.privacyAuditReview)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(VaultSceneBackground(tint: store.captureHealthReport.severity == .healthy ? .green : .orange))
        .navigationTitle("Diagnostics")
    }

    private var speechAnalyzerTint: Color {
        switch store.speechAnalyzerEvaluationReport.status {
        case .available:
            .green
        case .assetsNeeded:
            .orange
        case .unsupported, .failed:
            .red
        case .notEvaluated:
            .blue
        }
    }

    private var appleSpeechTint: Color {
        switch store.appleSpeechAuthorizationState {
        case .authorized:
            .green
        case .notDetermined:
            .orange
        case .denied, .restricted:
            .red
        case .unknown:
            .blue
        }
    }
}

struct OperationalHealthPane: View {
    @EnvironmentObject private var store: MeetingVaultStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VaultHeroBand(tint: store.captureHealthReport.severity == .healthy ? .green : .orange) {
                    HStack(alignment: .center, spacing: 16) {
                        VaultSectionHeader(
                            "System Readiness",
                            subtitle: "Permissions, provider readiness, storage review, recovery, automation, and privacy audit controls stay local.",
                            systemImage: "cross.case"
                        )
                        Spacer()
                        VaultStatusPill(
                            label: store.captureHealthReport.severity.rawValue,
                            systemImage: store.captureHealthReport.severity == .healthy ? "checkmark.seal" : "exclamationmark.triangle",
                            tint: store.captureHealthReport.severity == .healthy ? .green : .orange,
                            isActive: true
                        )
                    }
                }

                AppleSpeechPermissionView()
                SpeechAnalyzerEvaluationView()
                ReleaseBlockerReadinessView()
                StatusMatrixView(report: store.captureHealthReport)
                AutomationReadinessView(plans: store.automationPlans)
                RetentionReviewView()
                RecordingRecoveryView(reports: store.recoveredRecordings)
                HealthWarningsView(report: store.captureHealthReport)
                PrivacyAuditReviewView(review: store.privacyAuditReview)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct ReleaseBlockerReadinessView: View {
    @EnvironmentObject private var store: MeetingVaultStore
    @State private var copyStatus = "Copy action queue"

    private var summary: ReleaseBlockerSummary {
        store.releaseBlockerSummary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VaultSectionHeader(
                    "Release Readiness",
                    subtitle: store.releaseBlockerStatus,
                    systemImage: "shippingbox.and.arrow.backward"
                )

                Spacer()

                VaultStatusPill(
                    label: summary.readinessLabel,
                    systemImage: summary.releaseCandidateReady ? "checkmark.seal" : "lock.trianglebadge.exclamationmark",
                    tint: statusTint,
                    isActive: summary.status != "unavailable"
                )

                Button {
                    store.refreshReleaseBlockerSummary()
                    copyStatus = "Copy action queue"
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.glass)
                .help("Reload the bounded release blocker report without running release scripts")

                Button {
                    copyActionQueue()
                } label: {
                    Label(copyStatus, systemImage: "doc.on.doc")
                }
                .buttonStyle(.glassProminent)
                .disabled(summary.approvalQueue.isEmpty && summary.operatorBlockers.isEmpty)
                .help("Copy the bounded release-candidate clearance queue and operator blockers")
            }

            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                GridRow {
                    Text("Local App").foregroundStyle(.secondary)
                    Text(summary.localReady ? "ready" : "blocked")
                        .foregroundStyle(summary.localReady ? .green : .orange)
                }
                GridRow {
                    Text("Release Candidate").foregroundStyle(.secondary)
                    Text(summary.releaseCandidateReady ? "ready" : "blocked")
                        .foregroundStyle(summary.releaseCandidateReady ? .green : .orange)
                }
                GridRow {
                    Text("Blocked Gates").foregroundStyle(.secondary)
                    Text("\(summary.blockedGateCount)")
                        .monospacedDigit()
                }
                GridRow {
                    Text("Queued Actions").foregroundStyle(.secondary)
                    Text("\(summary.totalActionCount)")
                        .monospacedDigit()
                }
                GridRow {
                    Text("Approval Gated").foregroundStyle(.secondary)
                    Text("\(summary.approvalRequiredActionCount)")
                        .foregroundStyle(summary.approvalRequiredActionCount == 0 ? .green : .orange)
                        .monospacedDigit()
                }
                GridRow {
                    Text("Local Ready").foregroundStyle(.secondary)
                    Text("\(summary.localRunnableActionCount)")
                        .foregroundStyle(summary.localRunnableActionCount == 0 ? Color.secondary : Color.blue)
                        .monospacedDigit()
                }
                GridRow {
                    Text("Waiting on Prereqs").foregroundStyle(.secondary)
                    Text("\(summary.prerequisiteBlockedActionCount)")
                        .foregroundStyle(summary.prerequisiteBlockedActionCount == 0 ? Color.secondary : .orange)
                        .monospacedDigit()
                }
            }

            if let path = summary.loadedFromPath {
                Label(path, systemImage: "doc.text.magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if summary.status == "unavailable" {
                ForEach(summary.issues, id: \.self) { issue in
                    Label(issue, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            } else {
                operatorBlockerList
                cleanupCandidateList
                releaseGateGrid
                actionQueue
            }
        }
        .vaultGlassPanel(cornerRadius: 20, tint: statusTint)
        .accessibilityIdentifier("release-readiness-panel")
    }

    @ViewBuilder
    private var operatorBlockerList: some View {
        if !summary.operatorBlockers.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Operator blockers")
                    .font(.headline)

                ForEach(summary.operatorBlockers, id: \.self) { blocker in
                    Label {
                        Text(blocker)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "externaldrive.badge.exclamationmark")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .accessibilityIdentifier("release-operator-blockers")
        }
    }

    @ViewBuilder
    private var cleanupCandidateList: some View {
        if !summary.workspaceCleanupCandidates.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Manual cleanup candidates")
                    .font(.headline)

                ForEach(summary.workspaceCleanupCandidates.prefix(4), id: \.pathHint) { candidate in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "folder.badge.questionmark")
                            .foregroundStyle(.orange)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 8) {
                                Text(candidate.name)
                                    .font(.callout.weight(.semibold))
                                Text(byteCount(candidate.bytes))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Text(candidate.pathHint)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(candidate.cleanupAction)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if candidate.requiresManualReview {
                                Text("Requires manual review")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                }

                if summary.workspaceCleanupCandidates.count > 4 {
                    Text("+ \(summary.workspaceCleanupCandidates.count - 4) more cleanup candidate(s) in the bounded report")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("release-cleanup-candidates")
        }
    }

    private var releaseGateGrid: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Blocked release gates")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                GridRow {
                    Text("Gate").foregroundStyle(.secondary)
                    Text("State").foregroundStyle(.secondary)
                    Text("Proof").foregroundStyle(.secondary)
                }
                ForEach(summary.blockedGates.prefix(6), id: \.id) { gate in
                    GridRow {
                        Text(gate.title)
                            .lineLimit(1)
                        Text(gate.status)
                            .foregroundStyle(.orange)
                        Text(progressText(for: gate))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }

            if summary.blockedGates.count > 6 {
                Text("+ \(summary.blockedGates.count - 6) more gated release proofs")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var actionQueue: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Next clearance actions")
                .font(.headline)

            ForEach(summary.approvalQueue.prefix(5), id: \.id) { action in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: actionStatusIcon(for: action))
                        .foregroundStyle(actionStatusTint(for: action))
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(action.title)
                            .font(.callout.weight(.semibold))
                        Text(actionStatusText(for: action))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(actionStatusTint(for: action))
                        Text(action.manualStep)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        if !action.unmetPrerequisites.isEmpty {
                            Text("Waiting: \(action.unmetPrerequisites.joined(separator: "; "))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        if let command = action.commands.first {
                            Text(command)
                                .font(.caption.monospaced())
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            }
        }
    }

    private var statusTint: Color {
        if summary.releaseCandidateReady {
            return .green
        }
        if summary.status == "unavailable" {
            return .orange
        }
        return .red
    }

    private func progressText(for gate: ReleaseBlockerGateSummary) -> String {
        guard let passed = gate.passedScenarioCount,
              let required = gate.requiredScenarioCount else {
            return "blocked"
        }
        return "\(passed)/\(required)"
    }

    private func actionStatusText(for action: ReleaseBlockerActionSummary) -> String {
        action.displayStatusText
    }

    private func actionStatusIcon(for action: ReleaseBlockerActionSummary) -> String {
        if !action.unmetPrerequisites.isEmpty {
            return "clock.badge.exclamationmark"
        }
        if action.approvalRequired {
            return "hand.raised"
        }
        return "terminal"
    }

    private func actionStatusTint(for action: ReleaseBlockerActionSummary) -> Color {
        if action.approvalRequired || !action.unmetPrerequisites.isEmpty {
            return .orange
        }
        return .blue
    }

    private func copyActionQueue() {
        let operatorLines = summary.operatorBlockers.map { blocker in
            """
            Operator blocker
            \(blocker)
            """
        }
        let cleanupLines = summary.workspaceCleanupCandidates.map { candidate in
            """
            Manual cleanup candidate
            \(candidate.name) (\(byteCount(candidate.bytes)))
            \(candidate.pathHint)
            \(candidate.cleanupAction)
            Requires manual review: \(candidate.requiresManualReview ? "yes" : "no")
            """
        }
        let actionLines = summary.approvalQueue.map { action in
            let commands = action.commands.isEmpty
                ? "No command"
                : action.commands.joined(separator: "\n")
            let prerequisites = action.unmetPrerequisites.isEmpty
                ? "None"
                : action.unmetPrerequisites.joined(separator: "\n")
            return """
            \(action.title)
            Approval required: \(action.approvalRequired ? "yes" : "no")
            Unmet prerequisites:
            \(prerequisites)
            \(action.manualStep)
            \(commands)
            """
        }
        let lines = operatorLines + cleanupLines + actionLines
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n\n"), forType: .string)
        copyStatus = "Copied"
    }

    private func byteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private struct AdaptiveDiagnosticsActionHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    let systemImage: String
    private let trailing: Trailing

    init(
        _ title: String,
        subtitle: String,
        systemImage: String,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.trailing = trailing()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                sectionHeader
                    .layoutPriority(1)
                Spacer(minLength: 8)
                trailing
                    .fixedSize(horizontal: true, vertical: false)
            }

            VStack(alignment: .leading, spacing: 12) {
                sectionHeader
                trailing
            }
        }
    }

    private var sectionHeader: some View {
        VaultSectionHeader(
            title,
            subtitle: subtitle,
            systemImage: systemImage
        )
    }
}

struct AppleSpeechPermissionView: View {
    @EnvironmentObject private var store: MeetingVaultStore
    @State private var isRequestingPermission = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            AdaptiveDiagnosticsActionHeader(
                "Apple Speech Permission",
                subtitle: store.appleSpeechAuthorizationStatus,
                systemImage: "waveform.badge.mic"
            ) {
                HStack(spacing: 10) {
                    VaultStatusPill(
                        label: store.appleSpeechAuthorizationState.rawValue,
                        systemImage: statusSymbol,
                        tint: statusTint,
                        isActive: store.appleSpeechAuthorizationState == .authorized || store.appleSpeechAuthorizationState == .notDetermined
                    )

                    Button {
                        store.refreshAppleSpeechAuthorizationStatus()
                    } label: {
                        Label("Check", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.glass)
                    .help("Check Speech Recognition permission without prompting")

                    if store.appleSpeechAuthorizationState == .notDetermined {
                        Button {
                            isRequestingPermission = true
                            Task {
                                await store.requestAppleSpeechAuthorizationOnce()
                                isRequestingPermission = false
                            }
                        } label: {
                            Label(isRequestingPermission ? "Requesting" : "Request Once", systemImage: "hand.raised")
                        }
                        .disabled(isRequestingPermission)
                        .buttonStyle(.glassProminent)
                        .help("Ask macOS for Speech Recognition permission once; recording and transcription starts do not trigger this prompt")
                    }
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                GridRow {
                    Text("Current State").foregroundStyle(.secondary)
                    Text(store.appleSpeechAuthorizationState.rawValue)
                }
                GridRow {
                    Text("Prompt Policy").foregroundStyle(.secondary)
                    Text("Only from Request Once")
                }
            }

            Label(
                "Apple Speech fixture smokes and recording paths fail closed until this permission is authorized.",
                systemImage: "checkmark.shield"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .vaultGlassPanel(cornerRadius: 20, tint: statusTint)
    }

    private var statusTint: Color {
        switch store.appleSpeechAuthorizationState {
        case .authorized:
            .green
        case .notDetermined:
            .orange
        case .denied, .restricted:
            .red
        case .unknown:
            .blue
        }
    }

    private var statusSymbol: String {
        switch store.appleSpeechAuthorizationState {
        case .authorized:
            "checkmark.seal"
        case .notDetermined:
            "hand.raised"
        case .denied, .restricted:
            "exclamationmark.triangle"
        case .unknown:
            "questionmark.circle"
        }
    }
}

struct SpeechAnalyzerEvaluationView: View {
    @EnvironmentObject private var store: MeetingVaultStore
    @State private var isPreparingAssets = false

    private var report: SpeechAnalyzerEvaluationReport {
        store.speechAnalyzerEvaluationReport
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            AdaptiveDiagnosticsActionHeader(
                "SpeechAnalyzer Evaluation",
                subtitle: store.speechAnalyzerEvaluationStatus,
                systemImage: "captions.bubble"
            ) {
                HStack(spacing: 10) {
                    VaultStatusPill(
                        label: report.status.displayTitle,
                        systemImage: statusSymbol,
                        tint: statusTint,
                        isActive: report.status == .available || report.status == .assetsNeeded
                    )

                    Button {
                        Task {
                            await store.refreshSpeechAnalyzerEvaluation()
                        }
                    } label: {
                        Label("Evaluate", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.glass)
                    .help("Evaluate SpeechAnalyzer SDK, locale, and asset status without recording or transcribing audio")

                    if report.status == .assetsNeeded {
                        Button {
                            isPreparingAssets = true
                            Task {
                                await store.prepareSpeechAnalyzerAssets()
                                isPreparingAssets = false
                            }
                        } label: {
                            Label(isPreparingAssets ? "Preparing" : "Prepare Assets", systemImage: "square.and.arrow.down")
                        }
                        .disabled(isPreparingAssets)
                        .buttonStyle(.glassProminent)
                        .help("Download and install Apple SpeechAnalyzer assets intentionally; this does not open the microphone or read recordings")
                    }
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                GridRow {
                    Text("SDK").foregroundStyle(.secondary)
                    Text(report.sdkAvailable ? "available" : "not available")
                }
                GridRow {
                    Text("Locale").foregroundStyle(.secondary)
                    Text(report.resolvedLocaleIdentifier ?? report.requestedLocaleIdentifier)
                }
                GridRow {
                    Text("Assets").foregroundStyle(.secondary)
                    Text(report.assetStatus ?? "not checked")
                }
                GridRow {
                    Text("Format").foregroundStyle(.secondary)
                    Text(report.compatibleAudioFormatDescription ?? "not reported")
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(report.notes, id: \.self) { note in
                    Label(note, systemImage: "checkmark.shield")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .vaultGlassPanel(cornerRadius: 20, tint: statusTint)
        .task {
            guard report.status == .notEvaluated else { return }
            await store.refreshSpeechAnalyzerEvaluation()
        }
    }

    private var statusTint: Color {
        switch report.status {
        case .available:
            .green
        case .assetsNeeded:
            .orange
        case .unsupported, .failed:
            .red
        case .notEvaluated:
            .blue
        }
    }

    private var statusSymbol: String {
        switch report.status {
        case .available:
            "checkmark.seal"
        case .assetsNeeded:
            "square.and.arrow.down"
        case .unsupported, .failed:
            "exclamationmark.triangle"
        case .notEvaluated:
            "hourglass"
        }
    }
}

struct RetentionReviewView: View {
    @EnvironmentObject private var store: MeetingVaultStore
    @State private var confirmDeleteReviewed = false

    private var candidates: [RetentionCleanupCandidate] {
        store.retentionCleanupPlan?.candidates ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VaultSectionHeader(
                    "Retention Review",
                    subtitle: store.retentionCleanupStatus,
                    systemImage: "calendar.badge.clock"
                )
                Spacer()
                VaultStatusPill(
                    label: "\(candidates.count) expired",
                    systemImage: candidates.isEmpty ? "checkmark.circle" : "exclamationmark.triangle",
                    tint: candidates.isEmpty ? .green : .orange,
                    isActive: !candidates.isEmpty
                )
            }

            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Button {
                        store.retentionDays = max(1, store.retentionDays - 1)
                    } label: {
                        Label("Decrease retention", systemImage: "minus")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.glass)
                    .disabled(store.retentionDays <= 1)
                    .accessibilityLabel("Decrease retention")
                    .help("Decrease retention by one day")

                    Label("\(store.retentionDays) day policy", systemImage: "clock.arrow.circlepath")
                        .font(.callout.weight(.semibold))
                        .monospacedDigit()
                        .frame(minWidth: 138)

                    Button {
                        store.retentionDays = min(3650, store.retentionDays + 1)
                    } label: {
                        Label("Increase retention", systemImage: "plus")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.glass)
                    .disabled(store.retentionDays >= 3650)
                    .accessibilityLabel("Increase retention")
                    .help("Increase retention by one day")
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("retention-day-policy-control")

                Spacer()

                Button {
                    do {
                        try store.refreshRetentionCleanupPlan()
                    } catch {
                        // Store state carries the user-facing failure message.
                    }
                } label: {
                    Label("Review Expired", systemImage: "magnifyingglass")
                }
                .buttonStyle(.glass)

                Button {
                    confirmDeleteReviewed = true
                } label: {
                    Label("Delete Reviewed", systemImage: "trash")
                }
                .buttonStyle(.glassProminent)
                .tint(.red)
                .disabled(candidates.isEmpty)
                .help("Delete only the expired recordings currently listed in this review")
            }

            if candidates.isEmpty {
                Text("No expired bundles are selected for cleanup. Run review after changing the retention policy or after importing older recordings.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                    GridRow {
                        Text("Recording").foregroundStyle(.secondary)
                        Text("Age").foregroundStyle(.secondary)
                        Text("Created").foregroundStyle(.secondary)
                    }
                    ForEach(candidates, id: \.meetingID) { candidate in
                        GridRow {
                            Text(candidate.title)
                                .lineLimit(1)
                            Text("\(candidate.ageDays) days")
                                .monospacedDigit()
                                .foregroundStyle(.orange)
                            Text(candidate.createdAt, style: .date)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .vaultGlassPanel(cornerRadius: 20, tint: candidates.isEmpty ? .green : .orange)
        .confirmationDialog(
            "Delete reviewed recordings?",
            isPresented: $confirmDeleteReviewed,
            titleVisibility: .visible
        ) {
            Button("Delete Reviewed Recordings", role: .destructive) {
                do {
                    _ = try store.applyRetentionCleanup(userConfirmed: true)
                } catch {
                    // Store state carries the user-facing failure message.
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes only the expired recording bundles currently listed in Retention Review.")
        }
    }
}

struct RecordingRecoveryView: View {
    @EnvironmentObject private var store: MeetingVaultStore

    var reports: [RecoveredRecordingReport]

    private var partialReports: [RecoveredRecordingReport] {
        reports
            .filter { !$0.warnings.isEmpty }
            .sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VaultSectionHeader(
                    "Recording Recovery",
                    subtitle: "Incomplete bundles stay visible for recovery, import, and transcript review instead of silently disappearing from the library.",
                    systemImage: "lifepreserver"
                )
                Spacer()
                VaultStatusPill(
                    label: "\(partialReports.count) partial",
                    systemImage: partialReports.isEmpty ? "checkmark.circle" : "exclamationmark.triangle",
                    tint: partialReports.isEmpty ? .green : .orange,
                    isActive: !partialReports.isEmpty
                )
            }

            Text(store.recoveredRecordingImportStatus)
                .font(.callout)
                .foregroundStyle(.secondary)

            if partialReports.isEmpty {
                Text("No incomplete recording bundles need recovery.")
                    .foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                    GridRow {
                        Text("Recording").foregroundStyle(.secondary)
                        Text("Duration").foregroundStyle(.secondary)
                        Text("Tracks").foregroundStyle(.secondary)
                        Text("Warnings").foregroundStyle(.secondary)
                        Text("Action").foregroundStyle(.secondary)
                    }
                    ForEach(partialReports, id: \.meetingID) { report in
                        GridRow {
                            Text(report.title)
                                .lineLimit(1)
                            Text(durationText(report.totalRecordedDuration))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                            Text(trackSummary(report.trackReports))
                                .foregroundStyle(.secondary)
                            Text(warningSummary(report.warnings))
                                .foregroundStyle(.orange)
                                .lineLimit(2)
                            Button {
                                Task {
                                    do {
                                        try await store.importRecoveredRecording(meetingID: report.meetingID)
                                    } catch {
                                        // Store state carries the user-facing failure message.
                                    }
                                }
                            } label: {
                                Label("Recover", systemImage: "arrow.triangle.2.circlepath")
                            }
                            .buttonStyle(.glassProminent)
                            .controlSize(.small)
                            .disabled(!canImport(report))
                        }
                    }
                }
            }
        }
        .vaultGlassPanel(cornerRadius: 20, tint: partialReports.isEmpty ? .green : .orange)
    }

    private func trackSummary(_ tracks: [RecoveredTrackReport]) -> String {
        tracks
            .sorted { $0.track.rawValue < $1.track.rawValue }
            .map { "\($0.track.rawValue): \($0.chunkCount)" }
            .joined(separator: "  ")
    }

    private func warningSummary(_ warnings: Set<RecordingRecoveryWarning>) -> String {
        warnings
            .map(\.rawValue)
            .sorted()
            .joined(separator: ", ")
    }

    private func canImport(_ report: RecoveredRecordingReport) -> Bool {
        report.trackReports.contains { $0.chunkCount > 0 }
    }

    private func durationText(_ seconds: TimeInterval) -> String {
        let totalSeconds = max(0, Int(seconds.rounded(.down)))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

struct StatusMatrixView: View {
    var report: CaptureHealthReport

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VaultSectionHeader(
                "Production Checks",
                subtitle: "Current implementation evidence and remaining platform seams.",
                systemImage: "checklist.checked"
            )

            Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 12) {
                DiagnosticRow(label: "Capture callback", value: "No blocking work allowed")
                DiagnosticRow(label: "Audio storage", value: "AES-GCM encrypted bundle contract tested")
                DiagnosticRow(label: "Audio chunks", value: "Encrypted checkpoint writer tested")
                DiagnosticRow(label: "Capture mock", value: "Remote/microphone encrypted chunk flow tested")
                DiagnosticRow(label: "Capture primary", value: "Core Audio tap adapter tested")
                DiagnosticRow(label: "Capture fallback", value: "ScreenCaptureKit system-audio adapter tested")
                DiagnosticRow(label: "Transcript search", value: "SQLite FTS index tested")
                DiagnosticRow(label: "Final transcript", value: "Encrypted artifact and search indexing tested")
                DiagnosticRow(label: "Transcript edits", value: "Draft UI, encrypted history, and re-indexing tested")
                DiagnosticRow(label: "Playback", value: "Transcript/audio cue timeline tested")
                DiagnosticRow(label: "Automation", value: "App Intents, local handoff, and approval gates tested")
                DiagnosticRow(label: "AI artifacts", value: "Grounded summary persistence tested")
	                DiagnosticRow(label: "Exports", value: "Markdown, WebVTT, PDF, DOCX, JSON, and audio package tested")
                DiagnosticRow(label: "Permissions", value: "System adapter boundary tested")
                DiagnosticRow(label: "Recovery", value: "Checkpoint scanner tested")
	                DiagnosticRow(label: "Retention", value: "Visible review and confirmed cleanup tested")
                DiagnosticRow(label: "Privacy audit", value: "Filtered redacted review/export tested")
                DiagnosticRow(label: "Logging", value: "Redacted unified logs")
                DiagnosticRow(label: "Transcription", value: report.transcriptionEngine)
                DiagnosticRow(label: "Intelligence", value: report.intelligenceProvider)
            }
        }
        .vaultGlassPanel(cornerRadius: 20, tint: .blue)
    }
}

struct AutomationReadinessView: View {
    var plans: [MeetingAutomationPlan]

    private var preparedCount: Int {
        plans.filter { $0.status == .prepared }.count
    }

    private var blockedCount: Int {
        plans.filter { $0.status == .blocked }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VaultSectionHeader(
                    "Automation Readiness",
                    subtitle: "Shortcuts and App Intent requests use local handoffs while external effects stay approval-blocked.",
                    systemImage: "sparkle.magnifyingglass"
                )
                Spacer()
                VaultStatusPill(label: "\(preparedCount) prepared", systemImage: "checkmark.circle", tint: .green)
                VaultStatusPill(label: "\(blockedCount) blocked", systemImage: "hand.raised", tint: .orange, isActive: blockedCount > 0)
            }

            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                GridRow {
                    Text("Action").foregroundStyle(.secondary)
                    Text("Surface").foregroundStyle(.secondary)
                    Text("Destination").foregroundStyle(.secondary)
                    Text("State").foregroundStyle(.secondary)
                }
                ForEach(plans, id: \.reviewSummary) { plan in
                    GridRow {
                        Text(plan.action.rawValue)
                        Text(plan.surface.rawValue)
                            .foregroundStyle(.secondary)
                        Text(plan.destination.rawValue)
                            .foregroundStyle(.secondary)
                        Text(plan.status.rawValue)
                            .foregroundStyle(plan.status == .prepared ? .green : .orange)
                    }
                }
            }
        }
        .vaultGlassPanel(cornerRadius: 20, tint: blockedCount > 0 ? .orange : .green)
    }
}

struct PrivacyAuditReviewView: View {
    @EnvironmentObject private var store: MeetingVaultStore

    var review: PrivacyAuditReview

    private var rows: [PrivacyAuditReviewRow] {
        store.filteredPrivacyAuditRows
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VaultSectionHeader(
                    "Privacy Audit",
                    subtitle: "Filter and export only redacted review rows with allowlisted metadata.",
                    systemImage: "lock.doc"
                )
                Spacer()
                VaultStatusPill(label: "\(rows.count) shown", systemImage: "line.3.horizontal.decrease.circle", tint: .purple)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    filterPicker
                    exportButton
                    statusText
                }

                VStack(alignment: .leading, spacing: 10) {
                    filterPicker
                    HStack(spacing: 12) {
                        exportButton
                        statusText
                    }
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                GridRow {
                    Text("Action").foregroundStyle(.secondary)
                    Text("Meeting").foregroundStyle(.secondary)
                    Text("Metadata").foregroundStyle(.secondary)
                }
                ForEach(rows.prefix(8)) { row in
                    GridRow {
                        Text(row.action.rawValue)
                            .font(.callout.monospaced())
                        Text(row.meetingID.map { String($0.uuidString.prefix(8)) } ?? "none")
                            .monospaced()
                            .foregroundStyle(.secondary)
                        Text(metadataText(row.metadata))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if rows.isEmpty {
                Text("No redacted audit rows match the current filter.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let export = store.lastPrivacyAuditExport {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Latest local audit export")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(export.files, id: \.path) { file in
                        Label(file.lastPathComponent, systemImage: "doc.text")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack(spacing: 10) {
                ForEach(PrivacyAuditAction.allCases, id: \.self) { action in
                    VaultStatusPill(
                        label: "\(action.rawValue): \(review.counts[action, default: 0])",
                        systemImage: "number",
                        tint: .secondary
                    )
                }
            }
        }
        .vaultGlassPanel(cornerRadius: 20, tint: .purple)
    }

    private var filterPicker: some View {
        Picker(
            "Audit filter",
            selection: Binding(
                get: { store.privacyAuditActionFilter?.rawValue ?? "all" },
                set: { value in
                    store.privacyAuditActionFilter = value == "all" ? nil : PrivacyAuditAction(rawValue: value)
                }
            )
        ) {
            Text("All Actions").tag("all")
            ForEach(PrivacyAuditAction.allCases, id: \.self) { action in
                Text(action.rawValue).tag(action.rawValue)
            }
        }
        .pickerStyle(.menu)
        .frame(minWidth: 220)
        .help("Filter the visible privacy audit review rows")
    }

    private var exportButton: some View {
        Button {
            do {
                try store.exportFilteredPrivacyAuditReview()
            } catch {
                // Store state carries the user-facing failure message.
            }
        } label: {
            Label("Export Redacted Audit", systemImage: "square.and.arrow.down")
        }
        .buttonStyle(.glassProminent)
        .disabled(rows.isEmpty)
        .help("Write the currently filtered redacted audit rows to local JSON and CSV files")
    }

    private var statusText: some View {
        Text(store.privacyAuditExportStatus)
            .font(.callout)
            .foregroundStyle(.secondary)
            .contentTransition(.opacity)
    }

    private func metadataText(_ metadata: [String: String]) -> String {
        metadata
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
    }
}

private struct DiagnosticRow: View {
    var label: String
    var value: String

    var body: some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
        }
    }
}

struct HealthWarningsView: View {
    var report: CaptureHealthReport

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VaultSectionHeader(
                    "Capture Health",
                    subtitle: "Dropouts, clipping, silence, and device-change diagnostics.",
                    systemImage: report.severity == .healthy ? "checkmark.circle" : "exclamationmark.triangle"
                )
                Spacer()
                VaultStatusPill(
                    label: report.severity.rawValue,
                    systemImage: report.severity == .healthy ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                    tint: report.severity == .healthy ? .green : .orange,
                    isActive: report.severity != .healthy
                )
            }

            if report.warnings.isEmpty {
                HStack(spacing: 10) {
                    VaultPulseHalo(tint: .green, isActive: false, size: 36, systemImage: "checkmark")
                    Text("No capture warnings in the current diagnostic sample.")
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(report.warnings, id: \.message) { warning in
                    Label(warning.message, systemImage: warning.severity == .critical ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(warning.severity == .critical ? .red : .orange)
                }
            }
        }
        .vaultGlassPanel(cornerRadius: 20, tint: report.severity == .healthy ? .green : .orange)
    }
}
