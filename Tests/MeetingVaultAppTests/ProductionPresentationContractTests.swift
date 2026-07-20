import Foundation
import XCTest

final class ProductionPresentationContractTests: XCTestCase {
    func testCalmWorkspaceRemovesDecorativeAmbientMotion() throws {
        let source = try source("Sources/MeetingVault/Views/PolishSupport.swift")
        XCTAssertTrue(source.contains("enum VaultMotion"))
        XCTAssertFalse(source.contains("VaultAnimationCadence.ambient"))
        XCTAssertFalse(source.contains("rotationEffect(.radians(phase"))
        XCTAssertFalse(source.contains("symbolEffect(.bounce"))
    }

    func testMeetingRowsDoNotScaleOrShadowOnHover() throws {
        let source = try source("Sources/MeetingVault/Views/MeetingLibraryView.swift")
        XCTAssertFalse(source.contains("scaleEffect(!reduceMotion && isHovered"))
        XCTAssertFalse(source.contains("shadow(color: meeting.state.statusTint"))
    }

    func testCaptureSourceChoicesUseAnAdaptiveFullLabelLayout() throws {
        let source = try source("Sources/MeetingVault/Views/RecorderView.swift")
        XCTAssertTrue(source.contains("private var sourceChoiceColumns: [GridItem]"))
        XCTAssertTrue(source.contains("LazyVGrid(columns: sourceChoiceColumns"))
        XCTAssertFalse(source.contains(".minimumScaleFactor(0.82)"))
        XCTAssertTrue(source.contains(".fixedSize(horizontal: false, vertical: true)"))
    }

    func testRecordingSetupUsesFullUserFacingLabelsAndSpecificBlockers() throws {
        let recorder = try source("Sources/MeetingVault/Views/RecorderView.swift")
        XCTAssertTrue(recorder.contains("Text(source.mode.displayLabel)"))
        XCTAssertTrue(recorder.contains("Screen + Mic + Speech blocked"))
        XCTAssertFalse(recorder.contains("Text(source.mode.rawValue)"))
        XCTAssertFalse(recorder.contains("\\(source.mode.rawValue), level"))

        let inspector = try source("Sources/MeetingVault/Views/MeetingWorkspaceInspector.swift")
        XCTAssertTrue(inspector.contains("private var audioInputPicker: some View"))
        XCTAssertTrue(inspector.contains("audioInputPicker\n                .frame(maxWidth: .infinity)"))
        XCTAssertFalse(inspector.contains("HStack(spacing: 8) {\n                Picker(\"Audio Input\""))
        XCTAssertFalse(inspector.contains("device.isDefault ? \" · default\" : \"\""))
    }

    func testVisualMatrixKeepsMeetingConsoleDistinctFromAgentInspector() throws {
        let matrix = try source("script/visual_matrix_smoke.swift")
        XCTAssertTrue(matrix.contains("if workspace.rawValue == \"meetings\""))
        XCTAssertTrue(matrix.contains("appArguments += [\"--meeting-inspector\", \"details\"]"))
        XCTAssertTrue(
            matrix.contains(
                "WorkspaceTarget(name: \"Meetings\", rawValue: \"meetings\", expectedMarker: \"Meeting Details\")"
            )
        )
        XCTAssertFalse(matrix.contains("expectedMarker: \"meeting-transcript-workspace\""))

        let presentation = try source("Sources/MeetingVault/Views/MeetingWorkspacePresentation.swift")
        XCTAssertTrue(presentation.contains("static func launchMode(from arguments: [String])"))

        let workspace = try source("Sources/MeetingVault/Views/MeetingsWorkspaceView.swift")
        XCTAssertTrue(workspace.contains("var launchInspectorMode: MeetingInspectorMode?"))
        XCTAssertTrue(workspace.contains("explicitLaunchMode: launchInspectorMode"))
        XCTAssertFalse(workspace.contains("CommandLine.arguments"))

        let content = try source("Sources/MeetingVault/Views/ContentView.swift")
        XCTAssertTrue(content.contains("launchInspectorMode = MeetingInspectorMode.launchMode(from: arguments)"))
        XCTAssertTrue(content.contains("launchInspectorMode: launchInspectorMode"))
    }

    func testVisualMatrixWritesOpaquePrivateRetentionAwareEvidence() throws {
        let matrix = try source("script/visual_matrix_smoke.swift")
        XCTAssertTrue(matrix.contains("var opaque: Bool"))
        XCTAssertTrue(matrix.contains("var imagesDiscardedAfterReport: Bool"))
        XCTAssertTrue(matrix.contains("case \"--discard-images-after-report\""))
        XCTAssertTrue(matrix.contains("func safeEvidencePath(for url: URL) -> String"))
        XCTAssertTrue(matrix.contains("func flattenPNGToOpaque"))
        XCTAssertTrue(matrix.contains("opaque: !imageHasAlpha"))
        XCTAssertTrue(matrix.contains("screenshotsStored: screenshotsStored"))
        XCTAssertFalse(matrix.contains("screenshotPath: screenshotURL.path"))
    }

    func testUnifiedWorkspaceShowsSelectedMeetingContextAndCompactPlayback() throws {
        let toolbar = try source("Sources/MeetingVault/Views/MeetingWorkspaceToolbar.swift")
        XCTAssertTrue(toolbar.contains("store.selectedMeeting"))
        XCTAssertTrue(toolbar.contains("selected-meeting-toolbar-context"))
        XCTAssertTrue(toolbar.contains("meeting.state.displayTitle"))

        let transcript = try source("Sources/MeetingVault/Views/MeetingTranscriptWorkspace.swift")
        XCTAssertTrue(transcript.contains("meeting.title"))
        XCTAssertTrue(transcript.contains("meeting.sourceName"))
        XCTAssertTrue(transcript.contains("meeting-transcript-header"))
        XCTAssertTrue(transcript.contains("meeting-playback-transport"))
        XCTAssertTrue(transcript.contains("if store.playbackMatchesSelectedMeeting"))
        XCTAssertTrue(transcript.contains("store.playTranscriptCue"))
        XCTAssertTrue(transcript.contains("store.pauseTranscriptPlayback"))
        XCTAssertTrue(transcript.contains("store.stopTranscriptPlayback"))

        let library = try source("Sources/MeetingVault/Views/MeetingLibraryView.swift")
        XCTAssertFalse(
            library.contains(".background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))")
        )
        XCTAssertTrue(library.contains("transcript-segment-divider"))
    }

    func testSidebarDeleteIsContextualInsteadOfPermanentRowChrome() throws {
        let library = try source("Sources/MeetingVault/Views/MeetingLibraryView.swift")
        let rowStart = try XCTUnwrap(library.range(of: "struct MeetingLibraryRow: View"))
        let contextMenu = try XCTUnwrap(
            library.range(of: ".contextMenu {", range: rowStart.lowerBound..<library.endIndex)
        )
        let rowChrome = String(library[rowStart.lowerBound..<contextMenu.lowerBound])
        let contextualActions = String(library[contextMenu.lowerBound...])

        XCTAssertFalse(rowChrome.contains("Image(systemName: \"trash\")"))
        XCTAssertFalse(rowChrome.contains(".foregroundStyle(.red)"))
        XCTAssertFalse(rowChrome.contains("selected || isHovered"))
        XCTAssertTrue(rowChrome.contains("meeting-row-title-"))
        XCTAssertTrue(rowChrome.contains("Meeting row. "))
        XCTAssertTrue(contextualActions.contains("Button(role: .destructive, action: onDelete)"))
        XCTAssertTrue(contextualActions.contains("Label(\"Delete Recording\", systemImage: \"trash\")"))

        let workspace = try source("Sources/MeetingVault/Views/MeetingsWorkspaceView.swift")
        XCTAssertTrue(workspace.contains("\"Delete recording?\""))
        XCTAssertTrue(workspace.contains("Button(\"Delete\", role: .destructive)"))
    }

    func testApplicationCommandsExposePromisedLocalWorkflowRoutes() throws {
        let app = try source("Sources/MeetingVault/App/MeetingVaultApp.swift")
        XCTAssertTrue(app.contains("SidebarCommands()"))
        XCTAssertTrue(app.contains("MeetingVaultCommands("))
        XCTAssertTrue(app.contains("store: store"))
        XCTAssertTrue(app.contains("miniRecorderCoordinator: miniRecorderCoordinator"))
        XCTAssertTrue(app.contains("@Environment(\\.openWindow)"))
        XCTAssertTrue(app.contains("store.showWorkspace(.find)"))
        XCTAssertTrue(app.contains("store.showWorkspace(.record)"))
        XCTAssertTrue(app.contains("store.showWorkspace(.export)"))
        XCTAssertTrue(app.contains("store.requestHealthRecoveryPresentation()"))
        XCTAssertTrue(app.contains("openWindow(id: HealthRecoveryPresentation.windowID)"))
    }

