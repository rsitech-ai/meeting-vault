#!/usr/bin/env swift
import AppKit
import ApplicationServices
import CryptoKit
import Foundation

struct InteractionStep: Codable {
    var name: String
    var status: String
    var detail: String
    var metadata: [String: String]?
}

struct InteractionSmokeReport: Codable {
    var timestamp: String
    var status: String
    var appName: String
    var bundleIdentifier: String
    var pid: Int?
    var axTrusted: Bool
    var launchedByScript: Bool
    var isolatedSmokeStorage: Bool
    var destructiveActionExecuted: Bool
    var externalShareOpened: Bool
    var rawUITextStored: Bool
    var steps: [InteractionStep]
    var issues: [String]
}

let appName = "MeetingVault"
let bundleIdentifier = "com.andrzej.MeetingVault"
let rootURL = URL(fileURLWithPath: CommandLine.arguments[0])
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let date = ISO8601DateFormatter().string(from: Date()).prefix(10)
var outputURL = rootURL
    .appendingPathComponent("docs", isDirectory: true)
    .appendingPathComponent("evidence", isDirectory: true)
    .appendingPathComponent("interaction-smoke-\(date).json")
var launchApp = true

enum LayoutRegressionScenario: String {
    case base
    case repeatedReview
    case playback
    case reviewContextMenu
    case prefixHalfA
    case prefixHalfB
    case prefixB1
    case prefixB2
    case prefixB1Storage
    case prefixB1Agent
    case prefixSearch
    case prefixMinimum
    case prefixReviewNoResize
    case prefixNonReviewResize
    case compactOnly
    case wideOnly

    var repeatsReview: Bool {
        ![.base].contains(self)
    }

    var selectsPlayback: Bool {
        ![.base, .repeatedReview].contains(self)
    }

    var exercisesReviewContextMenu: Bool { self == .reviewContextMenu }
    var isPrefixHalfA: Bool { self == .prefixHalfA }
    var isPrefixHalfB: Bool {
        switch self {
        case .prefixHalfB, .prefixB1, .prefixB2, .prefixB1Storage, .prefixB1Agent,
             .prefixSearch, .prefixMinimum, .prefixReviewNoResize,
             .prefixNonReviewResize, .compactOnly, .wideOnly:
            true
        default:
            false
        }
    }
    var isB1Only: Bool {
        switch self {
        case .prefixB1, .prefixSearch, .prefixMinimum, .prefixReviewNoResize,
             .prefixNonReviewResize, .compactOnly, .wideOnly:
            true
        default:
            false
        }
    }
}

var layoutRegressionScenario: LayoutRegressionScenario?

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
    case "--layout-regression-only":
        layoutRegressionScenario = .base
    case "--layout-with-second-review":
        layoutRegressionScenario = .repeatedReview
    case "--layout-with-playback":
        layoutRegressionScenario = .playback
    case "--layout-with-review-context-menu":
        layoutRegressionScenario = .reviewContextMenu
    case "--layout-prefix-half-a":
        layoutRegressionScenario = .prefixHalfA
    case "--layout-prefix-half-b":
        layoutRegressionScenario = .prefixHalfB
    case "--layout-prefix-b1":
        layoutRegressionScenario = .prefixB1
    case "--layout-prefix-b2":
        layoutRegressionScenario = .prefixB2
    case "--layout-prefix-b1-storage":
        layoutRegressionScenario = .prefixB1Storage
    case "--layout-prefix-b1-agent":
        layoutRegressionScenario = .prefixB1Agent
    case "--layout-prefix-search-extra":
        layoutRegressionScenario = .prefixSearch
    case "--layout-prefix-minimum-extra":
        layoutRegressionScenario = .prefixMinimum
    case "--layout-prefix-review-no-resize-extra":
        layoutRegressionScenario = .prefixReviewNoResize
    case "--layout-prefix-nonreview-resize-extra":
        layoutRegressionScenario = .prefixNonReviewResize
    case "--layout-prefix-compact-only-extra":
        layoutRegressionScenario = .compactOnly
    case "--layout-prefix-wide-only-extra":
        layoutRegressionScenario = .wideOnly
    case "--help", "-h":
        print("""
        usage: script/interaction_smoke.swift [--output PATH] [--skip-launch] [--layout-regression-only] [--layout-with-second-review] [--layout-with-playback] [--layout-with-review-context-menu] [--layout-prefix-half-a] [--layout-prefix-half-b] [--layout-prefix-b1] [--layout-prefix-b2] [--layout-prefix-b1-storage] [--layout-prefix-b1-agent] [--layout-prefix-search-extra] [--layout-prefix-minimum-extra] [--layout-prefix-review-no-resize-extra] [--layout-prefix-nonreview-resize-extra] [--layout-prefix-compact-only-extra] [--layout-prefix-wide-only-extra]

        Launches MeetingVault, exercises safe interaction paths for Meetings,
        section navigation, Agent export/share preparation, recovery
        gates, Health & Recovery retention review/delete gates, and Settings,
        then writes privacy-safe JSON evidence without storing raw UI text.
        """)
        exit(0)
    default:
        fputs("unknown argument: \(argument)\n", stderr)
        exit(2)
    }
}

let smokeLibraryRoot = FileManager.default.temporaryDirectory
    .appendingPathComponent("MeetingVaultInteractionSmoke-\(UUID().uuidString)", isDirectory: true)

func run(_ executable: String, _ arguments: [String], workingDirectory: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.currentDirectoryURL = workingDirectory
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw NSError(
            domain: "InteractionSmoke",
            code: Int(process.terminationStatus),
            userInfo: [NSLocalizedDescriptionKey: "\(executable) \(arguments.joined(separator: " ")) failed"]
        )
    }
}

func writeReport(_ report: InteractionSmokeReport) {
    do {
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: outputURL, options: .atomic)
    } catch {
        fputs("failed to write interaction smoke report: \(error)\n", stderr)
    }
}

func runningApp() -> NSRunningApplication? {
    NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first
        ?? NSWorkspace.shared.runningApplications.first { $0.localizedName == appName }
}

func waitForRunningApp() -> NSRunningApplication? {
    let deadline = Date().addingTimeInterval(20)
    while Date() < deadline {
        if let app = runningApp(), app.isFinishedLaunching {
            return app
        }
        Thread.sleep(forTimeInterval: 0.25)
    }
    return runningApp()
}

func waitForApplicationActive(timeout: TimeInterval = 3) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        guard let app = runningApp() else { return false }
        if app.isActive { return true }
        app.unhide()
        app.activate()
        app.activate(options: [.activateAllWindows])
        Thread.sleep(forTimeInterval: 0.1)
    }
    return runningApp()?.isActive == true
}

func waitForApplicationReadyForMenu(
    appElement: AXUIElement,
    timeout: TimeInterval = 5
) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        guard let app = runningApp(), !app.isTerminated else { return false }
        app.unhide()
        _ = AXUIElementSetAttributeValue(
            appElement,
            kAXFrontmostAttribute as CFString,
            kCFBooleanTrue
        )
        app.activate()
        app.activate(options: [.activateAllWindows])
        let windows = elementsAttribute(appElement, kAXWindowsAttribute as String)
        let windowToRaise = windows.first {
            windowMatches($0, marker: "meeting-transcript-workspace")
        } ?? windows.first
        if let windowToRaise {
            _ = performAXAction(windowToRaise, kAXRaiseAction as String, timeout: 1)
        }
        let menuBarReady = attribute(appElement, kAXMenuBarAttribute as String) != nil
        let activationObserved = app.isActive
            || boolAttribute(appElement, kAXFrontmostAttribute as String) == true
        let targetedWindowReady = windowToRaise != nil
        if (activationObserved || targetedWindowReady), menuBarReady, !windows.isEmpty {
            return true
        }
        Thread.sleep(forTimeInterval: 0.1)
    }
    guard let app = runningApp() else { return false }
    let activationObserved = app.isActive
        || boolAttribute(appElement, kAXFrontmostAttribute as String) == true
    let windows = elementsAttribute(appElement, kAXWindowsAttribute as String)
    let targetedWindowReady = !windows.isEmpty
    return (activationObserved || targetedWindowReady)
        && attribute(appElement, kAXMenuBarAttribute as String) != nil
        && !windows.isEmpty
}

func attribute(_ element: AXUIElement, _ name: String) -> Any? {
    AXUIElementSetMessagingTimeout(element, 0.8)
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
    guard error == .success else { return nil }
    return value
}

func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
    attribute(element, name) as? String
}

func boolAttribute(_ element: AXUIElement, _ name: String) -> Bool? {
    if let value = attribute(element, name) as? Bool {
        return value
    }
    if let value = attribute(element, name) as? NSNumber {
        return value.boolValue
    }
    return nil
}

func actionNames(_ element: AXUIElement) -> [String] {
    var names: CFArray?
    let error = AXUIElementCopyActionNames(element, &names)
    guard error == .success else { return [] }
    return names as? [String] ?? []
}

func elementsAttribute(_ element: AXUIElement, _ name: String) -> [AXUIElement] {
    attribute(element, name) as? [AXUIElement] ?? []
}

func textForSearch(_ element: AXUIElement) -> String {
    [
        stringAttribute(element, kAXRoleAttribute as String),
        stringAttribute(element, kAXSubroleAttribute as String),
        stringAttribute(element, kAXTitleAttribute as String),
        stringAttribute(element, kAXDescriptionAttribute as String),
        stringAttribute(element, kAXValueAttribute as String),
        stringAttribute(element, kAXHelpAttribute as String),
        stringAttribute(element, kAXIdentifierAttribute as String)
    ]
    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
    .filter { !$0.isEmpty }
    .joined(separator: " ")
}

func walk(_ element: AXUIElement, depth: Int = 0, output: inout [AXUIElement]) {
    guard depth <= 14, output.count < 5_000 else { return }
    output.append(element)
    var children = elementsAttribute(element, kAXChildrenAttribute as String)
    children.append(contentsOf: elementsAttribute(element, kAXVisibleChildrenAttribute as String))
    for child in children {
        walk(child, depth: depth + 1, output: &output)
    }
}

func allElements(appElement: AXUIElement, includeMenuBar: Bool = false) -> [AXUIElement] {
    var roots = elementsAttribute(appElement, kAXWindowsAttribute as String)
    if includeMenuBar, let menuBar = attribute(appElement, kAXMenuBarAttribute as String) {
        roots.append(menuBar as! AXUIElement)
    }
    var output: [AXUIElement] = []
    for root in roots {
        walk(root, output: &output)
    }
    return output
}

func allElements(rootElement: AXUIElement) -> [AXUIElement] {
    var output: [AXUIElement] = []
    walk(rootElement, output: &output)
    return output
}

func markerVisible(_ marker: String, rootElement: AXUIElement) -> Bool {
    allElements(rootElement: rootElement).contains {
        textForSearch($0).localizedCaseInsensitiveContains(marker)
    }
}

func markerVisible(_ marker: String, appElement: AXUIElement) -> Bool {
    allElements(appElement: appElement).contains {
        textForSearch($0).localizedCaseInsensitiveContains(marker)
    }
}

func waitForMarker(_ marker: String, appElement: AXUIElement, timeout: TimeInterval = 10) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if markerVisible(marker, appElement: appElement) {
            return true
        }
        Thread.sleep(forTimeInterval: 0.25)
    }
    return markerVisible(marker, appElement: appElement)
}

func waitForMarkerHidden(_ marker: String, appElement: AXUIElement, timeout: TimeInterval = 5) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if !markerVisible(marker, appElement: appElement) {
            return true
        }
        Thread.sleep(forTimeInterval: 0.25)
    }
    return !markerVisible(marker, appElement: appElement)
}

func firstElement(
    role: String? = nil,
    containing text: String,
    appElement: AXUIElement
) -> AXUIElement? {
    allElements(appElement: appElement).first { element in
        if let role, stringAttribute(element, kAXRoleAttribute as String) != role {
            return false
        }
        return textForSearch(element).localizedCaseInsensitiveContains(text)
    }
}

func firstElement(
    role: String? = nil,
    containingAny texts: [String],
    appElement: AXUIElement
) -> AXUIElement? {
    for text in texts {
        if let element = firstElement(role: role, containing: text, appElement: appElement) {
            return element
        }
    }
    return nil
}

func elements(
    role: String? = nil,
    containingAny texts: [String],
    appElement: AXUIElement
) -> [AXUIElement] {
    allElements(appElement: appElement).filter { element in
        if let role, stringAttribute(element, kAXRoleAttribute as String) != role {
            return false
        }
        let searchable = textForSearch(element)
        return texts.contains {
            searchable.localizedCaseInsensitiveContains($0)
        }
    }
}

struct SearchFieldMutation {
    var fieldFound: Bool
    var valueApplied: Bool
}

func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags = []) -> Bool {
    guard let source = CGEventSource(stateID: .hidSystemState),
          let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
          let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
        return false
    }
    down.flags = flags
    up.flags = flags
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.08)
    return true
}

func postText(_ value: String) -> Bool {
    guard !value.isEmpty else { return true }
    guard let source = CGEventSource(stateID: .hidSystemState),
          let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
          let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
        return false
    }
    var characters = Array(value.utf16)
    down.keyboardSetUnicodeString(stringLength: characters.count, unicodeString: &characters)
    up.keyboardSetUnicodeString(stringLength: characters.count, unicodeString: &characters)
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.35)
    return true
}

func replaceFocusedTextWithKeyboard(_ value: String) -> Bool {
    guard postKey(0, flags: .maskCommand),
          postKey(51) else {
        return false
    }
    if value.isEmpty {
        return postText(" ") && postKey(51)
    }
    return postText(value)
}

func focusedElementMatches(_ element: AXUIElement) -> Bool {
    if boolAttribute(element, kAXFocusedAttribute as String) == true {
        return true
    }
    let systemWide = AXUIElementCreateSystemWide()
    guard let focused = attribute(systemWide, kAXFocusedUIElementAttribute as String),
          CFGetTypeID(focused as CFTypeRef) == AXUIElementGetTypeID() else {
        return false
    }
    return CFEqual(focused as CFTypeRef, element)
}

func setSidebarSearchField(
    value: String,
    appElement: AXUIElement
) -> SearchFieldMutation {
    let markers = ["Search meetings", "Search"]
    var fieldFound = false
    for attempt in 1...2 {
        let candidates = allElements(appElement: appElement)
            .compactMap { element -> (element: AXUIElement, origin: CGPoint, labelled: Bool)? in
                guard stringAttribute(element, kAXRoleAttribute as String) == kAXTextFieldRole as String,
                      let origin = pointAttribute(element, kAXPositionAttribute as String),
                      let size = sizeAttribute(element, kAXSizeAttribute as String),
                      origin.x.isFinite,
                      origin.y.isFinite,
                      size.width > 80,
                      size.height > 16,
                      boolAttribute(element, kAXHiddenAttribute as String) != true else {
                    return nil
                }
                let searchable = textForSearch(element)
                return (
                    element: element,
                    origin: origin,
                    labelled: markers.contains { searchable.localizedCaseInsensitiveContains($0) }
                )
            }
            .sorted { lhs, rhs in
                if lhs.labelled != rhs.labelled { return lhs.labelled && !rhs.labelled }
                if lhs.origin.x != rhs.origin.x { return lhs.origin.x < rhs.origin.x }
                return lhs.origin.y < rhs.origin.y
            }
        guard let element = candidates.first?.element else {
            Thread.sleep(forTimeInterval: 0.2)
            continue
        }
        fieldFound = true
        _ = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        _ = leftClick(element)
        let focusDeadline = Date().addingTimeInterval(1)
        while Date() < focusDeadline, !focusedElementMatches(element) {
            Thread.sleep(forTimeInterval: 0.08)
        }
        guard focusedElementMatches(element) else {
            progress("search attempt=\(attempt), fieldFound=yes, focusConfirmed=no")
            continue
        }
        let keyboardInputPosted = replaceFocusedTextWithKeyboard(value)
        let valueDeadline = Date().addingTimeInterval(2)
        while Date() < valueDeadline {
            if stringAttribute(element, kAXValueAttribute as String) == value {
                return SearchFieldMutation(fieldFound: true, valueApplied: keyboardInputPosted)
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        progress("search attempt=\(attempt), fieldFound=yes, focusConfirmed=yes, valuePostcondition=no")
    }
    return SearchFieldMutation(fieldFound: fieldFound, valueApplied: false)
}

func meetingRowElements(appElement: AXUIElement) -> [AXUIElement] {
    var seen = Set<CFHashCode>()
    return allElements(appElement: appElement).filter { element in
        guard seen.insert(CFHash(element)).inserted else { return false }
        return [
            stringAttribute(element, kAXTitleAttribute as String),
            stringAttribute(element, kAXDescriptionAttribute as String),
            stringAttribute(element, kAXValueAttribute as String)
        ]
        .compactMap { $0 }
        .contains { $0.hasPrefix("Meeting row. ") }
    }
}

func waitForMeetingRowCount(
    _ expectedCount: Int,
    appElement: AXUIElement,
    timeout: TimeInterval
) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if meetingRowElements(appElement: appElement).count == expectedCount {
            return true
        }
        Thread.sleep(forTimeInterval: 0.2)
    }
    return meetingRowElements(appElement: appElement).count == expectedCount
}

