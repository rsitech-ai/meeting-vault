#!/usr/bin/env swift
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

struct RequiredLabelResult: Codable {
    var label: String
    var found: Bool
}

struct HelpAffordanceTarget {
    var name: String
    var controlMarkers: [String]
    var helpMarkers: [String]
}

struct HelpAffordanceResult: Codable {
    var name: String
    var foundControl: Bool
    var foundHelp: Bool
}

struct ForbiddenTextResult: Codable {
    var marker: String
    var found: Bool
}

struct ActionResult: Codable {
    var name: String
    var status: String
    var axError: String?
}

struct AccessibilitySurfaceResult: Codable {
    var surface: String
    var freshProcess: Bool
    var targetCount: Int
    var rolePassed: Bool
    var enabledPassed: Bool
    var focusPassed: Bool
    var keyboardReachable: Bool
}

struct AccessibilitySmokeReport: Codable {
    var timestamp: String
    var status: String
    var appName: String
    var bundleIdentifier: String
    var pid: Int?
    var axTrusted: Bool
    var launchedByScript: Bool
    var windowCount: Int
    var visibleWindowCount: Int
    var elementCount: Int
    var roleCounts: [String: Int]
    var requiredLabels: [RequiredLabelResult]
    var helpAffordances: [HelpAffordanceResult]
    var forbiddenText: [ForbiddenTextResult]
    var actions: [ActionResult]
    var surfaces: [AccessibilitySurfaceResult]
    var issues: [String]
    var rawUITextStored: Bool
}

struct RuntimeElement {
    var element: AXUIElement
    var role: String
    var searchableText: String
}

let appName = "MeetingVault"
let bundleIdentifier = "com.andrzej.MeetingVault"
let expectedLabels = [
    "MeetingVault",
    "Meetings",
    "Live Transport",
    "Ready",
    "Audio Input",
    "Check Again",
    "Start Recording"
]
let forbiddenTextMarkers = [
    "recording placeholder",
    "stripped-down prototype",
    "Encrypted library unavailable",
    "Runtime initialization failed"
]
let expectedHelpAffordances = [
    HelpAffordanceTarget(
        name: "Recording Readiness Check",
        controlMarkers: ["Check Status", "Check Again"],
        helpMarkers: ["recording readiness"]
    ),
    HelpAffordanceTarget(
        name: "Primary Recording Transport",
        controlMarkers: ["primary-start-recording", "primary-stop-recording", "Start Recording"],
        helpMarkers: [
            "Start recording with the selected source",
            "Stop recording and create the final transcript",
            "Start recording with the selected source and audio input",
            "Ready to record with the selected input",
            "Ready with"
        ]
    ),
    HelpAffordanceTarget(
        name: "Start Recording",
        controlMarkers: ["Start Recording"],
        helpMarkers: [
            "Start recording with the selected capture source",
            "Start recording with the selected source and audio input",
            "Ready to record with the selected input",
            "Ready with"
        ]
    ),
    HelpAffordanceTarget(
        name: "Detect Audio Inputs",
        controlMarkers: ["Detect Inputs", "Detect"],
        helpMarkers: [
            "Detect connected microphones",
            "Re-detect connected microphones"
        ]
    )
]

let rootURL = URL(fileURLWithPath: CommandLine.arguments[0])
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let date = ISO8601DateFormatter().string(from: Date()).prefix(10)
var outputURL = rootURL
    .appendingPathComponent("docs", isDirectory: true)
    .appendingPathComponent("evidence", isDirectory: true)
    .appendingPathComponent("accessibility-smoke-\(date).json")
let smokeLibraryRoot = FileManager.default.temporaryDirectory
    .appendingPathComponent("MeetingVaultAccessibilitySmoke-\(UUID().uuidString)", isDirectory: true)
var launchApp = true
var performSafeActions = true

var iterator = CommandLine.arguments.dropFirst().makeIterator()
while let argument = iterator.next() {
    switch argument {
    case "--output":
        guard let path = iterator.next() else {
            fputs("--output requires a path\n", stderr)
            exit(2)
        }
        outputURL = URL(fileURLWithPath: path)
    case "--skip-launch":
        launchApp = false
    case "--no-actions":
        performSafeActions = false
    case "--help", "-h":
        print("""
        usage: script/accessibility_smoke.swift [--output PATH] [--skip-launch] [--no-actions]

        Launches MeetingVault through script/build_and_run.sh --verify by default, inspects
        the macOS accessibility tree, validates expected app labels without storing raw UI
        text, presses only the safe recording readiness check unless --no-actions is passed, and
        writes a privacy-safe JSON report.
        """)
        exit(0)
    default:
        fputs("unknown argument: \(argument)\n", stderr)
        exit(2)
    }
}

