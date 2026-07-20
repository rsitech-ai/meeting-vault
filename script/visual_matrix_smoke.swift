#!/usr/bin/env swift
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ImageIO

struct WorkspaceTarget {
    var name: String
    var rawValue: String
    var expectedMarker: String
}

struct WindowSize {
    var name: String
    var size: CGSize
}

struct AppearanceTarget {
    var name: String
    var rawValue: String
}

struct AccessibilityTraitTarget {
    var name: String
    var rawValue: String
    var reduceMotion: String
    var contrast: String
}

struct VisualSmokeSnapshot: Codable {
    var appearance: String
    var accessibilityVariant: String
    var reduceMotion: String
    var contrast: String
    var workspace: String
    var sizeName: String
    var requestedWidth: Int
    var requestedHeight: Int
    var windowID: UInt32
    var screenshotPath: String
    var fileBytes: Int
    var pixelWidth: Int
    var pixelHeight: Int
    var uniqueSampleColors: Int
    var nonBlank: Bool
    var opaque: Bool
    var nearBlackPixelRatio: Double
    var artifactFree: Bool
}

struct VisualSmokeReport: Codable {
    var timestamp: String
    var status: String
    var profile: String
    var appName: String
    var bundleIdentifier: String
    var axTrusted: Bool
    var launchedByScript: Bool
    var rawUITextStored: Bool
    var sensitiveUITextDetected: Bool
    var screenshotsStored: Bool
    var imagesDiscardedAfterReport: Bool
    var snapshots: [VisualSmokeSnapshot]
    var issues: [String]
}

let appName = "MeetingVault"
let bundleIdentifier = "com.andrzej.MeetingVault"
let workspaceTargets = [
    WorkspaceTarget(name: "Meetings", rawValue: "meetings", expectedMarker: "Meeting Details"),
    WorkspaceTarget(name: "Import", rawValue: "library", expectedMarker: "Local Recording Import"),
    WorkspaceTarget(name: "Setup", rawValue: "recorder", expectedMarker: "primary-audio-input-selection"),
    WorkspaceTarget(name: "Agent", rawValue: "intelligence", expectedMarker: "Preset prompts"),
    WorkspaceTarget(name: "Health", rawValue: "diagnostics", expectedMarker: "Health & Recovery")
]
let sizes = [
    WindowSize(name: "minimum", size: CGSize(width: 1180, height: 640)),
    WindowSize(name: "wide", size: CGSize(width: 1440, height: 900))
]
let appearances = [
    AppearanceTarget(name: "Light", rawValue: "light"),
    AppearanceTarget(name: "Dark", rawValue: "dark")
]
let accessibilityTraits = [
    AccessibilityTraitTarget(name: "Default", rawValue: "default", reduceMotion: "system", contrast: "system"),
    AccessibilityTraitTarget(name: "Reduce Motion", rawValue: "reduce-motion", reduceMotion: "on", contrast: "system"),
    AccessibilityTraitTarget(name: "Increased Contrast", rawValue: "increased-contrast", reduceMotion: "system", contrast: "increased")
]

let rootURL = URL(fileURLWithPath: CommandLine.arguments[0])
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let date = ISO8601DateFormatter().string(from: Date()).prefix(10)
var outputURL = rootURL
    .appendingPathComponent("docs", isDirectory: true)
    .appendingPathComponent("evidence", isDirectory: true)
    .appendingPathComponent("visual-matrix-\(date).json")
var imageDirectory = rootURL
    .appendingPathComponent("docs", isDirectory: true)
    .appendingPathComponent("evidence", isDirectory: true)
    .appendingPathComponent("visual-matrix-\(date)", isDirectory: true)
var profile = "baseline"
var sizeProfile = "all"
var appearanceProfile = "all"
var workspaceProfile = "all"
var outputOverridden = false
var imageDirectoryOverridden = false
var discardImagesAfterReport = false

