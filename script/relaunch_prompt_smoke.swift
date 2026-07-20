#!/usr/bin/env swift
import AppKit
import ApplicationServices
import Foundation

struct RelaunchPromptAttempt: Codable {
    var name: String
    var launched: Bool
    var mainWindowVisible: Bool
    var visibleWindowCount: Int
    var keychainPromptDetected: Bool
    var permissionPromptDetected: Bool
    var passwordPromptDetected: Bool
    var unexpectedPromptDetected: Bool
}

struct RelaunchPromptSmokeReport: Codable {
    var timestamp: String
    var status: String
    var appName: String
    var bundleIdentifier: String
    var launchCount: Int
    var isolatedSmokeStorage: Bool
    var keyProvider: String
    var keychainPromptDetected: Bool
    var permissionPromptDetected: Bool
    var passwordPromptDetected: Bool
    var unexpectedPromptDetected: Bool
    var privateAudioRecorded: Bool
    var microphoneOpened: Bool
    var externalNetworkRequested: Bool
    var rawTranscriptStored: Bool
    var rawAudioStored: Bool
    var rawLogsStored: Bool
    var rawUITextStored: Bool
    var attempts: [RelaunchPromptAttempt]
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
    .appendingPathComponent("relaunch-prompt-smoke-\(date).json")
var keyProvider = "local-file"
var outputWasProvided = false
let smokeLibraryRoot = FileManager.default.temporaryDirectory
    .appendingPathComponent("MeetingVaultRelaunchPromptSmoke-\(UUID().uuidString)", isDirectory: true)

var iterator = CommandLine.arguments.dropFirst().makeIterator()
while let argument = iterator.next() {
    switch argument {
    case "--output":
        guard let value = iterator.next() else {
            fputs("--output requires a path\n", stderr)
            exit(2)
        }
        outputURL = URL(fileURLWithPath: value)
        outputWasProvided = true
    case "--key-provider":
        guard let value = iterator.next() else {
            fputs("--key-provider requires local-file or keychain\n", stderr)
            exit(2)
        }
        switch value {
        case "local-file", "keychain":
            keyProvider = value
        default:
            fputs("--key-provider requires local-file or keychain\n", stderr)
            exit(2)
        }
    case "--help", "-h":
        print("""
        usage: script/relaunch_prompt_smoke.swift [--output PATH] [--key-provider local-file|keychain]

        Launches MeetingVault twice with isolated smoke storage. The default
        local-file key provider is reproducible local-ready evidence. Explicit
        keychain mode is bounded operator evidence for prompt regressions. The
        report records prompt booleans/counts only; it does not request
        permissions, open the microphone, record audio, or store raw UI text.
        """)
        exit(0)
    default:
        fputs("unknown argument: \(argument)\n", stderr)
        exit(2)
    }
}

if keyProvider == "keychain", !outputWasProvided {
    outputURL = rootURL
        .appendingPathComponent("docs", isDirectory: true)
        .appendingPathComponent("evidence", isDirectory: true)
        .appendingPathComponent("system-keychain-relaunch-prompt-smoke-\(date).json")
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
            domain: "RelaunchPromptSmoke",
            code: Int(process.terminationStatus),
            userInfo: [NSLocalizedDescriptionKey: "\(executable) \(arguments.joined(separator: " ")) failed"]
        )
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

func terminateRunningApp() {
    runningApp()?.terminate()
    let deadline = Date().addingTimeInterval(8)
    while Date() < deadline {
        if runningApp() == nil {
            return
        }
        Thread.sleep(forTimeInterval: 0.25)
    }
    try? run("/usr/bin/pkill", ["-x", appName], workingDirectory: rootURL)
}

func attribute(_ element: AXUIElement, _ name: String) -> Any? {
    AXUIElementSetMessagingTimeout(element, 0.6)
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
    guard depth <= 10, output.count < 2_000 else { return }
    output.append(element)
    var children = elementsAttribute(element, kAXChildrenAttribute as String)
    children.append(contentsOf: elementsAttribute(element, kAXVisibleChildrenAttribute as String))
    for child in children {
        walk(child, depth: depth + 1, output: &output)
    }
}

func appElements(_ app: NSRunningApplication) -> [AXUIElement] {
    let appElement = AXUIElementCreateApplication(app.processIdentifier)
    var output: [AXUIElement] = []
    for window in elementsAttribute(appElement, kAXWindowsAttribute as String) {
        walk(window, output: &output)
    }
    return output
}

func visibleWindowCount(_ app: NSRunningApplication) -> Int {
    let appElement = AXUIElementCreateApplication(app.processIdentifier)
    return elementsAttribute(appElement, kAXWindowsAttribute as String).count
}

func markerVisible(_ marker: String, app: NSRunningApplication) -> Bool {
    appElements(app).contains {
        textForSearch($0).localizedCaseInsensitiveContains(marker)
    }
}

func windowPromptFlags() -> (keychain: Bool, permission: Bool, password: Bool, unexpected: Bool) {
    guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
        return (false, false, false, false)
    }