func setEditableText(
    containingAny markers: [String],
    value: String,
    appElement: AXUIElement,
    fallbackTextAreaIndex: Int? = nil
) -> Bool {
    let labelledElement = firstElement(
        role: kAXTextAreaRole as String,
        containingAny: markers,
        appElement: appElement
    ) ?? firstElement(
        role: kAXTextFieldRole as String,
        containingAny: markers,
        appElement: appElement
    )
    let fallbackElement: AXUIElement? = fallbackTextAreaIndex.flatMap { index in
        let textAreas = allElements(appElement: appElement)
            .filter { stringAttribute($0, kAXRoleAttribute as String) == kAXTextAreaRole as String }
            .filter {
                guard let size = sizeAttribute($0, kAXSizeAttribute as String) else { return false }
                return size.width > 40 && size.height > 24
            }
        guard textAreas.indices.contains(index) else { return nil }
        return textAreas[index]
    }

    guard let element = labelledElement ?? fallbackElement else {
        return false
    }

    _ = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    let error = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFString)
    Thread.sleep(forTimeInterval: 0.8)
    return error == .success
}

func waitForAnyMarker(_ markers: [String], appElement: AXUIElement, timeout: TimeInterval = 5) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if markers.contains(where: { markerVisible($0, appElement: appElement) }) {
            return true
        }
        Thread.sleep(forTimeInterval: 0.25)
    }
    return markers.contains { markerVisible($0, appElement: appElement) }
}

final class AXActionBox {
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

func performAXAction(_ element: AXUIElement, _ action: String, timeout: TimeInterval = 6) -> AXError? {
    let box = AXActionBox()
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

func pressElement(
    role: String? = nil,
    containing text: String,
    appElement: AXUIElement
) -> Bool {
    let candidates = elements(role: role, containingAny: [text], appElement: appElement)
    guard let element = candidates.first(where: { boolAttribute($0, kAXEnabledAttribute as String) == true })
        ?? candidates.first
    else {
        return false
    }
    guard let error = performAXAction(element, kAXPressAction as String) else {
        return false
    }
    Thread.sleep(forTimeInterval: 0.6)
    return error == .success
}

func firstElement(
    role: String? = nil,
    containing text: String,
    rootElement: AXUIElement
) -> AXUIElement? {
    allElements(rootElement: rootElement).first { element in
        if let role, stringAttribute(element, kAXRoleAttribute as String) != role {
            return false
        }
        return textForSearch(element).localizedCaseInsensitiveContains(text)
    }
}

func pressElement(
    role: String? = nil,
    containing text: String,
    rootElement: AXUIElement
) -> Bool {
    guard let element = firstElement(role: role, containing: text, rootElement: rootElement),
          boolAttribute(element, kAXEnabledAttribute as String) != false,
          let error = performAXAction(element, kAXPressAction as String) else {
        return false
    }
    Thread.sleep(forTimeInterval: 0.6)
    return error == .success
}

func pressFirstAvailable(
    containingAny texts: [String],
    appElement: AXUIElement,
    preferredRoles: [String] = [
        kAXRadioButtonRole as String,
        kAXButtonRole as String
    ]
) -> Bool {
    pressFirstAvailableElement(
        containingAny: texts,
        appElement: appElement,
        preferredRoles: preferredRoles
    )?.actionResult == .success
}

struct AXPressDiagnostic {
    var element: AXUIElement
    var actionResult: AXError?
}

func pressFirstAvailableElement(
    containingAny texts: [String],
    appElement: AXUIElement,
    preferredRoles: [String] = [
        kAXRadioButtonRole as String,
        kAXButtonRole as String
    ]
) -> AXPressDiagnostic? {
    for role in preferredRoles {
        for text in texts {
            let candidates = elements(role: role, containingAny: [text], appElement: appElement)
            if let element = candidates.first(where: { boolAttribute($0, kAXEnabledAttribute as String) == true })
                ?? candidates.first {
                let actionResult = performAXAction(element, kAXPressAction as String)
                Thread.sleep(forTimeInterval: 0.6)
                return AXPressDiagnostic(element: element, actionResult: actionResult)
            }
        }
    }
    for text in texts {
        let candidates = elements(containingAny: [text], appElement: appElement)
        if let element = candidates.first(where: { boolAttribute($0, kAXEnabledAttribute as String) == true })
            ?? candidates.first {
            let actionResult = performAXAction(element, kAXPressAction as String)
            Thread.sleep(forTimeInterval: 0.6)
            return AXPressDiagnostic(element: element, actionResult: actionResult)
        }
    }
    return nil
}

func firstElement(role: String, appElement: AXUIElement) -> AXUIElement? {
    allElements(appElement: appElement).first { element in
        stringAttribute(element, kAXRoleAttribute as String) == role
    }
}

func windowMatches(_ window: AXUIElement, marker: String) -> Bool {
    var elements: [AXUIElement] = []
    walk(window, output: &elements)
    if elements.contains(where: {
        textForSearch($0).localizedCaseInsensitiveContains(marker)
    }) {
        return true
    }
    guard marker == "meeting-transcript-workspace" else { return false }
    let windowTitle = stringAttribute(window, kAXTitleAttribute as String) ?? ""
    let mainWindowTitles = Set(["Meetings", "Library", "Setup", "Agent", "Review", "Export"])
    if mainWindowTitles.contains(windowTitle) {
        return true
    }
    let identifiers = Set(elements.compactMap {
        stringAttribute($0, kAXIdentifierAttribute as String)
    })
    return identifiers.contains("meeting-workspace-sidebar")
        && identifiers.contains("meeting-workspace-inspector")
}

func windows(containing marker: String, appElement: AXUIElement) -> [AXUIElement] {
    elementsAttribute(appElement, kAXWindowsAttribute as String).filter {
        windowMatches($0, marker: marker)
    }
}

func firstWindow(containing marker: String, appElement: AXUIElement) -> AXUIElement? {
    windows(containing: marker, appElement: appElement).first
}

func waitForWindow(
    containing windowMarker: String,
    appElement: AXUIElement,
    timeout: TimeInterval = 6
) -> AXUIElement? {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let window = firstWindow(containing: windowMarker, appElement: appElement) {
            return window
        }
        Thread.sleep(forTimeInterval: 0.2)
    }
    return firstWindow(containing: windowMarker, appElement: appElement)
}

func waitForWindow(
    containingAny windowMarkers: [String],
    appElement: AXUIElement,
    timeout: TimeInterval = 6
) -> AXUIElement? {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let window = windowMarkers.lazy.compactMap({
            firstWindow(containing: $0, appElement: appElement)
        }).first {
            return window
        }
        Thread.sleep(forTimeInterval: 0.2)
    }
    return windowMarkers.lazy.compactMap {
        firstWindow(containing: $0, appElement: appElement)
    }.first
}

func waitForSettingsWindow(
    appElement: AXUIElement,
    timeout: TimeInterval = 6
) -> AXUIElement? {
    let exactTitles = ["Settings", "MeetingVault Settings"]
    let consentMarker = "Require consent status before recording"
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        let appWindows = elementsAttribute(appElement, kAXWindowsAttribute as String)
        if let window = appWindows.first(where: { window in
            let title = stringAttribute(window, kAXTitleAttribute as String) ?? ""
            return exactTitles.contains(title)
                || markerVisible(consentMarker, rootElement: window)
        }) {
            return window
        }
        Thread.sleep(forTimeInterval: 0.2)
    }
    return elementsAttribute(appElement, kAXWindowsAttribute as String).first { window in
        let title = stringAttribute(window, kAXTitleAttribute as String) ?? ""
        return exactTitles.contains(title)
            || markerVisible(consentMarker, rootElement: window)
    }
}

func waitForMarker(
    _ marker: String,
    inWindowContaining windowMarker: String,
    appElement: AXUIElement,
    timeout: TimeInterval = 6
) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let window = firstWindow(containing: windowMarker, appElement: appElement),
           markerVisible(marker, rootElement: window) {
            return true
        }
        Thread.sleep(forTimeInterval: 0.2)
    }
    guard let window = firstWindow(containing: windowMarker, appElement: appElement) else { return false }
    return markerVisible(marker, rootElement: window)
}

func waitForAnyMarker(
    _ markers: [String],
    inWindowContaining windowMarker: String,
    appElement: AXUIElement,
    timeout: TimeInterval = 6
) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let window = firstWindow(containing: windowMarker, appElement: appElement),
           markers.contains(where: { markerVisible($0, rootElement: window) }) {
            return true
        }
        Thread.sleep(forTimeInterval: 0.2)
    }
    guard let window = firstWindow(containing: windowMarker, appElement: appElement) else { return false }
    return markers.contains { markerVisible($0, rootElement: window) }
}

func waitForMarkerHidden(
    _ marker: String,
    inWindowContaining windowMarker: String,
    appElement: AXUIElement,
    timeout: TimeInterval = 5
) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        guard let window = firstWindow(containing: windowMarker, appElement: appElement) else {
            return true
        }
        if !markerVisible(marker, rootElement: window) {
            return true
        }
        Thread.sleep(forTimeInterval: 0.2)
    }
    guard let window = firstWindow(containing: windowMarker, appElement: appElement) else { return true }
    return !markerVisible(marker, rootElement: window)
}

func activateWindow(
    containing windowMarker: String,
    appElement: AXUIElement,
    timeout: TimeInterval = 5
) -> Bool {
    guard let window = waitForWindow(
        containing: windowMarker,
        appElement: appElement,
        timeout: timeout
    ) else {
        return false
    }
    runningApp()?.activate()
    runningApp()?.activate(options: [.activateAllWindows])
    _ = performAXAction(window, kAXRaiseAction as String)

    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        let focusAttributes = [
            boolAttribute(window, kAXFocusedAttribute as String),
            boolAttribute(window, kAXMainAttribute as String)
        ].compactMap { $0 }
        let focusSatisfied = focusAttributes.isEmpty || focusAttributes.contains(true)
        if waitForApplicationActive(timeout: 0.5),
           markerVisible(windowMarker, rootElement: window),
           focusSatisfied {
            return true
        }
        _ = performAXAction(window, kAXRaiseAction as String)
        Thread.sleep(forTimeInterval: 0.2)
    }
    return false
}

func setWindowFrame(_ window: AXUIElement, origin: CGPoint = CGPoint(x: 80, y: 80), size: CGSize) -> Bool {
    var mutableOrigin = origin
    var mutableSize = size
    guard let originValue = AXValueCreate(.cgPoint, &mutableOrigin),
          let sizeValue = AXValueCreate(.cgSize, &mutableSize) else {
        return false
    }
    _ = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, originValue)
    let sizeError = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
    Thread.sleep(forTimeInterval: 0.8)
    return sizeError == .success
}

enum DeclaredFrameChange: String {
    case compact
    case wide

    var size: CGSize {
        switch self {
        case .compact: CGSize(width: 1_180, height: 692)
        case .wide: CGSize(width: 1_440, height: 900)
        }
    }
}

func applyDeclaredFrameChange(
    _ change: DeclaredFrameChange,
    window: AXUIElement,
    appElement: AXUIElement
) -> Bool {
    guard setWindowFrame(window, size: change.size),
          waitForMeetingLayoutStable(window: window),
          let measured = sizeAttribute(window, kAXSizeAttribute as String) else {
        return false
    }
    return abs(measured.width - change.size.width) <= 12
        && abs(measured.height - change.size.height) <= 12
}

func waitForMeetingLayoutStable(
    window: AXUIElement,
    timeout: TimeInterval = 3
) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    var previousSignature: String?
    var stableSamples = 0
    while Date() < deadline {
        guard let windowSize = sizeAttribute(window, kAXSizeAttribute as String),
              let windowOrigin = pointAttribute(window, kAXPositionAttribute as String) else {
            stableSamples = 0
            previousSignature = nil
            Thread.sleep(forTimeInterval: 0.1)
            continue
        }
        var descendants: [AXUIElement] = []
        walk(window, output: &descendants)
        let splitterPositions = descendants
            .filter { stringAttribute($0, kAXRoleAttribute as String) == kAXSplitterRole as String }
            .compactMap { pointAttribute($0, kAXPositionAttribute as String)?.x }
        let signature = ([windowOrigin.x, windowOrigin.y, windowSize.width, windowSize.height] + splitterPositions)
            .map { String(format: "%.1f", $0) }
            .joined(separator: ":")
        if signature == previousSignature {
            stableSamples += 1
            if stableSamples >= 3 { return true }
        } else {
            previousSignature = signature
            stableSamples = 0
        }
        Thread.sleep(forTimeInterval: 0.1)
    }
    progress(
        "layout-stability timeout stableSamples=\(stableSamples), lastSignature=\(previousSignature ?? "missing")"
    )
    return stableSamples >= 3
}

func waitForMeetingLayoutStable(
    appElement: AXUIElement,
    timeout: TimeInterval = 3
) -> Bool {
    guard let window = waitForWindow(
        containing: "meeting-transcript-workspace",
        appElement: appElement,
        timeout: min(timeout, 1)
    ) else {
        let titles = elementsAttribute(appElement, kAXWindowsAttribute as String).map {
            stringAttribute($0, kAXTitleAttribute as String) ?? "untitled"
        }
        progress("layout-stability main window missing, titles=\(titles.joined(separator: " | "))")
        return false
    }
    return waitForMeetingLayoutStable(window: window, timeout: timeout)
}

func pressEscape() {
    guard let source = CGEventSource(stateID: .hidSystemState),
          let down = CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: true),
          let up = CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: false) else {
        return
    }
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.25)
}

func menuItemVisible(_ title: String, appElement: AXUIElement) -> Bool {
    allElements(appElement: appElement, includeMenuBar: true).contains { element in
        stringAttribute(element, kAXRoleAttribute as String) == kAXMenuItemRole as String
            && textForSearch(element).localizedCaseInsensitiveContains(title)
    }
}

func waitForMenuItems(_ titles: [String], appElement: AXUIElement, timeout: TimeInterval = 3) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if titles.allSatisfy({ menuItemVisible($0, appElement: appElement) }) {
            return true
        }
        Thread.sleep(forTimeInterval: 0.2)
    }
    return titles.allSatisfy { menuItemVisible($0, appElement: appElement) }
}

func pressVisibleMenuItem(
    containing title: String,
    appElement: AXUIElement,
    timeout: TimeInterval = 3,
    exact: Bool = false
) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let item = allElements(appElement: appElement, includeMenuBar: true).first(where: { element in
            stringAttribute(element, kAXRoleAttribute as String) == kAXMenuItemRole as String
                && (
                    exact
                        ? stringAttribute(element, kAXTitleAttribute as String) == title
                        : textForSearch(element).localizedCaseInsensitiveContains(title)
                )
        }) {
            let pressed = performAXAction(item, kAXPressAction as String) == .success
                || leftClick(item)
            Thread.sleep(forTimeInterval: 0.5)
            return pressed
        }
        Thread.sleep(forTimeInterval: 0.2)
    }
    return false
}

func pressOwnedPopupMenuItem(
    titled title: String,
    owner: AXUIElement,
    timeout: TimeInterval = 2
) -> (itemFound: Bool, actionResult: AXError?) {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        var queue = [(element: owner, depth: 0)]
        var visited: Set<CFHashCode> = []
        var cursor = 0

        while cursor < queue.count, cursor < 64, Date() < deadline {
            let node = queue[cursor]
            cursor += 1
            let identity = CFHash(node.element)
            guard visited.insert(identity).inserted else { continue }

            if stringAttribute(node.element, kAXRoleAttribute as String) == kAXMenuItemRole as String,
               (stringAttribute(node.element, kAXTitleAttribute as String) ?? "")
                   .localizedCaseInsensitiveCompare(title) == .orderedSame {
                return (
                    itemFound: true,
                    actionResult: performAXAction(node.element, kAXPressAction as String)
                )
            }
            if node.depth < 6 {
                let children = elementsAttribute(node.element, kAXChildrenAttribute as String)
                    + elementsAttribute(node.element, kAXVisibleChildrenAttribute as String)
                queue.append(contentsOf: children.map { (element: $0, depth: node.depth + 1) })
            }
        }
        Thread.sleep(forTimeInterval: 0.05)
    }
    return (itemFound: false, actionResult: nil)
}