func run(_ executable: String, _ arguments: [String], workingDirectory: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.currentDirectoryURL = workingDirectory
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw NSError(
            domain: "AccessibilitySmoke",
            code: Int(process.terminationStatus),
            userInfo: [NSLocalizedDescriptionKey: "\(executable) \(arguments.joined(separator: " ")) failed"]
        )
    }
}

func writeReport(_ report: AccessibilitySmokeReport) {
    do {
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: outputURL, options: .atomic)
    } catch {
        fputs("failed to write report: \(error)\n", stderr)
    }
}

func blankReport(status: String, pid: Int?, axTrusted: Bool, launched: Bool, issues: [String]) -> AccessibilitySmokeReport {
    AccessibilitySmokeReport(
        timestamp: ISO8601DateFormatter().string(from: Date()),
        status: status,
        appName: appName,
        bundleIdentifier: bundleIdentifier,
        pid: pid,
        axTrusted: axTrusted,
        launchedByScript: launched,
        windowCount: 0,
        visibleWindowCount: 0,
        elementCount: 0,
        roleCounts: [:],
        requiredLabels: expectedLabels.map { RequiredLabelResult(label: $0, found: false) },
        helpAffordances: expectedHelpAffordances.map {
            HelpAffordanceResult(name: $0.name, foundControl: false, foundHelp: false)
        },
        forbiddenText: forbiddenTextMarkers.map { ForbiddenTextResult(marker: $0, found: false) },
        actions: [],
        surfaces: [],
        issues: issues,
        rawUITextStored: false
    )
}

var launchedByScript = false
if launchApp {
    for existingApp in NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier) {
        existingApp.terminate()
    }
    let terminationDeadline = Date().addingTimeInterval(5)
    while !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty,
          Date() < terminationDeadline {
        Thread.sleep(forTimeInterval: 0.1)
    }
    do {
        try run(
            "/bin/bash",
            [
                "script/build_and_run.sh",
                "--verify",
                "--workspace",
                "recorder",
                "--ui-smoke-library-root",
                smokeLibraryRoot.path,
                "--ui-smoke-retention-days",
                "1",
                "--ui-smoke-storage-bytes",
                "100000000000",
                "--ui-smoke-permissions",
                "authorized",
                "--key-provider",
                "local-file"
            ],
            workingDirectory: rootURL
        )
        launchedByScript = true
        Thread.sleep(forTimeInterval: 1.0)
    } catch {
        let report = blankReport(
            status: "fail",
            pid: nil,
            axTrusted: AXIsProcessTrusted(),
            launched: false,
            issues: ["launch failed: \(error.localizedDescription)"]
        )
        writeReport(report)
        fputs("[FAIL] accessibility smoke launch failed: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
    Thread.sleep(forTimeInterval: 3.0)
}

let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
var runningApp = apps.first ?? NSWorkspace.shared.runningApplications.first { app in
    app.localizedName == appName
}

guard let initialRunningApp = runningApp else {
    let report = blankReport(
        status: "blocked",
        pid: nil,
        axTrusted: AXIsProcessTrusted(),
        launched: launchedByScript,
        issues: ["MeetingVault process not running"]
    )
    writeReport(report)
    fputs("[BLOCKED] MeetingVault process not running\n", stderr)
    exit(3)
}

var currentRunningApp = initialRunningApp
let launchDeadline = Date().addingTimeInterval(20)
while !currentRunningApp.isFinishedLaunching && Date() < launchDeadline {
    Thread.sleep(forTimeInterval: 0.25)
    if let refreshed = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first
        ?? NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == appName }) {
        currentRunningApp = refreshed
    }
}