    func testHealthRecoveryIsSuppressedSingletonNativeWindow() throws {
        let app = try source("Sources/MeetingVault/App/MeetingVaultApp.swift")
        XCTAssertTrue(app.contains("Window(\"Health & Recovery\", id: HealthRecoveryPresentation.windowID)"))
        XCTAssertTrue(app.contains("HealthRecoveryWindowView()"))
        XCTAssertTrue(app.contains(".defaultLaunchBehavior(.suppressed)"))
        XCTAssertTrue(app.contains(".restorationBehavior(.disabled)"))
        XCTAssertTrue(app.contains(".defaultSize(width:"))
    }

    func testPolishEvidenceUsesBuildCleanAndListsUnprovenRuntimeGates() throws {
        let audit = try source("docs/ui-polish-audit-2026-07-16.md")
        let report = try source(".superpowers/sdd/task-6-report.md")
        let combined = audit + report

        XCTAssertTrue(audit.contains("**Build-clean.**"))
        XCTAssertTrue(report.contains("Build-clean local UI/UX slice"))
        XCTAssertFalse(combined.localizedCaseInsensitiveContains("Consistency-clean"))
        XCTAssertFalse(combined.localizedCaseInsensitiveContains("Polish-ready"))
        for gate in [
            "Start/Stop runtime interaction",
            "Reduce Transparency",
            "manual VoiceOver",
            "keyboard-only",
            "tooltips",
            "focus behavior",
            "runtime logs",
            "performance"
        ] {
            XCTAssertTrue(combined.localizedCaseInsensitiveContains(gate), "Missing unproven gate: \(gate)")
        }
        XCTAssertTrue(combined.contains("Developer ID"))
        XCTAssertTrue(combined.localizedCaseInsensitiveContains("notarization"))
    }