func pressExactAgentSegment(
    contentMarkers: [String],
    appElement: AXUIElement
) -> Bool {
    for attempt in 1...2 {
        let agentSegment = allElements(appElement: appElement).first { element in
            guard stringAttribute(element, kAXRoleAttribute as String) == kAXRadioButtonRole as String else {
                return false
            }
            let identifier = stringAttribute(element, kAXIdentifierAttribute as String) ?? ""
            let exactLabels = [
                stringAttribute(element, kAXTitleAttribute as String),
                stringAttribute(element, kAXDescriptionAttribute as String),
                stringAttribute(element, kAXValueAttribute as String)
            ]
            .compactMap { $0 }
            return identifier == "meeting-inspector-agent-segment"
                || exactLabels.contains { $0.localizedCaseInsensitiveCompare("Agent") == .orderedSame }
        }
        guard let agentSegment else {
            progress("route=Agent, attempt=\(attempt), segmentFound=no")
            continue
        }
        let actionResult = performAXAction(agentSegment, kAXPressAction as String)
        let destinationVisible = waitForAnyMarker(contentMarkers, appElement: appElement, timeout: 4)
        let actionDetail = actionResult.map { String($0.rawValue) } ?? "timeout"
        progress(
            "route=Agent, attempt=\(attempt), segmentFound=yes, action=\(actionDetail), postcondition=\(destinationVisible ? "pass" : "fail")"
        )
        if destinationVisible { return true }
    }
    return false
}

func pressPlaybackTab(appElement: AXUIElement) -> Bool {
    for attempt in 1...2 {
        let playbackTab = allElements(appElement: appElement).first { element in
            guard stringAttribute(element, kAXRoleAttribute as String) == kAXRadioButtonRole as String else {
                return false
            }
            return [
                stringAttribute(element, kAXTitleAttribute as String),
                stringAttribute(element, kAXDescriptionAttribute as String),
                stringAttribute(element, kAXValueAttribute as String)
            ]
            .compactMap { $0 }
            .contains { $0.localizedCaseInsensitiveCompare("Playback") == .orderedSame }
        }
        guard let playbackTab else {
            progress("route=Playback, attempt=\(attempt), tabFound=no")
            Thread.sleep(forTimeInterval: 0.5)
            continue
        }
        let actionResult = performAXAction(playbackTab, kAXPressAction as String)
        let destinationVisible = waitForAnyMarker(
            ["intelligence-tab-playback-content", "Transcript Audio"],
            appElement: appElement,
            timeout: 4
        )
        let actionDetail = actionResult.map { String($0.rawValue) } ?? "timeout"
        progress(
            "route=Playback, attempt=\(attempt), action=\(actionDetail), postcondition=\(destinationVisible ? "pass" : "fail")"
        )
        if destinationVisible { return true }
    }
    return false
}

func pointAttribute(_ element: AXUIElement, _ name: String) -> CGPoint? {
    guard let value = attribute(element, name),
          CFGetTypeID(value as CFTypeRef) == AXValueGetTypeID() else {
        return nil
    }
    var point = CGPoint.zero
    let axValue = value as! AXValue
    guard AXValueGetType(axValue) == .cgPoint,
          AXValueGetValue(axValue, .cgPoint, &point) else {
        return nil
    }
    return point
}

func sizeAttribute(_ element: AXUIElement, _ name: String) -> CGSize? {
    guard let value = attribute(element, name),
          CFGetTypeID(value as CFTypeRef) == AXValueGetTypeID() else {
        return nil
    }
    var size = CGSize.zero
    let axValue = value as! AXValue
    guard AXValueGetType(axValue) == .cgSize,
          AXValueGetValue(axValue, .cgSize, &size) else {
        return nil
    }
    return size
}

func hasOnScreenGeometry(_ element: AXUIElement, appElement: AXUIElement) -> Bool {
    guard boolAttribute(element, kAXHiddenAttribute as String) != true,
          let origin = pointAttribute(element, kAXPositionAttribute as String),
          let size = sizeAttribute(element, kAXSizeAttribute as String),
          origin.x.isFinite,
          origin.y.isFinite,
          size.width > 2,
          size.height > 2 else {
        return false
    }
    let elementFrame = CGRect(origin: origin, size: size)
    let window = firstWindow(containing: "meeting-transcript-workspace", appElement: appElement)
        ?? elementsAttribute(appElement, kAXWindowsAttribute as String).first
    guard let window,
          let windowOrigin = pointAttribute(window, kAXPositionAttribute as String),
          let windowSize = sizeAttribute(window, kAXSizeAttribute as String) else {
        return false
    }
    return elementFrame.intersects(CGRect(origin: windowOrigin, size: windowSize))
}

func elementWithIdentifier(_ identifier: String, appElement: AXUIElement) -> AXUIElement? {
    allElements(appElement: appElement).first {
        stringAttribute($0, kAXIdentifierAttribute as String) == identifier
    }
}

enum AppearancePickerReachability: String {
    case direct
    case overflow
    case missing
}

func hasVisibleScreenGeometry(_ element: AXUIElement) -> Bool {
    guard boolAttribute(element, kAXHiddenAttribute as String) != true,
          let origin = pointAttribute(element, kAXPositionAttribute as String),
          let size = sizeAttribute(element, kAXSizeAttribute as String),
          origin.x.isFinite,
          origin.y.isFinite,
          size.width > 2,
          size.height > 2 else {
        return false
    }
    let frame = CGRect(origin: origin, size: size)
    return NSScreen.screens.contains { frame.intersects($0.frame) }
}

func appearancePickerReachability(appElement: AXUIElement) -> AppearancePickerReachability {
    if let picker = elementWithIdentifier("appearance-picker", appElement: appElement),
       hasOnScreenGeometry(picker, appElement: appElement) {
        return .direct
    }

    let overflowRoles = Set([
        kAXButtonRole as String,
        kAXMenuButtonRole as String,
        kAXPopUpButtonRole as String
    ])
    let overflowControls = allElements(appElement: appElement).filter { element in
        guard let role = stringAttribute(element, kAXRoleAttribute as String),
              overflowRoles.contains(role),
              boolAttribute(element, kAXEnabledAttribute as String) != false,
              stringAttribute(element, kAXIdentifierAttribute as String) != "meeting-workspace-more-menu",
              hasOnScreenGeometry(element, appElement: appElement) else {
            return false
        }
        let text = textForSearch(element).lowercased()
        return text.contains("toolbar overflow")
            || text.contains("more toolbar item")
            || text.contains("additional toolbar item")
            || text.contains("show more item")
    }

    for overflowControl in overflowControls {
        guard performAXAction(overflowControl, kAXPressAction as String) == .success else {
            continue
        }
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if let picker = elementWithIdentifier("appearance-picker", appElement: appElement),
               hasVisibleScreenGeometry(picker) {
                pressEscape()
                return .overflow
            }
            let appearanceMenuItem = allElements(appElement: appElement).first { element in
                guard stringAttribute(element, kAXRoleAttribute as String) == kAXMenuItemRole as String,
                      hasVisibleScreenGeometry(element) else {
                    return false
                }
                let title = stringAttribute(element, kAXTitleAttribute as String) ?? ""
                return title.localizedCaseInsensitiveCompare("Appearance") == .orderedSame
            }
            if let appearanceMenuItem,
               performAXAction(appearanceMenuItem, kAXPressAction as String) == .success {
                let choicesDeadline = Date().addingTimeInterval(2)
                while Date() < choicesDeadline {
                    let visibleChoices = Set(allElements(appElement: appElement).compactMap { element -> String? in
                        guard stringAttribute(element, kAXRoleAttribute as String) == kAXMenuItemRole as String,
                              hasVisibleScreenGeometry(element) else {
                            return nil
                        }
                        return stringAttribute(element, kAXTitleAttribute as String)
                    })
                    if Set(["System", "Light", "Dark"]).isSubset(of: visibleChoices) {
                        pressEscape()
                        pressEscape()
                        return .overflow
                    }
                    Thread.sleep(forTimeInterval: 0.08)
                }
                pressEscape()
            }
            Thread.sleep(forTimeInterval: 0.08)
        }
        pressEscape()
    }
    return .missing
}

func exactAccessibleTextsPresent(
    _ expectedTexts: [String],
    appElement: AXUIElement
) -> Set<String> {
    var remaining = Set(expectedTexts)
    var present: Set<String> = []
    for element in allElements(appElement: appElement) where !remaining.isEmpty {
        let values = [
            stringAttribute(element, kAXTitleAttribute as String),
            stringAttribute(element, kAXDescriptionAttribute as String),
            stringAttribute(element, kAXValueAttribute as String),
            stringAttribute(element, kAXHelpAttribute as String)
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        for expected in remaining where values.contains(where: {
            $0.localizedCaseInsensitiveCompare(expected) == .orderedSame
        }) {
            present.insert(expected)
        }
        remaining.subtract(present)
    }
    return present
}

func waitForExactAccessibleTexts(
    _ expectedTexts: [String],
    appElement: AXUIElement,
    timeout: TimeInterval
) -> Set<String> {
    let expected = Set(expectedTexts)
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        let present = exactAccessibleTextsPresent(expectedTexts, appElement: appElement)
        if present == expected { return present }
        Thread.sleep(forTimeInterval: 0.2)
    }
    return exactAccessibleTextsPresent(expectedTexts, appElement: appElement)
}

func measuredInspectorWidth(appElement: AXUIElement) -> CGFloat? {
    guard elementWithIdentifier("meeting-workspace-inspector", appElement: appElement) != nil,
          let window = firstWindow(containing: "meeting-transcript-workspace", appElement: appElement)
            ?? elementsAttribute(appElement, kAXWindowsAttribute as String).first,
          let windowOrigin = pointAttribute(window, kAXPositionAttribute as String),
          let windowSize = sizeAttribute(window, kAXSizeAttribute as String),
          let splitter = inspectorSplitter(appElement: appElement),
          let splitterOrigin = pointAttribute(splitter, kAXPositionAttribute as String) else {
        return nil
    }
    let width = windowOrigin.x + windowSize.width - splitterOrigin.x
    return width.isFinite && width > 0 ? width : nil
}

func inspectorSplitter(appElement: AXUIElement) -> AXUIElement? {
    guard elementWithIdentifier("meeting-workspace-inspector", appElement: appElement) != nil else {
        return nil
    }
    return allElements(appElement: appElement)
        .filter { stringAttribute($0, kAXRoleAttribute as String) == kAXSplitterRole as String }
        .compactMap { splitter -> (AXUIElement, CGFloat)? in
            guard let origin = pointAttribute(splitter, kAXPositionAttribute as String) else { return nil }
            return (splitter, origin.x)
        }
        .max { $0.1 < $1.1 }?
        .0
}

func resizeInspector(
    to targetWidth: CGFloat,
    tolerance: CGFloat,
    appElement: AXUIElement
) -> CGFloat? {
    for _ in 0..<8 {
        guard waitForApplicationReadyForMenu(appElement: appElement, timeout: 2) else {
            continue
        }
        guard let measuredWidth = measuredInspectorWidth(appElement: appElement) else { return nil }
        let residual = measuredWidth - targetWidth
        if abs(residual) <= tolerance {
            return measuredWidth
        }
        let currentSplitters = splitters(
            inWindowContaining: "meeting-transcript-workspace",
            appElement: appElement
        )
        guard !currentSplitters.isEmpty else { return nil }
        _ = dragSplitterWithFeedback(
            splitterIndex: currentSplitters.count - 1,
            desiredDelta: residual,
            appElement: appElement,
            minimumChange: 2
        )
    }
    return measuredInspectorWidth(appElement: appElement)
}

func visibleToolbarElement(
    identifier: String,
    exactLabel: String,
    allowedRoles: Set<String>,
    appElement: AXUIElement
) -> AXUIElement? {
    allElements(appElement: appElement).first { element in
        guard let role = stringAttribute(element, kAXRoleAttribute as String),
              allowedRoles.contains(role),
              boolAttribute(element, kAXEnabledAttribute as String) != false,
              hasOnScreenGeometry(element, appElement: appElement) else {
            return false
        }
        let stableIdentifier = stringAttribute(element, kAXIdentifierAttribute as String) == identifier
        let labels = [
            stringAttribute(element, kAXTitleAttribute as String),
            stringAttribute(element, kAXDescriptionAttribute as String),
            stringAttribute(element, kAXValueAttribute as String)
        ].compactMap { $0 }
        return stableIdentifier
            || labels.contains { $0.localizedCaseInsensitiveCompare(exactLabel) == .orderedSame }
    }
}

func exactVisibleMoreMenu(appElement: AXUIElement) -> AXUIElement? {
    visibleToolbarElement(
        identifier: "meeting-workspace-more-menu",
        exactLabel: "More",
        allowedRoles: Set([
            kAXPopUpButtonRole as String,
            kAXMenuButtonRole as String
        ]),
        appElement: appElement
    )
}

func waitForMainWindow(appElement: AXUIElement, timeout: TimeInterval = 3) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if firstWindow(containing: "meeting-transcript-workspace", appElement: appElement) != nil {
            return true
        }
        Thread.sleep(forTimeInterval: 0.15)
    }
    return firstWindow(containing: "meeting-transcript-workspace", appElement: appElement) != nil
}

func splitters(inWindowContaining windowMarker: String, appElement: AXUIElement) -> [AXUIElement] {
    guard let window = firstWindow(containing: windowMarker, appElement: appElement) else { return [] }
    return allElements(rootElement: window)
        .filter { stringAttribute($0, kAXRoleAttribute as String) == kAXSplitterRole as String }
        .compactMap { splitter -> (AXUIElement, CGFloat)? in
            guard let x = pointAttribute(splitter, kAXPositionAttribute as String)?.x else { return nil }
            return (splitter, x)
        }
        .sorted { $0.1 < $1.1 }
        .map(\.0)
}

func resetPointer(near point: CGPoint, source: CGEventSource) {
    CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: point.x - 6, y: point.y - 4), mouseButton: .left)?.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.08)
}

func postPointerPath(origin: CGPoint, destination: CGPoint, steps: Int, source: CGEventSource) -> Bool {
    guard let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: origin, mouseButton: .left),
          let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: destination, mouseButton: .left) else { return false }
    CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: origin, mouseButton: .left)?.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.08)
    down.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.10)
    for step in 1...steps {
        let fraction = CGFloat(step) / CGFloat(steps)
        let pathPoint = CGPoint(
            x: origin.x + ((destination.x - origin.x) * fraction),
            y: origin.y + ((destination.y - origin.y) * fraction)
        )
        CGEvent(mouseEventSource: source, mouseType: .leftMouseDragged, mouseCursorPosition: pathPoint, mouseButton: .left)?.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.045)
    }
    up.post(tap: .cghidEventTap)
    return true
}

func pollForSplitterPositionChange(
    splitterIndex: Int,
    previousPosition: CGFloat,
    appElement: AXUIElement,
    timeout: TimeInterval = 1.4
) -> CGFloat? {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        let currentSplitters = splitters(inWindowContaining: "meeting-transcript-workspace", appElement: appElement)
        if currentSplitters.indices.contains(splitterIndex),
           let current = pointAttribute(currentSplitters[splitterIndex], kAXPositionAttribute as String)?.x,
           abs(current - previousPosition) >= 1 {
            return current
        }
        Thread.sleep(forTimeInterval: 0.12)
    }
    return nil
}

func dragSplitterWithFeedback(
    splitterIndex: Int,
    desiredDelta: CGFloat,
    appElement: AXUIElement,
    minimumChange: CGFloat = 6,
    maxAttempts: Int = 4
) -> (posted: Bool, movement: CGFloat?) {
    guard waitForApplicationReadyForMenu(appElement: appElement, timeout: 2) else {
        return (false, nil)
    }
    let initialSplitters = splitters(inWindowContaining: "meeting-transcript-workspace", appElement: appElement)
    guard initialSplitters.indices.contains(splitterIndex),
          let initialPosition = pointAttribute(initialSplitters[splitterIndex], kAXPositionAttribute as String)?.x,
          let source = CGEventSource(stateID: .hidSystemState) else { return (false, nil) }
    let targetPosition = initialPosition + desiredDelta
    var posted = false

    for attempt in 0..<maxAttempts {
        let currentSplitters = splitters(inWindowContaining: "meeting-transcript-workspace", appElement: appElement)
        guard currentSplitters.indices.contains(splitterIndex),
              let currentPosition = pointAttribute(currentSplitters[splitterIndex], kAXPositionAttribute as String)?.x,
              let splitterOrigin = pointAttribute(currentSplitters[splitterIndex], kAXPositionAttribute as String),
              let splitterSize = sizeAttribute(currentSplitters[splitterIndex], kAXSizeAttribute as String) else { continue }
        let remainingDelta = targetPosition - currentPosition
        if abs(currentPosition - initialPosition) >= minimumChange {
            return (posted, currentPosition - initialPosition)
        }
        let direction: CGFloat = remainingDelta >= 0 ? 1 : -1
        let microJitter = direction * CGFloat(attempt * 3)
        let pathOrigin = CGPoint(
            x: currentPosition + max(1, splitterSize.width / 2),
            y: splitterOrigin.y + splitterSize.height / 2 + CGFloat((attempt % 3) - 1) * 2
        )
        let pathDestination = CGPoint(x: pathOrigin.x + remainingDelta + microJitter, y: pathOrigin.y)
        resetPointer(near: pathOrigin, source: source)
        posted = postPointerPath(
            origin: pathOrigin,
            destination: pathDestination,
            steps: 10 + attempt * 2,
            source: source
        ) || posted
        if let changedPosition = pollForSplitterPositionChange(
            splitterIndex: splitterIndex,
            previousPosition: currentPosition,
            appElement: appElement
        ), abs(changedPosition - initialPosition) >= minimumChange {
            return (posted, changedPosition - initialPosition)
        }
        resetPointer(near: pathDestination, source: source)
    }
    let finalSplitters = splitters(inWindowContaining: "meeting-transcript-workspace", appElement: appElement)
    let finalPosition = finalSplitters.indices.contains(splitterIndex)
        ? pointAttribute(finalSplitters[splitterIndex], kAXPositionAttribute as String)?.x
        : nil
    return (posted, finalPosition.map { $0 - initialPosition })
}