var iterator = CommandLine.arguments.dropFirst().makeIterator()
while let argument = iterator.next() {
    switch argument {
    case "--profile":
        guard let value = iterator.next() else {
            fputs("--profile requires baseline, accessibility, or full\n", stderr)
            exit(2)
        }
        guard ["baseline", "accessibility", "full"].contains(value) else {
            fputs("--profile requires baseline, accessibility, or full\n", stderr)
            exit(2)
        }
        profile = value
    case "--size":
        guard let value = iterator.next() else {
            fputs("--size requires minimum, wide, or all\n", stderr)
            exit(2)
        }
        guard ["minimum", "wide", "all"].contains(value) else {
            fputs("--size requires minimum, wide, or all\n", stderr)
            exit(2)
        }
        sizeProfile = value
    case "--appearance-filter":
        guard let value = iterator.next() else {
            fputs("--appearance-filter requires light, dark, or all\n", stderr)
            exit(2)
        }
        guard ["light", "dark", "all"].contains(value) else {
            fputs("--appearance-filter requires light, dark, or all\n", stderr)
            exit(2)
        }
        appearanceProfile = value
    case "--workspace-filter":
        guard let value = iterator.next() else {
            fputs("--workspace-filter requires meetings, library, recorder, intelligence, diagnostics, or all\n", stderr)
            exit(2)
        }
        guard value == "all" || workspaceTargets.contains(where: { $0.rawValue == value }) else {
            fputs("workspace filter did not match a supported workspace\n", stderr)
            exit(2)
        }
        workspaceProfile = value
    case "--output":
        guard let path = iterator.next() else {
            fputs("--output requires a path\n", stderr)
            exit(2)
        }
        outputURL = URL(fileURLWithPath: path)
        outputOverridden = true
    case "--image-dir":
        guard let path = iterator.next() else {
            fputs("--image-dir requires a path\n", stderr)
            exit(2)
        }
        imageDirectory = URL(fileURLWithPath: path, isDirectory: true)
        imageDirectoryOverridden = true
    case "--discard-images-after-report":
        discardImagesAfterReport = true
    case "--help", "-h":
        print("""
        usage: script/visual_matrix_smoke.swift [--profile baseline|accessibility|full] [--size minimum|wide|all] [--appearance-filter light|dark|all] [--workspace-filter meetings|library|recorder|intelligence|diagnostics|all] [--output PATH] [--image-dir PATH] [--discard-images-after-report]

        Stages MeetingVault once, then relaunches the app for a bounded visual
        matrix using --workspace --appearance --reduce-motion --contrast,
        verifies an expected AX detail marker, captures minimum and wide
        screenshots, and writes a privacy-safe JSON report. The report stores
        no raw UI text. --discard-images-after-report removes the generated
        raster directory after validation only when this invocation created
        that directory. A pre-existing image directory is rejected and kept.

        Profiles:
          baseline       Light/Dark, Meetings focus sections, default accessibility.
          accessibility  Light/Dark, Meetings and Recording, Reduce Motion and Increased Contrast.
          full           Light/Dark, Meetings focus sections, all accessibility variants.
        """)
        exit(0)
    default:
        fputs("unknown argument: \(argument)\n", stderr)
        exit(2)
    }
}

if profile == "accessibility" {
    if !outputOverridden {
        outputURL = rootURL
            .appendingPathComponent("docs", isDirectory: true)
            .appendingPathComponent("evidence", isDirectory: true)
            .appendingPathComponent("visual-accessibility-matrix-\(date).json")
    }
    if !imageDirectoryOverridden {
        imageDirectory = rootURL
            .appendingPathComponent("docs", isDirectory: true)
            .appendingPathComponent("evidence", isDirectory: true)
            .appendingPathComponent("visual-accessibility-matrix-\(date)", isDirectory: true)
    }
}

let suffixParts = [
    sizeProfile == "all" ? nil : sizeProfile,
    appearanceProfile == "all" ? nil : appearanceProfile
].compactMap { $0 }

if !suffixParts.isEmpty {
    let suffix = "-" + suffixParts.joined(separator: "-")
    if !outputOverridden {
        let baseURL = outputURL.deletingPathExtension()
        outputURL = baseURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(baseURL.lastPathComponent)\(suffix)")
            .appendingPathExtension("json")
    }
    if !imageDirectoryOverridden {
        imageDirectory = imageDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("\(imageDirectory.lastPathComponent)\(suffix)", isDirectory: true)
    }
}

var matrixWorkspaces: [WorkspaceTarget]
let matrixAccessibilityTraits: [AccessibilityTraitTarget]
let matrixSizes: [WindowSize]
let matrixAppearances: [AppearanceTarget]
switch profile {
case "accessibility":
    matrixWorkspaces = workspaceTargets.filter { ["meetings", "recorder"].contains($0.rawValue) }
    matrixAccessibilityTraits = accessibilityTraits.filter { $0.rawValue != "default" }
case "full":
    matrixWorkspaces = workspaceTargets
    matrixAccessibilityTraits = accessibilityTraits
default:
    matrixWorkspaces = workspaceTargets
    matrixAccessibilityTraits = accessibilityTraits.filter { $0.rawValue == "default" }
}
if workspaceProfile != "all" {
    matrixWorkspaces = workspaceTargets.filter { $0.rawValue == workspaceProfile }
    if matrixWorkspaces.isEmpty {
        fputs("workspace filter did not match a supported workspace\n", stderr)
        exit(2)
    }
}
if sizeProfile == "all" {
    matrixSizes = sizes
} else {
    matrixSizes = sizes.filter { $0.name == sizeProfile }
}
if appearanceProfile == "all" {
    matrixAppearances = appearances
} else {
    matrixAppearances = appearances.filter { $0.rawValue == appearanceProfile }
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
            domain: "VisualMatrixSmoke",
            code: Int(process.terminationStatus),
            userInfo: [NSLocalizedDescriptionKey: "\(executable) \(arguments.joined(separator: " ")) failed"]
        )
    }
}