let pid = currentRunningApp.processIdentifier
let axTrusted = AXIsProcessTrusted()
guard axTrusted else {
    let report = blankReport(
        status: "blocked",
        pid: Int(pid),
        axTrusted: false,
        launched: launchedByScript,
        issues: ["Accessibility is not trusted for this terminal. Enable System Settings > Privacy & Security > Accessibility for the calling terminal/app, then rerun."]
    )
    writeReport(report)
    fputs("[BLOCKED] Accessibility permission is not trusted\n", stderr)
    exit(3)
}

currentRunningApp.activate(options: [.activateAllWindows])
Thread.sleep(forTimeInterval: 0.8)

func attribute(_ element: AXUIElement, _ name: String) -> Any? {
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
    guard error == .success else { return nil }
    return value
}

func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
    attribute(element, name) as? String
}

func elementsAttribute(_ element: AXUIElement, _ name: String) -> [AXUIElement] {
    attribute(element, name) as? [AXUIElement] ?? []
}

func searchableText(for element: AXUIElement) -> String {
    let names = [
        kAXRoleAttribute as String,
        kAXSubroleAttribute as String,
        kAXTitleAttribute as String,
        kAXDescriptionAttribute as String,
        kAXValueAttribute as String,
        kAXHelpAttribute as String,
        kAXIdentifierAttribute as String
    ]
    return names.compactMap { name in
        guard let value = attribute(element, name) else { return nil }
        if let string = value as? String {
            return string
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return nil
    }
    .joined(separator: " ")
}

let appElement = AXUIElementCreateApplication(pid)
func loadWindowRoots(from appElement: AXUIElement) -> [AXUIElement] {
    elementsAttribute(appElement, kAXWindowsAttribute as String)
}

func loadRoots(from appElement: AXUIElement) -> [AXUIElement] {
    var roots = loadWindowRoots(from: appElement)
    if let menuBar = attribute(appElement, kAXMenuBarAttribute as String) {
        roots.append(menuBar as! AXUIElement)
    }
    return roots
}

let rootsDeadline = Date().addingTimeInterval(20)
var windowRoots = loadWindowRoots(from: appElement)
while windowRoots.isEmpty && Date() < rootsDeadline {
    Thread.sleep(forTimeInterval: 0.25)
    windowRoots = loadWindowRoots(from: appElement)
}
if windowRoots.isEmpty {
    let appBundleURL = rootURL
        .appendingPathComponent("dist", isDirectory: true)
        .appendingPathComponent("MeetingVault.app", isDirectory: true)
    if FileManager.default.fileExists(atPath: appBundleURL.path) {
        try? run("/usr/bin/open", [appBundleURL.path], workingDirectory: rootURL)
        currentRunningApp.activate(options: [.activateAllWindows])
        let reopenDeadline = Date().addingTimeInterval(12)
        while windowRoots.isEmpty && Date() < reopenDeadline {
            Thread.sleep(forTimeInterval: 0.25)
            windowRoots = loadWindowRoots(from: appElement)
        }
    }
}
var roots = loadRoots(from: appElement)

var runtimeElements: [RuntimeElement] = []
var currentRuntimeElements: [RuntimeElement] = []
var roleCounts: [String: Int] = [:]
var foundLabels = Dictionary(uniqueKeysWithValues: expectedLabels.map { ($0, false) })
var issues: [String] = []
let maxElements = 10_000

func visit(_ element: AXUIElement, depth: Int) {
    guard runtimeElements.count < maxElements, depth <= 16 else { return }
    let role = stringAttribute(element, kAXRoleAttribute as String) ?? "unknown"
    let text = searchableText(for: element)
    roleCounts[role, default: 0] += 1
    let runtimeElement = RuntimeElement(element: element, role: role, searchableText: text)
    runtimeElements.append(runtimeElement)
    currentRuntimeElements.append(runtimeElement)

    let lowerText = text.lowercased()
    for label in expectedLabels where !foundLabels[label, default: false] {
        if lowerText.contains(label.lowercased()) {
            foundLabels[label] = true
        }
    }

    var children = elementsAttribute(element, kAXChildrenAttribute as String)
    let visibleChildren = elementsAttribute(element, kAXVisibleChildrenAttribute as String)
    if !visibleChildren.isEmpty {
        children.append(contentsOf: visibleChildren)
    }
    for child in children {
        visit(child, depth: depth + 1)
    }
}

func scanCurrentTree() {
    currentRuntimeElements = []
    roots = loadRoots(from: appElement)
    for root in roots {
        visit(root, depth: 0)
    }
}

func performAXAction(_ element: AXUIElement, _ action: String, timeout: TimeInterval = 6) -> AXError? {
    final class ActionBox {
        private let lock = NSLock()
        private var storedResult: AXError?

        func store(_ result: AXError) {
            lock.lock()
            storedResult = result
            lock.unlock()
        }

        func result() -> AXError? {
            lock.lock()
            defer { lock.unlock() }
            return storedResult
        }
    }

    let box = ActionBox()
    let finished = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInitiated).async {
        box.store(AXUIElementPerformAction(element, action as CFString))
        finished.signal()
    }
    guard finished.wait(timeout: .now() + timeout) == .success else {
        return nil
    }
    return box.result()
}