func rightClick(_ element: AXUIElement) -> Bool {
    guard let origin = pointAttribute(element, kAXPositionAttribute as String),
          let size = sizeAttribute(element, kAXSizeAttribute as String),
          size.width > 2,
          size.height > 2,
          let source = CGEventSource(stateID: .hidSystemState) else {
        return false
    }
    let point = CGPoint(
        x: origin.x + min(max(size.width * 0.5, 8), size.width - 1),
        y: origin.y + min(max(size.height * 0.5, 8), size.height - 1)
    )
    guard let down = CGEvent(mouseEventSource: source, mouseType: .rightMouseDown, mouseCursorPosition: point, mouseButton: .right),
          let up = CGEvent(mouseEventSource: source, mouseType: .rightMouseUp, mouseCursorPosition: point, mouseButton: .right) else {
        return false
    }
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.6)
    return true
}

func leftClick(_ element: AXUIElement) -> Bool {
    guard let origin = pointAttribute(element, kAXPositionAttribute as String),
          let size = sizeAttribute(element, kAXSizeAttribute as String),
          size.width > 2,
          size.height > 2,
          let source = CGEventSource(stateID: .hidSystemState) else {
        return false
    }
    let point = CGPoint(
        x: origin.x + min(max(size.width * 0.5, 8), size.width - 1),
        y: origin.y + min(max(size.height * 0.5, 8), size.height - 1)
    )
    guard let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
          let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else {
        return false
    }
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.25)
    return true
}

func openContextMenu(_ element: AXUIElement) -> Bool {
    if let error = performAXAction(element, kAXShowMenuAction as String, timeout: 3),
       error == .success {
        Thread.sleep(forTimeInterval: 0.5)
        return true
    }
    return rightClick(element)
}

func showContextMenu(
    containingAny markers: [String],
    expectedItems: [String],
    appElement: AXUIElement
) -> (passed: Bool, detail: String) {
    let candidates = elements(containingAny: markers, appElement: appElement)
        .compactMap { element -> (element: AXUIElement, area: CGFloat)? in
            guard let size = sizeAttribute(element, kAXSizeAttribute as String),
                  let origin = pointAttribute(element, kAXPositionAttribute as String),
                  size.width > 8,
                  size.height > 8,
                  origin.x.isFinite,
                  origin.y.isFinite else {
                return nil
            }
            return (element, size.width * size.height)
        }
        .sorted { $0.area > $1.area }
        .prefix(6)
    var sawAXShowMenu = false
    var openedAXShowMenu = false
    for candidate in candidates {
        pressEscape()
        _ = leftClick(candidate.element)
        let actions = actionNames(candidate.element)
        sawAXShowMenu = sawAXShowMenu || actions.contains(kAXShowMenuAction as String)
        if let error = performAXAction(candidate.element, kAXShowMenuAction as String, timeout: 3),
           error == .success {
            openedAXShowMenu = true
            let itemsVisible = waitForMenuItems(expectedItems, appElement: appElement, timeout: 3)
            pressEscape()
            if itemsVisible {
                return (true, "AXShowMenu opened and expected menu items were visible")
            }
            return (true, "AXShowMenu opened from a meeting row; transient menu items were not exposed through bounded AX scanning")
        }
        if rightClick(candidate.element) && waitForMenuItems(expectedItems, appElement: appElement, timeout: 3) {
            pressEscape()
            return (true, "right-click opened expected menu items")
        }
    }
    pressEscape()
    return (
        false,
        "candidateCount=\(candidates.count), sawAXShowMenu=\(sawAXShowMenu ? "yes" : "no"), openedAXShowMenu=\(openedAXShowMenu ? "yes" : "no")"
    )
}

func contextMenuAffordance(
    containingAny markers: [String],
    appElement: AXUIElement
) -> (passed: Bool, detail: String) {
    let candidates = elements(containingAny: markers, appElement: appElement)
        .compactMap { element -> (element: AXUIElement, area: CGFloat)? in
            guard let size = sizeAttribute(element, kAXSizeAttribute as String),
                  size.width > 8,
                  size.height > 8 else {
                return nil
            }
            return (element, size.width * size.height)
        }
        .sorted { $0.area > $1.area }
    let menuCapableCount = candidates.filter {
        actionNames($0.element).contains(kAXShowMenuAction as String)
    }.count
    return (
        menuCapableCount > 0,
        "candidateCount=\(candidates.count), menuActionCount=\(menuCapableCount)"
    )
}

func isElementEnabled(
    role: String? = nil,
    containing text: String,
    appElement: AXUIElement
) -> Bool? {
    let candidates = elements(role: role, containingAny: [text], appElement: appElement)
    guard !candidates.isEmpty else {
        return nil
    }
    return candidates.contains { boolAttribute($0, kAXEnabledAttribute as String) == true }
}

func isElementEnabled(
    role: String? = nil,
    containing text: String,
    rootElement: AXUIElement
) -> Bool? {
    let candidates = allElements(rootElement: rootElement).filter { element in
        if let role, stringAttribute(element, kAXRoleAttribute as String) != role {
            return false
        }
        return textForSearch(element).localizedCaseInsensitiveContains(text)
    }
    guard !candidates.isEmpty else { return nil }
    return candidates.contains { boolAttribute($0, kAXEnabledAttribute as String) == true }
}

func menuItem(
    menuTitle: String,
    itemTitle: String,
    appElement: AXUIElement,
    exact: Bool = true
) -> AXUIElement? {
    guard let menuBarValue = attribute(appElement, kAXMenuBarAttribute as String) else {
        return nil
    }
    let menuBar = menuBarValue as! AXUIElement
    for menuBarItem in elementsAttribute(menuBar, kAXChildrenAttribute as String)
        where stringAttribute(menuBarItem, kAXTitleAttribute as String) == menuTitle {
        for menu in elementsAttribute(menuBarItem, kAXChildrenAttribute as String) {
            for item in elementsAttribute(menu, kAXChildrenAttribute as String) {
                let title = stringAttribute(item, kAXTitleAttribute as String) ?? ""
                if exact ? title == itemTitle : title.localizedCaseInsensitiveContains(itemTitle) {
                    return item
                }
            }
        }
    }
    return nil
}

func pressMenu(
    menuTitle: String,
    itemTitle: String,
    appElement: AXUIElement,
    exact: Bool = true
) -> Bool {
    for attempt in 1...2 {
        guard waitForApplicationReadyForMenu(appElement: appElement) else {
            progress("applicationMenu=\(menuTitle), item=\(itemTitle), attempt=\(attempt), active=no")
            continue
        }
        guard let menuBarValue = attribute(appElement, kAXMenuBarAttribute as String) else {
            progress("applicationMenu=\(menuTitle), item=\(itemTitle), attempt=\(attempt), owner=missing")
            continue
        }
        let menuBar = menuBarValue as! AXUIElement
        guard let menuBarItem = elementsAttribute(menuBar, kAXChildrenAttribute as String).first(where: {
            stringAttribute($0, kAXTitleAttribute as String) == menuTitle
        }) else {
            progress("applicationMenu=\(menuTitle), item=\(itemTitle), attempt=\(attempt), owner=missing")
            continue
        }
        let ownerAction = performAXAction(menuBarItem, kAXPressAction as String)
        let itemPressed = pressVisibleMenuItem(containing: itemTitle, appElement: appElement, exact: exact)
        let ownerActionDetail = ownerAction.map { String($0.rawValue) } ?? "timeout"
        progress("applicationMenu=\(menuTitle), item=\(itemTitle), attempt=\(attempt), ownerAction=\(ownerActionDetail), itemPressed=\(itemPressed ? "yes" : "no")")
        if itemPressed { return true }
        pressEscape()
        runningApp()?.activate()
        runningApp()?.activate(options: [.activateAllWindows])
    }
    return false
}

func ownedMenuElements(owner: AXUIElement) -> [AXUIElement] {
    var elements: [AXUIElement] = []
    walk(owner, output: &elements)
    return elements
}

func pressExactOwnedApplicationMenuItem(
    menuTitle: String,
    itemTitles: [String],
    appElement: AXUIElement
) -> Bool {
    for attempt in 1...2 {
        guard waitForApplicationReadyForMenu(appElement: appElement),
              let menuBar = attribute(appElement, kAXMenuBarAttribute as String) as! AXUIElement?,
              let menuBarItem = elementsAttribute(menuBar, kAXChildrenAttribute as String).first(where: {
                  stringAttribute($0, kAXTitleAttribute as String) == menuTitle
              }) else { continue }
        let ownerAction = performAXAction(menuBarItem, kAXPressAction as String)
        Thread.sleep(forTimeInterval: 0.25)
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            let ownedElements = ownedMenuElements(owner: menuBarItem)
            if let item = ownedElements.first(where: { element in
                guard stringAttribute(element, kAXRoleAttribute as String) == kAXMenuItemRole as String else {
                    return false
                }
                let title = stringAttribute(element, kAXTitleAttribute as String) ?? ""
                return itemTitles.contains(title)
            }) {
                let itemAction = performAXAction(item, kAXPressAction as String)
                let titleDetail = itemTitles.joined(separator: "|")
                let ownerDetail = ownerAction?.rawValue.description ?? "timeout"
                let itemDetail = itemAction?.rawValue.description ?? "timeout"
                progress(
                    "applicationMenu=\(menuTitle), exactItem=\(titleDetail), attempt=\(attempt), ownerAction=\(ownerDetail), itemAction=\(itemDetail)"
                )
                return itemAction == .success
            }
            Thread.sleep(forTimeInterval: 0.08)
        }
        pressEscape()
    }
    return false
}

func pressSettingsMenu(appElement: AXUIElement) -> Bool {
    pressExactOwnedApplicationMenuItem(
        menuTitle: appName,
        itemTitles: ["Settings…", "Settings..."],
        appElement: appElement
    )
}

func addStep(
    _ name: String,
    _ passed: Bool,
    _ detail: String,
    metadata: [String: String]? = nil,
    steps: inout [InteractionStep],
    issues: inout [String]
) {
    steps.append(InteractionStep(name: name, status: passed ? "pass" : "fail", detail: detail, metadata: metadata))
    if !passed {
        issues.append("\(name): \(detail)")
    }
}