func output(_ executable: String, _ arguments: [String], workingDirectory: URL) throws -> String {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.currentDirectoryURL = workingDirectory
    process.standardOutput = pipe
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw NSError(
            domain: "VisualMatrixSmoke",
            code: Int(process.terminationStatus),
            userInfo: [NSLocalizedDescriptionKey: "\(executable) \(arguments.joined(separator: " ")) failed"]
        )
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(decoding: data, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

func stageAppBundle() throws -> URL {
    let path = try output("/bin/bash", ["script/stage_app_bundle.sh"], workingDirectory: rootURL)
    return URL(fileURLWithPath: path)
}

func terminateRunningApp() {
    let applications = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
    applications.forEach { $0.terminate() }
    let gracefulDeadline = Date().addingTimeInterval(3)
    while Date() < gracefulDeadline,
          NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).contains(where: { !$0.isTerminated }) {
        Thread.sleep(forTimeInterval: 0.1)
    }
    let remaining = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        .filter { !$0.isTerminated }
    remaining.forEach { $0.forceTerminate() }
    let forcedDeadline = Date().addingTimeInterval(2)
    while Date() < forcedDeadline,
          NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).contains(where: { !$0.isTerminated }) {
        Thread.sleep(forTimeInterval: 0.1)
    }
}

func launchApp(bundleURL: URL, appArguments: [String]) throws {
    terminateRunningApp()
    try run(
        "/usr/bin/open",
        ["-n", bundleURL.path, "--args"] + appArguments,
        workingDirectory: rootURL
    )
}

func writeReport(_ report: VisualSmokeReport) {
    do {
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: outputURL, options: .atomic)
    } catch {
        fputs("failed to write visual smoke report: \(error)\n", stderr)
    }
}

func safeEvidencePath(for url: URL) -> String {
    let rootPath = rootURL.standardizedFileURL.path + "/"
    let path = url.standardizedFileURL.path
    guard path.hasPrefix(rootPath) else {
        return "generated/\(url.lastPathComponent)"
    }
    return String(path.dropFirst(rootPath.count))
}

enum ImageDirectoryOwnershipError: LocalizedError {
    case preexistingTarget(URL)

    var errorDescription: String? {
        switch self {
        case let .preexistingTarget(url):
            "Refusing to use pre-existing image directory: \(url.path)"
        }
    }
}