func boundedRuntimeElements(in root: AXUIElement, limit: Int = 4_000) -> [RuntimeElement] {
    var queue = [root]
    var seen: Set<CFHashCode> = []
    var result: [RuntimeElement] = []
    while !queue.isEmpty && result.count < limit {
        let element = queue.removeFirst()
        guard seen.insert(CFHash(element)).inserted else { continue }
        result.append(RuntimeElement(
            element: element,
            role: stringAttribute(element, kAXRoleAttribute as String) ?? "unknown",
            searchableText: searchableText(for: element)
        ))
        queue.append(contentsOf: elementsAttribute(element, kAXChildrenAttribute as String))
        queue.append(contentsOf: elementsAttribute(element, kAXVisibleChildrenAttribute as String))
    }
    return result
}

@discardableResult
func setVerticalScrollbars(in root: AXUIElement, to value: Double) -> Bool {
    let scrollbars = boundedRuntimeElements(in: root).filter {
        $0.role == kAXScrollBarRole as String
            && stringAttribute($0.element, kAXOrientationAttribute as String)
                == kAXVerticalOrientationValue as String
    }
    var changed = false
    for scrollbar in scrollbars {
        changed = AXUIElementSetAttributeValue(
            scrollbar.element,
            kAXValueAttribute as CFString,
            NSNumber(value: min(max(value, 0), 1))
        ) == .success || changed
    }
    return changed
}

func actionNames(_ element: AXUIElement) -> Set<String> {
    var names: CFArray?
    guard AXUIElementCopyActionNames(element, &names) == .success,
          let names = names as? [String] else {
        return []
    }
    return Set(names)
}

func semanticSurfaceResult(
    name: String,
    root: AXUIElement,
    markers: [String],
    freshProcess: Bool,
    keyboardMarkers: [String]
) -> AccessibilitySurfaceResult {
    let allCandidates = boundedRuntimeElements(in: root)
    let candidates = allCandidates.filter { candidate in
        markers.contains { candidate.searchableText.localizedCaseInsensitiveContains($0) }
    }
    let markerTargets = markers.compactMap { marker in
        candidates.first { $0.searchableText.localizedCaseInsensitiveContains(marker) }
    }
    let distinctTargets = Dictionary(grouping: candidates, by: { CFHash($0.element) }).compactMap(\.value.first)
    let rolePassed = markerTargets.count == markers.count
        && markerTargets.allSatisfy { $0.role != "unknown" && !$0.role.isEmpty }
    let enabledPassed = markerTargets.count == markers.count && markerTargets.allSatisfy {
        (attribute($0.element, kAXEnabledAttribute as String) as? Bool) != false
    }
    let keyboardControlRoles: Set<String> = [
        kAXButtonRole as String,
        kAXRadioButtonRole as String,
        kAXCheckBoxRole as String,
        kAXMenuButtonRole as String,
        kAXTextFieldRole as String,
        kAXTextAreaRole as String,
        kAXPopUpButtonRole as String
    ]
    let focusCandidate = allCandidates.first { candidate in
        keyboardControlRoles.contains(candidate.role)
            && keyboardMarkers.contains {
                candidate.searchableText.localizedCaseInsensitiveContains($0)
            }
    }
    let focusPassed: Bool
    let keyboardActionReachable: Bool
    if let focusCandidate {
        let set = AXUIElementSetAttributeValue(
            focusCandidate.element,
            kAXFocusedAttribute as CFString,
            kCFBooleanTrue
        ) == .success
        let nativeFocusReached = set
            && (attribute(focusCandidate.element, kAXFocusedAttribute as String) as? Bool == true)
        let actions = actionNames(focusCandidate.element)
        keyboardActionReachable = actions.contains(kAXPressAction as String)
            || actions.contains(kAXShowMenuAction as String)
        // Native macOS buttons and pop-ups often reject AXFocused while still
        // exposing their keyboard-equivalent action through Accessibility.
        focusPassed = nativeFocusReached || keyboardActionReachable
    } else {
        focusPassed = false
        keyboardActionReachable = false
    }
    let keyboardReachable = focusPassed && focusCandidate.map {
        keyboardControlRoles.contains($0.role)
    } == true
    return AccessibilitySurfaceResult(
        surface: name,
        freshProcess: freshProcess,
        targetCount: distinctTargets.count,
        rolePassed: rolePassed,
        enabledPassed: enabledPassed,
        focusPassed: focusPassed,
        keyboardReachable: keyboardReachable
    )
}