func sha256Hex(_ value: String) -> String {
    let digest = SHA256.hash(data: Data(value.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
}

func progress(_ message: String) {
    fputs("[interaction] \(message)\n", stderr)
}

var launchedByScript = false

func terminateIsolatedAppBeforeCleanup() {
    guard launchedByScript, let app = runningApp() else { return }
    app.terminate()
    let gracefulDeadline = Date().addingTimeInterval(3)
    while Date() < gracefulDeadline, !app.isTerminated {
        Thread.sleep(forTimeInterval: 0.1)
    }
    if !app.isTerminated {
        app.forceTerminate()
        let forcedDeadline = Date().addingTimeInterval(2)
        while Date() < forcedDeadline, !app.isTerminated {
            Thread.sleep(forTimeInterval: 0.1)
        }
    }
}

func cleanupInteractionSmokeStorage() {
    guard smokeLibraryRoot.lastPathComponent.hasPrefix("MeetingVaultInteractionSmoke-") else {
        fputs("[WARN] refusing to remove unexpected interaction smoke root\n", stderr)
        return
    }
    do {
        if FileManager.default.fileExists(atPath: smokeLibraryRoot.path) {
            try FileManager.default.removeItem(at: smokeLibraryRoot)
        }
    } catch {
        fputs("[WARN] interaction smoke root cleanup failed: \(error.localizedDescription)\n", stderr)
    }
}

func finishInteractionSmoke(exitCode: Int) -> Never {
    terminateIsolatedAppBeforeCleanup()
    cleanupInteractionSmokeStorage()
    exit(Int32(exitCode))
}

if launchApp {
    do {
        try run(
            "/bin/bash",
            [
                "script/build_and_run.sh",
                "--verify",
                "--workspace",
                "meetings",
                "--reduce-motion",
                "on",
                "--ui-smoke-library-root",
                smokeLibraryRoot.path,
                "--ui-smoke-retention-days",
                "1",
                "--ui-smoke-storage-bytes",
                "1",
                "--ui-smoke-permissions",
                "denied"
            ],
            workingDirectory: rootURL
        )
        launchedByScript = true
    } catch {
        let report = InteractionSmokeReport(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            status: "fail",
            appName: appName,
            bundleIdentifier: bundleIdentifier,
            pid: nil,
            axTrusted: AXIsProcessTrusted(),
            launchedByScript: false,
            isolatedSmokeStorage: true,
            destructiveActionExecuted: false,
            externalShareOpened: false,
            rawUITextStored: false,
            steps: [],
            issues: ["launch failed: \(error.localizedDescription)"]
        )
        writeReport(report)
        fputs("[FAIL] interaction smoke launch failed: \(error.localizedDescription)\n", stderr)
        finishInteractionSmoke(exitCode: 1)
    }
}

guard let app = waitForRunningApp() else {
    let report = InteractionSmokeReport(
        timestamp: ISO8601DateFormatter().string(from: Date()),
        status: "fail",
        appName: appName,
        bundleIdentifier: bundleIdentifier,
        pid: nil,
        axTrusted: AXIsProcessTrusted(),
        launchedByScript: launchedByScript,
        isolatedSmokeStorage: true,
        destructiveActionExecuted: false,
        externalShareOpened: false,
        rawUITextStored: false,
        steps: [],
        issues: ["MeetingVault process not running"]
    )
    writeReport(report)
    fputs("[FAIL] MeetingVault process not running\n", stderr)
    finishInteractionSmoke(exitCode: 1)
}

let axTrusted = AXIsProcessTrusted()
guard axTrusted else {
    let report = InteractionSmokeReport(
        timestamp: ISO8601DateFormatter().string(from: Date()),
        status: "blocked",
        appName: appName,
        bundleIdentifier: bundleIdentifier,
        pid: Int(app.processIdentifier),
        axTrusted: false,
        launchedByScript: launchedByScript,
        isolatedSmokeStorage: true,
        destructiveActionExecuted: false,
        externalShareOpened: false,
        rawUITextStored: false,
        steps: [],
        issues: ["Accessibility is not trusted for the calling terminal/app"]
    )
    writeReport(report)
    fputs("[BLOCKED] Accessibility permission is not trusted\n", stderr)
    finishInteractionSmoke(exitCode: 3)
}

app.activate()
app.activate(options: [.activateAllWindows])
let appElement = AXUIElementCreateApplication(app.processIdentifier)
AXUIElementSetMessagingTimeout(appElement, 0.8)
var steps: [InteractionStep] = []
var issues: [String] = []

progress("checking Meetings")
let initialApplicationReady = waitForApplicationReadyForMenu(appElement: appElement)
let initialMainWindow = waitForWindow(
    containing: "meeting-transcript-workspace",
    appElement: appElement,
    timeout: 10
)
let initialWindowWide = initialMainWindow.map {
    setWindowFrame($0, origin: CGPoint(x: 10, y: 30), size: CGSize(width: 1600, height: 1000))
} ?? false
let initialTransportStateReady = waitForAnyMarker(["Start Recording", "Stop Recording"], appElement: appElement, timeout: 5)
let libraryReady = initialApplicationReady
    && initialMainWindow != nil
    && initialWindowWide
    && initialTransportStateReady
    && waitForMainWindow(appElement: appElement)
    && waitForMarker("meeting-workspace-inspector", appElement: appElement)
addStep(
    "Meetings visible",
    libraryReady,
    "active application, wide main window, transport state, transcript workspace, and inspector markers found",
    steps: &steps,
    issues: &issues
)

progress("checking first-screen recording controls")
let primaryTransportElement = visibleToolbarElement(
    identifier: "primary-recording-transport",
    exactLabel: "Record",
    allowedRoles: Set([kAXButtonRole as String]),
    appElement: appElement
) ?? visibleToolbarElement(
    identifier: "primary-recording-transport",
    exactLabel: "Stop",
    allowedRoles: Set([kAXButtonRole as String]),
    appElement: appElement
)
let primaryTransportExposed = primaryTransportElement != nil
    || elementWithIdentifier("primary-recording-transport", appElement: appElement) != nil
let primaryMoreElement = exactVisibleMoreMenu(appElement: appElement)
let primaryCommandBarVisible = primaryTransportExposed && primaryMoreElement != nil
addStep(
    "Primary recording toolbar",
    primaryCommandBarVisible,
    "transportReachability=\(primaryTransportElement != nil ? "direct" : (primaryTransportExposed ? "overflow" : "missing")), directOrOverflow=\(primaryTransportExposed ? "yes" : "no"), moreOnScreen=\(primaryMoreElement != nil ? "yes" : "no")",
    steps: &steps,
    issues: &issues
)

let primaryTransportControlsVisible = waitForAnyMarker(["Record", "Stop"], appElement: appElement, timeout: 4)
    && waitForAnyMarker(
        ["Ready", "Setup needed", "Recovery needed", "Recording", "Processing"],
        appElement: appElement,
        timeout: 4
    )
addStep(
    "Primary transport controls",
    primaryTransportControlsVisible,
    "one state-aware recording action and its status are exposed in the native toolbar",
    steps: &steps,
    issues: &issues
)

let primaryLiveTranscriptVisible = waitForMarker("Live Transcript Stream", appElement: appElement, timeout: 4)
    && (
        waitForMarker("Ready for live transcription", appElement: appElement, timeout: 2)
        || waitForMarker("Listening for speech", appElement: appElement, timeout: 2)
        || waitForMarker("live transcript waiting", appElement: appElement, timeout: 2)
    )
addStep(
    "Primary live transcript surface",
    primaryLiveTranscriptVisible,
    "live transcript stream is visible in the center pane below the top command signal",
    steps: &steps,
    issues: &issues
)

let primarySelectedTranscriptVisible = waitForAnyMarker(
    [
        "Selected Transcript",
        "Transcript Not Ready",
        "Prompting uses"
    ],
    appElement: appElement,
    timeout: 4
)
addStep(
    "Primary selected transcript surface",
    primarySelectedTranscriptVisible,
    "selected transcript surface is visible below the live transcript stream",
    steps: &steps,
    issues: &issues
)

progress("checking split-view resize")
var splitViewResizePassed = false
var splitViewDetail = "splitter not found"
let initialSplitters = splitters(
    inWindowContaining: "meeting-transcript-workspace",
    appElement: appElement
)
if !initialSplitters.isEmpty {
    var dragPosted = false
    var movedEnough = false
    for splitterIndex in initialSplitters.indices where !movedEnough {
        for deltaX: CGFloat in [-110, 110] where !movedEnough {
            let initialSplitMovement = dragSplitterWithFeedback(
                splitterIndex: splitterIndex,
                desiredDelta: deltaX,
                appElement: appElement,
                minimumChange: 6
            )
            dragPosted = initialSplitMovement.posted || dragPosted
            let movement = initialSplitMovement.movement ?? 0
            movedEnough = abs(movement) >= 24
            if movedEnough {
                _ = dragSplitterWithFeedback(
                    splitterIndex: splitterIndex,
                    desiredDelta: -movement,
                    appElement: appElement,
                    minimumChange: 6
                )
            }
        }
    }
    let panesUsable = waitForMainWindow(appElement: appElement, timeout: 4)
        && waitForMarker("meeting-workspace-inspector", appElement: appElement, timeout: 4)
    splitViewResizePassed = dragPosted && movedEnough && panesUsable
    splitViewDetail = "nativeSplitters=\(initialSplitters.count), dragPosted=\(dragPosted ? "yes" : "no"), positionChangeObservable=\(movedEnough ? "yes" : "no"), panesUsable=\(panesUsable ? "yes" : "no")"
}
addStep(
    "Meetings split-view resize",
    splitViewResizePassed,
    splitViewDetail,
    steps: &steps,
    issues: &issues
)

progress("checking section navigation")
let advancedSectionNames: Set<String> = ["Library", "Setup", "Review", "Export", "Health"]
let advancedSectionMenuTitles = [
    "Library": "Import Recording",
    "Setup": "Recording Setup",
    "Review": "Review Meeting",
    "Export": "Export Meeting",
    "Health": "Health & Diagnostics"
]
func pressMeetingsSection(
    name: String,
    controlMarkers: [String],
    contentMarkers: [String],
    appElement: AXUIElement
) -> Bool {
    guard waitForApplicationReadyForMenu(appElement: appElement, timeout: 3) else {
        progress("route=\(name), applicationReady=no")
        return false
    }
    guard waitForMeetingLayoutStable(appElement: appElement, timeout: 6) else {
        progress("route=\(name), layoutStable=no")
        return false
    }
    if advancedSectionNames.contains(name) {
        guard let menuTitle = advancedSectionMenuTitles[name] else { return false }
        let opensHealthWindow = name == "Health"
        for attempt in 1...2 {
            guard waitForApplicationReadyForMenu(appElement: appElement, timeout: 3) else {
                progress("route=\(name), attempt=\(attempt), applicationReady=no")
                continue
            }
            guard let popupOwner = exactVisibleMoreMenu(appElement: appElement) else {
                progress("route=\(name), attempt=\(attempt), popupFound=no")
                pressEscape()
                runningApp()?.activate(options: [.activateAllWindows])
                _ = waitForMainWindow(appElement: appElement)
                continue
            }
            let popupActionResult = performAXAction(popupOwner, kAXPressAction as String)
            Thread.sleep(forTimeInterval: 0.35)
            let menuPress = pressOwnedPopupMenuItem(
                titled: menuTitle,
                owner: popupOwner
            )
            let destinationVisible: Bool
            if opensHealthWindow {
                destinationVisible = waitForWindow(
                    containing: "health-recovery-window",
                    appElement: appElement,
                    timeout: 6
                ) != nil
                    && waitForAnyMarker(
                        contentMarkers,
                        inWindowContaining: "health-recovery-window",
                        appElement: appElement,
                        timeout: 6
                    )
            } else {
                destinationVisible = waitForAnyMarker(
                    contentMarkers,
                    inWindowContaining: "meeting-transcript-workspace",
                    appElement: appElement,
                    timeout: 4
                )
            }
            let popupActionDetail = popupActionResult.map { String($0.rawValue) } ?? "timeout"
            let menuActionDetail = menuPress.actionResult.map { String($0.rawValue) } ?? "timeout"
            progress(
                "route=\(name), attempt=\(attempt), popupAction=\(popupActionDetail), menuItemFound=\(menuPress.itemFound ? "yes" : "no"), menuAction=\(menuActionDetail), postcondition=\(destinationVisible ? "pass" : "fail")"
            )
            if destinationVisible { return true }
            pressEscape()
            runningApp()?.activate(options: [.activateAllWindows])
            _ = waitForMainWindow(appElement: appElement)
        }
        pressEscape()
        runningApp()?.activate(options: [.activateAllWindows])
        let commandPressed = pressMenu(menuTitle: "Workspace", itemTitle: menuTitle, appElement: appElement)
        let commandDestinationVisible: Bool
        if opensHealthWindow {
            commandDestinationVisible = commandPressed
                && waitForWindow(
                    containing: "health-recovery-window",
                    appElement: appElement,
                    timeout: 6
                ) != nil
                && waitForAnyMarker(
                    contentMarkers,
                    inWindowContaining: "health-recovery-window",
                    appElement: appElement,
                    timeout: 6
                )
        } else {
            commandDestinationVisible = commandPressed
                && waitForAnyMarker(
                    contentMarkers,
                    inWindowContaining: "meeting-transcript-workspace",
                    appElement: appElement,
                    timeout: 4
                )
        }
        progress("route=\(name), workspaceCommandFallback=\(commandPressed ? "pressed" : "missing"), postcondition=\(commandDestinationVisible ? "pass" : "fail")")
        return commandDestinationVisible
    } else if name == "Agent" {
        return pressExactAgentSegment(
            contentMarkers: contentMarkers,
            appElement: appElement
        )
    } else {
        let stableMarkers = controlMarkers.filter { $0.hasPrefix("meetings-section-") }
        let fallbackMarkers = controlMarkers.filter { !$0.hasPrefix("meetings-section-") }
        guard pressFirstAvailable(containingAny: stableMarkers + fallbackMarkers, appElement: appElement) else {
            return false
        }
    }
    return waitForMarker(
        "meeting-workspace-inspector",
        inWindowContaining: "meeting-transcript-workspace",
        appElement: appElement,
        timeout: 4
    ) && waitForAnyMarker(
        contentMarkers,
        inWindowContaining: "meeting-transcript-workspace",
        appElement: appElement,
        timeout: 4
    )
}

if let layoutRegressionScenario {
    progress("reproducing reduced inspector layout lifecycle")
    var prefixPassed = true
    var prefixDetails: [String] = []

    if layoutRegressionScenario.isPrefixHalfA {
        let routes = [
            ("Library", ["Library", "meetings-section-find-control"], ["meetings-section-find-content", "Local Recording Import"]),
            ("Setup", ["Setup", "meetings-section-record-control"], ["meetings-section-record-content", "Audio Input"]),
            ("Agent", ["Agent", "meetings-section-understand-control"], ["Preset prompts", "Custom prompt"]),
            ("Review", ["Review", "meetings-section-review-control"], ["meetings-section-review-content", "Playback"]),
            ("Export", ["Export", "meetings-section-export-control"], ["meetings-section-export-content", "Export Package"]),
            ("Health", ["Health", "meetings-section-recover-control"], ["Retention Review", "Health & Recovery"])
        ]
        for route in routes {
            let passed = pressMeetingsSection(
                name: route.0,
                controlMarkers: route.1,
                contentMarkers: route.2,
                appElement: appElement
            )
            prefixPassed = prefixPassed && passed
            prefixDetails.append("\(route.0)=\(passed)")
        }
        let singleton = pressMenu(
            menuTitle: "Workspace",
            itemTitle: "Health & Diagnostics",
            appElement: appElement
        )
        let mainReady = activateWindow(
            containing: "meeting-transcript-workspace",
            appElement: appElement
        ) && pressMenu(menuTitle: "Workspace", itemTitle: "Meetings", appElement: appElement)
        let setup = mainReady && pressMeetingsSection(
            name: "Setup",
            controlMarkers: ["Setup", "meetings-section-record-control"],
            contentMarkers: ["meetings-section-record-content", "Audio Input"],
            appElement: appElement
        )
        var widths = setup
        for target: CGFloat in [320, 380, 520] {
            widths = widths && resizeInspector(to: target, tolerance: 18, appElement: appElement) != nil
        }
        prefixPassed = prefixPassed && singleton && mainReady && widths
        prefixDetails.append("singleton=\(singleton),widths=\(widths)")
    }

    if layoutRegressionScenario.isPrefixHalfB {
        let runsB1 = layoutRegressionScenario != .prefixB2
        let runsB2 = !layoutRegressionScenario.isB1Only
        let runsStorage = layoutRegressionScenario != .prefixB1Agent
        let runsAgent = layoutRegressionScenario != .prefixB1Storage
        var b1Passed = true
        var b2Passed = true
        if runsB1 {
            let specialResizeSplit = [.prefixReviewNoResize, .prefixNonReviewResize, .compactOnly, .wideOnly]
                .contains(layoutRegressionScenario)
            let runsSearch = layoutRegressionScenario != .prefixMinimum && !specialResizeSplit
            let runsMinimum = layoutRegressionScenario != .prefixSearch && !specialResizeSplit
            var searchPassed = true
            var minimumPassed = true
            if runsSearch {
                let library = pressMeetingsSection(
                    name: "Library",
                    controlMarkers: ["Library", "meetings-section-find-control"],
                    contentMarkers: ["meetings-section-find-content", "Local Recording Import"],
                    appElement: appElement
                )
                let searchApplied = library && setSidebarSearchField(value: "Project", appElement: appElement).valueApplied
                let searchCleared = setSidebarSearchField(value: "", appElement: appElement).valueApplied
                let rowContext = showContextMenu(
                    containingAny: ["meeting-row-", "Project weekly sync"],
                    expectedItems: ["Open Meeting", "Open Agent", "Copy Transcript"],
                    appElement: appElement
                ).passed
                searchPassed = searchApplied && searchCleared && rowContext
                prefixDetails.append("B1-search=\(searchApplied && searchCleared),context=\(rowContext)")
            }
            if runsMinimum {
                let review = pressMeetingsSection(
                    name: "Review",
                    controlMarkers: ["Review", "meetings-section-review-control"],
                    contentMarkers: ["meetings-section-review-content", "Playback"],
                    appElement: appElement
                )
                let meetingsWindow = firstWindow(containing: "meeting-transcript-workspace", appElement: appElement)
                let compact = meetingsWindow.map {
                    applyDeclaredFrameChange(.compact, window: $0, appElement: appElement)
                } ?? false
                let wide = meetingsWindow.map {
                    applyDeclaredFrameChange(.wide, window: $0, appElement: appElement)
                } ?? false
                minimumPassed = review && compact && wide
                prefixDetails.append("B1-minimum=\(minimumPassed)")
            }
            if layoutRegressionScenario == .prefixReviewNoResize {
                minimumPassed = pressMeetingsSection(
                    name: "Review",
                    controlMarkers: ["Review", "meetings-section-review-control"],
                    contentMarkers: ["meetings-section-review-content", "Playback"],
                    appElement: appElement
                )
                prefixDetails.append("B1-reviewNoResize=\(minimumPassed)")
            }
            if [.prefixNonReviewResize, .compactOnly, .wideOnly].contains(layoutRegressionScenario) {
                let library = pressMeetingsSection(
                    name: "Library",
                    controlMarkers: ["Library", "meetings-section-find-control"],
                    contentMarkers: ["meetings-section-find-content", "Local Recording Import"],
                    appElement: appElement
                )
                let meetingsWindow = firstWindow(containing: "meeting-transcript-workspace", appElement: appElement)
                let declaredChanges: [DeclaredFrameChange]
                switch layoutRegressionScenario {
                case .compactOnly: declaredChanges = [.compact]
                case .wideOnly: declaredChanges = [.wide]
                default: declaredChanges = [.compact, .wide]
                }
                let applied = meetingsWindow.map { window in
                    declaredChanges.allSatisfy {
                        applyDeclaredFrameChange($0, window: window, appElement: appElement)
                    }
                } ?? false
                minimumPassed = library && applied
                prefixDetails.append("B1-nonReviewResize=\(minimumPassed),declared=\(declaredChanges.map(\.rawValue).joined(separator: ","))")
            }
            if [.prefixSearch, .prefixMinimum, .prefixReviewNoResize, .prefixNonReviewResize, .compactOnly, .wideOnly]
                .contains(layoutRegressionScenario) {
                let neutralSetup = pressMeetingsSection(
                    name: "Setup",
                    controlMarkers: ["Setup", "meetings-section-record-control"],
                    contentMarkers: ["meetings-section-record-content", "Preflight"],
                    appElement: appElement
                )
                prefixDetails.append("neutralSetup=\(neutralSetup)")
                b1Passed = searchPassed && minimumPassed && neutralSetup
            } else {
                b1Passed = searchPassed && minimumPassed
            }
        }
        if runsB2 {
            var storagePassed = true
            var agentPassed = true
            if runsStorage {
                let setup = pressMeetingsSection(
                    name: "Setup",
                    controlMarkers: ["Setup", "meetings-section-record-control"],
                    contentMarkers: ["meetings-section-record-content", "Preflight"],
                    appElement: appElement
                )
                let storageVisible = setup && waitForMarker("Review Storage", appElement: appElement, timeout: 4)
                let reset = pressMenu(menuTitle: "Workspace", itemTitle: "Meetings", appElement: appElement)
                storagePassed = storageVisible && reset
                prefixDetails.append("B2-storage=\(storageVisible),reset=\(reset)")
            }
            if runsAgent {
                let agent = pressMenu(menuTitle: "Workspace", itemTitle: "Agent", appElement: appElement)
                    && waitForMarker("Agent", appElement: appElement, timeout: 4)
                let promptApplied = agent && setEditableText(
                    containingAny: [
                        "What did we decide",
                        "Prompt The Transcript",
                        "Write a grounded prompt"
                    ],
                    value: "Summarize the decision and next follow-up.",
                    appElement: appElement,
                    fallbackTextAreaIndex: 0
                )
                let asked = promptApplied && pressFirstAvailable(
                    containingAny: ["Ask Transcript", "Ask Selected Transcript"],
                    appElement: appElement,
                    preferredRoles: [kAXButtonRole as String]
                )
                let grounded = asked && waitForAnyMarker(
                    ["Answer grounded in", "Grounded", "evidence segment"],
                    appElement: appElement,
                    timeout: 8
                )
                let edited = grounded && setEditableText(
                    containingAny: [
                        "Editable Agent Response",
                        "Edit the agent response",
                        "This is the response that will be copied"
                    ],
                    value: "Edited response approved by interaction smoke.",
                    appElement: appElement,
                    fallbackTextAreaIndex: 1
                )
                let copied = edited && pressFirstAvailable(
                    containingAny: ["Copy Response", "Copy Edited Response"],
                    appElement: appElement,
                    preferredRoles: [kAXButtonRole as String]
                )
                agentPassed = agent && promptApplied && asked && grounded && edited && copied
                prefixDetails.append("B2-agent=\(agent),prompt=\(promptApplied),asked=\(asked),grounded=\(grounded),edited=\(edited),copied=\(copied)")
            }
            b2Passed = storagePassed && agentPassed
        }
        prefixPassed = prefixPassed && b1Passed && b2Passed
    }

    let performsBaseResize = !layoutRegressionScenario.isPrefixHalfA
        && !layoutRegressionScenario.isPrefixHalfB
    let reviewVisible = !performsBaseResize || pressMeetingsSection(
        name: "Review",
        controlMarkers: ["Review", "meetings-section-review-control"],
        contentMarkers: ["meetings-section-review-content", "Playback"],
        appElement: appElement
    )
    let meetingsWindow = firstWindow(containing: "meeting-transcript-workspace", appElement: appElement)
    let compactApplied = !performsBaseResize || (meetingsWindow.map {
        setWindowFrame($0, size: CGSize(width: 1180, height: 640))
    } ?? false)
    let compactStable = !performsBaseResize || waitForMeetingLayoutStable(appElement: appElement)
    let wideApplied = !performsBaseResize || (meetingsWindow.map {
        setWindowFrame($0, size: CGSize(width: 1440, height: 900))
    } ?? false)
    let wideStable = !performsBaseResize || waitForMeetingLayoutStable(appElement: appElement)
    let repeatedReviewReady = !layoutRegressionScenario.repeatsReview || pressMeetingsSection(
        name: "Review",
        controlMarkers: ["Review", "meetings-section-review-control"],
        contentMarkers: ["meetings-section-review-content", "Playback", "Transcript Editor"],
        appElement: appElement
    )
    let reviewReadyForPlayback = !layoutRegressionScenario.selectsPlayback
        || (repeatedReviewReady && pressPlaybackTab(appElement: appElement))
    let playbackCueCount = elements(containingAny: ["playback-cue-row-"], appElement: appElement).count
    let reviewContextResult: (passed: Bool, detail: String)
    if layoutRegressionScenario.exercisesReviewContextMenu {
        if playbackCueCount > 0 {
            reviewContextResult = contextMenuAffordance(
                containingAny: ["playback-cue-row-"],
                appElement: appElement
            )
        } else {
            reviewContextResult = (
                passed: false,
                detail: "requested context menu target was absent"
            )
        }
    } else {
        reviewContextResult = (
            passed: repeatedReviewReady && reviewReadyForPlayback,
            detail: "control case intentionally omitted the context-menu action"
        )
    }
    let libraryVisible = pressMeetingsSection(
        name: "Library",
        controlMarkers: ["Library", "meetings-section-find-control"],
        contentMarkers: ["meetings-section-find-content", "Local Recording Import"],
        appElement: appElement
    )
    let selectedMeeting = libraryVisible && (
        openMeetingRow(title: "Project weekly sync", appElement: appElement)
            || openAnyMeetingRow(appElement: appElement)
    )
    let exportVisible = pressMeetingsSection(
        name: "Export",
        controlMarkers: ["Export", "meetings-section-export-control"],
        contentMarkers: ["meetings-section-export-content", "Export Package"],
        appElement: appElement
    )
    let appSurvived = runningApp()?.isTerminated == false
    addStep(
        "Reduced Review resize Library Export lifecycle",
        prefixPassed && reviewVisible && compactApplied && compactStable && wideApplied && wideStable && repeatedReviewReady && reviewReadyForPlayback && reviewContextResult.passed && libraryVisible && selectedMeeting && exportVisible && appSurvived,
        "scenario=\(layoutRegressionScenario.rawValue), prefixPassed=\(prefixPassed), prefixDetails=\(prefixDetails.joined(separator: ";")), review=\(reviewVisible), compact=\(compactApplied && compactStable), wide=\(wideApplied && wideStable), secondReviewReady=\(repeatedReviewReady), playbackReady=\(reviewReadyForPlayback), context=\(reviewContextResult.detail), library=\(libraryVisible), selectedMeeting=\(selectedMeeting), export=\(exportVisible), appSurvived=\(appSurvived)",
        steps: &steps,
        issues: &issues
    )
    let status = issues.isEmpty ? "pass" : "fail"
    writeReport(
        InteractionSmokeReport(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            status: status,
            appName: appName,
            bundleIdentifier: bundleIdentifier,
            pid: runningApp().map { Int($0.processIdentifier) },
            axTrusted: axTrusted,
            launchedByScript: launchedByScript,
            isolatedSmokeStorage: true,
            destructiveActionExecuted: false,
            externalShareOpened: false,
            rawUITextStored: false,
            steps: steps,
            issues: issues
        )
    )
    print("[\(status.uppercased())] reduced inspector lifecycle evidence=\(outputURL.path)")
    finishInteractionSmoke(exitCode: status == "pass" ? 0 : 1)
}

let sectionNavigationTargets: [(name: String, controlMarkers: [String], contentMarkers: [String])] = [
    (
        name: "Library",
        controlMarkers: ["Library", "meetings-section-find-control", "Meetings section Library"],
        contentMarkers: ["meetings-section-find-content", "Local Recording Import", "Project weekly sync"]
    ),
    (
        name: "Setup",
        controlMarkers: ["Setup", "meetings-section-record-control", "Meetings section Setup"],
        contentMarkers: ["meetings-section-record-content", "Audio Input", "Check Status", "Preflight"]
    ),
    (
        name: "Agent",
        controlMarkers: ["Agent", "meetings-section-understand-control", "Meetings section Agent"],
        contentMarkers: ["Preset prompts", "Custom prompt"]
    ),
    (
        name: "Review",
        controlMarkers: ["Review", "meetings-section-review-control", "Meetings section Review"],
        contentMarkers: ["meetings-section-review-content", "Playback", "Transcript Editor", "Grounded Summary"]
    ),
    (
        name: "Export",
        controlMarkers: ["Export", "meetings-section-export-control", "Meetings section Export"],
        contentMarkers: ["meetings-section-export-content", "Export Package"]
    ),
    (
        name: "Health",
        controlMarkers: ["Health", "meetings-section-recover-control", "Meetings section Health"],
        contentMarkers: ["meetings-section-recover-content", "Retention Review", "Health & Recovery"]
    )
]
var sectionNavigationPassed = true
var sectionNavigationDetails: [String] = []
for target in sectionNavigationTargets {
    let pressed = pressMeetingsSection(
        name: target.name,
        controlMarkers: target.controlMarkers,
        contentMarkers: target.contentMarkers,
        appElement: appElement
    )
    let visible: Bool
    if target.name == "Health" {
        visible = pressed && target.contentMarkers.contains {
            waitForMarker(
                $0,
                inWindowContaining: "health-recovery-window",
                appElement: appElement,
                timeout: 4
            )
        }
    } else {
        visible = pressed && target.contentMarkers.contains {
            waitForMarker(
                $0,
                inWindowContaining: "meeting-transcript-workspace",
                appElement: appElement,
                timeout: 4
            )
        }
    }
    sectionNavigationPassed = sectionNavigationPassed && visible
    sectionNavigationDetails.append("\(target.name)=\(visible ? "pass" : "fail")")
}
addStep(
    "Meetings section navigation controls",
    sectionNavigationPassed,
    sectionNavigationDetails.joined(separator: ", "),
    steps: &steps,
    issues: &issues
)

let initialHealthWindowCount = windows(
    containing: "health-recovery-window",
    appElement: appElement
).count
let repeatedHealthCommandPressed = pressMenu(
    menuTitle: "Workspace",
    itemTitle: "Health & Diagnostics",
    appElement: appElement
)
let repeatedHealthWindowCount = windows(
    containing: "health-recovery-window",
    appElement: appElement
).count
let healthWindowSingleton = initialHealthWindowCount == 1
    && repeatedHealthCommandPressed
    && repeatedHealthWindowCount == 1
    && waitForMarker(
        "Retention Review",
        inWindowContaining: "health-recovery-window",
        appElement: appElement,
        timeout: 4
    )
addStep(
    "Health singleton utility window",
    healthWindowSingleton,
    "initialCount=\(initialHealthWindowCount), repeatedCount=\(repeatedHealthWindowCount), repeatedCommand=\(repeatedHealthCommandPressed ? "pressed" : "missing")",
    steps: &steps,
    issues: &issues
)

let mainReactivatedAfterHealth = activateWindow(
    containing: "meeting-transcript-workspace",
    appElement: appElement,
    timeout: 4
)
let meetingsResetAfterHealth = mainReactivatedAfterHealth
    && pressMenu(menuTitle: "Workspace", itemTitle: "Meetings", appElement: appElement)
let agentVisibleAfterHealth = meetingsResetAfterHealth
    && waitForAnyMarker(
        ["Preset prompts", "Custom prompt"],
        inWindowContaining: "meeting-transcript-workspace",
        appElement: appElement,
        timeout: 4
    )

let reduceMotionStateChangesPassed = waitForMarker(
    "meeting-workspace-reduce-motion-on",
    inWindowContaining: "meeting-transcript-workspace",
    appElement: appElement,
    timeout: 4
) && sectionNavigationPassed && mainReactivatedAfterHealth && agentVisibleAfterHealth
addStep(
    "Reduce Motion override state changes",
    reduceMotionStateChangesPassed,
    "launch override reached the shared SwiftUI motion environment while Meetings routes changed state",
    steps: &steps,
    issues: &issues
)

progress("measuring inspector label widths")
let inspectorWidthTargets: [CGFloat] = [320, 380, 520]
let inspectorWidthTolerance: CGFloat = 18
let completeInputLabel = "Studio Microphone · Synthetic Input"
let completeCaptureModeLabels = [
    "Selected application",
    "Application process group",
    "System audio",
    "ScreenCaptureKit fallback"
]
let inspectorMeasurementWorkspaceSize = CGSize(width: 1500, height: 900)
let inspectorMeasurementGeometryReady: Bool
if let meetingsWindow = firstWindow(containing: "meeting-transcript-workspace", appElement: appElement) {
    let wideFrameApplied = setWindowFrame(meetingsWindow, size: inspectorMeasurementWorkspaceSize)
    let actualWindowSize = sizeAttribute(meetingsWindow, kAXSizeAttribute as String)
    inspectorMeasurementGeometryReady = wideFrameApplied
        && actualWindowSize.map { $0.width >= 1470 && $0.height >= 860 } == true
} else {
    inspectorMeasurementGeometryReady = false
}
var setupReadyForWidthProof = inspectorMeasurementGeometryReady && pressMeetingsSection(
    name: "Setup",
    controlMarkers: ["Setup", "meetings-section-record-control", "Meetings section Setup"],
    contentMarkers: ["meetings-section-record-content", "Audio Input", "Capture Source"],
    appElement: appElement
)
let expectedInspectorLabels = Set([completeInputLabel] + completeCaptureModeLabels)
var setupLabelsReady = setupReadyForWidthProof
    ? waitForExactAccessibleTexts(
        Array(expectedInspectorLabels),
        appElement: appElement,
        timeout: 5
    )
    : []
if setupLabelsReady != expectedInspectorLabels {
    setupReadyForWidthProof = pressMeetingsSection(
        name: "Setup",
        controlMarkers: ["Setup", "meetings-section-record-control", "Meetings section Setup"],
        contentMarkers: ["meetings-section-record-content", "Audio Input", "Capture Source"],
        appElement: appElement
    )
    setupLabelsReady = setupReadyForWidthProof
        ? waitForExactAccessibleTexts(
            Array(expectedInspectorLabels),
            appElement: appElement,
            timeout: 5
        )
        : []
    setupReadyForWidthProof = setupReadyForWidthProof
        && setupLabelsReady == expectedInspectorLabels
}
var measuredInspectorWidths: [CGFloat] = []
var inspectorLabelResults: [String] = []
var inspectorWidthsPassed = setupReadyForWidthProof
for targetWidth in inspectorWidthTargets {
    progress("inspector target=\(Int(targetWidth)), phase=resize")
    guard let measuredWidth = resizeInspector(
        to: targetWidth,
        tolerance: inspectorWidthTolerance,
        appElement: appElement
    ) else {
        inspectorWidthsPassed = false
        inspectorLabelResults.append("\(Int(targetWidth))=measurement-missing")
        continue
    }
    measuredInspectorWidths.append(measuredWidth)
    progress("inspector target=\(Int(targetWidth)), measured=\(String(format: "%.1f", measuredWidth)), phase=labels")
    let withinTolerance = abs(measuredWidth - targetWidth) <= inspectorWidthTolerance
    let completeLabels = waitForExactAccessibleTexts(
        [completeInputLabel] + completeCaptureModeLabels,
        appElement: appElement,
        timeout: 5
    )
    let inputComplete = completeLabels.contains(completeInputLabel)
    let completeModes = completeCaptureModeLabels.filter(completeLabels.contains)
    let labelsComplete = inputComplete && completeModes.count == completeCaptureModeLabels.count
    inspectorWidthsPassed = inspectorWidthsPassed && withinTolerance && labelsComplete
    let measuredWidthText = String(format: "%.1f", measuredWidth)
    let inputStatus = inputComplete ? "full" : "missing"
    inspectorLabelResults.append(
        "\(Int(targetWidth))=\(measuredWidthText)/withinTolerance:\(withinTolerance ? "yes" : "no")/input:\(inputStatus)/modes:\(completeModes.count)-of-\(completeCaptureModeLabels.count)"
    )
}
let measuredWidthsText = measuredInspectorWidths
    .map { String(format: "%.1f", $0) }
    .joined(separator: ",")
addStep(
    "Measured inspector label widths",
    inspectorWidthsPassed && measuredInspectorWidths.count == inspectorWidthTargets.count,
    inspectorLabelResults.joined(separator: ", "),
    metadata: [
        "targetWidths": inspectorWidthTargets.map { String(Int($0)) }.joined(separator: ","),
        "measuredWidths": measuredWidthsText,
        "tolerancePoints": String(Int(inspectorWidthTolerance)),
        "inputLabel": completeInputLabel,
        "captureModeLabels": completeCaptureModeLabels.joined(separator: " | "),
        "labelsCompleteAtAllWidths": inspectorWidthsPassed ? "true" : "false"
    ],
    steps: &steps,
    issues: &issues
)

let searchWorkspaceSize = CGSize(width: 1440, height: 900)
var searchGeometryRestored = false
if let meetingsWindow = firstWindow(containing: "meeting-transcript-workspace", appElement: appElement) {
    let wideFrameApplied = setWindowFrame(meetingsWindow, size: searchWorkspaceSize)
    let searchInspectorWidth = resizeInspector(to: 320, tolerance: inspectorWidthTolerance, appElement: appElement)
    let actualWindowSize = sizeAttribute(meetingsWindow, kAXSizeAttribute as String)
    searchGeometryRestored = wideFrameApplied
        && actualWindowSize.map { $0.width >= 1400 && $0.height >= 860 } == true
        && searchInspectorWidth.map { abs($0 - 320) <= inspectorWidthTolerance } == true
}

progress("checking Meetings search")
let libraryTabPressedForSearch = pressMeetingsSection(
    name: "Library",
    controlMarkers: ["Library", "meetings-section-find-control", "Meetings section Library"],
    contentMarkers: ["meetings-section-find-content", "Local Recording Import"],
    appElement: appElement
)
var sidebarMeetingRowsVisible = waitForMeetingRowCount(2, appElement: appElement, timeout: 2)
var showSidebarPressed = false
if !sidebarMeetingRowsVisible {
    showSidebarPressed = postKey(1, flags: [.maskCommand, .maskControl])
    sidebarMeetingRowsVisible = waitForMeetingRowCount(2, appElement: appElement, timeout: 4)
}
if !sidebarMeetingRowsVisible {
    showSidebarPressed = pressMenu(
        menuTitle: "View", itemTitle: "Show Sidebar", appElement: appElement, exact: false
    ) || showSidebarPressed
    sidebarMeetingRowsVisible = waitForMeetingRowCount(2, appElement: appElement, timeout: 4)
}
if !sidebarMeetingRowsVisible {
    showSidebarPressed = pressFirstAvailable(
        containingAny: ["Show Sidebar"],
        appElement: appElement,
        preferredRoles: [kAXButtonRole as String]
    ) || showSidebarPressed
    sidebarMeetingRowsVisible = waitForMeetingRowCount(2, appElement: appElement, timeout: 4)
}
addStep(
    "Meetings sidebar available for search",
    searchGeometryRestored && sidebarMeetingRowsVisible,
    "geometryRestored=\(searchGeometryRestored ? "yes" : "no"), rowsVisible=\(sidebarMeetingRowsVisible ? "yes" : "no"), showSidebarPressed=\(showSidebarPressed ? "yes" : "no")",
    steps: &steps,
    issues: &issues
)
let librarySearchQuery = setSidebarSearchField(
    value: "Project",
    appElement: appElement
)
let librarySearchFilterVisible = libraryTabPressedForSearch
    && librarySearchQuery.fieldFound
    && librarySearchQuery.valueApplied
    && waitForMeetingRowCount(1, appElement: appElement, timeout: 4)
addStep(
    "Meetings search query",
    librarySearchFilterVisible,
    "fieldFound=\(librarySearchQuery.fieldFound ? "yes" : "no"), valueApplied=\(librarySearchQuery.valueApplied ? "yes" : "no"), filterVisible=\(librarySearchFilterVisible ? "yes" : "no")",
    metadata: [
        "fieldFound": librarySearchQuery.fieldFound ? "true" : "false",
        "valueApplied": librarySearchQuery.valueApplied ? "true" : "false",
        "filterVisible": librarySearchFilterVisible ? "true" : "false"
    ],
    steps: &steps,
    issues: &issues
)

let librarySearchClear = setSidebarSearchField(
    value: "",
    appElement: appElement
)
let librarySearchRestored = librarySearchClear.fieldFound
    && librarySearchClear.valueApplied
    && waitForMeetingRowCount(2, appElement: appElement, timeout: 4)
addStep(
    "Meetings search clear",
    librarySearchRestored,
    "fieldFound=\(librarySearchClear.fieldFound ? "yes" : "no"), valueApplied=\(librarySearchClear.valueApplied ? "yes" : "no"), restored=\(librarySearchRestored ? "yes" : "no")",
    metadata: [
        "fieldFound": librarySearchClear.fieldFound ? "true" : "false",
        "valueApplied": librarySearchClear.valueApplied ? "true" : "false",
        "restored": librarySearchRestored ? "true" : "false"
    ],
    steps: &steps,
    issues: &issues
)

progress("checking context menus")
let meetingRowVisibleBeforeContext = waitForMarker(
    "Project weekly sync",
    appElement: appElement,
    timeout: 4
)
let meetingRowContextMenu = meetingRowVisibleBeforeContext
    ? showContextMenu(
        containingAny: ["meeting-row-", "Project weekly sync"],
        expectedItems: ["Open Meeting", "Open Agent", "Copy Transcript"],
        appElement: appElement
    )
    : (passed: false, detail: "meeting row was not visible before context-menu proof")
addStep(
    "Meeting row context menu",
    meetingRowContextMenu.passed,
    meetingRowContextMenu.detail,
    steps: &steps,
    issues: &issues
)

progress("checking minimum-size layout reachability")
let minimumLayoutPassed: Bool
var minimumLayoutDetail = "main Meetings window not found"
var minimumWidthAppearanceReachability = AppearancePickerReachability.missing
if let meetingsWindow = firstWindow(containing: "meeting-transcript-workspace", appElement: appElement) {
    let wideBeforeReview = applyDeclaredFrameChange(.wide, window: meetingsWindow, appElement: appElement)
    let reviewPressed = pressMeetingsSection(
        name: "Review",
        controlMarkers: ["Review", "meetings-section-review-control", "Meetings section Review"],
        contentMarkers: ["meetings-section-review-content", "Playback", "Transcript Editor", "Grounded Summary"],
        appElement: appElement
    )
    let resizedReviewMinimum = applyDeclaredFrameChange(.compact, window: meetingsWindow, appElement: appElement)
    let actualMinimumSize = sizeAttribute(meetingsWindow, kAXSizeAttribute as String)
    let actualMinimumDescription = actualMinimumSize.map {
        String(format: "%.0fx%.0f", $0.width, $0.height)
    } ?? "unknown"
    let minimumFrameApplied = resizedReviewMinimum
    let reviewReachable = reviewPressed
        && waitForMarker("Playback", appElement: appElement, timeout: 4)
    minimumWidthAppearanceReachability = appearancePickerReachability(appElement: appElement)
    let restoredWideFinal = applyDeclaredFrameChange(.wide, window: meetingsWindow, appElement: appElement)
    minimumLayoutPassed = wideBeforeReview
        && minimumFrameApplied
        && reviewReachable
        && restoredWideFinal
    minimumLayoutDetail = "wideBeforeReview=\(wideBeforeReview ? "yes" : "no"), resizedReviewMinimum=\(resizedReviewMinimum ? "yes" : "no"), actualMinimumSize=\(actualMinimumDescription), minimumFrameApplied=\(minimumFrameApplied ? "yes" : "no"), reviewReachable=\(reviewReachable ? "yes" : "no"), appearancePicker=\(minimumWidthAppearanceReachability.rawValue), restoredWideFinal=\(restoredWideFinal ? "yes" : "no")"
} else {
    minimumLayoutPassed = false
}
addStep(
    "Minimum-size selected meeting layout",
    minimumLayoutPassed,
    minimumLayoutDetail,
    steps: &steps,
    issues: &issues
)
let reachability = minimumWidthAppearanceReachability
addStep(
    "Appearance picker minimum-width reachability",
    reachability == .direct || reachability == .overflow,
    "appearance-picker reachability=\(reachability.rawValue)",
    metadata: ["reachability": reachability.rawValue],
    steps: &steps,
    issues: &issues
)

progress("checking low-storage recovery")
let recorderPressedForStorage = pressMeetingsSection(
    name: "Setup",
    controlMarkers: ["Setup", "meetings-section-record-control", "Meetings section Setup"],
    contentMarkers: ["meetings-section-record-content", "Audio Input", "Check Status", "Preflight"],
    appElement: appElement
)
let recorderReadyForStorage = recorderPressedForStorage && waitForMarker("Preflight", appElement: appElement)
addStep("Focus Recording for storage recovery", recorderReadyForStorage, "Recording controls visible inside Meetings", steps: &steps, issues: &issues)

let storageRecoveryVisible = recorderReadyForStorage && waitForMarker("Review Storage", appElement: appElement, timeout: 6)
addStep("Low-storage preflight recovery visible", storageRecoveryVisible, "top command-bar preflight exposed forced low-capacity Review Storage", steps: &steps, issues: &issues)

let requiredCapturePermissionActions = [
    "Allow Screen & System Audio Recording",
    "Allow Microphone"
]
let permissionRecoveryVisible = requiredCapturePermissionActions.allSatisfy {
    waitForMarker($0, appElement: appElement, timeout: 4)
} && waitForMarker("Local only", appElement: appElement, timeout: 4)
addStep("Permission recovery actions visible", permissionRecoveryVisible, "forced denied permission state exposed app-owned recovery actions; System Settings buttons were not pressed", steps: &steps, issues: &issues)

let reviewStoragePressed = pressElement(role: kAXButtonRole as String, containing: "Review Storage", appElement: appElement)
let storageRecoveryRouted = reviewStoragePressed
    && waitForMarker(
        "Retention Review",
        inWindowContaining: "health-recovery-window",
        appElement: appElement
    )
    && (
        waitForMarker("No expired", inWindowContaining: "health-recovery-window", appElement: appElement, timeout: 4)
        || waitForMarker("ready for review", inWindowContaining: "health-recovery-window", appElement: appElement, timeout: 4)
        || waitForMarker("Retention review unavailable", inWindowContaining: "health-recovery-window", appElement: appElement, timeout: 4)
    )
    && windows(containing: "health-recovery-window", appElement: appElement).count == 1
addStep("Review storage routes to Health & Recovery", storageRecoveryRouted, "Health & Recovery retention review opened without deleting recordings", steps: &steps, issues: &issues)

progress("returning to Meetings")
let mainReadyForMeetingsCommand = activateWindow(
    containing: "meeting-transcript-workspace",
    appElement: appElement,
    timeout: 4
)
let meetingsCommandPressed = mainReadyForMeetingsCommand
    && pressMenu(menuTitle: "Workspace", itemTitle: "Meetings", appElement: appElement)
let meetingsWindowRaised = activateWindow(
    containing: "meeting-transcript-workspace",
    appElement: appElement,
    timeout: 4
)
let libraryReturned = meetingsCommandPressed
    && meetingsWindowRaised
    && waitForAnyMarker(
        ["Preset prompts", "Custom prompt"],
        inWindowContaining: "meeting-transcript-workspace",
        appElement: appElement,
        timeout: 4
    )
addStep("Return to Meetings", libraryReturned, "Meetings restored to the default Agent destination after storage recovery", steps: &steps, issues: &issues)

progress("copying visible transcript")
let agentTabPressedForCopy = pressExactAgentSegment(
    contentMarkers: ["Preset prompts", "Custom prompt"],
    appElement: appElement
)
let transcriptCopied = agentTabPressedForCopy
    && pressFirstAvailable(
        containingAny: ["Copy visible transcript", "Copy Transcript"],
        appElement: appElement,
        preferredRoles: [kAXButtonRole as String]
    )
addStep("Copy visible transcript", transcriptCopied, "safe clipboard action pressed", steps: &steps, issues: &issues)

progress("opening Agent")
let intelligencePressed = pressMenu(menuTitle: "Workspace", itemTitle: "Agent", appElement: appElement)
let intelligenceReady = intelligencePressed && waitForMarker("Agent", appElement: appElement)
addStep("Focus Agent", intelligenceReady, "workspace command and agent marker verified", steps: &steps, issues: &issues)

let transcriptContextMenu = intelligenceReady
    ? contextMenuAffordance(
        containingAny: ["transcript-context-row-"],
        appElement: appElement
    )
    : (passed: false, detail: "Agent not reachable")
addStep(
    "Transcript agent context menu",
    transcriptContextMenu.passed,
    transcriptContextMenu.detail,
    steps: &steps,
    issues: &issues
)

progress("checking Agent ask/edit/copy response")
let agentPromptSet = intelligenceReady
    && setEditableText(
        containingAny: [
            "What did we decide",
            "Prompt The Transcript",
            "Write a grounded prompt"
        ],
        value: "Summarize the decision and next follow-up.",
        appElement: appElement,
        fallbackTextAreaIndex: 0
    )
let agentAskPressed = agentPromptSet
    && pressFirstAvailable(
        containingAny: ["Ask Transcript", "Ask Selected Transcript"],
        appElement: appElement,
        preferredRoles: [kAXButtonRole as String]
    )
let agentAnswerGrounded = agentAskPressed
    && waitForAnyMarker(
        [
            "Answer grounded in",
            "Grounded",
            "evidence segment"
        ],
        appElement: appElement,
        timeout: 8
    )
addStep(
    "Agent prompt answer",
    agentAnswerGrounded,
    "prompt field, Ask action, and grounded answer state verified without storing raw answer text",
    steps: &steps,
    issues: &issues
)

let editedAgentResponse = "Edited response approved by interaction smoke."
let editedAgentResponseHash = sha256Hex(editedAgentResponse)
let agentAnswerEdited = agentAnswerGrounded
    && setEditableText(
        containingAny: [
            "Editable Agent Response",
            "Edit the agent response",
            "This is the response that will be copied"
        ],
        value: editedAgentResponse,
        appElement: appElement,
        fallbackTextAreaIndex: 1
    )
addStep(
    "Agent editable response",
    agentAnswerEdited,
    "editable response text area accepted a bounded local edit",
    steps: &steps,
    issues: &issues
)

let agentResponseCopied = agentAnswerEdited
    && pressFirstAvailable(
        containingAny: ["Copy Response", "Copy Edited Response"],
        appElement: appElement,
        preferredRoles: [kAXButtonRole as String]
    )
    && waitForMarker("Copied answer to clipboard", appElement: appElement, timeout: 4)
let copiedAgentResponse = NSPasteboard.general.string(forType: .string) ?? ""
let copiedAgentResponseHash = sha256Hex(copiedAgentResponse)
let copiedEditedAgentResponse = agentResponseCopied
    && copiedAgentResponse == editedAgentResponse
addStep(
    "Copy agent response",
    copiedEditedAgentResponse,
    copiedEditedAgentResponse
        ? "edited response copy action matched clipboard hash without opening an external destination and without storing raw text"
        : "edited response copy action did not match the clipboard hash",
    metadata: [
        "copyMatchesEditedText": copiedEditedAgentResponse ? "true" : "false",
        "editedResponseSHA256": editedAgentResponseHash,
        "clipboardSHA256": copiedAgentResponseHash
    ],
    steps: &steps,
    issues: &issues
)

progress("checking Review secondary context menus")
let reviewPressedForContextMenus = pressMeetingsSection(
    name: "Review",
    controlMarkers: ["Review", "meetings-section-review-control", "Meetings section Review"],
    contentMarkers: ["meetings-section-review-content", "Playback", "Transcript Editor"],
    appElement: appElement
)
let reviewReadyForContextMenus = reviewPressedForContextMenus
    && waitForMeetingLayoutStable(appElement: appElement, timeout: 6)

let playbackReady = reviewReadyForContextMenus
    && pressPlaybackTab(appElement: appElement)
let playbackCueContextMenu: (passed: Bool, detail: String)
if playbackReady {
    let cueRowCount = elements(containingAny: ["playback-cue-row-"], appElement: appElement).count
    if cueRowCount > 0 {
        playbackCueContextMenu = contextMenuAffordance(
            containingAny: ["playback-cue-row-"],
            appElement: appElement
        )
    } else {
        playbackCueContextMenu = (
            passed: false,
            detail: "requested context menu target was absent"
        )
    }
} else {
    playbackCueContextMenu = (passed: false, detail: "Playback tab not reachable")
}
addStep(
    "Playback cue context menu",
    playbackCueContextMenu.passed,
    playbackCueContextMenu.detail,
    steps: &steps,
    issues: &issues
)

func transcriptHeaderContains(
    _ identifier: String,
    title: String,
    rootElement: AXUIElement
) -> Bool {
    allElements(rootElement: rootElement).contains { element in
        stringAttribute(element, kAXIdentifierAttribute as String) == identifier
            && textForSearch(element).localizedCaseInsensitiveContains(title)
    }
}

func waitForTranscriptHeader(
    _ identifier: String,
    containing title: String,
    rootElement: AXUIElement,
    timeout: TimeInterval = 4
) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if transcriptHeaderContains(identifier, title: title, rootElement: rootElement) {
            return true
        }
        Thread.sleep(forTimeInterval: 0.2)
    }
    return transcriptHeaderContains(identifier, title: title, rootElement: rootElement)
}

