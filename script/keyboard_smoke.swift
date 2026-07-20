#!/usr/bin/env swift
import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

struct ShortcutTarget {
    var name: String
    var menuTitle: String
    var menuItemTitle: String
    var expectedCommandChar: String
    var expectedCommandModifiers: Int
    var expectedMarker: String
}

struct ShortcutResult: Codable {
    var name: String
    var keyDescription: String
    var commandEquivalentFound: Bool
    var menuItemPressed: Bool
    var expectedMarker: String
    var markerFound: Bool
}

struct KeyboardSmokeReport: Codable {
    var timestamp: String
    var status: String
    var appName: String
    var bundleIdentifier: String
    var pid: Int?
    var axTrusted: Bool
    var launchedByScript: Bool
    var rawUITextStored: Bool
    var shortcuts: [ShortcutResult]
    var issues: [String]
}

let appName = "MeetingVault"
let bundleIdentifier = "com.andrzej.MeetingVault"
let shortcutTargets = [
    ShortcutTarget(name: "Meetings", menuTitle: "Workspace", menuItemTitle: "Meetings", expectedCommandChar: "1", expectedCommandModifiers: 0, expectedMarker: "Ask Selected Transcript"),
    ShortcutTarget(name: "Recording", menuTitle: "Workspace", menuItemTitle: "Recording Setup", expectedCommandChar: "2", expectedCommandModifiers: 0, expectedMarker: "Audio Input"),
    ShortcutTarget(name: "Agent", menuTitle: "Workspace", menuItemTitle: "Agent", expectedCommandChar: "3", expectedCommandModifiers: 0, expectedMarker: "Agent"),
    ShortcutTarget(name: "Health & Recovery", menuTitle: "Workspace", menuItemTitle: "Health & Diagnostics", expectedCommandChar: "4", expectedCommandModifiers: 0, expectedMarker: "Health & Recovery")
]
let safeActionTarget = ShortcutTarget(
    name: "Run Preflight",
    menuTitle: "Recording",
    menuItemTitle: "Run Preflight",
    expectedCommandChar: "P",
    expectedCommandModifiers: 1,
    expectedMarker: "Audio Input"
)

let rootURL = URL(fileURLWithPath: CommandLine.arguments[0])
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let smokeLibraryRoot = FileManager.default.temporaryDirectory
    .appendingPathComponent("MeetingVaultKeyboardSmoke-\(UUID().uuidString)", isDirectory: true)
defer {
    if smokeLibraryRoot.lastPathComponent.hasPrefix("MeetingVaultKeyboardSmoke-") {
        try? FileManager.default.removeItem(at: smokeLibraryRoot)
    }
}
let date = ISO8601DateFormatter().string(from: Date()).prefix(10)
var outputURL = rootURL
    .appendingPathComponent("docs", isDirectory: true)
    .appendingPathComponent("evidence", isDirectory: true)
    .appendingPathComponent("keyboard-smoke-\(date).json")