func terminateMeetingVault() {
    for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier) {
        app.terminate()
    }
    let deadline = Date().addingTimeInterval(6)
    while !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty,
          Date() < deadline {
        Thread.sleep(forTimeInterval: 0.1)
    }
}

func launchFreshAccessibilityRoute(_ routeArguments: [String]) -> NSRunningApplication? {
    do {
        try run(
            "/bin/bash",
            [
                "script/build_and_run.sh", "--verify"
            ] + routeArguments + [
                "--ui-smoke-library-root", smokeLibraryRoot.path,
                "--ui-smoke-retention-days", "1",
                "--ui-smoke-storage-bytes", "100000000000",
                "--ui-smoke-permissions", "authorized",
                "--key-provider", "local-file"
            ],
            workingDirectory: rootURL
        )
    } catch {
        return nil
    }
    let deadline = Date().addingTimeInterval(15)
    while Date() < deadline {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first,
           app.isFinishedLaunching {
            app.activate(options: [.activateAllWindows])
            Thread.sleep(forTimeInterval: 1)
            return app
        }
        Thread.sleep(forTimeInterval: 0.2)
    }
    return nil
}

func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags) {
    let source = CGEventSource(stateID: .hidSystemState)
    let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
    let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
    down?.flags = flags
    up?.flags = flags
    down?.post(tap: .cghidEventTap)
    up?.post(tap: .cghidEventTap)
}

func pressFirstAvailable(containingAny markers: [String]) -> Bool {
    let preferredRoles = [
        kAXButtonRole as String,
        kAXRadioButtonRole as String,
        kAXCheckBoxRole as String,
        kAXMenuItemRole as String,
        kAXPopUpButtonRole as String
    ]
    for role in preferredRoles {
        for marker in markers {
            if let element = currentRuntimeElements.reversed().first(where: {
                $0.role == role && $0.searchableText.localizedCaseInsensitiveContains(marker)
            }) {
                guard let error = performAXAction(element.element, kAXPressAction as String) else {
                    continue
                }
                Thread.sleep(forTimeInterval: 0.7)
                return error == .success
            }
        }
    }
    for marker in markers {
        if let element = currentRuntimeElements.reversed().first(where: {
            $0.searchableText.localizedCaseInsensitiveContains(marker)
        }), let error = performAXAction(element.element, kAXPressAction as String), error == .success {
            Thread.sleep(forTimeInterval: 0.7)
            return true
        }
    }
    return false
}

func pressAndScan(containingAny markers: [String]) {
    _ = pressFirstAvailable(containingAny: markers)
    Thread.sleep(forTimeInterval: 0.5)
    scanCurrentTree()
}

scanCurrentTree()
pressAndScan(containingAny: ["Check Status", "Check Again"])

let visibleWindowCount = (CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? [])
    .filter { ($0[kCGWindowOwnerName as String] as? String) == appName }
    .count

if roots.isEmpty {
    issues.append("No AX windows or menu bar roots were exposed")
}
if runtimeElements.count >= maxElements {
    issues.append("AX tree traversal reached the \(maxElements) element cap")
}

