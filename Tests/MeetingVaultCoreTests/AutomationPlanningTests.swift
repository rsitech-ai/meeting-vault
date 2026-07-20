import Foundation
import XCTest
@testable import MeetingVaultCore

final class AutomationPlanningTests: XCTestCase {
    func testAutomationPlannerPreparesLocalRecordingIntentWithPreflightGate() {
        let meetingID = UUID()
        let request = MeetingAutomationRequest(
            action: .startRecording,
            surface: .shortcuts,
            meetingID: meetingID,
            sourceID: "zoom",
            localOnlyMode: true,
            approval: .notApproved
        )

        let plan = MeetingAutomationPlanner().plan(request)

        XCTAssertEqual(plan.status, .prepared)
        XCTAssertEqual(plan.action, .startRecording)
        XCTAssertEqual(plan.surface, .shortcuts)
        XCTAssertEqual(plan.destination, .recorder)
        XCTAssertTrue(plan.requiresPreflight)
        XCTAssertFalse(plan.requiresExternalApproval)
        XCTAssertEqual(plan.allowedSideEffects, [.localStateChange])
        XCTAssertEqual(plan.blockers, [])
        XCTAssertEqual(plan.auditMetadata["action"], "startRecording")
        XCTAssertEqual(plan.auditMetadata["surface"], "shortcuts")
        XCTAssertEqual(plan.auditMetadata["meetingID"], meetingID.uuidString)
        XCTAssertEqual(plan.auditMetadata["sourceID"], "zoom")
    }

    func testAutomationPlannerPreparesStopRecordingWithoutPreflightGate() {
        let request = MeetingAutomationRequest(
            action: .stopRecording,
            surface: .appIntent,
            localOnlyMode: true,
            approval: .userConfirmed
        )

        let plan = MeetingAutomationPlanner().plan(request)

        XCTAssertEqual(plan.status, .prepared)
        XCTAssertEqual(plan.action, .stopRecording)
        XCTAssertEqual(plan.destination, .recorder)
        XCTAssertFalse(plan.requiresPreflight)
        XCTAssertEqual(plan.allowedSideEffects, [.localStateChange])
        XCTAssertEqual(plan.blockers, [])
    }

    func testAutomationPlannerBlocksExternalSideEffectsWithoutApprovalAndRedactsPayload() {
        let meetingID = UUID()
        let request = MeetingAutomationRequest(
            action: .sendWebhook,
            surface: .appIntent,
            meetingID: meetingID,
            sourceID: nil,
            localOnlyMode: true,
            approval: .notApproved,
            payloadPreview: "Secret transcript detail and customer@example.com"
        )

        let plan = MeetingAutomationPlanner().plan(request)

        XCTAssertEqual(plan.status, .blocked)
        XCTAssertEqual(plan.action, .sendWebhook)
        XCTAssertEqual(plan.destination, .automationReview)
        XCTAssertTrue(plan.requiresExternalApproval)
        XCTAssertEqual(plan.allowedSideEffects, [])
        XCTAssertEqual(plan.blockers, [.externalApprovalRequired, .blockedByLocalOnlyMode])
        XCTAssertEqual(plan.auditMetadata["action"], "sendWebhook")
        XCTAssertEqual(plan.auditMetadata["surface"], "appIntent")
        XCTAssertEqual(plan.auditMetadata["meetingID"], meetingID.uuidString)
        XCTAssertNil(plan.auditMetadata["payloadPreview"])
        XCTAssertFalse(plan.reviewSummary.contains("Secret transcript"))
        XCTAssertFalse(plan.reviewSummary.contains("customer@example.com"))
    }

    func testShortcutCatalogUsesUniqueSystemFacingLocalActions() {
        let shortcuts = MeetingAutomationShortcutCatalog.shortcuts

        XCTAssertEqual(shortcuts.map(\.id), Set(shortcuts.map(\.id)).map { $0 }.sorted(by: shortcutOrder(shortcuts)))
        XCTAssertTrue(shortcuts.allSatisfy { !$0.title.isEmpty })
        XCTAssertTrue(shortcuts.allSatisfy { !$0.systemImageName.isEmpty })
        XCTAssertTrue(shortcuts.allSatisfy { !$0.phraseTemplates.isEmpty })
        XCTAssertFalse(shortcuts.contains { $0.action == .sendWebhook })
        XCTAssertEqual(shortcuts.first { $0.action == .startRecording }?.requiresSourceSelection, true)
        XCTAssertEqual(shortcuts.first { $0.action == .prepareShare }?.requiresMeetingSelection, true)
    }

    func testShortcutCatalogRequestsFeedAutomationPlanner() {
        let planner = MeetingAutomationPlanner()

        let plans = MeetingAutomationShortcutCatalog.shortcuts.map { shortcut in
            planner.plan(
                shortcut.request(
                    meetingID: shortcut.requiresMeetingSelection ? UUID() : nil,
                    sourceID: shortcut.requiresSourceSelection ? "selected-input" : nil
                )
            )
        }

        XCTAssertEqual(plans.map(\.status), Array(repeating: .prepared, count: plans.count))
        XCTAssertTrue(plans.allSatisfy { $0.surface == .appIntent })
        XCTAssertTrue(plans.allSatisfy { $0.allowedSideEffects.contains(.externalNetwork) == false })
    }

    private func shortcutOrder(_ shortcuts: [MeetingAutomationShortcut]) -> (String, String) -> Bool {
        let order = Dictionary(uniqueKeysWithValues: shortcuts.enumerated().map { ($0.element.id, $0.offset) })
        return { left, right in
            (order[left] ?? .max) < (order[right] ?? .max)
        }
    }
}