var launchApp = true

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
    case "--help", "-h":
        print("""
        usage: script/keyboard_smoke.swift [--output PATH] [--skip-launch]

        Launches MeetingVault by default, sends native keyboard shortcuts for
        Workspace navigation plus the safe Run Preflight shortcut, verifies
        expected AX detail markers, and writes privacy-safe JSON evidence.
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
            domain: "KeyboardSmoke",
            code: Int(process.terminationStatus),
            userInfo: [NSLocalizedDescriptionKey: "\(executable) \(arguments.joined(separator: " ")) failed"]
        )
    }
}

func writeReport(_ report: KeyboardSmokeReport) {
    do {
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: outputURL, options: .atomic)
    } catch {
        fputs("failed to write keyboard smoke report: \(error)\n", stderr)
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

func attribute(_ element: AXUIElement, _ name: String) -> Any? {
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
    guard error == .success else { return nil }
    return value
}

func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
    attribute(element, name) as? String
}

func numberAttribute(_ element: AXUIElement, _ name: String) -> NSNumber? {
    attribute(element, name) as? NSNumber
}

func elementsAttribute(_ element: AXUIElement, _ name: String) -> [AXUIElement] {
    attribute(element, name) as? [AXUIElement] ?? []
}

func textForSearch(_ element: AXUIElement) -> String {
    [
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
    guard depth <= 16, output.count < 2_500 else { return }
    output.append(element)
    var children = elementsAttribute(element, kAXChildrenAttribute as String)
    children.append(contentsOf: elementsAttribute(element, kAXVisibleChildrenAttribute as String))
    for child in children {
        walk(child, depth: depth + 1, output: &output)
    }
}

func markerVisible(_ marker: String, appElement: AXUIElement) -> Bool {
    var elements: [AXUIElement] = []
    walk(appElement, output: &elements)
    return elements.contains { textForSearch($0).localizedCaseInsensitiveContains(marker) }
}

func waitForMarker(_ marker: String, appElement: AXUIElement) -> Bool {
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
        if markerVisible(marker, appElement: appElement) {
            return true
        }
        Thread.sleep(forTimeInterval: 0.25)
    }
    return markerVisible(marker, appElement: appElement)
}

func menuItem(for target: ShortcutTarget, appElement: AXUIElement) -> AXUIElement? {
    guard let menuBarValue = attribute(appElement, kAXMenuBarAttribute as String) else {
        return nil
    }
    let menuBar = menuBarValue as! AXUIElement
    for menuBarItem in elementsAttribute(menuBar, kAXChildrenAttribute as String)
        where stringAttribute(menuBarItem, kAXTitleAttribute as String) == target.menuTitle {
        for menu in elementsAttribute(menuBarItem, kAXChildrenAttribute as String) {
            for item in elementsAttribute(menu, kAXChildrenAttribute as String)
                where stringAttribute(item, kAXTitleAttribute as String) == target.menuItemTitle {
                return item
            }
        }
    }
    return nil
}

func commandEquivalentMatches(_ target: ShortcutTarget, item: AXUIElement) -> Bool {
    let commandChar = stringAttribute(item, "AXMenuItemCmdChar") ?? ""
    let commandModifiers = numberAttribute(item, "AXMenuItemCmdModifiers")?.intValue ?? -1
    return commandChar == target.expectedCommandChar
        && commandModifiers == target.expectedCommandModifiers
}

func pressMenuCommand(_ target: ShortcutTarget, appElement: AXUIElement) -> (commandEquivalentFound: Bool, menuItemPressed: Bool) {
    guard let item = menuItem(for: target, appElement: appElement) else {
        return (false, false)
    }
    let shortcutMatches = commandEquivalentMatches(target, item: item)
    let pressError = AXUIElementPerformAction(item, kAXPressAction as CFString)
    Thread.sleep(forTimeInterval: 0.4)
    return (shortcutMatches, pressError == .success)
}

func keyDescription(_ target: ShortcutTarget) -> String {
    let modifiers = target.expectedCommandModifiers == 1
        ? ["Command", "Shift"]
        : ["Command"]
    return (modifiers + [target.expectedCommandChar]).joined(separator: "+")
}

var launchedByScript = false
if launchApp {
    do {
        try run(
            "/bin/bash",
            [
                "script/build_and_run.sh", "--verify", "--workspace", "recorder",
                "--ui-smoke-library-root", smokeLibraryRoot.path,
                "--ui-smoke-storage-bytes", "100000000000",
                "--ui-smoke-permissions", "authorized",
                "--key-provider", "local-file"
            ],
            workingDirectory: rootURL
        )
        launchedByScript = true
        Thread.sleep(forTimeInterval: 3.0)
    } catch {
        let report = KeyboardSmokeReport(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            status: "fail",
            appName: appName,
            bundleIdentifier: bundleIdentifier,
            pid: nil,
            axTrusted: AXIsProcessTrusted(),
            launchedByScript: false,
            rawUITextStored: false,
            shortcuts: [],
            issues: ["launch failed: \(error.localizedDescription)"]
        )
        writeReport(report)
        fputs("[FAIL] keyboard smoke launch failed: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

guard let app = waitForRunningApp() else {
    let report = KeyboardSmokeReport(
        timestamp: ISO8601DateFormatter().string(from: Date()),
        status: "fail",
        appName: appName,
        bundleIdentifier: bundleIdentifier,
        pid: nil,
        axTrusted: AXIsProcessTrusted(),
        launchedByScript: launchedByScript,
        rawUITextStored: false,
        shortcuts: [],
        issues: ["MeetingVault process not running"]
    )
    writeReport(report)
    fputs("[FAIL] MeetingVault process not running\n", stderr)
    exit(1)
}

let axTrusted = AXIsProcessTrusted()
var results: [ShortcutResult] = []
var issues: [String] = []
guard axTrusted else {
    issues.append("Accessibility is not trusted for the calling terminal/app")
    let report = KeyboardSmokeReport(
        timestamp: ISO8601DateFormatter().string(from: Date()),
        status: "blocked",
        appName: appName,
        bundleIdentifier: bundleIdentifier,
        pid: Int(app.processIdentifier),
        axTrusted: false,
        launchedByScript: launchedByScript,
        rawUITextStored: false,
        shortcuts: [],
        issues: issues
    )
    writeReport(report)
    fputs("[BLOCKED] Accessibility permission is not trusted\n", stderr)
    exit(3)
}

app.activate(options: [.activateAllWindows])
Thread.sleep(forTimeInterval: 0.8)
let appElement = AXUIElementCreateApplication(app.processIdentifier)

for target in shortcutTargets {
    let commandResult = pressMenuCommand(target, appElement: appElement)
    let found = waitForMarker(target.expectedMarker, appElement: appElement)
    results.append(
        ShortcutResult(
            name: target.name,
            keyDescription: keyDescription(target),
            commandEquivalentFound: commandResult.commandEquivalentFound,
            menuItemPressed: commandResult.menuItemPressed,
            expectedMarker: target.expectedMarker,
            markerFound: found
        )
    )
    if !commandResult.commandEquivalentFound {
        issues.append("\(target.name) does not expose expected \(keyDescription(target)) command equivalent")
    }
    if !commandResult.menuItemPressed {
        issues.append("\(target.name) menu command could not be pressed through AX")
    }
    if !found {
        issues.append("\(keyDescription(target)) did not reveal \(target.name)")
    }
}

_ = pressMenuCommand(shortcutTargets[1], appElement: appElement)
let recorderVisible = waitForMarker(shortcutTargets[1].expectedMarker, appElement: appElement)
if recorderVisible {
    let commandResult = pressMenuCommand(safeActionTarget, appElement: appElement)
    let safeActionStillVisible = waitForMarker(safeActionTarget.expectedMarker, appElement: appElement)
    results.append(
        ShortcutResult(
            name: safeActionTarget.name,
            keyDescription: keyDescription(safeActionTarget),
            commandEquivalentFound: commandResult.commandEquivalentFound,
            menuItemPressed: commandResult.menuItemPressed,
            expectedMarker: safeActionTarget.expectedMarker,
            markerFound: safeActionStillVisible
        )
    )
    if !commandResult.commandEquivalentFound {
        issues.append("\(safeActionTarget.name) does not expose expected \(keyDescription(safeActionTarget)) command equivalent")
    }
    if !commandResult.menuItemPressed {
        issues.append("\(safeActionTarget.name) menu command could not be pressed through AX")
    }
    if !safeActionStillVisible {
        issues.append("\(keyDescription(safeActionTarget)) did not leave Recording in a recoverable visible state")
    }
} else {
    issues.append("Recording was not visible before safe Run Preflight shortcut")
}

let status = issues.isEmpty ? "pass" : "fail"
let report = KeyboardSmokeReport(
    timestamp: ISO8601DateFormatter().string(from: Date()),
    status: status,
    appName: appName,
    bundleIdentifier: bundleIdentifier,
    pid: Int(app.processIdentifier),
    axTrusted: axTrusted,
    launchedByScript: launchedByScript,
    rawUITextStored: false,
    shortcuts: results,
    issues: issues
)
writeReport(report)

if status == "pass" {
    print("[OK] keyboard smoke passed: shortcuts=\(results.count) evidence=\(outputURL.path)")
    exit(0)
}

fputs("[FAIL] keyboard smoke failed: \(issues.joined(separator: "; ")) evidence=\(outputURL.path)\n", stderr)
exit(1)