func prepareImageDirectory(
    _ directory: URL,
    fileManager: FileManager = .default
) throws -> Bool {
    let directory = directory.standardizedFileURL
    if fileManager.fileExists(atPath: directory.path) {
        throw ImageDirectoryOwnershipError.preexistingTarget(directory)
    }

    try fileManager.createDirectory(
        at: directory.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    do {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        return true
    } catch {
        if fileManager.fileExists(atPath: directory.path) {
            throw ImageDirectoryOwnershipError.preexistingTarget(directory)
        }
        throw error
    }
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

func elementsAttribute(_ element: AXUIElement, _ name: String) -> [AXUIElement] {
    attribute(element, name) as? [AXUIElement] ?? []
}

func textForSearch(_ element: AXUIElement) -> String {
    [
        stringAttribute(element, kAXTitleAttribute),
        stringAttribute(element, kAXDescriptionAttribute),
        stringAttribute(element, kAXHelpAttribute),
        stringAttribute(element, kAXValueAttribute),
        stringAttribute(element, kAXIdentifierAttribute)
    ]
    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
    .filter { !$0.isEmpty }
    .joined(separator: " ")
}

struct SensitiveUITextMarker {
    var label: String
    var value: String
}

func sensitiveUITextMarkerLabels(appElement: AXUIElement) -> [String] {
    var markers = [
        SensitiveUITextMarker(label: "/Users/", value: "/Users/"),
        SensitiveUITextMarker(label: "/Volumes/", value: "/Volumes/"),
        SensitiveUITextMarker(label: "/private/var/folders/", value: "/private/var/folders/"),
        SensitiveUITextMarker(label: "/var/folders/", value: "/var/folders/"),
        SensitiveUITextMarker(label: "/Downloads/", value: "/Downloads/"),
        SensitiveUITextMarker(label: "/Music/", value: "/Music/"),
        SensitiveUITextMarker(label: "Audio Hijack", value: "Audio Hijack")
    ]
    if let hostName = Host.current().localizedName?.trimmingCharacters(in: .whitespacesAndNewlines),
       !hostName.isEmpty {
        markers.append(SensitiveUITextMarker(label: "current-device-name", value: hostName))
    }
    var elements: [AXUIElement] = []
    walk(appElement, output: &elements)
    let searchableText = elements.map(textForSearch).joined(separator: "\n")
    return markers.compactMap { marker in
        searchableText.localizedCaseInsensitiveContains(marker.value) ? marker.label : nil
    }
}

func resetVisualSmokeLibraryRoot(_ root: URL) throws {
    guard root.standardizedFileURL.path == "/tmp/MeetingVault-Visual-Smoke" else {
        throw NSError(
            domain: "VisualMatrixSmoke",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "Refusing to reset unexpected visual smoke root"]
        )
    }
    if FileManager.default.fileExists(atPath: root.path) {
        try FileManager.default.removeItem(at: root)
    }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
}

func walk(_ element: AXUIElement, depth: Int = 0, output: inout [AXUIElement]) {
    guard depth <= 14, output.count < 2_500 else { return }
    output.append(element)
    for child in elementsAttribute(element, kAXChildrenAttribute) {
        walk(child, depth: depth + 1, output: &output)
    }
}

func runningApp() -> NSRunningApplication? {
    let bundled = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        .filter { !$0.isTerminated }
        .max { $0.processIdentifier < $1.processIdentifier }
    return bundled
        ?? NSWorkspace.shared.runningApplications
            .filter { !$0.isTerminated && $0.localizedName == appName }
            .max { $0.processIdentifier < $1.processIdentifier }
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

func waitForWindow(appElement: AXUIElement) -> AXUIElement? {
    let deadline = Date().addingTimeInterval(20)
    while Date() < deadline {
        if let window = elementsAttribute(appElement, kAXWindowsAttribute).first {
            return window
        }
        Thread.sleep(forTimeInterval: 0.25)
    }
    return nil
}

func windowContains(_ marker: String, window: AXUIElement) -> Bool {
    var elements: [AXUIElement] = []
    walk(window, output: &elements)
    return elements.contains {
        textForSearch($0).localizedCaseInsensitiveContains(marker)
    }
}

func waitForWindow(
    containing marker: String,
    appElement: AXUIElement,
    timeout: TimeInterval = 20
) -> AXUIElement? {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let window = elementsAttribute(appElement, kAXWindowsAttribute).first(where: {
            windowContains(marker, window: $0)
        }) {
            return window
        }
        Thread.sleep(forTimeInterval: 0.25)
    }
    return elementsAttribute(appElement, kAXWindowsAttribute).first(where: {
        windowContains(marker, window: $0)
    })
}

func workspaceVisible(_ workspace: WorkspaceTarget, appElement: AXUIElement) -> Bool {
    var elements: [AXUIElement] = []
    walk(appElement, output: &elements)
    return elements.contains { element in
        let text = textForSearch(element)
        return text.localizedCaseInsensitiveContains(workspace.expectedMarker)
    }
}

func waitForWorkspaceVisible(_ workspace: WorkspaceTarget, appElement: AXUIElement) -> Bool {
    let deadline = Date().addingTimeInterval(12)
    while Date() < deadline {
        if workspaceVisible(workspace, appElement: appElement) {
            return true
        }
        Thread.sleep(forTimeInterval: 0.35)
    }
    return workspaceVisible(workspace, appElement: appElement)
}

func containsRuntimeFailure(appElement: AXUIElement) -> Bool {
    var elements: [AXUIElement] = []
    walk(appElement, output: &elements)
    return elements.contains { element in
        let text = textForSearch(element)
        return text.localizedCaseInsensitiveContains("Encrypted library unavailable")
            || text.localizedCaseInsensitiveContains("Runtime initialization failed")
    }
}

func setWindow(_ window: AXUIElement, size: CGSize) -> Bool {
    var point = CGPoint(x: 80, y: 80)
    var requestedSize = size
    guard let pointValue = AXValueCreate(.cgPoint, &point),
          let sizeValue = AXValueCreate(.cgSize, &requestedSize) else {
        return false
    }
    let positionError = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, pointValue)
    let sizeError = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
    Thread.sleep(forTimeInterval: 1.2)
    return positionError == .success && sizeError == .success
}

