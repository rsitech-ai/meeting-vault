#!/usr/bin/env swift
import AppKit
import ApplicationServices
import Foundation

struct DiskPressureStep: Codable {
    var name: String
    var status: String
    var detail: String
}

struct DiskPressureSmokeReport: Codable {
    var timestamp: String
    var status: String
    var appName: String
    var bundleIdentifier: String
    var pid: Int?
    var axTrusted: Bool
    var diskImageSizeMB: Int
    var mountedVolumeFreeBytes: Int64?
    var mountedVolumeTotalBytes: Int64?
    var isolatedSmokeStorage: Bool
    var storageOverrideUsed: Bool
    var destructiveActionExecuted: Bool
    var privateAudioRecorded: Bool
    var microphoneOpened: Bool
    var rawTranscriptStored: Bool
    var rawAudioStored: Bool
    var rawLogsStored: Bool
    var rawUITextStored: Bool
    var temporaryDiskImageDeleted: Bool
    var steps: [DiskPressureStep]
    var issues: [String]
}

let appName = "MeetingVault"
let bundleIdentifier = "com.andrzej.MeetingVault"
let diskImageSizeMB = 96
let rootURL = URL(fileURLWithPath: CommandLine.arguments[0])
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let date = ISO8601DateFormatter().string(from: Date()).prefix(10)
var outputURL = rootURL
    .appendingPathComponent("docs", isDirectory: true)
    .appendingPathComponent("evidence", isDirectory: true)
    .appendingPathComponent("disk-pressure-smoke-\(date).json")

var iterator = CommandLine.arguments.dropFirst().makeIterator()
while let argument = iterator.next() {
    switch argument {
    case "--output":
        guard let path = iterator.next() else {
            fputs("--output requires a path\n", stderr)
            exit(2)
        }
        outputURL = URL(fileURLWithPath: path)
    case "--help", "-h":
        print("""
        usage: script/disk_pressure_smoke.swift [--output PATH]

        Creates and mounts a tiny APFS disk image, launches MeetingVault with
        that mounted volume as the isolated library root, verifies the Meetings
        low-storage recovery path through the real app, then detaches and
        removes the temporary disk image. This smoke does not use
        --ui-smoke-storage-bytes and does not record audio.
        """)
        exit(0)
    default:
        fputs("unknown argument: \(argument)\n", stderr)
        exit(2)
    }
}

@discardableResult
func run(_ executable: String, _ arguments: [String], workingDirectory: URL? = nil) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.currentDirectoryURL = workingDirectory
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    process.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8) ?? ""
    guard process.terminationStatus == 0 else {
        throw NSError(
            domain: "DiskPressureSmoke",
            code: Int(process.terminationStatus),
            userInfo: [NSLocalizedDescriptionKey: "\(executable) \(arguments.joined(separator: " ")) failed: \(output)"]
        )
    }
    return output
}

func terminateRunningApp() {
    guard let app = runningApp() else { return }
    app.terminate()
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
        if runningApp() == nil {
            return
        }
        Thread.sleep(forTimeInterval: 0.25)
    }
    app.forceTerminate()
}

func writeReport(_ report: DiskPressureSmokeReport) {
    do {
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: outputURL, options: .atomic)
    } catch {
        fputs("failed to write disk-pressure smoke report: \(error)\n", stderr)
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
    AXUIElementSetMessagingTimeout(element, 0.8)
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
    guard depth <= 14, output.count < 1_800 else { return }
    output.append(element)
    var children = elementsAttribute(element, kAXChildrenAttribute as String)
    if children.isEmpty {
        children.append(contentsOf: elementsAttribute(element, kAXVisibleChildrenAttribute as String))
    }
    for child in children {
        walk(child, depth: depth + 1, output: &output)
    }
}

