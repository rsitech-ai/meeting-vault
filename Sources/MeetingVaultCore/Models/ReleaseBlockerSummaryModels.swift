import Foundation

public struct ReleaseBlockerSummary: Equatable, Sendable {
    public var status: String
    public var releaseBlockerStatus: String
    public var readinessLabel: String
    public var localReady: Bool
    public var releaseCandidateReady: Bool
    public var sourceCommit: String
    public var cleanCheckoutSourceCommit: String
    public var blockedGateCount: Int
    public var totalActionCount: Int
    public var blockedGates: [ReleaseBlockerGateSummary]
    public var approvalQueue: [ReleaseBlockerActionSummary]
    public var operatorBlockers: [String]
    public var workspaceCleanupCandidates: [ReleaseWorkspaceCleanupCandidateSummary]
    public var issues: [String]
    public var loadedFromPath: String?

    public var approvalRequiredActionCount: Int {
        approvalQueue.filter(\.approvalRequired).count
    }

    public var localRunnableActionCount: Int {
        approvalQueue.filter(\.isRunnableLocalCommand).count
    }

    public var prerequisiteBlockedActionCount: Int {
        approvalQueue.filter {
            !$0.commands.isEmpty && !$0.unmetPrerequisites.isEmpty
        }.count
    }

    public init(
        status: String,
        releaseBlockerStatus: String,
        readinessLabel: String,
        localReady: Bool,
        releaseCandidateReady: Bool,
        sourceCommit: String,
        cleanCheckoutSourceCommit: String,
        blockedGateCount: Int,
        totalActionCount: Int,
        blockedGates: [ReleaseBlockerGateSummary],
        approvalQueue: [ReleaseBlockerActionSummary],
        operatorBlockers: [String] = [],
        workspaceCleanupCandidates: [ReleaseWorkspaceCleanupCandidateSummary] = [],
        issues: [String],
        loadedFromPath: String? = nil
    ) {
        self.status = status
        self.releaseBlockerStatus = releaseBlockerStatus
        self.readinessLabel = readinessLabel
        self.localReady = localReady
        self.releaseCandidateReady = releaseCandidateReady
        self.sourceCommit = sourceCommit
        self.cleanCheckoutSourceCommit = cleanCheckoutSourceCommit
        self.blockedGateCount = blockedGateCount
        self.totalActionCount = totalActionCount
        self.blockedGates = blockedGates
        self.approvalQueue = approvalQueue
        self.operatorBlockers = operatorBlockers
        self.workspaceCleanupCandidates = workspaceCleanupCandidates
        self.issues = issues
        self.loadedFromPath = loadedFromPath
    }

    public static func unavailable(reason: String, path: String? = nil) -> ReleaseBlockerSummary {
        ReleaseBlockerSummary(
            status: "unavailable",
            releaseBlockerStatus: "unknown",
            readinessLabel: "Release blocker report unavailable",
            localReady: false,
            releaseCandidateReady: false,
            sourceCommit: "unknown",
            cleanCheckoutSourceCommit: "unknown",
            blockedGateCount: 0,
            totalActionCount: 0,
            blockedGates: [],
            approvalQueue: [],
            operatorBlockers: [],
            workspaceCleanupCandidates: [],
            issues: [reason],
            loadedFromPath: path
        )
    }
}

public struct ReleaseBlockerGateSummary: Equatable, Sendable {
    public var id: String
    public var title: String
    public var path: String
    public var status: String
    public var passedScenarioCount: Int?
    public var requiredScenarioCount: Int?

    public init(
        id: String,
        title: String,
        path: String,
        status: String,
        passedScenarioCount: Int? = nil,
        requiredScenarioCount: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.path = path
        self.status = status
        self.passedScenarioCount = passedScenarioCount
        self.requiredScenarioCount = requiredScenarioCount
    }
}

public struct ReleaseBlockerActionSummary: Equatable, Sendable {
    public var id: String
    public var title: String
    public var category: String
    public var blockedGateID: String?
    public var commands: [String]
    public var manualStep: String
    public var approvalRequired: Bool
    public var unmetPrerequisites: [String]

    public var isRunnableLocalCommand: Bool {
        !approvalRequired && !commands.isEmpty && unmetPrerequisites.isEmpty
    }

    public var displayStatusText: String {
        if !unmetPrerequisites.isEmpty {
            return "Waiting on prerequisites"
        }
        if approvalRequired {
            return "Approval required before running"
        }
        return "Local command ready"
    }

    public init(
        id: String,
        title: String,
        category: String,
        blockedGateID: String?,
        commands: [String],
        manualStep: String,
        approvalRequired: Bool,
        unmetPrerequisites: [String] = []
    ) {
        self.id = id
        self.title = title
        self.category = category
        self.blockedGateID = blockedGateID
        self.commands = commands
        self.manualStep = manualStep
        self.approvalRequired = approvalRequired
        self.unmetPrerequisites = unmetPrerequisites
    }
}

public struct ReleaseWorkspaceCleanupCandidateSummary: Equatable, Sendable {
    public var name: String
    public var pathHint: String
    public var bytes: Int64
    public var safetyClass: String
    public var cleanupAction: String
    public var requiresManualReview: Bool
    public var exists: Bool

    public init(
        name: String,
        pathHint: String,
        bytes: Int64,
        safetyClass: String,
        cleanupAction: String,
        requiresManualReview: Bool,
        exists: Bool
    ) {
        self.name = name
        self.pathHint = pathHint
        self.bytes = bytes
        self.safetyClass = safetyClass
        self.cleanupAction = cleanupAction
        self.requiresManualReview = requiresManualReview
        self.exists = exists
    }
}