func appWindowID(pid: pid_t) -> UInt32? {
    guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
        return nil
    }
    let matching = windows.first { info in
        let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t
        let layer = info[kCGWindowLayer as String] as? Int
        let alpha = info[kCGWindowAlpha as String] as? Double ?? 1
        return ownerPID == pid && layer == 0 && alpha > 0
    }
    return matching?[kCGWindowNumber as String] as? UInt32
}

func appWindowID(pid: pid_t, titled title: String) -> UInt32? {
    guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
        return nil
    }
    let matching = windows.first { info in
        let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t
        let layer = info[kCGWindowLayer as String] as? Int
        let alpha = info[kCGWindowAlpha as String] as? Double ?? 1
        let windowTitle = info[kCGWindowName as String] as? String
        return ownerPID == pid && layer == 0 && alpha > 0 && windowTitle == title
    }
    return matching?[kCGWindowNumber as String] as? UInt32
}

func windowLookupDiagnostic(pid: pid_t, app: NSRunningApplication) -> String {
    let appElement = AXUIElementCreateApplication(pid)
    let axWindows = elementsAttribute(appElement, kAXWindowsAttribute)
    let axDetails = axWindows.map { window in
        let title = stringAttribute(window, kAXTitleAttribute) ?? "nil"
        let position = attribute(window, kAXPositionAttribute).map { String(describing: $0) } ?? "nil"
        let size = attribute(window, kAXSizeAttribute).map { String(describing: $0) } ?? "nil"
        return "AX title=\(title) position=\(position) size=\(size)"
    }.joined(separator: "; ")
    let cgWindows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
    let cgDetails = cgWindows.filter {
        ($0[kCGWindowOwnerPID as String] as? pid_t) == pid
    }.map { info in
        let id = info[kCGWindowNumber as String].map { String(describing: $0) } ?? "nil"
        let title = info[kCGWindowName as String].map { String(describing: $0) } ?? "nil"
        let onScreen = info[kCGWindowIsOnscreen as String].map { String(describing: $0) } ?? "nil"
        let layer = info[kCGWindowLayer as String].map { String(describing: $0) } ?? "nil"
        let alpha = info[kCGWindowAlpha as String].map { String(describing: $0) } ?? "nil"
        let bounds = info[kCGWindowBounds as String].map { String(describing: $0) } ?? "nil"
        return "id=\(id) title=\(title) onScreen=\(onScreen) layer=\(layer) alpha=\(alpha) bounds=\(bounds)"
    }.joined(separator: "; ")
    return "pid=\(pid) active=\(app.isActive) terminated=\(app.isTerminated) \(axDetails) CG entries=\(cgDetails)"
}

func reportWindowLookupTimeout(pid: pid_t, app: NSRunningApplication) {
    fputs("[visual] window lookup timeout \(windowLookupDiagnostic(pid: pid, app: app))\n", stderr)
}

func waitForAppWindowID(
    pid: pid_t,
    app: NSRunningApplication,
    timeout: TimeInterval = 15
) -> UInt32? {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if app.isTerminated {
            reportWindowLookupTimeout(pid: pid, app: app)
            return nil
        }
        if let windowID = appWindowID(pid: pid) {
            return windowID
        }
        app.activate(options: [.activateAllWindows])
        Thread.sleep(forTimeInterval: 0.2)
    }
    if let windowID = appWindowID(pid: pid) {
        return windowID
    }
    reportWindowLookupTimeout(pid: pid, app: app)
    return nil
}

func waitForAppWindowID(
    pid: pid_t,
    app: NSRunningApplication,
    titled title: String,
    timeout: TimeInterval = 15
) -> UInt32? {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if app.isTerminated {
            reportWindowLookupTimeout(pid: pid, app: app)
            return nil
        }
        if let windowID = appWindowID(pid: pid, titled: title) {
            return windowID
        }
        app.activate(options: [.activateAllWindows])
        Thread.sleep(forTimeInterval: 0.2)
    }
    if let windowID = appWindowID(pid: pid, titled: title) {
        return windowID
    }
    reportWindowLookupTimeout(pid: pid, app: app)
    return nil
}

func imageHasAlpha(_ image: CGImage) -> Bool {
    switch image.alphaInfo {
    case .first, .last, .premultipliedFirst, .premultipliedLast, .alphaOnly:
        true
    case .none, .noneSkipFirst, .noneSkipLast:
        false
    @unknown default:
        true
    }
}