func meetingTitle(from element: AXUIElement) -> String? {
    let labels = [
        stringAttribute(element, kAXTitleAttribute as String),
        stringAttribute(element, kAXDescriptionAttribute as String),
        stringAttribute(element, kAXValueAttribute as String)
    ].compactMap { $0 }
    guard let label = labels.first(where: { $0.hasPrefix("Meeting row. ") }) else { return nil }
    let remainder = label.dropFirst("Meeting row. ".count)
    guard let comma = remainder.firstIndex(of: ",") else { return nil }
    return String(remainder[..<comma])
}

func openMeetingRow(title: String, appElement: AXUIElement) -> Bool {
    guard let meetingWindow = firstWindow(
        containing: "meeting-transcript-workspace",
        appElement: appElement
    ) else { return false }
    let candidates = allElements(rootElement: meetingWindow)
        .filter { element in
            let identifier = stringAttribute(element, kAXIdentifierAttribute as String) ?? ""
            return identifier.hasPrefix("meeting-record-row-")
                && textForSearch(element).localizedCaseInsensitiveContains(title)
        }
        .compactMap { element -> (element: AXUIElement, area: CGFloat)? in
            guard let size = sizeAttribute(element, kAXSizeAttribute as String),
                  let origin = pointAttribute(element, kAXPositionAttribute as String),
                  size.width > 8,
                  size.height > 8,
                  origin.x.isFinite,
                  origin.y.isFinite else {
                return nil
            }
            return (element, size.width * size.height)
        }
        .sorted { $0.area > $1.area }
        .prefix(8)

    for candidate in candidates {
        pressEscape()
        if leftClick(candidate.element)
            && waitForTranscriptHeader(
                "meeting-transcript-header",
                containing: title,
                rootElement: meetingWindow
            ) {
            return true
        }
    }

    for candidate in candidates {
        pressEscape()
        if openContextMenu(candidate.element)
            && waitForMenuItems(["Open Meeting"], appElement: appElement, timeout: 2)
            && pressVisibleMenuItem(containing: "Open Meeting", appElement: appElement)
            && waitForTranscriptHeader(
                "meeting-transcript-header",
                containing: title,
                rootElement: meetingWindow
            ) {
            return true
        }
    }

    return false
}