var actionResults: [ActionResult] = []
if performSafeActions {
    if let readinessCheckButton = runtimeElements.first(where: {
        $0.role == (kAXButtonRole as String)
            && (
                $0.searchableText.lowercased().contains("check status")
                || $0.searchableText.lowercased().contains("check again")
            )
    }) {
        let error = performAXAction(readinessCheckButton.element, kAXPressAction as String) ?? .cannotComplete
        actionResults.append(
            ActionResult(
                name: "Recording Readiness Check",
                status: error == .success ? "pressed" : "failed",
                axError: error == .success ? nil : "\(error)"
            )
        )
        if error != .success {
            issues.append("Recording readiness check button was visible but AXPress failed")
        }
    } else {
        actionResults.append(ActionResult(name: "Recording Readiness Check", status: "not found", axError: nil))
        issues.append("Recording readiness check button was not exposed as an AX button")
    }
}

var surfaceResults: [AccessibilitySurfaceResult] = []
let initialSurfaceElements = boundedRuntimeElements(in: appElement)
let startControl = initialSurfaceElements.first {
    $0.role == kAXButtonRole as String
        && ($0.searchableText.contains("primary-live-recording-transport")
            || $0.searchableText.localizedCaseInsensitiveContains("Start Recording"))
}
let recordingStarted = startControl.flatMap {
    performAXAction($0.element, kAXPressAction as String)
} == .success
let activeRecorderDeadline = Date().addingTimeInterval(10)
while Date() < activeRecorderDeadline {
    let text = boundedRuntimeElements(in: appElement).map(\.searchableText).joined(separator: " ")
    if text.contains("mark-moment-button") && text.contains("primary-live-recording-transport") { break }
    Thread.sleep(forTimeInterval: 0.2)
}
_ = setVerticalScrollbars(in: appElement, to: 0)
Thread.sleep(forTimeInterval: 0.6)
surfaceResults.append(semanticSurfaceResult(
    name: "Active recording controls",
    root: appElement,
    markers: ["Stop Recording", "Mark recording moment", "recording-level-microphone"],
    freshProcess: launchedByScript,
    keyboardMarkers: ["Mark recording moment"]
))

let miniDeadline = Date().addingTimeInterval(8)
while Date() < miniDeadline {
    if boundedRuntimeElements(in: appElement).contains(where: { $0.searchableText.contains("mini-recorder") }) { break }
    Thread.sleep(forTimeInterval: 0.2)
}
surfaceResults.append(semanticSurfaceResult(
    name: "Mini Recorder",
    root: appElement,
    markers: ["mini-recorder", "mini-recorder-transport", "mini-recorder-mark-moment"],
    freshProcess: launchedByScript,
    keyboardMarkers: ["mini-recorder-mark-moment"]
))
if recordingStarted {
    postKey(15, flags: [.maskCommand, .maskShift])
    Thread.sleep(forTimeInterval: 5)
}

let initialSurfacePID = currentRunningApp.processIdentifier
terminateMeetingVault()
if let reviewApp = launchFreshAccessibilityRoute([
    "--workspace", "intelligence", "--intelligence-tab", "review"
]) {
    let reviewRoot = AXUIElementCreateApplication(reviewApp.processIdentifier)
    Thread.sleep(forTimeInterval: 2)
    _ = setVerticalScrollbars(in: reviewRoot, to: 1)
    Thread.sleep(forTimeInterval: 0.6)
    surfaceResults.append(semanticSurfaceResult(
        name: "Confidence Review correction controls",
        root: reviewRoot,
        markers: [
            "confidence-review-corrected-speaker",
            "confidence-review-corrected-transcript",
            "Save Correction"
        ],
        freshProcess: reviewApp.processIdentifier != initialSurfacePID,
        keyboardMarkers: ["confidence-review-corrected-transcript"]
    ))
    terminateMeetingVault()
} else {
    surfaceResults.append(AccessibilitySurfaceResult(
        surface: "Confidence Review correction controls",
        freshProcess: false,
        targetCount: 0,
        rolePassed: false,
        enabledPassed: false,
        focusPassed: false,
        keyboardReachable: false
    ))
}

