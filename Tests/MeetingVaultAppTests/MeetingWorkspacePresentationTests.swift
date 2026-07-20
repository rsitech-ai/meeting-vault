import XCTest
@testable import MeetingVault

final class MeetingWorkspacePresentationTests: XCTestCase {
    func testAgentFocusMapsToAgentInspectorWithoutAdvancedDestination() {
        XCTAssertEqual(MeetingWorkspacePresentation.inspectorMode(for: .understand), .agent)
        XCTAssertNil(MeetingWorkspacePresentation.destination(for: .understand))
    }

    func testCompatibilityRoutesKeepHealthOutsideInspectorDestinations() {
        XCTAssertEqual(MeetingWorkspacePresentation.destination(for: .find), .importRecording)
        XCTAssertEqual(MeetingWorkspacePresentation.destination(for: .record), .setup)
        XCTAssertEqual(MeetingWorkspacePresentation.destination(for: .review), .review)
        XCTAssertEqual(MeetingWorkspacePresentation.destination(for: .export), .export)
        XCTAssertNil(MeetingWorkspacePresentation.destination(for: .recover))

        XCTAssertEqual(MeetingWorkspacePresentation.routeTarget(for: .recover), .healthWindow)
        XCTAssertEqual(MeetingWorkspacePresentation.routeTarget(for: .export), .inspector(.export))

        for focus in [
            MeetingsWorkspaceFocus.find,
            .record,
            .review,
            .export
        ] {
            XCTAssertEqual(MeetingWorkspacePresentation.inspectorMode(for: focus), .details)
        }
    }

    func testInspectorModesHaveStableSceneStorageValues() {
        XCTAssertEqual(MeetingInspectorMode(rawValue: "agent"), .agent)
        XCTAssertEqual(MeetingInspectorMode(rawValue: "details"), .details)
    }

    func testLaunchInspectorModeParsesOnlyExplicitSupportedArgument() {
        XCTAssertEqual(
            MeetingInspectorMode.launchMode(from: ["MeetingVault", "--meeting-inspector", "Details"]),
            .details
        )
        XCTAssertEqual(
            MeetingInspectorMode.launchMode(from: ["MeetingVault", "--meeting-inspector", "agent"]),
            .agent
        )
        XCTAssertNil(MeetingInspectorMode.launchMode(from: ["MeetingVault"]))
        XCTAssertNil(
            MeetingInspectorMode.launchMode(from: ["MeetingVault", "--meeting-inspector", "unsupported"])
        )
    }

    func testInitialInspectorModeUsesExplicitThenWorkspaceThenPersistedPrecedence() {
        XCTAssertEqual(
            MeetingWorkspacePresentation.initialInspectorMode(
                persisted: .agent,
                explicitLaunchMode: .details,
                launchFocus: .understand
            ),
            .details
        )
        XCTAssertEqual(
            MeetingWorkspacePresentation.initialInspectorMode(
                persisted: .agent,
                explicitLaunchMode: nil,
                launchFocus: .recover
            ),
            .details
        )
        XCTAssertEqual(
            MeetingWorkspacePresentation.initialInspectorMode(
                persisted: .details,
                explicitLaunchMode: nil,
                launchFocus: nil
            ),
            .details
        )
    }

    func testPausedLegacyTransportIsDisabledRecoveryPresentation() {
        let presentation = MeetingWorkspacePresentation.recordingTransport(
            state: .paused,
            canStart: false,
            canStop: false
        )

        XCTAssertEqual(presentation.title, "Recovery Required")
        XCTAssertEqual(presentation.statusTitle, "Recovery required")
        XCTAssertFalse(presentation.isEnabled)
        XCTAssertNil(presentation.action)
    }

    func testRepeatedHealthRequestsAdvancePresentationRevision() {
        let first = HealthRecoveryPresentationEvent.next(after: nil)
        let second = HealthRecoveryPresentationEvent.next(after: first)

        XCTAssertEqual(first.revision, 1)
        XCTAssertEqual(second.revision, 2)
        XCTAssertNotEqual(first, second)
    }

    func testRepeatRouteReopensHiddenInspectorWithoutChangingFocus() {
        let first = MeetingWorkspacePresentationEvent.next(focus: .record, after: nil)
        let repeated = MeetingWorkspacePresentationEvent.next(focus: .record, after: first)
        let hidden = MeetingWorkspaceInspectorPresentation(mode: .details, isPresented: false)

        XCTAssertEqual(first.focus, repeated.focus)
        XCTAssertEqual(repeated.revision, first.revision + 1)
        XCTAssertNotEqual(first, repeated)
        XCTAssertEqual(
            MeetingWorkspacePresentation.inspectorPresentation(current: hidden, after: repeated),
            MeetingWorkspaceInspectorPresentation(mode: .details, isPresented: true)
        )
    }

    func testOrdinaryAppearanceKeepsPersistedInspectorModeUntilExplicitRoute() {
        let persisted = MeetingWorkspaceInspectorPresentation(mode: .details, isPresented: false)
        XCTAssertEqual(
            MeetingWorkspacePresentation.inspectorPresentation(current: persisted, after: nil),
            persisted
        )
        XCTAssertEqual(
            MeetingWorkspacePresentation.inspectorMode(current: .details, afterExplicitRouteTo: nil),
            .details
        )
        XCTAssertEqual(
            MeetingWorkspacePresentation.inspectorMode(current: .details, afterExplicitRouteTo: .understand),
            .agent
        )
        XCTAssertEqual(MeetingWorkspacePresentation.routeTarget(for: .recover), .healthWindow)
    }

    func testInitialPresentationMapsCompatibilityWorkspaceArguments() {
        let cases: [([String], MeetingsWorkspaceFocus)] = [
            (["MeetingVault", "--workspace", "library"], .find),
            (["MeetingVault", "--workspace", "recorder"], .record),
            (["MeetingVault", "--workspace", "intelligence"], .understand)
        ]

        for (arguments, expectedFocus) in cases {
            let event = MeetingWorkspacePresentation.initialEvent(from: arguments)
            XCTAssertEqual(event?.focus, expectedFocus)
            XCTAssertEqual(event?.revision, 1)
        }

        XCTAssertNil(
            MeetingWorkspacePresentation.initialEvent(
                from: ["MeetingVault", "--workspace", "diagnostics"]
            )
        )
        XCTAssertEqual(
            MeetingWorkspacePresentation.initialRouteTarget(
                from: ["MeetingVault", "--workspace", "diagnostics"]
            ),
            .healthWindow
        )
    }

    func testInitialPresentationIsNilWithoutExplicitLaunchFocus() {
        XCTAssertNil(MeetingWorkspacePresentation.initialEvent(from: ["MeetingVault"]))
        XCTAssertNil(
            MeetingWorkspacePresentation.initialEvent(
                from: ["MeetingVault", "--workspace", "unsupported"]
            )
        )
    }
}