func flattenPNGToOpaque(
    _ image: CGImage,
    appearance: AppearanceTarget,
    to url: URL
) -> CGImage? {
    guard let context = CGContext(
        data: nil,
        width: image.width,
        height: image.height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else {
        return nil
    }

    let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    let backingColor = appearance.rawValue == "dark"
        ? NSColor(calibratedWhite: 0.10, alpha: 1)
        : NSColor(calibratedWhite: 0.96, alpha: 1)
    context.setFillColor(backingColor.cgColor)
    context.fill(bounds)
    context.draw(image, in: bounds)

    guard let opaqueImage = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(
              url as CFURL,
              "public.png" as CFString,
              1,
              nil
          )
    else {
        return nil
    }
    CGImageDestinationAddImage(destination, opaqueImage, nil)
    guard CGImageDestinationFinalize(destination),
          let source = CGImageSourceCreateWithURL(url as CFURL, nil)
    else {
        return nil
    }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

func captureWindow(
    windowID: UInt32,
    appearance: AppearanceTarget,
    to url: URL
) -> CGImage? {
    try? FileManager.default.removeItem(at: url)
    let rawURL = url.deletingPathExtension().appendingPathExtension("raw.png")
    try? FileManager.default.removeItem(at: rawURL)
    defer { try? FileManager.default.removeItem(at: rawURL) }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    process.arguments = ["-x", "-l\(windowID)", rawURL.path]
    let finished = DispatchSemaphore(value: 0)
    do {
        try process.run()
    } catch {
        return nil
    }
    DispatchQueue.global(qos: .utility).async {
        process.waitUntilExit()
        finished.signal()
    }
    guard finished.wait(timeout: .now() + 8) == .success else {
        process.terminate()
        return nil
    }
    guard process.terminationStatus == 0,
          let source = CGImageSourceCreateWithURL(rawURL as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        return nil
    }
    return flattenPNGToOpaque(image, appearance: appearance, to: url)
}

func sampledRGBABytes(in image: CGImage, width: Int, height: Int) -> [UInt8]? {
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    let rendered = bytes.withUnsafeMutableBytes { buffer -> Bool in
        guard let context = CGContext(
            data: buffer.baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                | CGBitmapInfo.byteOrder32Big.rawValue
        ) else {
            return false
        }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    return rendered ? bytes : nil
}

func uniqueColorCount(in image: CGImage) -> Int {
    guard let bytes = sampledRGBABytes(in: image, width: 64, height: 64) else {
        return 0
    }

    var colors = Set<UInt32>()
    for offset in stride(from: 0, to: bytes.count, by: 4) {
        let packed = UInt32(bytes[offset]) << 24
            | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8
            | UInt32(bytes[offset + 3])
        colors.insert(packed)
    }
    return colors.count
}

let lightAppearanceNearBlackThreshold = 0.08

func nearBlackPixelRatio(in image: CGImage) -> Double {
    let width = 128
    let height = 128
    guard let bytes = sampledRGBABytes(in: image, width: width, height: height) else {
        return 1
    }

    var nearBlackPixels = 0
    for offset in stride(from: 0, to: bytes.count, by: 4) {
        if bytes[offset] < 24,
           bytes[offset + 1] < 24,
           bytes[offset + 2] < 24 {
            nearBlackPixels += 1
        }
    }
    return Double(nearBlackPixels) / Double(width * height)
}

let imageDirectoryCreatedByRun: Bool
do {
    imageDirectoryCreatedByRun = try prepareImageDirectory(imageDirectory)
} catch {
    fputs("\(error.localizedDescription)\n", stderr)
    exit(2)
}
let smokeLibraryRoot = URL(
    fileURLWithPath: "/tmp/MeetingVault-Visual-Smoke",
    isDirectory: true
).standardizedFileURL
try resetVisualSmokeLibraryRoot(smokeLibraryRoot)
if let existingScreenshots = try? FileManager.default.contentsOfDirectory(
    at: imageDirectory,
    includingPropertiesForKeys: nil
) {
    for url in existingScreenshots where url.pathExtension.lowercased() == "png" {
        try? FileManager.default.removeItem(at: url)
    }
}

let axTrusted = AXIsProcessTrusted()
var snapshots: [VisualSmokeSnapshot] = []
var issues: [String] = []
var sensitiveUITextDetected = false

if !axTrusted {
    issues.append("Accessibility is not trusted for the calling terminal/app")
} else {
    let appBundleURL: URL
    do {
        appBundleURL = try stageAppBundle()
    } catch {
        issues.append("Could not stage MeetingVault app bundle: \(error.localizedDescription)")
        appBundleURL = URL(fileURLWithPath: "")
    }

    for appearance in matrixAppearances {
        for accessibilityTrait in matrixAccessibilityTraits {
            for workspace in matrixWorkspaces {
                guard issues.filter({ $0.hasPrefix("Could not stage MeetingVault") }).isEmpty else {
                    continue
                }
                var appArguments = [
                    "--workspace",
                    workspace.rawValue,
                    "--appearance",
                    appearance.rawValue,
                    "--reduce-motion",
                    accessibilityTrait.reduceMotion,
                    "--contrast",
                    accessibilityTrait.contrast,
                    "--ui-smoke-library-root",
                    smokeLibraryRoot.path,
                    "--ui-smoke-storage-bytes",
                    "21474836480",
                    "--ui-smoke-permissions",
                    "denied"
                ]
                if workspace.rawValue == "meetings" {
                    appArguments += ["--meeting-inspector", "details"]
                }
                do {
                    try launchApp(
                        bundleURL: appBundleURL,
                        appArguments: appArguments
                    )
                } catch {
                    issues.append("Could not launch \(appearance.name) \(accessibilityTrait.name) \(workspace.name): \(error.localizedDescription)")
                    continue
                }

                guard let app = waitForRunningApp() else {
                    issues.append("MeetingVault did not finish launching for \(appearance.name) \(accessibilityTrait.name) \(workspace.name)")
                    continue
                }

                app.activate(options: [.activateAllWindows])
                let pid = app.processIdentifier
                let appElement = AXUIElementCreateApplication(pid)
                let targetWindow = workspace.rawValue == "diagnostics"
                    ? waitForWindow(containing: "health-recovery-window", appElement: appElement)
                    : waitForWindow(appElement: appElement)
                guard let window = targetWindow else {
                    issues.append("No AX window appeared for \(appearance.name) \(accessibilityTrait.name) \(workspace.name)")
                    continue
                }

                if !waitForWorkspaceVisible(workspace, appElement: appElement) {
                    issues.append("Expected marker was not visible for \(appearance.name) \(accessibilityTrait.name) \(workspace.name)")
                    continue
                }
                Thread.sleep(forTimeInterval: 2.5)
                let sensitiveMarkers = sensitiveUITextMarkerLabels(appElement: appElement)
                if !sensitiveMarkers.isEmpty {
                    sensitiveUITextDetected = true
                    issues.append(
                        "Sensitive UI text detected for \(appearance.name) \(accessibilityTrait.name) \(workspace.name): \(sensitiveMarkers.joined(separator: ", "))"
                    )
                    continue
                }
                if containsRuntimeFailure(appElement: appElement) {
                    issues.append("Runtime initialization failed for \(appearance.name) \(accessibilityTrait.name) \(workspace.name)")
                    continue
                }

                for windowSize in matrixSizes {
                    if !setWindow(window, size: windowSize.size) {
                        issues.append("Could not resize \(appearance.name) \(accessibilityTrait.name) \(workspace.name) window to \(windowSize.name)")
                    }

                    let resolvedWindowID = workspace.rawValue == "diagnostics"
                        ? waitForAppWindowID(pid: pid, app: app, titled: "Health & Recovery")
                        : waitForAppWindowID(pid: pid, app: app)
                    guard let windowID = resolvedWindowID else {
                        issues.append("No on-screen window id for \(appearance.name) \(accessibilityTrait.name) \(workspace.name) \(windowSize.name)")
                        continue
                    }

                    let fileName = "\(appearance.rawValue)-\(accessibilityTrait.rawValue)-\(workspace.rawValue)-\(windowSize.name).png"
                    let screenshotURL = imageDirectory.appendingPathComponent(fileName)
                    var acceptedImage: CGImage?
                    var acceptedNearBlackRatio = 1.0
                    var capturedCandidate = false
                    for captureAttempt in 1...3 {
                        guard let candidate = captureWindow(
                            windowID: windowID,
                            appearance: appearance,
                            to: screenshotURL
                        ) else {
                            Thread.sleep(forTimeInterval: 0.8)
                            continue
                        }
                        capturedCandidate = true
                        let candidateNearBlackRatio = nearBlackPixelRatio(in: candidate)
                        let artifactFree = appearance.rawValue != "light"
                            || candidateNearBlackRatio <= lightAppearanceNearBlackThreshold
                        if artifactFree {
                            acceptedImage = candidate
                            acceptedNearBlackRatio = candidateNearBlackRatio
                            break
                        }
                        let ratioText = String(format: "%.4f", candidateNearBlackRatio)
                        fputs(
                            "[visual] retrying corrupt light frame attempt=\(captureAttempt) ratio=\(ratioText) file=\(fileName)\n",
                            stderr
                        )
                        Thread.sleep(forTimeInterval: 0.8)
                    }
                    guard let image = acceptedImage else {
                        let prefix = capturedCandidate
                            ? "Corrupt light-appearance capture"
                            : "Could not capture"
                        issues.append("\(prefix) \(appearance.name) \(accessibilityTrait.name) \(workspace.name) \(windowSize.name)")
                        continue
                    }

                    let fileBytes = ((try? FileManager.default.attributesOfItem(atPath: screenshotURL.path)[.size]) as? NSNumber)?.intValue ?? 0
                    let uniqueColors = uniqueColorCount(in: image)
                    let imageHasAlpha = imageHasAlpha(image)
                    snapshots.append(
                        VisualSmokeSnapshot(
                            appearance: appearance.name,
                            accessibilityVariant: accessibilityTrait.name,
                            reduceMotion: accessibilityTrait.reduceMotion,
                            contrast: accessibilityTrait.contrast,
                            workspace: workspace.name,
                            sizeName: windowSize.name,
                            requestedWidth: Int(windowSize.size.width),
                            requestedHeight: Int(windowSize.size.height),
                            windowID: windowID,
                            screenshotPath: safeEvidencePath(for: screenshotURL),
                            fileBytes: fileBytes,
                            pixelWidth: image.width,
                            pixelHeight: image.height,
                            uniqueSampleColors: uniqueColors,
                            nonBlank: fileBytes > 10_000 && uniqueColors > 16,
                            opaque: !imageHasAlpha,
                            nearBlackPixelRatio: acceptedNearBlackRatio,
                            artifactFree: true
                        )
                    )
                }
            }
        }
    }
}

let expectedSnapshotCount = matrixAppearances.count * matrixAccessibilityTraits.count * matrixWorkspaces.count * matrixSizes.count
if snapshots.count != expectedSnapshotCount {
    issues.append("Expected \(expectedSnapshotCount) snapshots, captured \(snapshots.count)")
}
let blankSnapshots = snapshots.filter { !$0.nonBlank }
if !blankSnapshots.isEmpty {
    issues.append("Blank or low-detail screenshots: \(blankSnapshots.map { "\($0.workspace)-\($0.sizeName)" }.joined(separator: ", "))")
}
let transparentSnapshots = snapshots.filter { !$0.opaque }
if !transparentSnapshots.isEmpty {
    issues.append(
        "Screenshots with alpha: \(transparentSnapshots.map { "\($0.workspace)-\($0.sizeName)" }.joined(separator: ", "))"
    )
}

terminateRunningApp()
try? FileManager.default.removeItem(at: smokeLibraryRoot)
var imagesDiscardedAfterReport = false
if discardImagesAfterReport {
    if !imageDirectoryCreatedByRun {
        issues.append("Refused to discard screenshots because this invocation did not create the image directory")
    } else {
        do {
            if FileManager.default.fileExists(atPath: imageDirectory.path) {
                try FileManager.default.removeItem(at: imageDirectory)
            }
            imagesDiscardedAfterReport = !FileManager.default.fileExists(atPath: imageDirectory.path)
        } catch {
            issues.append("Could not discard generated screenshots: \(error.localizedDescription)")
        }
    }
}
let screenshotsStored = FileManager.default.fileExists(atPath: imageDirectory.path) && !snapshots.isEmpty
let status = issues.isEmpty ? "pass" : "fail"
let report = VisualSmokeReport(
    timestamp: ISO8601DateFormatter().string(from: Date()),
    status: status,
    profile: profile,
    appName: appName,
    bundleIdentifier: bundleIdentifier,
    axTrusted: axTrusted,
    launchedByScript: axTrusted,
    rawUITextStored: false,
    sensitiveUITextDetected: sensitiveUITextDetected,
    screenshotsStored: screenshotsStored,
    imagesDiscardedAfterReport: imagesDiscardedAfterReport,
    snapshots: snapshots,
    issues: issues
)
writeReport(report)

if status == "pass" {
    print("[OK] visual matrix smoke passed: snapshots=\(snapshots.count) evidence=\(outputURL.path)")
    exit(0)
}

fputs("[FAIL] visual matrix smoke failed: \(issues.joined(separator: "; "))\n", stderr)
exit(1)