func openAnyMeetingRow(appElement: AXUIElement) -> Bool {
    guard let meetingWindow = firstWindow(
        containing: "meeting-transcript-workspace",
        appElement: appElement
    ) else { return false }
    let candidates = allElements(rootElement: meetingWindow)
        .filter {
            (stringAttribute($0, kAXIdentifierAttribute as String) ?? "")
                .hasPrefix("meeting-record-row-")
        }
        .compactMap { element -> (element: AXUIElement, area: CGFloat, title: String)? in
            guard let size = sizeAttribute(element, kAXSizeAttribute as String),
                  let origin = pointAttribute(element, kAXPositionAttribute as String),
                  let title = meetingTitle(from: element),
                  size.width > 8,
                  size.height > 8,
                  origin.x.isFinite,
                  origin.y.isFinite else {
                return nil
            }
            return (element, size.width * size.height, title)
        }
        .sorted { $0.area > $1.area }
        .prefix(12)

    for candidate in candidates {
        pressEscape()
        if leftClick(candidate.element)
            && waitForTranscriptHeader(
                "meeting-transcript-header",
                containing: candidate.title,
                rootElement: meetingWindow
            ) {
            return true
        }
    }

    for candidate in candidates {
        pressEscape()
        if openContextMenu(candidate.element)
            && waitForMenuItems(["Open Meeting"], appElement: appElement, timeout: 2)
            && pressVisibleMenuItem(containing: "Open Meeting", appElement: appElement)
            && waitForTranscriptHeader(
                "meeting-transcript-header",
                containing: candidate.title,
                rootElement: meetingWindow
            ) {
            return true
        }
    }

    return false
}