func allElements(appElement: AXUIElement) -> [AXUIElement] {
    var output: [AXUIElement] = []
    for root in elementsAttribute(appElement, kAXWindowsAttribute as String) {
        walk(root, output: &output)
    }
    return output
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

func firstElement(role: String? = nil, containing text: String, appElement: AXUIElement) -> AXUIElement? {
    allElements(appElement: appElement).first { element in
        if let role, stringAttribute(element, kAXRoleAttribute as String) != role {
            return false
        }
        return textForSearch(element).localizedCaseInsensitiveContains(text)
    }
}

func pressElement(role: String? = nil, containing text: String, appElement: AXUIElement) -> Bool {
    guard let element = firstElement(role: role, containing: text, appElement: appElement) else {
        return false
    }
    let error = AXUIElementPerformAction(element, kAXPressAction as CFString)
    Thread.sleep(forTimeInterval: 0.7)
    return error == .success
}

func addStep(_ name: String, _ passed: Bool, _ detail: String, steps: inout [DiskPressureStep], issues: inout [String]) {
    steps.append(DiskPressureStep(name: name, status: passed ? "pass" : "fail", detail: detail))
    if !passed {
        issues.append("\(name): \(detail)")
    }
}

func capacity(for url: URL) -> (free: Int64?, total: Int64?) {
    let keys: Set<URLResourceKey> = [
        .volumeAvailableCapacityForImportantUsageKey,
        .volumeTotalCapacityKey
    ]
    guard let values = try? url.resourceValues(forKeys: keys) else {
        return (nil, nil)
    }
    return (values.volumeAvailableCapacityForImportantUsage, values.volumeTotalCapacity.map(Int64.init))
}

func baseReport(
    status: String,
    pid: Int?,
    axTrusted: Bool,
    freeBytes: Int64?,
    totalBytes: Int64?,
    temporaryDiskImageDeleted: Bool,
    steps: [DiskPressureStep],
    issues: [String]
) -> DiskPressureSmokeReport {
    DiskPressureSmokeReport(
        timestamp: ISO8601DateFormatter().string(from: Date()),
        status: status,
        appName: appName,
        bundleIdentifier: bundleIdentifier,
        pid: pid,
        axTrusted: axTrusted,
        diskImageSizeMB: diskImageSizeMB,
        mountedVolumeFreeBytes: freeBytes,
        mountedVolumeTotalBytes: totalBytes,
        isolatedSmokeStorage: true,
        storageOverrideUsed: false,
        destructiveActionExecuted: false,
        privateAudioRecorded: false,
        microphoneOpened: false,
        rawTranscriptStored: false,
        rawAudioStored: false,
        rawLogsStored: false,
        rawUITextStored: false,
        temporaryDiskImageDeleted: temporaryDiskImageDeleted,
        steps: steps,
        issues: issues
    )
}

let tempRoot = FileManager.default.temporaryDirectory
    .appendingPathComponent("MeetingVaultDiskPressureSmoke-\(UUID().uuidString)", isDirectory: true)
let diskImageURL = tempRoot.appendingPathComponent("pressure.dmg")
let mountURL = tempRoot.appendingPathComponent("mount", isDirectory: true)
let libraryRoot = mountURL.appendingPathComponent("Library", isDirectory: true)
var mounted = false
var tempDeleted = false
var freeBytes: Int64?
var totalBytes: Int64?

defer {
    terminateRunningApp()
    if mounted {
        _ = try? run("/usr/bin/hdiutil", ["detach", mountURL.path, "-quiet"])
    }
    try? FileManager.default.removeItem(at: tempRoot)
    tempDeleted = !FileManager.default.fileExists(atPath: tempRoot.path)
}

do {
    try FileManager.default.createDirectory(at: mountURL, withIntermediateDirectories: true)
    try run(
        "/usr/bin/hdiutil",
        [
            "create",
            "-size",
            "\(diskImageSizeMB)m",
            "-fs",
            "APFS",
            "-volname",
            "MeetingVaultDiskPressureSmoke",
            diskImageURL.path
        ]
    )
    try run("/usr/bin/hdiutil", ["attach", diskImageURL.path, "-mountpoint", mountURL.path, "-nobrowse", "-quiet"])
    mounted = true
    try FileManager.default.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
    let measuredCapacity = capacity(for: libraryRoot)
    freeBytes = measuredCapacity.free
    totalBytes = measuredCapacity.total
} catch {
    try? FileManager.default.removeItem(at: tempRoot)
    tempDeleted = !FileManager.default.fileExists(atPath: tempRoot.path)
    let report = baseReport(
        status: "blocked",
        pid: nil,
        axTrusted: AXIsProcessTrusted(),
        freeBytes: freeBytes,
        totalBytes: totalBytes,
        temporaryDiskImageDeleted: tempDeleted,
        steps: [],
        issues: ["disk image setup failed: \(error.localizedDescription)"]
    )
    writeReport(report)
    fputs("[BLOCKED] disk image setup failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}

var steps: [DiskPressureStep] = []
var issues: [String] = []

do {
    try run(
        "/bin/bash",
        [
            "script/build_and_run.sh",
            "--verify",
            "--workspace",
            "recorder",
            "--ui-smoke-library-root",
            libraryRoot.path,
            "--ui-smoke-retention-days",
            "1"
        ],
        workingDirectory: rootURL
    )
    Thread.sleep(forTimeInterval: 3.0)
} catch {
    tempDeleted = false
    let report = baseReport(
        status: "fail",
        pid: nil,
        axTrusted: AXIsProcessTrusted(),
        freeBytes: freeBytes,
        totalBytes: totalBytes,
        temporaryDiskImageDeleted: tempDeleted,
        steps: steps,
        issues: ["launch failed: \(error.localizedDescription)"]
    )
    writeReport(report)
    fputs("[FAIL] app launch failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}

guard let app = waitForRunningApp() else {
    let report = baseReport(
        status: "fail",
        pid: nil,
        axTrusted: AXIsProcessTrusted(),
        freeBytes: freeBytes,
        totalBytes: totalBytes,
        temporaryDiskImageDeleted: false,
        steps: steps,
        issues: ["MeetingVault process not running"]
    )
    writeReport(report)
    fputs("[FAIL] MeetingVault process not running\n", stderr)
    exit(1)
}

let axTrusted = AXIsProcessTrusted()
guard axTrusted else {
    let report = baseReport(
        status: "blocked",
        pid: Int(app.processIdentifier),
        axTrusted: false,
        freeBytes: freeBytes,
        totalBytes: totalBytes,
        temporaryDiskImageDeleted: false,
        steps: steps,
        issues: ["Accessibility is not trusted for the calling terminal/app"]
    )
    writeReport(report)
    fputs("[BLOCKED] Accessibility permission is not trusted\n", stderr)
    exit(3)
}

app.activate(options: [.activateAllWindows])
Thread.sleep(forTimeInterval: 0.8)
let appElement = AXUIElementCreateApplication(app.processIdentifier)
AXUIElementSetMessagingTimeout(appElement, 0.8)

let recorderReady = waitForMarker("Preflight", appElement: appElement)
addStep("Meetings preflight visible", recorderReady, "Meetings launched from real disk-pressure library root", steps: &steps, issues: &issues)

let readinessCheckPressed = pressElement(role: kAXButtonRole as String, containing: "Check Status", appElement: appElement)
    || pressElement(role: kAXButtonRole as String, containing: "Check Again", appElement: appElement)
let reviewStorageVisible = readinessCheckPressed && waitForMarker("Review Storage", appElement: appElement)
addStep("Real disk-pressure recovery visible", reviewStorageVisible, "normal storage checker exposed Review Storage on constrained APFS volume", steps: &steps, issues: &issues)

let reviewStoragePressed = pressElement(role: kAXButtonRole as String, containing: "Review Storage", appElement: appElement)
let reviewStorageRouted = reviewStoragePressed
    && waitForMarker("Retention Review", appElement: appElement)
    && (
        waitForMarker("No expired", appElement: appElement, timeout: 4)
        || waitForMarker("ready for review", appElement: appElement, timeout: 4)
        || waitForMarker("Retention review unavailable", appElement: appElement, timeout: 4)
    )
addStep("Review Storage routes to Health & Recovery", reviewStorageRouted, "Health & Recovery retention review opened without deleting recordings", steps: &steps, issues: &issues)

terminateRunningApp()
if mounted {
    _ = try? run("/usr/bin/hdiutil", ["detach", mountURL.path, "-quiet"])
    mounted = false
}
try? FileManager.default.removeItem(at: tempRoot)
tempDeleted = !FileManager.default.fileExists(atPath: tempRoot.path)

let status = issues.isEmpty ? "pass" : "fail"
let report = baseReport(
    status: status,
    pid: Int(app.processIdentifier),
    axTrusted: axTrusted,
    freeBytes: freeBytes,
    totalBytes: totalBytes,
    temporaryDiskImageDeleted: tempDeleted,
    steps: steps,
    issues: issues
)
writeReport(report)

if status == "pass" {
    print("[OK] Disk-pressure smoke passed: \(outputURL.path)")
} else {
    fputs("[FAIL] Disk-pressure smoke failed: \(issues.joined(separator: "; "))\n", stderr)
    exit(1)
}