    func testVisualMatrixRefusesToDiscardPreexistingImageDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultVisualMatrixOwnership-\(UUID().uuidString)", isDirectory: true)
        let imageDirectory = root.appendingPathComponent("caller-owned", isDirectory: true)
        let sentinelURL = imageDirectory.appendingPathComponent("preserve-me.txt")
        let reportURL = root.appendingPathComponent("report.json")
        let stdoutURL = root.appendingPathComponent("stdout.txt")
        let stderrURL = root.appendingPathComponent("stderr.txt")
        try FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
        try Data("caller-owned".utf8).write(to: sentinelURL)
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: root) }

        let stdout = try FileHandle(forWritingTo: stdoutURL)
        let stderr = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? stdout.close()
            try? stderr.close()
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "swift",
            repoRoot().appendingPathComponent("script/visual_matrix_smoke.swift").path,
            "--profile", "accessibility",
            "--size", "minimum",
            "--appearance-filter", "light",
            "--output", reportURL.path,
            "--image-dir", imageDirectory.path,
            "--discard-images-after-report"
        ]
        process.currentDirectoryURL = repoRoot()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        try stdout.synchronize()
        try stderr.synchronize()

        let stderrText = try String(contentsOf: stderrURL, encoding: .utf8)
        XCTAssertEqual(process.terminationStatus, 2, stderrText)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinelURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: reportURL.path))
        XCTAssertTrue(stderrText.contains("Refusing to use pre-existing image directory"))
    }

    func testVisualMatrixRefusesPreexistingImageDirectoryWithoutDiscardingCallerPNG() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultVisualMatrixNonDiscardOwnership-\(UUID().uuidString)", isDirectory: true)
        let imageDirectory = root.appendingPathComponent("caller-owned", isDirectory: true)
        let sentinelURL = imageDirectory.appendingPathComponent("preserve-me.png")
        let reportURL = root.appendingPathComponent("report.json")
        let stdoutURL = root.appendingPathComponent("stdout.txt")
        let stderrURL = root.appendingPathComponent("stderr.txt")
        try FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
        try Data("caller-owned-png".utf8).write(to: sentinelURL)
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: root) }

        let stdout = try FileHandle(forWritingTo: stdoutURL)
        let stderr = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? stdout.close()
            try? stderr.close()
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "swift",
            repoRoot().appendingPathComponent("script/visual_matrix_smoke.swift").path,
            "--profile", "accessibility",
            "--size", "minimum",
            "--appearance-filter", "light",
            "--output", reportURL.path,
            "--image-dir", imageDirectory.path
        ]
        process.currentDirectoryURL = repoRoot()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        // A cold `swift` script compilation can exceed 20 seconds while the
        // full test suite is compiling other targets. Keep this subprocess
        // bounded without turning normal compiler contention into SIGTERM.
        let deadline = Date().addingTimeInterval(60)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
        }
        process.waitUntilExit()
        try stdout.synchronize()
        try stderr.synchronize()

        let stderrText = try String(contentsOf: stderrURL, encoding: .utf8)
        XCTAssertEqual(process.terminationStatus, 2, stderrText)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinelURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: reportURL.path))
        XCTAssertTrue(stderrText.contains("Refusing to use pre-existing image directory"))
    }

    func testVisualMatrixRejectsCorruptLightAppearanceFrames() throws {
        let matrix = try source("script/visual_matrix_smoke.swift")
        XCTAssertTrue(matrix.contains("var nearBlackPixelRatio: Double"))
        XCTAssertTrue(matrix.contains("var artifactFree: Bool"))
        XCTAssertTrue(matrix.contains("let lightAppearanceNearBlackThreshold = 0.08"))
        XCTAssertTrue(matrix.contains("func nearBlackPixelRatio(in image: CGImage) -> Double"))
        XCTAssertTrue(matrix.contains("for captureAttempt in 1...3"))
        XCTAssertTrue(matrix.contains("Corrupt light-appearance capture"))
    }

    func testVisualMatrixRetriesWindowIDLookupWithinBoundedDeadline() throws {
        let matrix = try source("script/visual_matrix_smoke.swift")
        XCTAssertTrue(matrix.contains("func waitForAppWindowID("))
        XCTAssertTrue(matrix.contains("let deadline = Date().addingTimeInterval(timeout)"))
        XCTAssertTrue(matrix.contains("app.activate(options: [.activateAllWindows])"))
        XCTAssertTrue(matrix.contains("waitForAppWindowID(pid: pid, app: app)"))
    }

    func testVisualMatrixUsesExtendedAliveCheckedWindowLookupWithTimeoutDiagnostics() throws {
        let matrix = try source("script/visual_matrix_smoke.swift")

        XCTAssertEqual(matrix.components(separatedBy: "timeout: TimeInterval = 15").count - 1, 2)
        XCTAssertTrue(matrix.contains("if app.isTerminated"))
        XCTAssertTrue(matrix.contains("windowLookupDiagnostic(pid: pid, app: app)"))
        XCTAssertTrue(matrix.contains("AX title="))
        XCTAssertTrue(matrix.contains("CG entries="))
        XCTAssertTrue(matrix.contains("active=\\(app.isActive)"))
        XCTAssertTrue(matrix.contains("appWindowID(pid: pid, titled: title)"))
    }

    func testVisualMatrixCanBoundCuratedCaptureToOneWorkspace() throws {
        let matrix = try source("script/visual_matrix_smoke.swift")

        XCTAssertTrue(matrix.contains("--workspace-filter"))
        XCTAssertTrue(matrix.contains("workspaceProfile"))
        XCTAssertTrue(matrix.contains("workspaceTargets.filter { $0.rawValue == workspaceProfile }"))
        XCTAssertTrue(matrix.contains("workspace filter did not match a supported workspace"))
    }

    func testLaunchReduceMotionOverrideReachesSharedSwiftUIEnvironment() throws {
        let app = try source("Sources/MeetingVault/App/MeetingVaultApp.swift")
        XCTAssertTrue(app.contains(".resolvedReduceMotion(launchAccessibilityTraits.reduceMotion)"))

        let support = try source("Sources/MeetingVault/Views/LaunchAccessibilitySupport.swift")
        XCTAssertTrue(support.contains("@Environment(\\.accessibilityReduceMotion) private var systemReduceMotion"))
        XCTAssertTrue(support.contains("override ?? systemReduceMotion"))
        XCTAssertTrue(support.contains("environment(\\.vaultReduceMotion, resolvedReduceMotion)"))

        let content = try source("Sources/MeetingVault/Views/ContentView.swift")
        XCTAssertTrue(content.contains("@Environment(\\.vaultReduceMotion)"))
        XCTAssertTrue(content.contains("meeting-workspace-reduce-motion-"))

        for path in [
            "Sources/MeetingVault/Views/RecorderView.swift",
            "Sources/MeetingVault/Views/MeetingLibraryView.swift",
            "Sources/MeetingVault/Views/IntelligenceWorkspaceView.swift",
            "Sources/MeetingVault/Views/SidebarView.swift"
        ] {
            XCTAssertFalse(try source(path).contains("@Environment(\\.accessibilityReduceMotion)"))
        }

        let interaction = try source("script/interaction_smoke.swift")
        XCTAssertTrue(interaction.contains("\"--reduce-motion\",\n                \"on\""))
        XCTAssertTrue(interaction.contains("Reduce Motion override state changes"))
    }

    func testTransitionsNeverUseDefaultZeroScale() throws {
        let recorder = try source("Sources/MeetingVault/Views/RecorderView.swift")
        let sidebar = try source("Sources/MeetingVault/Views/SidebarView.swift")
        let intelligence = try source("Sources/MeetingVault/Views/IntelligenceWorkspaceView.swift")
        let library = try source("Sources/MeetingVault/Views/MeetingLibraryView.swift")
        XCTAssertFalse(recorder.contains(".transition(.opacity.combined(with: .scale))"))
        XCTAssertFalse(sidebar.contains(".transition(.scale.combined(with: .opacity))"))
        XCTAssertFalse(recorder.contains(".move(edge:"))
        XCTAssertFalse(intelligence.contains(".move(edge:"))
        XCTAssertFalse(library.contains(".move(edge:"))
        XCTAssertTrue(recorder.contains(".scale(scale: 0.97)"))
        XCTAssertTrue(sidebar.contains(".scale(scale: 0.97)"))
        XCTAssertTrue(recorder.contains("reduceMotion ? .opacity"))
        XCTAssertTrue(sidebar.contains("reduceMotion ? .opacity"))
    }

    func testInteractionSmokeMeasuresInspectorAtRepresentativeWidths() throws {
        let interaction = try source("script/interaction_smoke.swift")
        let measurementStart = try XCTUnwrap(interaction.range(of: "progress(\"measuring inspector label widths\")"))
        let measurementLoop = try XCTUnwrap(
            interaction.range(of: "for targetWidth in inspectorWidthTargets", range: measurementStart.upperBound..<interaction.endIndex)
        )
        let setup = String(interaction[measurementStart.lowerBound..<measurementLoop.lowerBound])
        XCTAssertTrue(interaction.contains("let inspectorWidthTargets: [CGFloat] = [320, 380, 520]"))
        XCTAssertTrue(interaction.contains("let inspectorWidthTolerance: CGFloat = 18"))
        XCTAssertTrue(setup.contains("let inspectorMeasurementWorkspaceSize = CGSize(width: 1500, height: 900)"))
        XCTAssertTrue(setup.contains("setWindowFrame(meetingsWindow, size: inspectorMeasurementWorkspaceSize)"))
        XCTAssertTrue(setup.contains("$0.width >= 1470 && $0.height >= 860"))
        XCTAssertTrue(interaction.contains("Measured inspector label widths"))
        XCTAssertTrue(interaction.contains("func waitForExactAccessibleTexts("))
        XCTAssertTrue(interaction.contains("waitForExactAccessibleTexts("))
        XCTAssertTrue(interaction.contains("timeout: 5"))
        XCTAssertTrue(interaction.contains("if setupLabelsReady != expectedInspectorLabels"))
        XCTAssertTrue(interaction.contains("setupReadyForWidthProof = pressMeetingsSection("))
        XCTAssertTrue(interaction.contains("\"targetWidths\""))
        XCTAssertTrue(interaction.contains("\"measuredWidths\""))
        XCTAssertTrue(interaction.contains("\"tolerancePoints\""))
        XCTAssertTrue(interaction.contains("let withinTolerance = abs(measuredWidth - targetWidth) <= inspectorWidthTolerance"))
        XCTAssertFalse(interaction.contains("systemConstrainedMaximum"))
        XCTAssertFalse(interaction.contains("targetWidth == 520 && measuredWidth >= 440"))
        XCTAssertTrue(interaction.contains("Studio Microphone · Synthetic Input"))
        XCTAssertTrue(interaction.contains("Application process group"))
        XCTAssertTrue(interaction.contains("ScreenCaptureKit fallback"))

        let recorder = try source("Sources/MeetingVault/Views/RecorderView.swift")
        XCTAssertTrue(recorder.contains(#"capture-source-mode-\(source.id)"#))
    }

    func testInteractionSmokeReactivatesAndWaitsForMenuLifecycleState() throws {
        let smoke = try source("script/interaction_smoke.swift")
        let readiness = try functionSource("waitForApplicationReadyForMenu", in: smoke)

        XCTAssertTrue(readiness.contains("app.activate()"))
        XCTAssertTrue(readiness.contains(".activateAllWindows"))
        XCTAssertTrue(readiness.contains("kAXMenuBarAttribute"))
        XCTAssertTrue(readiness.contains("kAXWindowsAttribute"))
        XCTAssertTrue(readiness.contains("kAXFrontmostAttribute"))
        XCTAssertTrue(readiness.contains("let activationObserved = app.isActive"))
        XCTAssertTrue(readiness.contains("boolAttribute(appElement, kAXFrontmostAttribute as String) == true"))
        XCTAssertTrue(readiness.contains("let targetedWindowReady = windowToRaise != nil"))
        XCTAssertTrue(readiness.contains("activationObserved || targetedWindowReady"))
        XCTAssertTrue(readiness.contains("windowMatches($0, marker: \"meeting-transcript-workspace\")"))
        XCTAssertTrue(readiness.contains("Date().addingTimeInterval(timeout)"))
        XCTAssertTrue(smoke.contains("guard waitForApplicationReadyForMenu(appElement: appElement)"))
        XCTAssertTrue(smoke.contains("guard waitForApplicationReadyForMenu(appElement: appElement, timeout: 3) else {"))
        let layoutWait = try functionSource("waitForMeetingLayoutStable", in: smoke)
        XCTAssertTrue(layoutWait.contains("stableSamples >= 3"))
        XCTAssertTrue(layoutWait.contains("Date().addingTimeInterval(timeout)"))
        XCTAssertTrue(smoke.contains("guard waitForMeetingLayoutStable(appElement: appElement, timeout: 6) else {"))
        XCTAssertTrue(smoke.contains("return waitForMeetingLayoutStable(window: window, timeout: timeout)"))
        XCTAssertTrue(smoke.contains("func windowMatches(_ window: AXUIElement, marker: String) -> Bool"))
        XCTAssertTrue(smoke.contains("let mainWindowTitles = Set([\"Meetings\", \"Library\", \"Setup\", \"Agent\", \"Review\", \"Export\"])"))
        XCTAssertTrue(smoke.contains("mainWindowTitles.contains(windowTitle)"))
        XCTAssertTrue(smoke.contains("identifiers.contains(\"meeting-workspace-sidebar\")"))
        XCTAssertTrue(smoke.contains("identifiers.contains(\"meeting-workspace-inspector\")"))
    }

    func testInteractionSmokeMakesPrimaryTransportReachableBeforeInspectingIt() throws {
        let smoke = try source("script/interaction_smoke.swift")
        let start = try XCTUnwrap(smoke.range(of: "progress(\"checking Meetings\")"))
        let end = try XCTUnwrap(
            smoke.range(of: "progress(\"checking first-screen recording controls\")", range: start.upperBound..<smoke.endIndex)
        )
        let preparation = String(smoke[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(preparation.contains("waitForApplicationReadyForMenu(appElement: appElement)"))
        XCTAssertTrue(preparation.contains("waitForWindow("))
        XCTAssertTrue(preparation.contains("setWindowFrame("))
        XCTAssertTrue(preparation.contains("CGSize(width: 1600, height: 1000)"))
        XCTAssertTrue(preparation.contains("CGPoint(x: 10, y: 30)"))
        XCTAssertTrue(preparation.contains("waitForAnyMarker([\"Start Recording\", \"Stop Recording\"]"))
        XCTAssertTrue(smoke.contains("primaryTransportExposed"))
        XCTAssertTrue(smoke.contains("directOrOverflow"))
    }

    func testInteractionSmokeTreatsSpeechPermissionAsOptionalForLocalProvider() throws {
        let smoke = try source("script/interaction_smoke.swift")
        let start = try XCTUnwrap(smoke.range(of: "let requiredCapturePermissionActions"))
        let end = try XCTUnwrap(smoke.range(of: "addStep(\"Permission recovery actions visible\"", range: start.upperBound..<smoke.endIndex))
        let route = String(smoke[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(route.contains("Allow Screen & System Audio Recording"))
        XCTAssertTrue(route.contains("Allow Microphone"))
        XCTAssertFalse(route.contains("Allow Speech Recognition"))
        XCTAssertTrue(route.contains("Local only"))
    }

    func testRecorderExcellenceSmokeRequiresNativeStateDeltasAndMeasuredPrivacyEvidence() throws {
        let smoke = try source("script/recorder_excellence_smoke.swift")

        XCTAssertTrue(smoke.contains("local_transcription_fixture_smoke.swift"))
        XCTAssertTrue(smoke.contains("local_model_lifecycle_smoke.swift"))
        XCTAssertTrue(smoke.contains("confidence_review_smoke.swift"))
        for requiredContract in [
            "func editMeetingContext",
            "func meetingContextHash",
            "recording-level-microphone",
            "func numericAccessibilityValue",
            "func liveTranscriptHash",
            "struct WindowActivationSnapshot",
            "func bookmarkObservation",
            "struct NativeWorkflowObserver",
            "nativeObserved",
            "fixtureProven",
            "blockedEvidence"
        ] {
            XCTAssertTrue(smoke.contains(requiredContract), "Missing stateful proof contract: \(requiredContract)")
        }
        XCTAssertFalse(smoke.contains("containsText(\"Dark\", in: appElement) || containsText(\"Live Transport\""))
        XCTAssertFalse(smoke.contains("containsText(\"Speaking\", in: appElement) || containsText(\"Audio detected\""))
        XCTAssertFalse(smoke.contains("let miniDidNotActivate = nativeApp.isActive"))
        XCTAssertFalse(smoke.contains("finalized && fixturePassed"))
        XCTAssertFalse(smoke.contains("rawPrivateDataStored: false"))
        XCTAssertFalse(smoke.contains("externalNetworkUsed: false"))
    }

    func testKeyboardSmokeUsesAuthorizedIsolatedRecorderFixtures() throws {
        let smoke = try source("script/keyboard_smoke.swift")

        XCTAssertTrue(smoke.contains("MeetingVaultKeyboardSmoke-"))
        XCTAssertTrue(smoke.contains("--ui-smoke-library-root"))
        XCTAssertTrue(smoke.contains("--ui-smoke-permissions"))
        XCTAssertTrue(smoke.contains("authorized"))
        XCTAssertTrue(smoke.contains("--key-provider"))
        XCTAssertTrue(smoke.contains("local-file"))
        XCTAssertTrue(smoke.contains("rawUITextStored: false"))
    }

    func testToolbarInspectorRoutingHasSingleFocusedSectionAuthority() throws {
        let source = try source("Sources/MeetingVault/Views/MeetingsWorkspaceView.swift")
        let start = try XCTUnwrap(source.range(of: "private func route(_ focus: MeetingsWorkspaceFocus)"))
        let end = try XCTUnwrap(source.range(of: "private func applyPresentationEvent", range: start.upperBound..<source.endIndex))
        let route = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(route.contains("routePresentationEvent = .next("))
        XCTAssertTrue(route.contains("focus: inspectorFocus"))
        XCTAssertFalse(route.contains("focusedSection = inspectorFocus"))
        XCTAssertFalse(route.contains("inspectorModeValue ="))
        XCTAssertFalse(route.contains("isInspectorPresented ="))
    }

    func testConfidenceReviewAndSetupUseReachableAdaptiveSurfaces() throws {
        let inspector = try source("Sources/MeetingVault/Views/MeetingWorkspaceInspector.swift")
        let reviewStart = try XCTUnwrap(inspector.range(of: "private var reviewContent: some View"))
        let reviewEnd = try XCTUnwrap(inspector.range(of: "private var exportContent", range: reviewStart.upperBound..<inspector.endIndex))
        let review = String(inspector[reviewStart.lowerBound..<reviewEnd.lowerBound])
        XCTAssertTrue(review.contains("ConfidenceReviewView()"))
        XCTAssertFalse(review.contains("IntelligenceWorkspaceView("))

        let workspace = try source("Sources/MeetingVault/Views/MeetingsWorkspaceView.swift")
        XCTAssertTrue(workspace.contains("if focusedSection == .review"))
        XCTAssertTrue(workspace.contains("IntelligenceWorkspaceView(selectedTab: $selectedIntelligenceTab)"))
        XCTAssertTrue(workspace.contains("full-width-review-workspace"))

        let confidence = try source("Sources/MeetingVault/Views/ConfidenceReviewView.swift")
        for identifier in [
            "confidence-review-title",
            "confidence-review-issue-content",
            "confidence-review-correction-controls"
        ] {
            XCTAssertTrue(confidence.contains(identifier), "Missing visible Review geometry marker: \(identifier)")
        }

        let setup = try source("Sources/MeetingVault/Views/TranscriptionSetupCard.swift")
        XCTAssertTrue(setup.contains("ViewThatFits(in: .horizontal)"))
        XCTAssertTrue(setup.contains("transcription-recovery-row"))

        let settings = try source("Sources/MeetingVault/Views/SettingsView.swift")
        XCTAssertTrue(settings.contains("settings-status-content"))
        XCTAssertTrue(settings.contains("LazyVGrid"))
        XCTAssertFalse(settings.contains(".frame(width: 600, height: 620)"))

        let app = try source("Sources/MeetingVault/App/MeetingVaultApp.swift")
        XCTAssertTrue(app.contains(".frame(minWidth: 640, minHeight: 620)"))
        XCTAssertFalse(app.contains(".frame(width: 560)"))
    }

    func testCuratedAuditRequiresSurfaceSpecificVisibleGeometryEvidence() throws {
        let audit = try source("script/curated_screenshot_audit.swift")
        XCTAssertTrue(audit.contains("struct CuratedSurfaceGeometryEvidence"))
        XCTAssertTrue(audit.contains("surfaceGeometryEvidence"))
        for marker in [
            "confidence-review-title",
            "confidence-review-issue-content",
            "confidence-review-correction-controls",
            "settings-status-content",
            "transcription-recovery"
        ] {
            XCTAssertTrue(audit.contains(marker), "Missing curated surface assertion: \(marker)")
        }
    }

    func testReducedLayoutDiagnosticsUseExplicitStrictScenarios() throws {
        let smoke = try source("script/interaction_smoke.swift")
        XCTAssertTrue(smoke.contains("enum LayoutRegressionScenario"))
        XCTAssertTrue(smoke.contains("case compactOnly"))
        XCTAssertTrue(smoke.contains("case wideOnly"))
        XCTAssertTrue(smoke.contains("func applyDeclaredFrameChange"))
        XCTAssertTrue(smoke.contains("requested context menu target was absent"))
        XCTAssertTrue(smoke.contains("passed: false"))
        XCTAssertFalse(smoke.contains("var layoutPrefixCompactOnlyExtra"))
        XCTAssertFalse(smoke.contains("var layoutPrefixWideOnlyExtra"))
        XCTAssertFalse(smoke.contains("targetWidth == 520 && measuredWidth >= 440"))
    }

    func testAccessibilitySmokeCoversEveryRecorderExcellenceSurfaceSemantically() throws {
        let smoke = try source("script/accessibility_smoke.swift")
        for requiredContract in [
            "struct AccessibilitySurfaceResult",
            "Active recording controls",
            "Mini Recorder",
            "Confidence Review correction controls",
            "Local Models & Privacy",
            "keyboardReachable",
            "rolePassed",
            "enabledPassed",
            "focusPassed"
        ] {
            XCTAssertTrue(smoke.contains(requiredContract), "Missing accessibility surface contract: \(requiredContract)")
        }
        XCTAssertTrue(smoke.contains("func actionNames(_ element: AXUIElement) -> Set<String>"))
        XCTAssertTrue(smoke.contains("markerTargets.count == markers.count"))
        XCTAssertTrue(smoke.contains("let keyboardActionReachable"))
        XCTAssertTrue(smoke.contains("let keyboardControlRoles: Set<String>"))
        XCTAssertTrue(smoke.contains("let allCandidates = boundedRuntimeElements(in: root)"))
        XCTAssertTrue(smoke.contains("kAXPressAction as String"))
        XCTAssertTrue(smoke.contains("kAXShowMenuAction as String"))
        XCTAssertTrue(smoke.contains("func setVerticalScrollbars(in root: AXUIElement, to value: Double)"))
        XCTAssertTrue(smoke.contains("setVerticalScrollbars(in: appElement, to: 0)"))
        XCTAssertTrue(smoke.contains("setVerticalScrollbars(in: reviewRoot, to: 1)"))
        XCTAssertTrue(smoke.contains("setVerticalScrollbars(in: modelsRoot, to: 1)"))
        XCTAssertFalse(smoke.contains("let navigationPasses: [[String]] = []"))
        XCTAssertTrue(smoke.contains("rawUITextStored: false"))
    }

    func testInspectorHostingRootPublishesStableWindowResizeConstraints() throws {
        let source = try source("Sources/MeetingVault/Views/MeetingsWorkspaceView.swift")
        let start = try XCTUnwrap(source.range(of: ".inspector(isPresented: $isInspectorPresented)"))
        let end = try XCTUnwrap(source.range(of: ".onAppear", range: start.upperBound..<source.endIndex))
        let inspector = String(source[start.lowerBound..<end.lowerBound])

        let frame = try XCTUnwrap(inspector.range(of: ".frame("))
        XCTAssertTrue(inspector.contains("minWidth: 320"))
        XCTAssertTrue(inspector.contains("maxWidth: 520"))
        XCTAssertTrue(inspector.contains("minHeight: 0"))
        XCTAssertTrue(inspector.contains("maxHeight: .infinity"))
        XCTAssertTrue(inspector.contains("alignment: .topLeading"))
        let columnWidth = try XCTUnwrap(inspector.range(of: ".inspectorColumnWidth(min: 320, ideal: 380, max: 520)"))
        XCTAssertLessThan(frame.lowerBound, columnWidth.lowerBound)
    }

    func testAgentPresetPromptsUseCompactLeadingAlignedRows() throws {
        let source = try source("Sources/MeetingVault/Views/MeetingLibraryView.swift")
        XCTAssertTrue(source.contains("TranscriptPromptPresetRow"))
        XCTAssertTrue(source.contains("VStack(alignment: .leading, spacing: 0)"))
        XCTAssertFalse(source.contains("private var presetColumns: [GridItem]"))
        XCTAssertFalse(source.contains("LazyVGrid(columns: presetColumns"))
    }

    func testInspectorRowsUseNonSpatialHoverFeedbackAndSharedMotion() throws {
        let recorder = try source("Sources/MeetingVault/Views/RecorderView.swift")
        XCTAssertFalse(recorder.contains("scaleEffect(!reduceMotion && isHovered"))
        XCTAssertFalse(recorder.contains("shadow(color: Color.blue.opacity(isHovered"))
        XCTAssertFalse(recorder.contains(".smooth(duration: 0.24)"))
        XCTAssertFalse(recorder.contains(".smooth(duration: 0.3)"))

        let intelligence = try source("Sources/MeetingVault/Views/IntelligenceWorkspaceView.swift")
        XCTAssertFalse(intelligence.contains("scaleEffect(!reduceMotion && isHovered"))
        XCTAssertFalse(intelligence.contains("shadow(color: (segment.hasChanges"))
        XCTAssertTrue(intelligence.contains(".animation(reduceMotion ? nil : VaultMotion.selection, value: isHovered)"))
        XCTAssertTrue(intelligence.contains(".animation(reduceMotion ? nil : VaultMotion.selection, value: isSelected)"))
    }

    func testHealthDestinationLivesOnlyInDedicatedWindow() throws {
        let inspector = try source("Sources/MeetingVault/Views/MeetingWorkspaceInspector.swift")
        let healthWindow = try source("Sources/MeetingVault/Views/HealthRecoveryWindowView.swift")
        XCTAssertFalse(inspector.contains("OperationalHealthPane"))
        XCTAssertFalse(inspector.contains("showHealthRecovery"))
        XCTAssertFalse(inspector.contains("meetings-section-recover-content"))
        XCTAssertTrue(healthWindow.contains("OperationalHealthPane()"))
        XCTAssertTrue(healthWindow.contains("health-recovery-window"))
        XCTAssertTrue(healthWindow.contains("meetings-section-recover-content"))
        XCTAssertEqual(healthWindow.components(separatedBy: "ScrollView").count - 1, 0)
    }

    func testReduceMotionDisablesSpatialLayoutAnimations() throws {
        let polishSupport = try source("Sources/MeetingVault/Views/PolishSupport.swift")
        XCTAssertTrue(
            polishSupport.contains(".animation(reduceMotion ? nil : VaultMotion.selection, value: value)"),
            "The audio-level width animation must be disabled under Reduce Motion."
        )
        XCTAssertFalse(
            polishSupport.contains(".animation(VaultMotion.reveal(reduceMotion: reduceMotion), value: value)"),
            "The crossfade fallback must not animate audio-level width under Reduce Motion."
        )

        let meetingLibrary = try source("Sources/MeetingVault/Views/MeetingLibraryView.swift")
        XCTAssertTrue(
            meetingLibrary.contains(".animation(reduceMotion ? nil : VaultMotion.reveal, value: visibleTranscriptCount)"),
            "Visible transcript row-count layout must not animate under Reduce Motion."
        )
        XCTAssertFalse(
            meetingLibrary.contains(".animation(VaultMotion.reveal(reduceMotion: reduceMotion), value: visibleTranscriptCount)"),
            "The crossfade fallback must not spatially animate transcript layout under Reduce Motion."
        )
    }

    func testLiveAudioLevelUsesTransformBasedMotion() throws {
        let source = try source("Sources/MeetingVault/Views/PolishSupport.swift")
        XCTAssertTrue(source.contains(".scaleEffect(x: normalizedLevel, y: 1, anchor: .leading)"))
        XCTAssertFalse(source.contains(".frame(width: max(8, proxy.size.width"))
        XCTAssertTrue(source.contains(".animation(reduceMotion ? nil : VaultMotion.selection, value: value)"))
    }

    func testDiagnosticsActionHeadersAdaptToNarrowInspector() throws {
        let source = try String(
            contentsOf: repoRoot().appendingPathComponent("Sources/MeetingVault/Views/DiagnosticsView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(
            source.contains("AdaptiveDiagnosticsActionHeader"),
            "Diagnostics action cards must share a narrow-inspector-aware header."
        )
        XCTAssertTrue(
            source.contains("ViewThatFits(in: .horizontal)"),
            "The diagnostics header must switch layouts from measured horizontal fit."
        )
    }

    func testRepositoryPresentationIncludesCuratedScreenshots() throws {
        let expectedScreenshots = [
            "meeting-console.png",
            "recording-setup.png",
            "transcript-agent.png",
            "health-recovery.png"
        ]
        let screenshots = repoRoot().appendingPathComponent("docs/screenshots", isDirectory: true)

        for name in expectedScreenshots {
            let url = screenshots.appendingPathComponent(name)
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: url.path),
                "Missing curated repository screenshot: \(name)"
            )
        }

        let exporter = try String(
            contentsOf: repoRoot().appendingPathComponent("script/export_public_source.sh"),
            encoding: .utf8
        )
        XCTAssertTrue(
            exporter.contains("docs/screenshots"),
            "The deterministic public export must explicitly include curated screenshots."
        )
        XCTAssertTrue(exporter.contains("-name '__pycache__'"))
        XCTAssertTrue(exporter.contains("-name '*.pyc'"))

        let readme = try String(
            contentsOf: repoRoot().appendingPathComponent("README.md"),
            encoding: .utf8
        )
        for name in expectedScreenshots {
            XCTAssertTrue(readme.contains("docs/screenshots/\(name)"))
        }
    }

    func testCleanCheckoutSmokeAcceptsNormalRepositoriesAndLinkedWorktrees() throws {
        let smoke = try source("script/clean_checkout_smoke.sh")

        XCTAssertTrue(smoke.contains("git -C \"$ROOT_DIR\" rev-parse --is-inside-work-tree"))
        XCTAssertFalse(smoke.contains("[[ ! -d \"$ROOT_DIR/.git\" ]]"))
    }

    func testCuratedScreenshotAuditGuardsFinalDeliverables() throws {
        let audit = try source("script/curated_screenshot_audit.swift")
        for name in [
            "meeting-console.png",
            "recording-setup.png",
            "transcript-agent.png",
            "health-recovery.png"
        ] {
            XCTAssertTrue(audit.contains(name))
        }
        XCTAssertTrue(audit.contains("let lightNearBlackRatioUpperBound = 0.08"))
        XCTAssertTrue(audit.contains("func sampledImageMetrics"))
        XCTAssertTrue(audit.contains("artifactFree"))
        XCTAssertTrue(audit.contains("darkIntegrityPassed"))
        XCTAssertTrue(audit.contains("repoRelativePath"))
        XCTAssertFalse(audit.contains("screenshotPath: screenshotURL.path"))

        let reportURL = repoRoot()
            .appendingPathComponent("docs/evidence/curated-screenshot-audit-2026-07-16.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: reportURL.path))
        guard let data = try? Data(contentsOf: reportURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("Curated screenshot audit report must be readable JSON")
            return
        }
        XCTAssertEqual(json["status"] as? String, "pass")
        XCTAssertEqual((json["files"] as? [[String: Any]])?.count, 4)
        XCTAssertEqual((json["issues"] as? [String]) ?? ["missing"], [])
    }

    func testInteractionSmokeDragsSplittersWithIntermediatePointerEvents() throws {
        let source = try String(
            contentsOf: repoRoot().appendingPathComponent("script/interaction_smoke.swift"),
            encoding: .utf8
        )

        let pointerPath = try functionSource("postPointerPath", in: source)
        XCTAssertTrue(
            pointerPath.contains("for step in 1...steps"),
            "AppKit splitters require a short stream of pointer events rather than one jumped drag event."
        )
        XCTAssertTrue(pointerPath.contains("mouseType: .leftMouseDragged"))
        XCTAssertTrue(source.contains("steps: 10 + attempt * 2"))
    }

    func testInteractionSmokeUsesStableInWindowRouteForLateHealthNavigation() throws {
        let source = try String(
            contentsOf: repoRoot().appendingPathComponent("script/interaction_smoke.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(
            source.contains("controlMarkers: [\"Health\", \"meetings-section-recover-control\""),
            "Health navigation must use the already-proven in-window section control."
        )
        XCTAssertTrue(source.contains("pressSettingsMenu(appElement: appElement)"))
    }

    func testInteractionSmokeUsesObservableWindowActivationInsteadOfAXRaiseResult() throws {
        let source = try source("script/interaction_smoke.swift")
        let activation = try functionSource("activateWindow", in: source)

        XCTAssertTrue(activation.contains("waitForApplicationActive"))
        XCTAssertTrue(activation.contains("markerVisible(windowMarker, rootElement: window)"))
        XCTAssertTrue(activation.contains("kAXFocusedAttribute"))
        XCTAssertTrue(activation.contains("kAXMainAttribute"))
        XCTAssertFalse(activation.contains("return result == .success"))

        let reduceStart = try XCTUnwrap(source.range(of: "let mainReactivatedAfterHealth"))
        let reduceEnd = try XCTUnwrap(
            source.range(
                of: "progress(\"measuring inspector label widths\")",
                range: reduceStart.upperBound..<source.endIndex
            )
        )
        let reduceMotion = String(source[reduceStart.lowerBound..<reduceEnd.lowerBound])
        XCTAssertTrue(reduceMotion.contains("itemTitle: \"Meetings\""))
        XCTAssertTrue(reduceMotion.contains("[\"Preset prompts\", \"Custom prompt\"]"))
        XCTAssertTrue(reduceMotion.contains("inWindowContaining: \"meeting-transcript-workspace\""))
    }

    func testInteractionSmokeOpensSettingsFromObservablyActiveMainWindow() throws {
        let source = try source("script/interaction_smoke.swift")
        let start = try XCTUnwrap(source.range(of: "progress(\"opening Settings\")"))
        let end = try XCTUnwrap(source.range(of: "let status = issues.isEmpty", range: start.upperBound..<source.endIndex))
        let block = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(block.contains("activateWindow(\n    containing: \"meeting-transcript-workspace\""))
        XCTAssertTrue(block.contains("pressSettingsMenu(appElement: appElement)"))
        XCTAssertTrue(block.contains("waitForSettingsWindow(appElement: appElement"))
        XCTAssertTrue(block.contains("rootElement: settingsWindow"))
        XCTAssertFalse(block.contains("postKey(43"))
    }

    func testInteractionSmokeScopesMeetingSelectionToMainWindowAndRequiresHeaderPostcondition() throws {
        let source = try source("script/interaction_smoke.swift")
        let named = try functionSource("openMeetingRow", in: source)
        let fallback = try functionSource("openAnyMeetingRow", in: source)

        for selection in [named, fallback] {
            XCTAssertTrue(selection.contains("firstWindow("))
            XCTAssertTrue(selection.contains("containing: \"meeting-transcript-workspace\""))
            XCTAssertTrue(selection.contains("allElements(rootElement: meetingWindow)"))
            XCTAssertTrue(selection.contains("meeting-transcript-header"))
            XCTAssertTrue(selection.contains("rootElement: meetingWindow"))
        }
    }

    func testInteractionSmokeFindsSettingsByExactTitleOrConsentMarker() throws {
        let source = try source("script/interaction_smoke.swift")
        let settings = try functionSource("waitForSettingsWindow", in: source)

        XCTAssertTrue(settings.contains("kAXTitleAttribute"))
        XCTAssertTrue(settings.contains("[\"Settings\", \"MeetingVault Settings\"]"))
        XCTAssertTrue(settings.contains("Require consent status before recording"))
        XCTAssertTrue(settings.contains("elementsAttribute(appElement, kAXWindowsAttribute"))
        XCTAssertFalse(settings.contains("windowContains(\"Settings\""))
    }

    func testInteractionSmokeReacquiresHealthWindowBeforeLaterActions() throws {
        let source = try source("script/interaction_smoke.swift")
        let start = try XCTUnwrap(source.range(of: "progress(\"checking release readiness panel\")"))
        let end = try XCTUnwrap(source.range(of: "progress(\"opening Settings\")", range: start.upperBound..<source.endIndex))
        let block = String(source[start.lowerBound..<end.lowerBound])

        for root in ["healthWindowForReleaseActions", "healthWindowForRetentionReview", "healthWindowForDeleteGate"] {
            XCTAssertTrue(block.contains("let \(root) = waitForWindow("), "Missing fresh root: \(root)")
        }
    }

    func testInteractionSmokeOpensOnlyExactOwnedSettingsMenuItem() throws {
        let source = try source("script/interaction_smoke.swift")
        let settingsMenu = try functionSource("pressSettingsMenu", in: source)

        XCTAssertTrue(settingsMenu.contains("menuTitle: appName"))
        XCTAssertTrue(settingsMenu.contains("itemTitles: [\"Settings…\", \"Settings...\"]"))
        XCTAssertTrue(settingsMenu.contains("pressExactOwnedApplicationMenuItem"))
        XCTAssertFalse(settingsMenu.contains("exact: false"))

        let owned = try functionSource("pressExactOwnedApplicationMenuItem", in: source)
        XCTAssertTrue(owned.contains("owner: menuBarItem"))
        XCTAssertTrue(owned.contains("itemTitles.contains(title)"))
        XCTAssertFalse(owned.contains("pressVisibleMenuItem"))
    }

    func testInteractionSmokeUsesFreshFeedbackDrivenSplitterPaths() throws {
        let source = try source("script/interaction_smoke.swift")
        let feedback = try functionSource("dragSplitterWithFeedback", in: source)
        let resize = try functionSource("resizeInspector", in: source)

        XCTAssertTrue(feedback.contains("splitters(inWindowContaining:"))
        XCTAssertTrue(feedback.contains("for attempt in 0..<"))
        XCTAssertTrue(feedback.contains("pollForSplitterPositionChange"))
        XCTAssertTrue(feedback.contains("resetPointer"))
        XCTAssertTrue(feedback.contains("currentPosition"))
        XCTAssertTrue(feedback.contains("remainingDelta"))
        XCTAssertFalse(feedback.contains("let start ="))

        XCTAssertTrue(resize.contains("measuredInspectorWidth"))
        XCTAssertTrue(resize.contains("dragSplitterWithFeedback"))
        XCTAssertTrue(resize.contains("splitterIndex:"))
        XCTAssertTrue(source.contains("let initialSplitMovement = dragSplitterWithFeedback"))
        XCTAssertFalse(source.contains("dragElement(splitter"))
    }

    func testReturnToMeetingsRequiresTheDefaultAgentDestination() throws {
        let source = try source("script/interaction_smoke.swift")
        let start = try XCTUnwrap(source.range(of: "progress(\"returning to Meetings\")"))
        let end = try XCTUnwrap(
            source.range(of: "progress(\"copying visible transcript\")", range: start.upperBound..<source.endIndex)
        )
        let block = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(block.contains("[\"Preset prompts\", \"Custom prompt\"]"))
        XCTAssertTrue(block.contains("inWindowContaining: \"meeting-transcript-workspace\""))
        XCTAssertFalse(block.contains("&& waitForMarker(\"meeting-transcript-workspace\""))
    }

    func testFilteredLibraryDoesNotClearTheMeetingUsedByExport() throws {
        let source = try String(
            contentsOf: repoRoot().appendingPathComponent("Sources/MeetingVault/Views/MeetingWorkspaceSidebar.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("private var meetingSelectionBinding: Binding<UUID?>"))
        XCTAssertTrue(source.contains("List(selection: meetingSelectionBinding)"))
        XCTAssertTrue(source.contains("else if store.meetings.isEmpty"))
    }

    func testMeetingWorkspaceUsesNativeSplitView() throws {
        let source = try source("Sources/MeetingVault/Views/MeetingsWorkspaceView.swift")
        XCTAssertTrue(source.contains("NavigationSplitView"))
        XCTAssertFalse(source.contains("HSplitView"))
    }

    func testTranscriptWorkspaceIsThePrimaryDetailSurface() throws {
        let source = try source("Sources/MeetingVault/Views/MeetingTranscriptWorkspace.swift")
        XCTAssertTrue(source.contains("LiveTranscriptionPreviewBlock()"))
        XCTAssertTrue(source.contains("LibraryVisibleTranscriptBlock()"))
        XCTAssertTrue(source.contains("meeting-transcript-workspace"))
    }

    func testWorkspaceToolbarKeepsOneStableRecordingTransport() throws {
        let source = try source("Sources/MeetingVault/Views/MeetingWorkspaceToolbar.swift")
        XCTAssertTrue(source.contains("primary-recording-transport"))
        XCTAssertTrue(source.contains("meeting-workspace-more-menu"))
        XCTAssertFalse(source.contains("VaultPulseHalo"))
    }

    func testAdvancedToolsLiveBehindDetailsOrMore() throws {
        let workspace = try source("Sources/MeetingVault/Views/MeetingsWorkspaceView.swift")
        let inspector = try source("Sources/MeetingVault/Views/MeetingWorkspaceInspector.swift")
        XCTAssertTrue(workspace.contains(".inspector(isPresented:"))
        XCTAssertFalse(workspace.contains("toolsInspector"))
        XCTAssertTrue(workspace.contains("MeetingWorkspacePresentation.routeTarget(for:"))
        XCTAssertFalse(inspector.contains("meetings-section-recover-content"))
        XCTAssertFalse(inspector.contains("OperationalHealthPane"))
    }

    func testAdvancedDestinationControlsRetainCompatibilityIdentifiers() throws {
        let toolbar = try source("Sources/MeetingVault/Views/MeetingWorkspaceToolbar.swift")
        let inspector = try source("Sources/MeetingVault/Views/MeetingWorkspaceInspector.swift")

        for focus in ["find", "record", "review", "export", "recover"] {
            let identifier = "meetings-section-\(focus)-control"
            XCTAssertTrue(
                toolbar.contains(identifier) || inspector.contains(identifier),
                "Missing live replacement control identifier: \(identifier)"
            )
        }
    }

    func testInteractionSmokeRoutesAdvancedToolsThroughMoreAndInspector() throws {
        let source = try source("script/interaction_smoke.swift")
        XCTAssertTrue(source.contains("meeting-workspace-more-menu"))
        XCTAssertTrue(source.contains("meeting-workspace-inspector"))
        XCTAssertFalse(source.contains("meetings-section-more-content"))
    }

    func testInteractionSmokeTraversesOnlyThePressedPopupOwnedMenu() throws {
        let source = try source("script/interaction_smoke.swift")
        XCTAssertTrue(source.contains("func pressFirstAvailableElement("))
        XCTAssertTrue(source.contains("func pressOwnedPopupMenuItem("))
        XCTAssertFalse(source.contains("func pressBoundedPopupMenuItem("))

        let ownedTraversal = try functionSource("pressOwnedPopupMenuItem", in: source)
        XCTAssertTrue(ownedTraversal.contains("let deadline = Date().addingTimeInterval"))
        XCTAssertFalse(ownedTraversal.contains("appElement"))
        XCTAssertFalse(ownedTraversal.contains("kAXWindowsAttribute"))
    }

    func testVisualMatrixUsesAXVisibleSetupMarker() throws {
        let source = try source("script/visual_matrix_smoke.swift")
        XCTAssertTrue(source.contains("stringAttribute(element, kAXIdentifierAttribute)"))
        XCTAssertTrue(
            source.contains(
                "WorkspaceTarget(name: \"Setup\", rawValue: \"recorder\", expectedMarker: \"primary-audio-input-selection\")"
            )
        )
        XCTAssertFalse(
            source.contains(
                "WorkspaceTarget(name: \"Setup\", rawValue: \"recorder\", expectedMarker: \"meetings-section-record-content\")"
            )
        )
    }

    func testVisualMatrixUsesExposedLeafMarkersForAdvancedRoutes() throws {
        let source = try source("script/visual_matrix_smoke.swift")
        XCTAssertTrue(
            source.contains(
                "WorkspaceTarget(name: \"Import\", rawValue: \"library\", expectedMarker: \"Local Recording Import\")"
            )
        )
        XCTAssertTrue(
            source.contains(
                "WorkspaceTarget(name: \"Agent\", rawValue: \"intelligence\", expectedMarker: \"Preset prompts\")"
            )
        )
        XCTAssertTrue(
            source.contains(
                "WorkspaceTarget(name: \"Health\", rawValue: \"diagnostics\", expectedMarker: \"Health & Recovery\")"
            )
        )
        XCTAssertFalse(source.contains("expectedMarker: \"meetings-section-find-content\""))
        XCTAssertFalse(source.contains("expectedMarker: \"meetings-section-understand-content\""))
        XCTAssertFalse(source.contains("expectedMarker: \"meetings-section-recover-content\""))
    }

    func testInteractionSmokeUsesPostconditionsRetryAndGeometryForFragileRoutes() throws {
        let source = try source("script/interaction_smoke.swift")
        let routeSource = try functionSource("pressMeetingsSection", in: source)
        let searchPosition = try XCTUnwrap(source.range(of: "checking Meetings search"))
        let minimumPosition = try XCTUnwrap(source.range(of: "checking minimum-size layout reachability"))

        XCTAssertTrue(routeSource.contains("for attempt in 1...2"))
        XCTAssertTrue(routeSource.contains("\"meeting-workspace-inspector\""))
        XCTAssertTrue(routeSource.contains("inWindowContaining: \"meeting-transcript-workspace\""))
        XCTAssertTrue(routeSource.contains("pressEscape()"))
        XCTAssertTrue(routeSource.contains("pressMenu(menuTitle: \"Workspace\", itemTitle: menuTitle"))
        XCTAssertLessThan(searchPosition.lowerBound, minimumPosition.lowerBound)
        XCTAssertTrue(source.contains("sorted { lhs, rhs in"))
        for detail in ["fieldFound", "valueApplied", "filterVisible", "restored"] {
            XCTAssertTrue(source.contains(detail), "Missing search proof detail: \(detail)")
        }
    }

    func testApplicationMenuFallbackOpensTheOwningMenuBeforeRetryingItsItem() throws {
        let source = try source("script/interaction_smoke.swift")
        let pressMenu = try functionSource("pressMenu", in: source)

        XCTAssertTrue(pressMenu.contains("for attempt in 1...2"))
        XCTAssertFalse(pressMenu.contains("waitForApplicationActive()"))
        XCTAssertTrue(pressMenu.contains("waitForApplicationReadyForMenu(appElement: appElement)"))
        XCTAssertTrue(pressMenu.contains("performAXAction(menuBarItem, kAXPressAction as String)"))
        XCTAssertTrue(pressMenu.contains("pressVisibleMenuItem(containing: itemTitle"))
        XCTAssertTrue(pressMenu.contains("progress(\"applicationMenu="))
    }

    func testLaunchEventAndAgentSegmentAreAppliedAuthoritatively() throws {
        let content = try source("Sources/MeetingVault/Views/ContentView.swift")
        let workspace = try source("Sources/MeetingVault/Views/MeetingsWorkspaceView.swift")
        let smoke = try source("script/interaction_smoke.swift")

        XCTAssertTrue(content.contains("MeetingWorkspacePresentation.initialEvent(from: arguments)"))
        XCTAssertTrue(workspace.contains(".onAppear {"))
        let applyEvent = try functionSource("applyPresentationEvent", in: workspace)
        XCTAssertTrue(applyEvent.contains("focusedSection = event.focus"))
        XCTAssertTrue(smoke.contains("func pressExactAgentSegment("))
        XCTAssertTrue(smoke.contains("for attempt in 1...2"))
        XCTAssertTrue(smoke.contains("kAXRadioButtonRole"))
    }

    func testSidebarSearchUsesFocusedKeyboardInputRatherThanAXValueMutation() throws {
        let source = try source("script/interaction_smoke.swift")
        let search = try functionSource("setSidebarSearchField", in: source)

        XCTAssertTrue(search.contains("replaceFocusedTextWithKeyboard"))
        XCTAssertFalse(search.contains("AXUIElementSetAttributeValue(element, kAXValueAttribute"))
        XCTAssertTrue(source.contains("Show Sidebar"))
    }

    func testUISmokeVisualFixturesCannotReadHostAudioOrImportPaths() throws {
        let app = try source("Sources/MeetingVault/App/MeetingVaultApp.swift")
        let visual = try source("script/visual_matrix_smoke.swift")

        XCTAssertTrue(app.contains("MockAudioInputDeviceProvider("))
        XCTAssertTrue(app.contains("ui-smoke-studio-microphone"))
        XCTAssertTrue(app.contains("Synthetic Planning Session"))
        XCTAssertTrue(app.contains("seedUISmokeLocalRecordingFixture"))
        for marker in ["/Users/", "/Volumes/", "/Downloads/", "/Music/", "Audio Hijack"] {
            XCTAssertTrue(visual.contains(marker), "Visual privacy scan is missing marker: \(marker)")
        }
        XCTAssertFalse(visual.contains("label: \"Downloads\", value: \"Downloads\""))
        XCTAssertFalse(visual.contains("label: \"Music\", value: \"Music\""))
        XCTAssertTrue(visual.contains("Host.current().localizedName"))
        XCTAssertTrue(visual.contains("sensitiveUITextDetected"))
    }

    func testPrimaryToolbarKeepsTransportAndMoreAsSeparateVisibleItems() throws {
        let toolbar = try source("Sources/MeetingVault/Views/MeetingWorkspaceToolbar.swift")
        let smoke = try source("script/interaction_smoke.swift")

        XCTAssertFalse(toolbar.contains("ToolbarItemGroup(placement: .primaryAction)"))
        XCTAssertEqual(
            toolbar.components(separatedBy: "ToolbarItem(placement: .navigation)").count - 1,
            2
        )
        XCTAssertEqual(
            toolbar.components(separatedBy: "ToolbarItem(placement: .secondaryAction)").count - 1,
            3
        )
        XCTAssertTrue(toolbar.contains("AppearancePicker()"))
        XCTAssertTrue(toolbar.contains(".fixedSize(horizontal: true, vertical: false)"))
        XCTAssertTrue(toolbar.contains(".labelStyle(.iconOnly)"))
        XCTAssertTrue(toolbar.contains(".accessibilityLabel(\"Inspector\")"))
        XCTAssertTrue(smoke.contains("func visibleToolbarElement("))
        XCTAssertTrue(smoke.contains("func hasOnScreenGeometry("))
    }

    func testInteractionSmokeProvesAppearancePickerReachableAtMinimumWidth() throws {
        let smoke = try source("script/interaction_smoke.swift")

        XCTAssertTrue(smoke.contains("func appearancePickerReachability("))
        XCTAssertTrue(smoke.contains("Appearance picker minimum-width reachability"))
        XCTAssertTrue(smoke.contains("appearance-picker"))
        XCTAssertTrue(smoke.contains("reachability == .direct || reachability == .overflow"))
    }

    func testAdvancedRouteReacquiresOnlyExactVisibleMoreMenu() throws {
        let source = try source("script/interaction_smoke.swift")
        let route = try functionSource("pressMeetingsSection", in: source)
        let lookup = try functionSource("exactVisibleMoreMenu", in: source)
        let visibleLookup = try functionSource("visibleToolbarElement", in: source)

        XCTAssertTrue(lookup.contains("meeting-workspace-more-menu"))
        XCTAssertTrue(visibleLookup.contains("localizedCaseInsensitiveCompare(exactLabel)"))
        XCTAssertTrue(lookup.contains("kAXPopUpButtonRole"))
        XCTAssertTrue(lookup.contains("kAXMenuButtonRole"))
        XCTAssertTrue(visibleLookup.contains("hasOnScreenGeometry"))
        XCTAssertFalse(route.contains("containingAny: [\"meeting-workspace-more-menu\", \"More\"]"))
        XCTAssertTrue(route.contains("exactVisibleMoreMenu("))
        XCTAssertTrue(route.contains("waitForMainWindow("))
        XCTAssertTrue(route.contains("activate(options: [.activateAllWindows])"))
    }

    func testSidebarSearchReacquiresAndConfirmsFocusBeforeTyping() throws {
        let source = try source("script/interaction_smoke.swift")
        let search = try functionSource("setSidebarSearchField", in: source)

        XCTAssertTrue(search.contains("for attempt in 1...2"))
        XCTAssertTrue(search.contains("focusedElementMatches("))
        XCTAssertTrue(search.contains("replaceFocusedTextWithKeyboard"))
        XCTAssertTrue(source.contains("func waitForMeetingRowCount("))
        XCTAssertTrue(source.contains("hasPrefix(\"Meeting row. \")"))
        XCTAssertTrue(source.contains("seen.insert(CFHash(element)).inserted"))
        XCTAssertFalse(source.contains("hasPrefix(\"meeting-row-title-\")"))
        XCTAssertTrue(source.contains("postKey(1, flags: [.maskCommand, .maskControl])"))
        XCTAssertTrue(source.contains("menuTitle: \"View\", itemTitle: \"Show Sidebar\""))
        XCTAssertTrue(source.contains("let searchWorkspaceSize = CGSize(width: 1440, height: 900)"))
        XCTAssertTrue(source.contains("resizeInspector(to: 320"))
        XCTAssertTrue(source.contains("searchGeometryRestored && sidebarMeetingRowsVisible"))
        XCTAssertTrue(source.contains("waitForMeetingRowCount(2, appElement: appElement, timeout: 4)"))
        XCTAssertLessThan(
            try XCTUnwrap(search.range(of: "focusedElementMatches(")).lowerBound,
            try XCTUnwrap(search.range(of: "replaceFocusedTextWithKeyboard")).lowerBound
        )
    }

    func testMinimumLayoutRoutesWhileWideThenVerifiesCompactContent() throws {
        let source = try source("script/interaction_smoke.swift")
        let minimumStart = try XCTUnwrap(source.range(of: "checking minimum-size layout reachability"))
        let minimumEnd = try XCTUnwrap(
            source.range(of: "checking low-storage recovery", range: minimumStart.upperBound..<source.endIndex)
        )
        let block = String(source[minimumStart.lowerBound..<minimumEnd.lowerBound])

        let reviewRoute = try XCTUnwrap(block.range(of: "let reviewPressed = pressMeetingsSection("))
        let reviewResize = try XCTUnwrap(block.range(of: "let resizedReviewMinimum = applyDeclaredFrameChange(.compact"))
        XCTAssertLessThan(reviewRoute.lowerBound, reviewResize.lowerBound)
        XCTAssertTrue(block.contains("restoredWideFinal"))
        XCTAssertFalse(block.contains("let exportPressed = pressMeetingsSection("))
        XCTAssertTrue(block.contains("waitForMarker(\"Playback\""))
        XCTAssertTrue(source.contains("case .compact: CGSize(width: 1_180, height: 692)"))
    }

    func testPlaybackPanePublishesStableContentIdentityAndSmokeSelectsTheTabRole() throws {
        let workspace = try source("Sources/MeetingVault/Views/IntelligenceWorkspaceView.swift")
        let smoke = try source("script/interaction_smoke.swift")

        XCTAssertTrue(
            workspace.contains(
                ".accessibilityIdentifier(IntelligenceWorkspaceTab.playback.contentAccessibilityIdentifier)"
            )
        )
        XCTAssertTrue(smoke.contains("intelligence-tab-playback-content"))
        let selector = try functionSource("pressPlaybackTab", in: smoke)
        XCTAssertTrue(selector.contains("for attempt in 1...2"))
        XCTAssertTrue(selector.contains("== kAXRadioButtonRole as String"))
        XCTAssertTrue(selector.contains("localizedCaseInsensitiveCompare(\"Playback\") == .orderedSame"))
        XCTAssertTrue(selector.contains("Thread.sleep(forTimeInterval: 0.5)"))
        XCTAssertTrue(selector.contains("postcondition="))
        XCTAssertTrue(
            smoke.contains(
                "let reviewReadyForContextMenus = reviewPressedForContextMenus\n    && waitForMeetingLayoutStable(appElement: appElement, timeout: 6)"
            )
        )
        XCTAssertTrue(smoke.contains("let playbackReady = reviewReadyForContextMenus\n    && pressPlaybackTab(appElement: appElement)"))
    }

    func testVisualMatrixUsesFixedDeniedPermissionFixture() throws {
        let source = try source("script/visual_matrix_smoke.swift")

        XCTAssertTrue(source.contains("\"--ui-smoke-permissions\""))
        XCTAssertTrue(source.contains("\"denied\""))
    }

    func testVisualMatrixUsesDeterministicPublicFixtureRootAndScansPrivateTemps() throws {
        let source = try source("script/visual_matrix_smoke.swift")

        XCTAssertTrue(source.contains("/tmp/MeetingVault-Visual-Smoke"))
        XCTAssertFalse(source.contains("MeetingVaultVisualMatrix-\(UUID().uuidString)"))
        XCTAssertTrue(source.contains("func resetVisualSmokeLibraryRoot("))
        XCTAssertTrue(source.contains("SensitiveUITextMarker(label: \"/var/folders/\""))
        XCTAssertTrue(source.contains("SensitiveUITextMarker(label: \"/private/var/folders/\""))
    }

    func testInteractionSmokeCleansUniqueRootThroughCentralizedExit() throws {
        let source = try source("script/interaction_smoke.swift")
        let cleanup = try functionSource("cleanupInteractionSmokeStorage", in: source)
        let finish = try functionSource("finishInteractionSmoke", in: source)

        XCTAssertTrue(cleanup.contains("FileManager.default.removeItem(at: smokeLibraryRoot)"))
        XCTAssertTrue(finish.contains("terminateIsolatedAppBeforeCleanup()"))
        XCTAssertTrue(finish.contains("cleanupInteractionSmokeStorage()"))
        XCTAssertEqual(
            source.components(separatedBy: "finishInteractionSmoke(").count - 1,
            7,
            "Six post-root terminal paths, including reduced layout mode, plus the centralized function must use one cleanup exit."
        )
        XCTAssertEqual(
            source.components(separatedBy: "exit(").count - 1,
            4,
            "Only three pre-root argument exits and the centralized cleanup exit may remain."
        )
    }

    func testInteractionSmokeKeepsResizeAndCancelProofStrict() throws {
        let source = try source("script/interaction_smoke.swift")
        XCTAssertTrue(source.contains("splitViewResizePassed = dragPosted && movedEnough && panesUsable"))
        XCTAssertTrue(
            source.contains(
                "let cancelPreservedCandidate = confirmationVisible && dialogClosed && retentionStillVisible && deleteStillGated"
            )
        )
        XCTAssertFalse(source.contains("let cancelAttemptDismissedDialog"))
    }

    func testAppAndLocalTranscriptionSmokeShareProductionFinalCompositionResolver() throws {
        let store = try source("Sources/MeetingVault/Stores/MeetingVaultStore.swift")
        let smoke = try source("Sources/MeetingVaultLocalTranscriptionFixtureSmoke/main.swift")

        XCTAssertTrue(store.contains("LocalFinalTranscriptionCompositionResolver.production("))
        XCTAssertTrue(smoke.contains("LocalFinalTranscriptionCompositionResolver.production("))
        XCTAssertFalse(smoke.contains("LocalFinalTranscriptionCompositionFactory.fixture("))
        XCTAssertTrue(smoke.contains("productionWiringExercised: true"))
        XCTAssertTrue(smoke.contains("realModelInference: false"))
    }

    private func functionSource(_ name: String, in source: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: "func \(name)("))
        let remainder = source[start.lowerBound...]
        let next = remainder.dropFirst().range(of: "\nfunc ")?.lowerBound ?? source.endIndex
        return String(source[start.lowerBound..<next])
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: repoRoot().appendingPathComponent(path), encoding: .utf8)
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