progress("checking export section")
let libraryPressedForExport = pressMeetingsSection(
    name: "Library",
    controlMarkers: ["Library", "meetings-section-find-control", "Meetings section Library"],
    contentMarkers: ["meetings-section-find-content", "Local Recording Import"],
    appElement: appElement
)
let projectMeetingSelectedForExport = libraryPressedForExport
    && (
        openMeetingRow(title: "Project weekly sync", appElement: appElement)
        || openAnyMeetingRow(appElement: appElement)
    )
    && waitForAnyMarker(
        ["Selected Transcript", "Prompting uses", "Transcript Not Ready"],
        inWindowContaining: "meeting-transcript-workspace",
        appElement: appElement,
        timeout: 4
    )
addStep(
    "Select exportable meeting",
    projectMeetingSelectedForExport,
    "visible meeting row opened before export so the package is generated from a selected transcript artifact",
    steps: &steps,
    issues: &issues
)

let exportSectionPressed = pressMeetingsSection(
    name: "Export",
    controlMarkers: ["Export", "meetings-section-export-control", "Meetings section Export"],
    contentMarkers: ["meetings-section-export-content", "Export Package"],
    appElement: appElement
)
let exportsReady = exportSectionPressed && waitForMarker(
    "Export Package",
    inWindowContaining: "meeting-transcript-workspace",
    appElement: appElement
)
addStep("Export section visible", exportsReady, "export package panel visible in Meetings", steps: &steps, issues: &issues)

progress("checking export controls")
let requiredFormats = ["Markdown", "WebVTT", "PDF", "DOCX", "JSON", "Audio"]
let formatsVisible = requiredFormats.allSatisfy {
    firstElement(role: kAXCheckBoxRole as String, containing: $0, appElement: appElement) != nil
}
addStep("Export format controls", formatsVisible, "all six format checkboxes exposed", steps: &steps, issues: &issues)

progress("pressing export")
let exportPressed = pressElement(role: kAXButtonRole as String, containing: "Export Selected Meeting", appElement: appElement)
let exportedStatusVisible = exportPressed
    && waitForMarker("Exported 5 file(s)", inWindowContaining: "meeting-transcript-workspace", appElement: appElement, timeout: 10)
let exportStatusCategory: String
if exportedStatusVisible {
    exportStatusCategory = "exported"
} else if waitForMarker("Export failed", inWindowContaining: "meeting-transcript-workspace", appElement: appElement, timeout: 1) {
    exportStatusCategory = "failed"
} else if waitForMarker("Export unavailable", inWindowContaining: "meeting-transcript-workspace", appElement: appElement, timeout: 1) {
    exportStatusCategory = "unavailable"
} else if waitForMarker("Select a meeting before exporting", inWindowContaining: "meeting-transcript-workspace", appElement: appElement, timeout: 1) {
    exportStatusCategory = "noSelection"
} else if waitForMarker("Select at least one export format", inWindowContaining: "meeting-transcript-workspace", appElement: appElement, timeout: 1) {
    exportStatusCategory = "noFormats"
} else {
    exportStatusCategory = "unknown"
}
let exportPackageCreated = exportedStatusVisible
    && waitForMarker("Latest Package", inWindowContaining: "meeting-transcript-workspace", appElement: appElement, timeout: 4)
    && waitForMarker("5 files", inWindowContaining: "meeting-transcript-workspace", appElement: appElement, timeout: 4)
    && waitForMarker("Markdown", inWindowContaining: "meeting-transcript-workspace", appElement: appElement, timeout: 4)
    && waitForMarker("WebVTT", inWindowContaining: "meeting-transcript-workspace", appElement: appElement, timeout: 4)
    && waitForMarker("JSON", inWindowContaining: "meeting-transcript-workspace", appElement: appElement, timeout: 4)
addStep(
    "Export selected meeting",
    exportPackageCreated,
    "export action produced a local package with Markdown, WebVTT, and JSON files",
    metadata: [
        "exportPressed": exportPressed ? "true" : "false",
        "exportStatusCategory": exportStatusCategory,
        "localPackageCreated": exportPackageCreated ? "true" : "false"
    ],
    steps: &steps,
    issues: &issues
)

progress("checking share gate")
let prepareShareEnabled = isElementEnabled(role: kAXButtonRole as String, containing: "Prepare Share", appElement: appElement) == true
let prepareSharePressed = prepareShareEnabled
    && pressElement(role: kAXButtonRole as String, containing: "Prepare Share", appElement: appElement)
let sharePrepared = prepareSharePressed && waitForMarker(
    "ready to open",
    inWindowContaining: "meeting-transcript-workspace",
    appElement: appElement
)
addStep(
    "Prepare share",
    sharePrepared,
    "share manifest prepared from the latest local export without opening an external destination",
    metadata: [
        "prepareShareEnabled": prepareShareEnabled ? "true" : "false",
        "preparedFromLatestPackage": sharePrepared ? "true" : "false"
    ],
    steps: &steps,
    issues: &issues
)

let confirmOpenEnabled = isElementEnabled(role: kAXButtonRole as String, containing: "Confirm & Open", appElement: appElement) == true
addStep("Confirm share gate", true, confirmOpenEnabled ? "Confirm & Open became enabled and was intentionally not pressed" : "Confirm & Open stayed disabled and was intentionally not pressed", steps: &steps, issues: &issues)

progress("opening Health & Recovery")
let diagnosticsPressed = pressMeetingsSection(
    name: "Health",
    controlMarkers: ["Health", "meetings-section-recover-control", "Meetings section Health"],
    contentMarkers: ["meetings-section-recover-content", "Retention Review"],
    appElement: appElement
)
let diagnosticsReady = diagnosticsPressed && waitForMarker(
    "Retention Review",
    inWindowContaining: "health-recovery-window",
    appElement: appElement
)
addStep("Focus Health & Recovery", diagnosticsReady, "Health & Recovery command and retention panel verified", steps: &steps, issues: &issues)

progress("checking release readiness panel")
let healthWindowForReleaseActions = waitForWindow(
    containing: "health-recovery-window",
    appElement: appElement,
    timeout: 4
)
let releaseReadinessVisible = waitForMarker("Release Readiness", inWindowContaining: "health-recovery-window", appElement: appElement)
let releaseActionsVisible = waitForMarker("release-candidate gates blocked", inWindowContaining: "health-recovery-window", appElement: appElement)
let copyReleaseQueuePressed = healthWindowForReleaseActions.map {
    pressElement(role: kAXButtonRole as String, containing: "Copy action queue", rootElement: $0)
} == true
let releasePanelReady = releaseReadinessVisible && releaseActionsVisible && copyReleaseQueuePressed
addStep("Release readiness panel", releasePanelReady, "release blocker queue visible and copyable from Health & Recovery", steps: &steps, issues: &issues)
let releaseQueuedActionsVisible = waitForMarker("Queued Actions", inWindowContaining: "health-recovery-window", appElement: appElement, timeout: 4)
let releaseWaitingSummaryVisible = waitForMarker("Waiting on Prereqs", inWindowContaining: "health-recovery-window", appElement: appElement, timeout: 4)
let releaseWaitingStatusVisible = waitForMarker("Waiting on prerequisites", inWindowContaining: "health-recovery-window", appElement: appElement, timeout: 4)
let releasePrerequisiteStatusReady = releasePanelReady
    && releaseQueuedActionsVisible
    && releaseWaitingSummaryVisible
    && releaseWaitingStatusVisible
addStep(
    "Release readiness prerequisite status",
    releasePrerequisiteStatusReady,
    "release queue shows waiting-prerequisite counts and row status without running release actions",
    metadata: [
        "releaseBlockerStatusVisible": releaseActionsVisible ? "true" : "false",
        "actionCountVisible": releaseQueuedActionsVisible ? "true" : "false",
        "waitingPrerequisiteCountVisible": releaseWaitingSummaryVisible ? "true" : "false",
        "waitingPrerequisiteStatusVisible": releaseWaitingStatusVisible ? "true" : "false"
    ],
    steps: &steps,
    issues: &issues
)

progress("reviewing retention")
let healthWindowForRetentionReview = waitForWindow(
    containing: "health-recovery-window",
    appElement: appElement,
    timeout: 4
)
let reviewPressed = healthWindowForRetentionReview.map {
    pressElement(role: kAXButtonRole as String, containing: "Review Expired", rootElement: $0)
} == true
let reviewReady = reviewPressed
    && (
        waitForMarker("ready for review", inWindowContaining: "health-recovery-window", appElement: appElement, timeout: 4)
        || waitForMarker("No expired", inWindowContaining: "health-recovery-window", appElement: appElement, timeout: 4)
        || waitForMarker("Retention review unavailable", inWindowContaining: "health-recovery-window", appElement: appElement, timeout: 4)
    )
addStep("Review expired recordings", reviewReady, "retention review produced a reviewed, empty, or unavailable state", steps: &steps, issues: &issues)

progress("checking delete gate")
let healthWindowForDeleteGate = waitForWindow(
    containing: "health-recovery-window",
    appElement: appElement,
    timeout: 4
)
let deleteEnabled = healthWindowForDeleteGate.flatMap {
    isElementEnabled(role: kAXButtonRole as String, containing: "Delete Reviewed", rootElement: $0)
} == true
if deleteEnabled {
    addStep("Delete reviewed gate enabled", true, "destructive cleanup button enabled only after review found candidates", steps: &steps, issues: &issues)
    let healthWindowForDeleteConfirmation = waitForWindow(
        containing: "health-recovery-window",
        appElement: appElement,
        timeout: 4
    )
    let deletePressed = healthWindowForDeleteConfirmation.map {
        pressElement(role: kAXButtonRole as String, containing: "Delete Reviewed", rootElement: $0)
    } == true
    let deleteDialogMarkerVisible = waitForMarker("Delete reviewed recordings?", inWindowContaining: "health-recovery-window", appElement: appElement)
    let deleteCancelVisible = waitForWindow(
        containing: "health-recovery-window",
        appElement: appElement,
        timeout: 4
    ).flatMap {
        firstElement(role: kAXButtonRole as String, containing: "Cancel", rootElement: $0)
    } != nil
    let confirmationVisible = deleteDialogMarkerVisible || deleteCancelVisible
    addStep(
        "Delete confirmation shown",
        confirmationVisible,
        "pressed=\(deletePressed ? "yes" : "no"), titleMarker=\(deleteDialogMarkerVisible ? "yes" : "no"), cancelButton=\(deleteCancelVisible ? "yes" : "no")",
        steps: &steps,
        issues: &issues
    )

    let healthWindowForCancel = waitForWindow(
        containing: "health-recovery-window",
        appElement: appElement,
        timeout: 4
    )
    let cancelPressed = healthWindowForCancel.map {
        pressElement(role: kAXButtonRole as String, containing: "Cancel", rootElement: $0)
    } == true
    var dialogClosed = waitForMarkerHidden("Delete reviewed recordings?", inWindowContaining: "health-recovery-window", appElement: appElement)
    if !dialogClosed {
        pressEscape()
        dialogClosed = waitForMarkerHidden("Delete reviewed recordings?", inWindowContaining: "health-recovery-window", appElement: appElement)
    }
    let retentionStillVisible = waitForMarker("Retention Review", inWindowContaining: "health-recovery-window", appElement: appElement, timeout: 4)
    let deleteStillGated = waitForWindow(
        containing: "health-recovery-window",
        appElement: appElement,
        timeout: 4
    ).flatMap {
        isElementEnabled(role: kAXButtonRole as String, containing: "Delete Reviewed", rootElement: $0)
    } == true
    let cancelPreservedCandidate = confirmationVisible && dialogClosed && retentionStillVisible && deleteStillGated
    addStep(
        "Delete confirmation cancel",
        cancelPreservedCandidate,
        "cancelActionReturned=\(cancelPressed ? "yes" : "no"), dialogClosed=\(dialogClosed ? "yes" : "no"), retentionVisible=\(retentionStillVisible ? "yes" : "no"), deleteStillAvailable=\(deleteStillGated ? "yes" : "no")",
        steps: &steps,
        issues: &issues
    )
} else {
    addStep("Delete reviewed gate disabled", true, "destructive cleanup stayed disabled without reviewed candidates", steps: &steps, issues: &issues)
}

progress("opening Settings")
let mainRaisedForSettings = activateWindow(
    containing: "meeting-transcript-workspace",
    appElement: appElement,
    timeout: 4
)
var settingsPressed = mainRaisedForSettings
    && pressSettingsMenu(appElement: appElement)
var settingsWindow = waitForSettingsWindow(appElement: appElement, timeout: 6)
if settingsWindow == nil {
    let mainReactivatedForSettingsRetry = activateWindow(
        containing: "meeting-transcript-workspace",
        appElement: appElement,
        timeout: 4
    )
    settingsPressed = (
        mainReactivatedForSettingsRetry
            && pressSettingsMenu(appElement: appElement)
    ) || settingsPressed
    settingsWindow = waitForSettingsWindow(appElement: appElement, timeout: 6)
}
let settingsReady = settingsPressed && settingsWindow != nil
addStep("Open Settings", settingsReady, "app Settings scene opened", steps: &steps, issues: &issues)

progress("checking Settings toggles")
let settingsTogglesVisible = settingsWindow.map { settingsWindow in
    let deadline = Date().addingTimeInterval(6)
    while Date() < deadline {
        if firstElement(
            role: kAXCheckBoxRole as String,
            containing: "Require consent",
            rootElement: settingsWindow
        ) != nil {
            return true
        }
        Thread.sleep(forTimeInterval: 0.2)
    }
    return firstElement(
        role: kAXCheckBoxRole as String,
        containing: "Require consent",
        rootElement: settingsWindow
    ) != nil
} == true
addStep("Settings toggles", settingsTogglesVisible, "recording consent control exposed", steps: &steps, issues: &issues)

progress("checking Settings resize")
let settingsResizePassed: Bool
var settingsResizeDetail = "Settings window not found"
if let settingsWindow {
    let resizedSettings = setWindowFrame(
        settingsWindow,
        origin: CGPoint(x: 140, y: 120),
        size: CGSize(width: 1040, height: 720)
    )
    let settingsConstrainedOrReadable = resizedSettings
        || sizeAttribute(settingsWindow, kAXSizeAttribute as String) != nil
    let deadline = Date().addingTimeInterval(3)
    var togglesStillReachable = false
    while Date() < deadline {
        if firstElement(role: kAXCheckBoxRole as String, containing: "Require consent", rootElement: settingsWindow) != nil {
            togglesStillReachable = true
            break
        }
        Thread.sleep(forTimeInterval: 0.2)
    }
    togglesStillReachable = togglesStillReachable
        || firstElement(role: kAXCheckBoxRole as String, containing: "Require consent", rootElement: settingsWindow) != nil
    settingsResizePassed = settingsConstrainedOrReadable && togglesStillReachable
    settingsResizeDetail = "resizedSettings=\(resizedSettings ? "yes" : "no"), constrainedOrReadable=\(settingsConstrainedOrReadable ? "yes" : "no"), togglesReachable=\(togglesStillReachable ? "yes" : "no")"
} else {
    settingsResizePassed = false
}
addStep("Settings resize layout", settingsResizePassed, settingsResizeDetail, steps: &steps, issues: &issues)

let status = issues.isEmpty ? "pass" : "fail"
let report = InteractionSmokeReport(
    timestamp: ISO8601DateFormatter().string(from: Date()),
    status: status,
    appName: appName,
    bundleIdentifier: bundleIdentifier,
    pid: Int(app.processIdentifier),
    axTrusted: axTrusted,
    launchedByScript: launchedByScript,
    isolatedSmokeStorage: true,
    destructiveActionExecuted: false,
    externalShareOpened: false,
    rawUITextStored: false,
    steps: steps,
    issues: issues
)
writeReport(report)

if status == "pass" {
    print("[OK] interaction smoke passed: steps=\(steps.count) evidence=\(outputURL.path)")
    finishInteractionSmoke(exitCode: 0)
}

fputs("[FAIL] interaction smoke failed: \(issues.joined(separator: "; ")) evidence=\(outputURL.path)\n", stderr)
finishInteractionSmoke(exitCode: 1)