if let modelsApp = launchFreshAccessibilityRoute(["--workspace", "recorder"]) {
    postKey(43, flags: [.maskCommand])
    Thread.sleep(forTimeInterval: 2)
    let modelsRoot = AXUIElementCreateApplication(modelsApp.processIdentifier)
    _ = setVerticalScrollbars(in: modelsRoot, to: 1)
    Thread.sleep(forTimeInterval: 0.6)
    surfaceResults.append(semanticSurfaceResult(
        name: "Local Models & Privacy",
        root: modelsRoot,
        markers: ["Local Models & Privacy", "Transcription privacy mode", "Local model status"],
        freshProcess: modelsApp.processIdentifier != initialSurfacePID,
        keyboardMarkers: ["Local only"]
    ))
    terminateMeetingVault()
} else {
    surfaceResults.append(AccessibilitySurfaceResult(
        surface: "Local Models & Privacy",
        freshProcess: false,
        targetCount: 0,
        rolePassed: false,
        enabledPassed: false,
        focusPassed: false,
        keyboardReachable: false
    ))
}

let failedSurfaces = surfaceResults.filter {
    !$0.freshProcess || !$0.rolePassed || !$0.enabledPassed || !$0.focusPassed || !$0.keyboardReachable
}
if !failedSurfaces.isEmpty {
    issues.append("Accessibility semantic route failures: \(failedSurfaces.map(\.surface).joined(separator: ", "))")
}

let requiredResults = expectedLabels.map { label in
    RequiredLabelResult(label: label, found: foundLabels[label, default: false])
}
let missingRequired = requiredResults.filter { !$0.found }.map(\.label)
if !missingRequired.isEmpty {
    issues.append("Missing required AX labels: \(missingRequired.joined(separator: ", "))")
}

let forbiddenTextResults = forbiddenTextMarkers.map { marker in
    let found = runtimeElements.contains {
        $0.searchableText.localizedCaseInsensitiveContains(marker)
    }
    return ForbiddenTextResult(marker: marker, found: found)
}
let foundForbiddenText = forbiddenTextResults.filter(\.found).map(\.marker)
if !foundForbiddenText.isEmpty {
    issues.append("Forbidden prototype copy exposed in AX tree: \(foundForbiddenText.joined(separator: ", "))")
}

let helpAffordanceResults = expectedHelpAffordances.map { target in
    let matchingControls = runtimeElements.filter { element in
        let text = element.searchableText.lowercased()
        return target.controlMarkers.contains { marker in
            text.contains(marker.lowercased())
        }
    }
    let foundHelp = matchingControls.contains { element in
        let help = [
            stringAttribute(element.element, kAXHelpAttribute as String),
            stringAttribute(element.element, kAXDescriptionAttribute as String),
            element.searchableText
        ]
        .compactMap { $0?.lowercased() }
        .joined(separator: " ")
        return target.helpMarkers.contains { marker in
            help.contains(marker.lowercased())
        }
    }
    return HelpAffordanceResult(
        name: target.name,
        foundControl: !matchingControls.isEmpty,
        foundHelp: foundHelp
    )
}
let missingHelp = helpAffordanceResults.filter { !$0.foundControl || !$0.foundHelp }
if !missingHelp.isEmpty {
    let names = missingHelp.map { result in
        if !result.foundControl {
            return "\(result.name) control"
        }
        return "\(result.name) help"
    }
    issues.append("Missing required AX help affordances: \(names.joined(separator: ", "))")
}

let hasWindow = !roots.isEmpty
let hasButtons = (roleCounts[kAXButtonRole as String] ?? 0) >= 2
if !hasButtons {
    issues.append("Fewer than 2 AX buttons were exposed")
}

let status = issues.isEmpty && hasWindow && hasButtons ? "pass" : "fail"
let report = AccessibilitySmokeReport(
    timestamp: ISO8601DateFormatter().string(from: Date()),
    status: status,
    appName: appName,
    bundleIdentifier: bundleIdentifier,
    pid: Int(pid),
    axTrusted: axTrusted,
    launchedByScript: launchedByScript,
    windowCount: roots.count,
    visibleWindowCount: visibleWindowCount,
    elementCount: runtimeElements.count,
    roleCounts: roleCounts,
    requiredLabels: requiredResults,
    helpAffordances: helpAffordanceResults,
    forbiddenText: forbiddenTextResults,
    actions: actionResults,
    surfaces: surfaceResults,
    issues: issues,
    rawUITextStored: false
)
writeReport(report)

if status == "pass" {
    print("[OK] accessibility smoke passed: elements=\(runtimeElements.count) windows=\(roots.count) evidence=\(outputURL.path)")
    exit(0)
}

fputs("[FAIL] accessibility smoke failed: \(issues.joined(separator: "; ")) evidence=\(outputURL.path)\n", stderr)
exit(1)
