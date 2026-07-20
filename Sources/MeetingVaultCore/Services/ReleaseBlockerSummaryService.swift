import Foundation

public struct ReleaseBlockerSummaryService: Sendable {
    public init() {}

    public func loadReport(at url: URL?) -> ReleaseBlockerSummary {
        guard let url else {
            return .unavailable(reason: "No release blocker report path configured.")
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .unavailable(reason: "Release blocker report is missing.", path: url.path)
        }

        do {
            let data = try Data(contentsOf: url)
            let report = try JSONDecoder().decode(ReleaseBlockerDoctorReport.self, from: data)
            return report.summary(loadedFromPath: url.path)
        } catch {
            return .unavailable(
                reason: "Release blocker report could not be decoded: \(error.localizedDescription)",
                path: url.path
            )
        }
    }
}

private struct ReleaseBlockerDoctorReport: Decodable {
    var status: String
    var releaseBlockerStatus: String
    var readinessLabel: String
    var localReady: Bool
    var releaseCandidateReady: Bool
    var sourceCommit: String
    var cleanCheckoutSourceCommit: String
    var blockedGateCount: Int
    var totalActionCount: Int
    var approvalRequiredActionCount: Int?
    var localRunnableActionCount: Int?
    var prerequisiteBlockedActionCount: Int?
    var blockedGates: [ReleaseBlockerGateReport]
    var approvalQueue: [ReleaseBlockerActionReport]
    var operatorBlockers: [String]?
    var workspaceCleanupCandidates: [WorkspaceCleanupCandidateReport]?
    var privateAudioRecorded: Bool
    var microphoneOpened: Bool
    var externalNetworkRequested: Bool
    var downloadRequested: Bool
    var externalUploadAttempted: Bool
    var notarizationSubmitted: Bool
    var rawTranscriptStored: Bool
    var rawAudioStored: Bool
    var rawModelOutputStored: Bool
    var rawLogsStored: Bool
    var rawUITextStored: Bool
    var rawCredentialStored: Bool
    var rawSigningOutputStored: Bool
    var rawNotarizationOutputStored: Bool
    var issues: [String]

    func summary(loadedFromPath: String) -> ReleaseBlockerSummary {
        var reportIssues = issues
        let unsafeFlags = [
            ("privateAudioRecorded", privateAudioRecorded),
            ("microphoneOpened", microphoneOpened),
            ("externalNetworkRequested", externalNetworkRequested),
            ("downloadRequested", downloadRequested),
            ("externalUploadAttempted", externalUploadAttempted),
            ("notarizationSubmitted", notarizationSubmitted),
            ("rawTranscriptStored", rawTranscriptStored),
            ("rawAudioStored", rawAudioStored),
            ("rawModelOutputStored", rawModelOutputStored),
            ("rawLogsStored", rawLogsStored),
            ("rawUITextStored", rawUITextStored),
            ("rawCredentialStored", rawCredentialStored),
            ("rawSigningOutputStored", rawSigningOutputStored),
            ("rawNotarizationOutputStored", rawNotarizationOutputStored)
        ].filter(\.1).map(\.0)
        if !unsafeFlags.isEmpty {
            reportIssues.append("Release blocker report contains unsafe side-effect or raw-output flags: \(unsafeFlags.joined(separator: ", ")).")
        }
        let actionSummaries = approvalQueue.map(\.summary)
        if blockedGateCount != blockedGates.count {
            reportIssues.append("Release blocker report blockedGateCount=\(blockedGateCount) does not match blocked gate count \(blockedGates.count).")
        }
        if totalActionCount != actionSummaries.count {
            reportIssues.append("Release blocker report totalActionCount=\(totalActionCount) does not match approval queue count \(actionSummaries.count).")
        }
        let computedApprovalRequiredActionCount = actionSummaries.filter(\.approvalRequired).count
        let computedLocalRunnableActionCount = actionSummaries.filter(\.isRunnableLocalCommand).count
        let computedPrerequisiteBlockedActionCount = actionSummaries.filter {
            !$0.commands.isEmpty && !$0.unmetPrerequisites.isEmpty
        }.count
        if let approvalRequiredActionCount,
           approvalRequiredActionCount != computedApprovalRequiredActionCount {
            reportIssues.append("Release blocker report approvalRequiredActionCount=\(approvalRequiredActionCount) does not match approval queue count \(computedApprovalRequiredActionCount).")
        }
        if let localRunnableActionCount,
           localRunnableActionCount != computedLocalRunnableActionCount {
            reportIssues.append("Release blocker report localRunnableActionCount=\(localRunnableActionCount) does not match approval queue count \(computedLocalRunnableActionCount).")
        }
        if let prerequisiteBlockedActionCount,
           prerequisiteBlockedActionCount != computedPrerequisiteBlockedActionCount {
            reportIssues.append("Release blocker report prerequisiteBlockedActionCount=\(prerequisiteBlockedActionCount) does not match approval queue count \(computedPrerequisiteBlockedActionCount).")
        }

        return ReleaseBlockerSummary(
            status: status,
            releaseBlockerStatus: releaseBlockerStatus,
            readinessLabel: readinessLabel,
            localReady: localReady,
            releaseCandidateReady: releaseCandidateReady,
            sourceCommit: sourceCommit,
            cleanCheckoutSourceCommit: cleanCheckoutSourceCommit,
            blockedGateCount: blockedGateCount,
            totalActionCount: totalActionCount,
            blockedGates: blockedGates.map(\.summary),
            approvalQueue: actionSummaries,
            operatorBlockers: operatorBlockers ?? [],
            workspaceCleanupCandidates: (workspaceCleanupCandidates ?? []).map(\.summary),
            issues: reportIssues,
            loadedFromPath: loadedFromPath
        )
    }
}

private struct ReleaseBlockerGateReport: Decodable {
    var id: String
    var title: String
    var path: String
    var status: String
    var passedScenarioCount: Int?
    var requiredScenarioCount: Int?

    var summary: ReleaseBlockerGateSummary {
        ReleaseBlockerGateSummary(
            id: id,
            title: title,
            path: path,
            status: status,
            passedScenarioCount: passedScenarioCount,
            requiredScenarioCount: requiredScenarioCount
        )
    }
}

private struct ReleaseBlockerActionReport: Decodable {
    var id: String
    var title: String
    var category: String
    var blockedGateID: String?
    var commands: [String]
    var manualStep: String
    var approvalRequired: Bool
    var unmetPrerequisites: [String]?

    var summary: ReleaseBlockerActionSummary {
        ReleaseBlockerActionSummary(
            id: id,
            title: title,
            category: category,
            blockedGateID: blockedGateID,
            commands: commands,
            manualStep: manualStep,
            approvalRequired: approvalRequired,
            unmetPrerequisites: unmetPrerequisites ?? []
        )
    }
}

private struct WorkspaceCleanupCandidateReport: Decodable {
    var name: String
    var pathHint: String
    var bytes: Int64
    var safetyClass: String
    var cleanupAction: String
    var requiresManualReview: Bool
    var exists: Bool

    var summary: ReleaseWorkspaceCleanupCandidateSummary {
        ReleaseWorkspaceCleanupCandidateSummary(
            name: name,
            pathHint: pathHint,
            bytes: bytes,
            safetyClass: safetyClass,
            cleanupAction: cleanupAction,
            requiresManualReview: requiresManualReview,
            exists: exists
        )
    }
}
