import Foundation

public struct MeetingAutomationPlanner {
    public init() {}

    public func plan(_ request: MeetingAutomationRequest) -> MeetingAutomationPlan {
        var blockers: [MeetingAutomationBlocker] = []

        if request.action.needsMeeting && request.meetingID == nil {
            blockers.append(.missingMeetingID)
        }
        if request.action == .startRecording && request.sourceID == nil {
            blockers.append(.missingSourceID)
        }
        if request.action.isExternal {
            if request.approval != .externalApproved {
                blockers.append(.externalApprovalRequired)
            }
            if request.localOnlyMode {
                blockers.append(.blockedByLocalOnlyMode)
            }
        }

        let status: MeetingAutomationPlanStatus = blockers.isEmpty ? .prepared : .blocked
        return MeetingAutomationPlan(
            status: status,
            action: request.action,
            surface: request.surface,
            destination: destination(for: request.action, status: status),
            requiresPreflight: request.action.requiresPreflight,
            requiresExternalApproval: request.action.isExternal && request.approval != .externalApproved,
            allowedSideEffects: status == .prepared ? allowedSideEffects(for: request.action) : [],
            blockers: blockers,
            auditMetadata: auditMetadata(for: request),
            reviewSummary: reviewSummary(for: request.action, status: status, blockers: blockers)
        )
    }

    private func destination(
        for action: MeetingAutomationAction,
        status: MeetingAutomationPlanStatus
    ) -> MeetingAutomationDestination {
        if status == .blocked {
            return .automationReview
        }
        switch action {
        case .openRecorder, .runPreflight, .startRecording, .stopRecording:
            return .recorder
        case .prepareShare:
            return .intelligence
        case .sendWebhook:
            return .automationReview
        }
    }

    private func allowedSideEffects(for action: MeetingAutomationAction) -> [MeetingAutomationSideEffect] {
        switch action {
        case .openRecorder:
            []
        case .runPreflight, .startRecording, .stopRecording:
            [.localStateChange]
        case .prepareShare:
            [.localFileWrite]
        case .sendWebhook:
            [.externalNetwork]
        }
    }

    private func auditMetadata(for request: MeetingAutomationRequest) -> [String: String] {
        var metadata: [String: String] = [
            "action": request.action.rawValue,
            "surface": request.surface.rawValue
        ]
        if let meetingID = request.meetingID {
            metadata["meetingID"] = meetingID.uuidString
        }
        if let sourceID = request.sourceID {
            metadata["sourceID"] = LogRedactor.redact(sourceID)
        }
        return metadata
    }

    private func reviewSummary(
        for action: MeetingAutomationAction,
        status: MeetingAutomationPlanStatus,
        blockers: [MeetingAutomationBlocker]
    ) -> String {
        switch status {
        case .prepared:
            return "Prepared \(action.rawValue) for local in-app execution."
        case .blocked:
            let blockerText = blockers.map(\.rawValue).joined(separator: ",")
            return "Blocked \(action.rawValue) pending review: \(blockerText)."
        }
    }
}

private extension MeetingAutomationAction {
    var needsMeeting: Bool {
        switch self {
        case .openRecorder, .runPreflight, .startRecording, .stopRecording:
            false
        case .prepareShare, .sendWebhook:
            true
        }
    }

    var isExternal: Bool {
        self == .sendWebhook
    }

    var requiresPreflight: Bool {
        switch self {
        case .runPreflight, .startRecording:
            true
        case .openRecorder, .stopRecording, .prepareShare, .sendWebhook:
            false
        }
    }
}