    var keychain = false
    var permission = false
    var password = false
    for window in windows {
        let owner = (window[kCGWindowOwnerName as String] as? String ?? "").lowercased()
        let title = (window[kCGWindowName as String] as? String ?? "").lowercased()
        let combined = owner + " " + title
        keychain = keychain
            || combined.contains("securityagent")
            || combined.contains("confidential information")
            || combined.contains("meetingvault wants to use")
        permission = permission
            || combined.contains("would like to access")
            || combined.contains("wants to access")
            || combined.contains("privacy")
            || combined.contains("microphone")
            || combined.contains("speech recognition")
            || combined.contains("screen recording")
        password = password
            || combined.contains("password")
            || combined.contains("allow")
            || combined.contains("always allow")
            || combined.contains("deny")
    }
    return (keychain, permission, password, keychain || permission || password)
}

func launchAttempt(name: String) -> RelaunchPromptAttempt {
    do {
        try run(
            "/bin/bash",
            [
                "script/build_and_run.sh",
                "--verify",
                "--workspace",
                "meetings",
                "--ui-smoke-library-root",
                smokeLibraryRoot.path,
                "--key-provider",
                keyProvider
            ],
            workingDirectory: rootURL
        )
    } catch {
        let flags = windowPromptFlags()
        return RelaunchPromptAttempt(
            name: name,
            launched: false,
            mainWindowVisible: false,
            visibleWindowCount: 0,
            keychainPromptDetected: flags.keychain,
            permissionPromptDetected: flags.permission,
            passwordPromptDetected: flags.password,
            unexpectedPromptDetected: flags.unexpected
        )
    }

    guard let app = waitForRunningApp() else {
        let flags = windowPromptFlags()
        return RelaunchPromptAttempt(
            name: name,
            launched: false,
            mainWindowVisible: false,
            visibleWindowCount: 0,
            keychainPromptDetected: flags.keychain,
            permissionPromptDetected: flags.permission,
            passwordPromptDetected: flags.password,
            unexpectedPromptDetected: flags.unexpected
        )
    }

    app.activate(options: [.activateAllWindows])
    Thread.sleep(forTimeInterval: 1.0)
    let flags = windowPromptFlags()
    return RelaunchPromptAttempt(
        name: name,
        launched: true,
        mainWindowVisible: markerVisible("Live Recording", app: app),
        visibleWindowCount: visibleWindowCount(app),
        keychainPromptDetected: flags.keychain,
        permissionPromptDetected: flags.permission,
        passwordPromptDetected: flags.password,
        unexpectedPromptDetected: flags.unexpected
    )
}

func writeReport(_ report: RelaunchPromptSmokeReport) {
    do {
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: outputURL, options: .atomic)
    } catch {
        fputs("failed to write relaunch prompt smoke report: \(error.localizedDescription)\n", stderr)
    }
}

terminateRunningApp()
let first = launchAttempt(name: "first-launch")
terminateRunningApp()
let second = launchAttempt(name: "relaunch")

let attempts = [first, second]
let issues = attempts.flatMap { attempt -> [String] in
    var values: [String] = []
    if !attempt.launched {
        values.append("\(attempt.name): app did not launch")
    }
    if !attempt.mainWindowVisible {
        values.append("\(attempt.name): main Meetings window was not visible")
    }
    if attempt.keychainPromptDetected {
        values.append("\(attempt.name): keychain prompt detected")
    }
    if attempt.permissionPromptDetected {
        values.append("\(attempt.name): permission prompt detected")
    }
    if attempt.passwordPromptDetected {
        values.append("\(attempt.name): password/allow prompt detected")
    }
    return values
}

let keychainPromptDetected = attempts.contains { $0.keychainPromptDetected }
let permissionPromptDetected = attempts.contains { $0.permissionPromptDetected }
let passwordPromptDetected = attempts.contains { $0.passwordPromptDetected }
let unexpectedPromptDetected = attempts.contains { $0.unexpectedPromptDetected }
let status = issues.isEmpty ? "pass" : "fail"

let report = RelaunchPromptSmokeReport(
    timestamp: ISO8601DateFormatter().string(from: Date()),
    status: status,
    appName: appName,
    bundleIdentifier: bundleIdentifier,
    launchCount: attempts.count,
    isolatedSmokeStorage: true,
    keyProvider: keyProvider,
    keychainPromptDetected: keychainPromptDetected,
    permissionPromptDetected: permissionPromptDetected,
    passwordPromptDetected: passwordPromptDetected,
    unexpectedPromptDetected: unexpectedPromptDetected,
    privateAudioRecorded: false,
    microphoneOpened: false,
    externalNetworkRequested: false,
    rawTranscriptStored: false,
    rawAudioStored: false,
    rawLogsStored: false,
    rawUITextStored: false,
    attempts: attempts,
    issues: issues
)
writeReport(report)

if status == "pass" {
    print("[OK] relaunch prompt smoke passed: launches=\(attempts.count) evidence=\(outputURL.path)")
    exit(0)
}

fputs("[FAIL] relaunch prompt smoke failed: \(issues.joined(separator: "; ")) evidence=\(outputURL.path)\n", stderr)
exit(1)
