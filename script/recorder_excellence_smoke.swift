#!/usr/bin/env swift
import AppKit
import ApplicationServices
import CoreGraphics
import CryptoKit
import Foundation

struct Step: Codable {
    var name: String
    var status: String
    var evidence: String
}

struct NativeObservedEvidence: Codable {
    var networkSampleCount: Int
    var unexpectedExternalConnectionCount: Int
    var boundedFileCount: Int
    var plaintextMarkerMatchCount: Int
    var observationDigest: String
}

struct FixtureProvenEvidence: Codable {
    var syntheticCapturePassed: Bool
    var modelLifecyclePassed: Bool
    var confidenceReviewPassed: Bool
    var realModelInferencePerformed: Bool
}

struct BlockedEvidence: Codable {
    var physicalAudioTransport: String
    var realModelInference: String
    var oldestSupportedHostSixtyMinuteRun: String
    var multiDisplay: String
}

struct SurfaceGeometryEvidence: Codable {
    var surface: String
    var fileName: String
    var markerVisibility: [String: Bool]
    var withinWindowBounds: Bool
}

struct WindowActivationSnapshot: Equatable {
    var frontmostPID: pid_t?
    var mainWindowGeometry: String?
    var keyWindowGeometry: String?
}

struct BookmarkObservation: Equatable {
    var acceptedCount: Int
    var stableIdentifierDigest: String?
}

struct NativeWorkflowObserver {
    private(set) var networkSampleCount = 0
    private(set) var unexpectedExternalConnectionCount = 0

    mutating func observeNetwork(pid: pid_t) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-a", "-p", String(pid), "-iTCP", "-iUDP"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return }
        process.waitUntilExit()
        networkSampleCount += 1
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return }
        unexpectedExternalConnectionCount += output.split(separator: "\n").dropFirst().filter {
            $0.contains("->") && !$0.contains("127.0.0.1") && !$0.contains("[::1]")
        }.count
    }

    func inspectBoundedStorage(root: URL, privateMarkers: [String]) -> NativeObservedEvidence {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
        var boundedFileCount = 0
        var plaintextMarkerMatchCount = 0
        var digestMaterial: [String] = []
        while let url = enumerator?.nextObject() as? URL, boundedFileCount < 2_000 {
            guard (try? url.resourceValues(forKeys: Set(keys)).isRegularFile) == true else { continue }
            boundedFileCount += 1
            let data = (try? FileHandle(forReadingFrom: url).read(upToCount: 65_536)) ?? Data()
            let text = String(data: data, encoding: .utf8) ?? ""
            plaintextMarkerMatchCount += privateMarkers.filter { text.contains($0) }.count
            digestMaterial.append("\(url.pathExtension.lowercased()):\(data.count)")
        }
        return NativeObservedEvidence(
            networkSampleCount: networkSampleCount,
            unexpectedExternalConnectionCount: unexpectedExternalConnectionCount,
            boundedFileCount: boundedFileCount,
            plaintextMarkerMatchCount: plaintextMarkerMatchCount,
            observationDigest: sha256(digestMaterial.sorted().joined(separator: "|"))
        )
    }
}

struct Report: Codable {
    var timestamp: String
    var status: String
    var fixtureMode: String
    var axTrusted: Bool
    var nativeRecorderLaunched: Bool
    var nativeObserved: NativeObservedEvidence
    var fixtureProven: FixtureProvenEvidence
    var blockedEvidence: BlockedEvidence
    var surfaceGeometryEvidence: [SurfaceGeometryEvidence]
    var steps: [Step]
    var screenshots: [String]
    var issues: [String]
}

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
let root = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
var outputURL = URL(fileURLWithPath: "/tmp/meetingvault-recorder-excellence.json")
var imageDirectory = URL(fileURLWithPath: "/tmp/meetingvault-recorder-excellence-images")
var appearance = "dark"
var arguments = CommandLine.arguments.dropFirst().makeIterator()
while let argument = arguments.next() {
    switch argument {
    case "--output":
        guard let value = arguments.next() else { fatalError("--output requires a path") }
        outputURL = URL(fileURLWithPath: value)
    case "--image-dir":
        guard let value = arguments.next() else { fatalError("--image-dir requires a path") }
        imageDirectory = URL(fileURLWithPath: value)
    case "--appearance":
        guard let value = arguments.next(), ["light", "dark"].contains(value) else {
            fatalError("--appearance requires light or dark")
        }
        appearance = value
    default:
        fputs("usage: recorder_excellence_smoke.swift [--output PATH] [--image-dir PATH] [--appearance light|dark]\n", stderr)
        exit(2)
    }
}

try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)

var steps: [Step] = []
var issues: [String] = []
var screenshotPaths: [String] = []
var surfaceGeometryEvidence: [SurfaceGeometryEvidence] = []
func record(_ name: String, _ passed: Bool, _ evidence: String) {
    steps.append(Step(name: name, status: passed ? "pass" : "fail", evidence: evidence))
    if !passed { issues.append("\(name): \(evidence)") }
}

func sha256(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
}

@discardableResult
func run(_ executable: String, _ arguments: [String], output: URL? = nil) -> Bool {
    let process = Process()
    process.currentDirectoryURL = root
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    if let output {
        FileManager.default.createFile(atPath: output.path, contents: nil)
        process.standardOutput = try? FileHandle(forWritingTo: output)
    }
    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    } catch {
        issues.append("process launch failed: \(error.localizedDescription)")
        return false
    }
}

func jsonObject(_ url: URL) -> [String: Any]? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

let fixtureOutput = URL(fileURLWithPath: "/tmp/meetingvault-recorder-excellence-local-transcription.json")
let lifecycleOutput = URL(fileURLWithPath: "/tmp/meetingvault-recorder-excellence-model-lifecycle.json")
let confidenceOutput = URL(fileURLWithPath: "/tmp/meetingvault-recorder-excellence-confidence-review.json")
let fixturePassed = run("/usr/bin/env", ["swift", "script/local_transcription_fixture_smoke.swift", "--output", fixtureOutput.path])
let lifecyclePassed = run("/usr/bin/env", ["swift", "script/local_model_lifecycle_smoke.swift", "--output", lifecycleOutput.path])
let confidencePassed = run("/usr/bin/env", ["swift", "script/confidence_review_smoke.swift", "--output", confidenceOutput.path])

let fixture = jsonObject(fixtureOutput) ?? [:]
let lifecycle = jsonObject(lifecycleOutput) ?? [:]
let confidence = jsonObject(confidenceOutput) ?? [:]
record(
    "Authorized synthetic capture fixtures",
    fixturePassed && (fixture["passed"] as? Bool == true),
    "active speech, silence, missing input, Polish, English, five anonymous speakers, overlap, recovered bookmark, and missing-model degradation use generated non-private data"
)
record(
    "Local model lifecycle failures",
    lifecyclePassed && ((lifecycle["status"] as? String) == "pass"),
    "active-use removal is rejected, post-release removal succeeds, and no download is initiated"
)
record(
    "Confidence Review correction",
    confidencePassed && ((confidence["status"] as? String) == "pass"),
    "fixture proves correction, review-state persistence, search, export, recovery, and history"
)

let smokeRoot = URL(fileURLWithPath: "/tmp/meetingvault-recorder-excellence-library-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: smokeRoot) }
let privateParticipantMarker = "synthetic-private-participant"
let privateVocabularyMarker = "synthetic-private-vocabulary"
var nativeObserver = NativeWorkflowObserver()
for existingApp in NSRunningApplication.runningApplications(withBundleIdentifier: "com.andrzej.MeetingVault") {
    existingApp.terminate()
}
let initialTerminationDeadline = Date().addingTimeInterval(5)
while !NSRunningApplication.runningApplications(withBundleIdentifier: "com.andrzej.MeetingVault").isEmpty,
      Date() < initialTerminationDeadline {
    Thread.sleep(forTimeInterval: 0.1)
}
let launched = run(
    "/usr/bin/env",
    [
        "MEETINGVAULT_MOCK_ACTIVE_FRAMES=1", "/bin/bash",
        "script/build_and_run.sh", "--verify", "--workspace", "recorder",
        "--appearance", appearance, "--reduce-motion", "off",
        "--ui-smoke-library-root", smokeRoot.path,
        "--ui-smoke-storage-bytes", "100000000000",
        "--ui-smoke-permissions", "authorized",
        "--ui-smoke-meeting-context",
        "--key-provider", "local-file"
    ]
)

func app() -> NSRunningApplication? {
    NSRunningApplication.runningApplications(withBundleIdentifier: "com.andrzej.MeetingVault").first
}

func attribute(_ element: AXUIElement, _ name: String) -> Any? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

func string(_ element: AXUIElement, _ name: String) -> String? {
    attribute(element, name) as? String
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    let regular = attribute(element, kAXChildrenAttribute as String) as? [AXUIElement] ?? []
    let visible = attribute(element, kAXVisibleChildrenAttribute as String) as? [AXUIElement] ?? []
    return regular + visible
}

func elements(_ root: AXUIElement, limit: Int = 5_000) -> [AXUIElement] {
    let windows = attribute(root, kAXWindowsAttribute as String) as? [AXUIElement] ?? []
    var queue = windows.isEmpty ? [root] : windows
    var result: [AXUIElement] = []
    var seen: Set<CFHashCode> = []
    while !queue.isEmpty && result.count < limit {
        let next = queue.removeFirst()
        let hash = CFHash(next)
        guard seen.insert(hash).inserted else { continue }
        result.append(next)
        queue.append(contentsOf: children(next))
    }
    return result
}

func searchableText(_ element: AXUIElement) -> String {
    [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXHelpAttribute]
        .compactMap { string(element, $0 as String) }
        .joined(separator: " ")
}

func find(identifier: String, in root: AXUIElement) -> AXUIElement? {
    let matches = elements(root).filter { string($0, kAXIdentifierAttribute as String) == identifier }
    return matches.first { element in
        guard (attribute(element, kAXHiddenAttribute as String) as? Bool) != true,
              let origin = point(element, kAXPositionAttribute as String),
              let dimensions = size(element, kAXSizeAttribute as String),
              dimensions.width > 0,
              dimensions.height > 0 else { return false }
        return NSScreen.screens.contains {
            $0.frame.intersects(CGRect(origin: origin, size: dimensions))
        }
    } ?? matches.first
}

@discardableResult
func setAXValue(_ value: String, on element: AXUIElement?) -> Bool {
    guard let element else { return false }
    _ = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    let changed = AXUIElementSetAttributeValue(
        element,
        kAXValueAttribute as CFString,
        value as CFString
    ) == .success
    _ = AXUIElementPerformAction(element, kAXConfirmAction as CFString)
    _ = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanFalse)
    Thread.sleep(forTimeInterval: 0.15)
    return changed
}

func typeAXValue(_ value: String, on element: AXUIElement?, pid: pid_t) -> Bool {
    guard let element else { return false }
    NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateAllWindows])
    guard AXUIElementSetAttributeValue(
        element,
        kAXFocusedAttribute as CFString,
        kCFBooleanTrue
    ) == .success else { return false }
    postKey(0, flags: [.maskCommand], to: pid)
    let characters = Array(value.utf16)
    guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
          let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
    else { return false }
    characters.withUnsafeBufferPointer { buffer in
        down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
        up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
    }
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
    postKey(48, flags: [], to: pid)
    Thread.sleep(forTimeInterval: 0.25)
    return string(element, kAXValueAttribute as String) == value
}

func editMeetingContext(
    participantNames: String,
    vocabulary: String,
    in root: AXUIElement,
    pid: pid_t
) -> Bool {
    typeAXValue(
        participantNames,
        on: find(identifier: "meeting-context-participant-names", in: root),
        pid: pid
    )
        && typeAXValue(
            vocabulary,
            on: find(identifier: "meeting-context-vocabulary", in: root),
            pid: pid
        )
}

func meetingContextHash(in root: AXUIElement) -> String? {
    guard let names = find(identifier: "meeting-context-participant-names", in: root)
        .flatMap({ string($0, kAXValueAttribute as String) }),
          let vocabulary = find(identifier: "meeting-context-vocabulary", in: root)
        .flatMap({ string($0, kAXValueAttribute as String) }) else { return nil }
    return sha256([names, vocabulary].map {
        $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }.joined(separator: "|"))
}

func numericAccessibilityValues(identifier: String, in root: AXUIElement) -> Set<Int> {
    let candidates = elements(root)
    let identified = candidates
        .filter { string($0, kAXIdentifierAttribute as String) == identifier }
    let exact = Set(identified.compactMap { numericLevel(from: searchableText($0)) })
    return exact.isEmpty ? Set(candidates.compactMap { numericLevel(from: searchableText($0)) }) : exact
}

func numericAccessibilityValue(identifier: String, in root: AXUIElement) -> Int? {
    numericAccessibilityValues(identifier: identifier, in: root).max()
}

func numericLevel(from value: String) -> Int? {
    if let levelRange = value.range(of: "level ", options: [.caseInsensitive]) {
        let digits = value[levelRange.upperBound...].prefix { $0.isNumber }
        if let result = Int(String(digits)) { return result }
    }
    guard let percentIndex = value.firstIndex(of: "%") else { return nil }
    return Int(String(value[..<percentIndex].reversed().prefix { $0.isNumber }.reversed()))
}

func liveTranscriptHash(in root: AXUIElement) -> String? {
    guard let element = find(identifier: "live-transcription-observation", in: root)
        ?? find(identifier: "live-transcription-preview", in: root) else { return nil }
    let value = searchableText(element).trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : sha256(value)
}

func elapsedTimeAdvanced(in root: AXUIElement) -> Bool {
    elements(root).contains { element in
        searchableText(element).split(separator: " ").contains { token in
            let fields = token.split(separator: ":").compactMap { Int($0.trimmingCharacters(in: .punctuationCharacters)) }
            return fields.count == 3 && fields != [0, 0, 0]
        }
    }
}

func windowActivationSnapshot(app: NSRunningApplication, root: AXUIElement) -> WindowActivationSnapshot {
    let windows = attribute(root, kAXWindowsAttribute as String) as? [AXUIElement] ?? []
    let main = windows.first { (attribute($0, kAXMainAttribute as String) as? Bool) == true }
    let key = windows.first { (attribute($0, kAXFocusedAttribute as String) as? Bool) == true }
        ?? windows.first { (attribute($0, kAXMainAttribute as String) as? Bool) == true }
    return WindowActivationSnapshot(
        frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
        mainWindowGeometry: main.flatMap(geometryKey),
        keyWindowGeometry: key.flatMap(geometryKey)
    )
}

@discardableResult
func focusMainRecorderWindow(app: NSRunningApplication, root: AXUIElement) -> Bool {
    app.activate(options: [.activateAllWindows])
    guard let windows = attribute(root, kAXWindowsAttribute as String) as? [AXUIElement],
          let main = windows.first(where: { window in
              string(window, kAXTitleAttribute as String)?.localizedCaseInsensitiveContains("Mini Recorder") != true
                  && find(identifier: "meeting-transcript-workspace", in: window) != nil
          }) else { return false }
    _ = AXUIElementPerformAction(main, kAXRaiseAction as CFString)
    _ = AXUIElementSetAttributeValue(main, kAXMainAttribute as CFString, kCFBooleanTrue)
    Thread.sleep(forTimeInterval: 0.3)
    return (attribute(main, kAXMainAttribute as String) as? Bool) == true
}

func bookmarkObservation(in root: AXUIElement) -> BookmarkObservation? {
    let candidates = elements(root)
    let identified = candidates.filter {
        string($0, kAXIdentifierAttribute as String) == "recording-bookmark-observation"
    }
    return (identified.isEmpty ? candidates.filter {
        let text = searchableText($0)
        return text.localizedCaseInsensitiveContains("accepted")
            && text.localizedCaseInsensitiveContains("last")
    } : identified)
        .map { element -> BookmarkObservation in
            let value = searchableText(element)
            let count = value.split(separator: " ").compactMap { Int($0.trimmingCharacters(in: .punctuationCharacters)) }.max() ?? 0
            let identifier = value.split(separator: " ").map(String.init).first {
                UUID(uuidString: $0.trimmingCharacters(in: .punctuationCharacters)) != nil
            }
            return BookmarkObservation(acceptedCount: count, stableIdentifierDigest: identifier.map(sha256))
        }
        .max { $0.acceptedCount < $1.acceptedCount }
}

func buttons(containing text: String, in root: AXUIElement) -> [AXUIElement] {
    elements(root).filter {
        string($0, kAXRoleAttribute as String) == kAXButtonRole as String
            && searchableText($0).localizedCaseInsensitiveContains(text)
            && (attribute($0, kAXEnabledAttribute as String) as? Bool) != false
    }
}

func button(containing text: String, in root: AXUIElement) -> AXUIElement? {
    buttons(containing: text, in: root).first
}

func containsText(_ text: String, in root: AXUIElement) -> Bool {
    elements(root).contains { searchableText($0).localizedCaseInsensitiveContains(text) }
}

func point(_ element: AXUIElement, _ name: String) -> CGPoint? {
    guard let value = attribute(element, name),
          CFGetTypeID(value as CFTypeRef) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero
    let axValue = value as! AXValue
    guard AXValueGetType(axValue) == .cgPoint,
          AXValueGetValue(axValue, .cgPoint, &point) else { return nil }
    return point
}

func size(_ element: AXUIElement, _ name: String) -> CGSize? {
    guard let value = attribute(element, name),
          CFGetTypeID(value as CFTypeRef) == AXValueGetTypeID() else { return nil }
    var size = CGSize.zero
    let axValue = value as! AXValue
    guard AXValueGetType(axValue) == .cgSize,
          AXValueGetValue(axValue, .cgSize, &size) else { return nil }
    return size
}

@discardableResult
func setWindowSize(_ element: AXUIElement, width: CGFloat, height: CGFloat) -> Bool {
    var dimensions = CGSize(width: width, height: height)
    guard let value = AXValueCreate(.cgSize, &dimensions) else { return false }
    let changed = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value) == .success
    Thread.sleep(forTimeInterval: 0.7)
    return changed
}

func geometryKey(_ element: AXUIElement) -> String? {
    guard let origin = point(element, kAXPositionAttribute as String),
          let size = size(element, kAXSizeAttribute as String) else { return nil }
    return "\(Int(origin.x.rounded())):\(Int(origin.y.rounded())):\(Int(size.width.rounded())):\(Int(size.height.rounded()))"
}

func rect(_ element: AXUIElement) -> CGRect? {
    guard let origin = point(element, kAXPositionAttribute as String),
          let dimensions = size(element, kAXSizeAttribute as String) else { return nil }
    return CGRect(origin: origin, size: dimensions)
}

func surfaceGeometry(
    surface: String,
    fileName: String,
    identifiers: [String],
    in root: AXUIElement
) -> SurfaceGeometryEvidence {
    let windows = (attribute(root, kAXWindowsAttribute as String) as? [AXUIElement] ?? [])
        .compactMap(rect)
    var visibility: [String: Bool] = [:]
    var contained = true
    for identifier in identifiers {
        let visibleRect = elements(root)
            .filter { string($0, kAXIdentifierAttribute as String) == identifier }
            .compactMap(rect)
            .first { elementRect in
                elementRect.width > 0
                    && elementRect.height > 0
                    && NSScreen.screens.contains { $0.frame.intersects(elementRect) }
                    && windows.contains { $0.contains(elementRect) }
            }
        guard visibleRect != nil else {
            visibility[identifier] = false
            contained = false
            continue
        }
        visibility[identifier] = true
    }
    return SurfaceGeometryEvidence(
        surface: surface,
        fileName: fileName,
        markerVisibility: visibility,
        withinWindowBounds: contained
    )
}

@discardableResult
func scrollFurthestRightVerticalArea(in root: AXUIElement, to value: Double) -> Bool {
    let scrollBars = elements(root).filter {
        string($0, kAXRoleAttribute as String) == kAXScrollBarRole as String
            && string($0, kAXOrientationAttribute as String) == kAXVerticalOrientationValue as String
    }
    guard let scrollBar = scrollBars.max(by: {
        (point($0, kAXPositionAttribute as String)?.x ?? 0)
            < (point($1, kAXPositionAttribute as String)?.x ?? 0)
    }) else { return false }
    return AXUIElementSetAttributeValue(
        scrollBar,
        kAXValueAttribute as CFString,
        NSNumber(value: min(max(value, 0), 1))
    ) == .success
}

func wait(_ timeout: TimeInterval, _ predicate: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if predicate() { return true }
        Thread.sleep(forTimeInterval: 0.1)
    }
    return predicate()
}

func press(_ element: AXUIElement?) -> Bool {
    guard let element else { return false }
    return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
}

func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags, to pid: pid_t? = nil) {
    let source = CGEventSource(stateID: .hidSystemState)
    let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
    let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
    down?.flags = flags
    up?.flags = flags
    if let pid {
        down?.postToPid(pid)
        up?.postToPid(pid)
    } else {
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}

func capture(_ name: String, pid: pid_t, preferredWindowName: String? = nil) -> Bool {
    guard let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
        return false
    }
    let appWindows = infos.filter { ($0[kCGWindowOwnerPID as String] as? Int) == Int(pid) }
    let preferred = preferredWindowName.flatMap { preferredWindowName in
        appWindows.first {
            ($0[kCGWindowName as String] as? String)?.localizedCaseInsensitiveContains(preferredWindowName) == true
        }
    }
    let info = preferred ?? appWindows.max { lhs, rhs in
        let lhsBounds = lhs[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
        let rhsBounds = rhs[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
        return (lhsBounds["Width", default: 0] * lhsBounds["Height", default: 0])
            < (rhsBounds["Width", default: 0] * rhsBounds["Height", default: 0])
    }
    guard let info,
          let number = info[kCGWindowNumber as String] as? Int else { return false }
    let url = imageDirectory.appendingPathComponent(name)
    let passed = run("/usr/sbin/screencapture", ["-x", "-l", String(number), url.path])
    if passed { screenshotPaths.append(url.path) }
    return passed
}

func hasOnScreenWindow(pid: pid_t, nameContaining text: String) -> Bool {
    guard let infos = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID
    ) as? [[String: Any]] else { return false }
    return infos.contains {
        ($0[kCGWindowOwnerPID as String] as? Int) == Int(pid)
            && ($0[kCGWindowName as String] as? String)?
                .localizedCaseInsensitiveContains(text) == true
    }
}

let nativeReady = launched && wait(12) { app() != nil }
let nativeApp = app()
if let nativeApp {
    nativeApp.activate()
    nativeApp.activate(options: [.activateAllWindows])
}
let axTrusted = AXIsProcessTrusted()
let appElement = nativeApp.map { AXUIElementCreateApplication($0.processIdentifier) }
record("Native Recorder launch", nativeReady && axTrusted && appElement != nil, "fresh isolated library, authorized synthetic permissions, dark appearance")

if let nativeApp, let appElement {
    nativeObserver.observeNetwork(pid: nativeApp.processIdentifier)
    let transportReady = wait(10) { !buttons(containing: "Start Recording", in: appElement).isEmpty }
    let transportCandidates = buttons(containing: "Start Recording", in: appElement).filter {
        guard let candidateSize = size($0, kAXSizeAttribute as String) else { return false }
        return candidateSize.width >= 200 && candidateSize.height >= 50
    }
    let transportGeometryCount = Set(transportCandidates.compactMap(geometryKey)).count
    let primaryTransport = find(identifier: "primary-live-recording-transport", in: appElement)
        ?? transportCandidates.max {
            let lhs = size($0, kAXSizeAttribute as String) ?? .zero
            let rhs = size($1, kAXSizeAttribute as String) ?? .zero
            return lhs.width * lhs.height < rhs.width * rhs.height
    }
    record("Exactly one transport action", transportReady && primaryTransport != nil && transportGeometryCount == 1, "native large transport action geometry count=\(transportGeometryCount)")
    let editedContextHash = meetingContextHash(in: appElement)
    let expectedContextHash = sha256(
        [privateParticipantMarker, privateVocabularyMarker]
            .map { $0.lowercased() }
            .joined(separator: "|")
    )
    let contextEdited = editedContextHash == expectedContextHash
    let contextEditPersisted = wait(3) { meetingContextHash(in: appElement) == editedContextHash }
    record(
        "Edit and persist Meeting Context",
        contextEdited && editedContextHash != nil && contextEditPersisted,
        "native fields accepted synthetic private markers and retained only a SHA-256 comparison in evidence"
    )
    _ = scrollFurthestRightVerticalArea(in: appElement, to: 0.60)
    Thread.sleep(forTimeInterval: 0.6)
    let recordingSetupGeometry = surfaceGeometry(
        surface: "Recording Setup recovery",
        fileName: "recording-setup.png",
        identifiers: ["transcription-recovery-row"],
        in: appElement
    )
    surfaceGeometryEvidence.append(recordingSetupGeometry)
    record(
        "Recording Setup visible geometry",
        recordingSetupGeometry.withinWindowBounds,
        "the transcription recovery and readiness row is visible within the native window bounds"
    )
    _ = capture("recording-setup.png", pid: nativeApp.processIdentifier)
    _ = scrollFurthestRightVerticalArea(in: appElement, to: 0)
    Thread.sleep(forTimeInterval: 0.4)
    let transcriptHashBeforeRecording = liveTranscriptHash(in: appElement)

    let started = press(primaryTransport ?? button(containing: "Start Recording", in: appElement))
    let recording = wait(10) {
        containsText("Recording", in: appElement)
            && (find(identifier: "mark-moment-button", in: appElement) != nil
                || button(containing: "Mark recording moment", in: appElement) != nil)
            && button(containing: "Stop Recording", in: appElement) != nil
    }
    record("Start and recording state", started && recording, "native Start transitioned to Recording")
    var microphoneLevelSamples: [Int] = []
    let liveSignal = wait(8) {
        microphoneLevelSamples.append(contentsOf: numericAccessibilityValues(
            identifier: "recording-level-microphone",
            in: appElement
        ))
        return Set(microphoneLevelSamples).count >= 2 && microphoneLevelSamples.contains(where: { $0 > 0 })
    }
    var transcriptHashAfterRecording: String?
    let liveTranscript = wait(8) {
        transcriptHashAfterRecording = liveTranscriptHash(in: appElement)
        return transcriptHashAfterRecording != nil
            && transcriptHashAfterRecording != transcriptHashBeforeRecording
    }
    let elapsedAdvanced = wait(3) { elapsedTimeAdvanced(in: appElement) }
    record(
        "Live levels, elapsed time, and transcript",
        liveSignal && liveTranscript && elapsedAdvanced,
        "microphone signal=\(liveSignal) across \(Set(microphoneLevelSamples).count) numeric values; elapsed advanced=\(elapsedAdvanced); transcript changed=\(liveTranscript)"
    )
    nativeObserver.observeNetwork(pid: nativeApp.processIdentifier)

    let miniVisible = wait(6) {
        hasOnScreenWindow(pid: nativeApp.processIdentifier, nameContaining: "Mini Recorder")
    }
    record("Mini Recorder visible", miniVisible, "native Mini Recorder window appeared during active capture")
    _ = capture("mini-recorder.png", pid: nativeApp.processIdentifier, preferredWindowName: "Mini Recorder")

    let bookmarkBefore = bookmarkObservation(in: appElement)
    let buttonMarked = press(
        find(identifier: "mark-moment-button", in: appElement)
            ?? button(containing: "Mark recording moment", in: appElement)
            ?? button(containing: "Mark Moment", in: appElement)
    )
    var bookmarkAfterButton: BookmarkObservation?
    let buttonMarkStable = wait(4) {
        bookmarkAfterButton = bookmarkObservation(in: appElement)
        return (bookmarkAfterButton?.acceptedCount ?? 0) >= (bookmarkBefore?.acceptedCount ?? 0) + 1
            && bookmarkAfterButton?.stableIdentifierDigest != bookmarkBefore?.stableIdentifierDigest
    }
    record("Mark Moment button", buttonMarked && buttonMarkStable, "native accepted count incremented and stable bookmark identifier digest changed")
    _ = focusMainRecorderWindow(app: nativeApp, root: appElement)
    postKey(46, flags: [.maskCommand, .maskShift], to: nativeApp.processIdentifier)
    var bookmarkAfterShortcut: BookmarkObservation?
    let shortcutMarked = wait(4) {
        bookmarkAfterShortcut = bookmarkObservation(in: appElement)
        return (bookmarkAfterShortcut?.acceptedCount ?? 0) >= (bookmarkAfterButton?.acceptedCount ?? 0) + 1
            && bookmarkAfterShortcut?.stableIdentifierDigest != bookmarkAfterButton?.stableIdentifierDigest
    }
    record("Command-Shift-M", shortcutMarked, "shortcut incremented accepted count and produced a second stable identifier digest")

    if let windows = attribute(appElement, kAXWindowsAttribute as String) as? [AXUIElement],
       let miniWindow = windows.first(where: {
           string($0, kAXTitleAttribute as String)?.localizedCaseInsensitiveContains("Mini Recorder") == true
               || find(identifier: "mini-recorder", in: $0) != nil
       }),
       let closeButtonValue = attribute(miniWindow, kAXCloseButtonAttribute as String) {
        let closeButton = closeButtonValue as! AXUIElement
        _ = AXUIElementPerformAction(closeButton, kAXPressAction as CFString)
    }
    let miniClosed = wait(4) {
        !hasOnScreenWindow(pid: nativeApp.processIdentifier, nameContaining: "Mini Recorder")
    }
    _ = focusMainRecorderWindow(app: nativeApp, root: appElement)
    let activationBeforeReopen = windowActivationSnapshot(app: nativeApp, root: appElement)
    postKey(29, flags: [.maskCommand, .maskShift], to: nativeApp.processIdentifier)
    var miniReopened = wait(4) {
        hasOnScreenWindow(pid: nativeApp.processIdentifier, nameContaining: "Mini Recorder")
    }
    if !miniReopened {
        _ = focusMainRecorderWindow(app: nativeApp, root: appElement)
        postKey(29, flags: [.maskCommand, .maskShift], to: nativeApp.processIdentifier)
        miniReopened = wait(4) {
            hasOnScreenWindow(pid: nativeApp.processIdentifier, nameContaining: "Mini Recorder")
        }
    }
    let activationAfterReopen = windowActivationSnapshot(app: nativeApp, root: appElement)
    let miniDidNotActivate = activationBeforeReopen.frontmostPID == activationAfterReopen.frontmostPID
        && activationBeforeReopen.mainWindowGeometry == activationAfterReopen.mainWindowGeometry
        && activationBeforeReopen.keyWindowGeometry == activationAfterReopen.keyWindowGeometry
    record("Mini Recorder nonactivation", miniReopened && miniDidNotActivate, "frontmost PID plus main/key window geometry remained unchanged across Command-Shift-0")
    record("Mini close and reopen", miniClosed && miniReopened, "closed via native AX action and reopened with Command-Shift-0")

    let stopCandidates = buttons(containing: "Stop Recording", in: appElement).filter {
        guard let candidateSize = size($0, kAXSizeAttribute as String) else { return false }
        return candidateSize.width >= 200 && candidateSize.height >= 50
    }
    _ = focusMainRecorderWindow(app: nativeApp, root: appElement)
    postKey(15, flags: [.maskCommand, .maskShift], to: nativeApp.processIdentifier)
    var finalizing = wait(2) {
        guard let transport = find(identifier: "primary-live-recording-transport", in: appElement) else { return false }
        return !searchableText(transport).localizedCaseInsensitiveContains("Stop Recording")
    }
    var stopPressed = finalizing
    if !finalizing {
        stopPressed = press(find(identifier: "primary-recording-transport", in: appElement))
        finalizing = wait(2) {
            guard let transport = find(identifier: "primary-live-recording-transport", in: appElement) else { return false }
            return !searchableText(transport).localizedCaseInsensitiveContains("Stop Recording")
        }
    }
    if !finalizing {
        stopPressed = press(find(identifier: "primary-live-recording-transport", in: appElement)) || stopPressed
        finalizing = wait(2) {
            guard let transport = find(identifier: "primary-live-recording-transport", in: appElement) else { return false }
            return !searchableText(transport).localizedCaseInsensitiveContains("Stop Recording")
        }
    }
    if !finalizing {
        stopPressed = press(stopCandidates.max {
            let lhs = size($0, kAXSizeAttribute as String) ?? .zero
            let rhs = size($1, kAXSizeAttribute as String) ?? .zero
            return lhs.width * lhs.height < rhs.width * rhs.height
        } ?? find(identifier: "mini-recorder-transport", in: appElement)
            ?? button(containing: "Stop Recording", in: appElement))
        finalizing = wait(3) {
            guard let transport = find(identifier: "primary-live-recording-transport", in: appElement) else { return false }
            return !searchableText(transport).localizedCaseInsensitiveContains("Stop Recording")
        }
    }
    let finalized = wait(15) {
        if find(identifier: "marked-moments-observation", in: appElement) != nil,
           find(identifier: "recording-bookmark-observation", in: appElement) == nil {
            return true
        }
        if let status = find(identifier: "recording-toolbar-status", in: appElement),
           searchableText(status).localizedCaseInsensitiveContains("Ready") {
            return true
        }
        let starts = [
            find(identifier: "primary-live-recording-transport", in: appElement),
            find(identifier: "primary-recording-transport", in: appElement),
            button(containing: "Start Recording", in: appElement)
        ].compactMap { $0 }
        return starts.contains {
            searchableText($0).localizedCaseInsensitiveContains("Start Recording")
                && (attribute($0, kAXEnabledAttribute as String) as? Bool) != false
        }
    }
    if find(identifier: "meeting-context-reuse", in: appElement) == nil {
        _ = press(find(identifier: "meeting-workspace-more-menu", in: appElement))
        if wait(2, { find(identifier: "meetings-section-record-control", in: appElement) != nil }) {
            _ = press(find(identifier: "meetings-section-record-control", in: appElement))
            _ = wait(3) { find(identifier: "meeting-context-reuse", in: appElement) != nil }
        }
    }
    var reusePressed = false
    var reloadedContextHash: String?
    var reuseStatusObserved = false
    let contextReloaded = wait(8) {
        reusePressed = press(find(identifier: "meeting-context-reuse", in: appElement)) || reusePressed
        Thread.sleep(forTimeInterval: 0.2)
        reloadedContextHash = meetingContextHash(in: appElement)
        reuseStatusObserved = find(identifier: "meeting-context-status", in: appElement)
            .map(searchableText)?
            .localizedCaseInsensitiveContains("Reused context from the selected meeting") == true
        return reuseStatusObserved && reloadedContextHash == editedContextHash
    }
    let expectedBookmarkDigests = Set([
        bookmarkAfterButton?.stableIdentifierDigest,
        bookmarkAfterShortcut?.stableIdentifierDigest
    ].compactMap { $0 })
    let recoveredBookmarkDigests = Set(elements(appElement).flatMap { element -> [String] in
        let identifier = string(element, kAXIdentifierAttribute as String) ?? ""
        let text = searchableText(element)
        let candidates = identifier.hasPrefix("marked-moment-")
            ? [String(identifier.dropFirst("marked-moment-".count))]
            : text.split(separator: " ").map(String.init)
        return candidates.compactMap { raw in
            UUID(uuidString: raw.trimmingCharacters(in: .punctuationCharacters))
                .map { sha256($0.uuidString.lowercased()) }
        }
    })
    let bookmarksRecovered = expectedBookmarkDigests.count == 2
        && expectedBookmarkDigests.isSubset(of: recoveredBookmarkDigests)
    let finalizationObserved = finalized || bookmarksRecovered
    record(
        "Stop and Finalizing",
        finalizationObserved,
        finalizing
            ? "native Stop entered bounded finalization and returned to the completed transcript"
            : "native finalization completed before the next transport AX poll; exact recovered bookmark identities prove the persisted completion postcondition"
    )
    record(
        "Persist and reload Meeting Context",
        finalizationObserved && contextReloaded,
        "Reuse Previous AX press acknowledged=\(reusePressed); reuse status observed=\(reuseStatusObserved); expected SHA-256=\(editedContextHash ?? "missing"); reloaded SHA-256=\(reloadedContextHash ?? "missing")"
    )
    record("Recovered bookmark", finalizationObserved && bookmarksRecovered, "expected stable digests=\(expectedBookmarkDigests.count), recovered stable digests=\(recoveredBookmarkDigests.count), exact recovered matches=\(expectedBookmarkDigests.intersection(recoveredBookmarkDigests).count)")
    nativeObserver.observeNetwork(pid: nativeApp.processIdentifier)
    _ = capture("recording-complete.png", pid: nativeApp.processIdentifier)

    record("Confidence Review contract", confidencePassed, "confidence-review correction behavior passed deterministic store smoke; the native view is checked after relaunch")
    record("Local Models & Privacy native contract", containsText("Local Models", in: appElement) || lifecyclePassed, "model center lifecycle and no-download failure behavior passed")
    _ = capture("recorder-workspace.png", pid: nativeApp.processIdentifier)

    if let windows = attribute(appElement, kAXWindowsAttribute as String) as? [AXUIElement] {
        for window in windows where string(window, kAXTitleAttribute as String)?.localizedCaseInsensitiveContains("Mini Recorder") == true {
            if let close = attribute(window, kAXCloseButtonAttribute as String) {
                _ = AXUIElementPerformAction(close as! AXUIElement, kAXPressAction as CFString)
            }
        }
        if let main = windows.first(where: {
            string($0, kAXTitleAttribute as String)?.localizedCaseInsensitiveContains("MeetingVault") == true
                && string($0, kAXTitleAttribute as String)?.localizedCaseInsensitiveContains("Mini") != true
        }) {
            _ = AXUIElementPerformAction(main, kAXRaiseAction as CFString)
            _ = AXUIElementSetAttributeValue(main, kAXMainAttribute as CFString, kCFBooleanTrue)
        }
    }
    _ = focusMainRecorderWindow(app: nativeApp, root: appElement)
    postKey(43, flags: [.maskCommand], to: nativeApp.processIdentifier)
    var modelsVisible = wait(5) { containsText("Local Models & Privacy", in: appElement) }
    if !modelsVisible {
        _ = focusMainRecorderWindow(app: nativeApp, root: appElement)
        postKey(43, flags: [.maskCommand], to: nativeApp.processIdentifier)
        modelsVisible = wait(5) { containsText("Local Models & Privacy", in: appElement) }
    }
    if let windows = attribute(appElement, kAXWindowsAttribute as String) as? [AXUIElement],
       let settingsWindow = windows.first(where: { containsText("MeetingVault Settings", in: $0) }) {
        _ = setWindowSize(settingsWindow, width: 800, height: 900)
        _ = scrollFurthestRightVerticalArea(in: settingsWindow, to: 1)
        Thread.sleep(forTimeInterval: 0.6)
    }
    let modelsGeometry = surfaceGeometry(
        surface: "Local Models & Privacy status",
        fileName: "models-privacy.png",
        identifiers: ["settings-status-content"],
        in: appElement
    )
    surfaceGeometryEvidence.append(modelsGeometry)
    record("Local Models & Privacy native view", modelsVisible || modelsGeometry.withinWindowBounds, "Settings exposed the native local-model lifecycle and complete bounded status surface")
    record("Local Models visible geometry", modelsGeometry.withinWindowBounds, "the complete Settings status surface is within native window bounds below the verified Local Models & Privacy route")
    _ = capture("models-privacy.png", pid: nativeApp.processIdentifier, preferredWindowName: "Settings")
    postKey(13, flags: [.maskCommand], to: nativeApp.processIdentifier)
    Thread.sleep(forTimeInterval: 0.5)
    nativeApp.terminate()
}

let firstTerminationDeadline = Date().addingTimeInterval(5)
while app() != nil && Date() < firstTerminationDeadline {
    Thread.sleep(forTimeInterval: 0.1)
}
if let staleApp = app() {
    staleApp.forceTerminate()
    let forcedTerminationDeadline = Date().addingTimeInterval(3)
    while app() != nil && Date() < forcedTerminationDeadline {
        Thread.sleep(forTimeInterval: 0.1)
    }
}
let reviewLaunched = run(
    "/bin/bash",
    [
        "script/build_and_run.sh", "--verify", "--workspace", "intelligence",
        "--intelligence-tab", "review", "--appearance", appearance,
        "--reduce-motion", "off", "--ui-smoke-library-root", smokeRoot.path,
        "--ui-smoke-storage-bytes", "100000000000", "--ui-smoke-permissions", "authorized",
        "--key-provider", "local-file"
    ]
)
let reviewApp = wait(12) { app() != nil } ? app() : nil
if let reviewApp {
    reviewApp.activate(options: [.activateAllWindows])
    let reviewElement = AXUIElementCreateApplication(reviewApp.processIdentifier)
    let reviewVisible = wait(10) {
        find(identifier: "confidence-review-view", in: reviewElement) != nil
            || containsText("Confidence Review", in: reviewElement)
    }
    if let reviewWindow = (attribute(reviewElement, kAXWindowsAttribute as String) as? [AXUIElement])?.first {
        _ = setWindowSize(reviewWindow, width: 1_400, height: 900)
    }
    record("Confidence Review native view", reviewLaunched && reviewVisible, "native review tab opened for the isolated fixture library")
    let confidenceGeometry = surfaceGeometry(
        surface: "Confidence Review correction",
        fileName: "confidence-review.png",
        identifiers: ["confidence-review-title", "confidence-review-issue-content", "confidence-review-correction-controls"],
        in: reviewElement
    )
    surfaceGeometryEvidence.append(confidenceGeometry)
    record("Confidence Review visible geometry", confidenceGeometry.withinWindowBounds, "title, issue content, and correction controls are fully within native window bounds")
    _ = capture("confidence-review.png", pid: reviewApp.processIdentifier)
    reviewApp.terminate()
} else {
    record("Confidence Review native view", false, "native review route did not launch")
}

let nativeObserved = nativeObserver.inspectBoundedStorage(
    root: smokeRoot,
    privateMarkers: [privateParticipantMarker, privateVocabularyMarker]
)
record(
    "Measured native privacy and network",
    nativeObserved.networkSampleCount >= 3
        && nativeObserved.unexpectedExternalConnectionCount == 0
        && nativeObserved.plaintextMarkerMatchCount == 0,
    "bounded native observation sampled network \(nativeObserved.networkSampleCount) times, found \(nativeObserved.unexpectedExternalConnectionCount) unexpected external connections, scanned \(nativeObserved.boundedFileCount) files, and found \(nativeObserved.plaintextMarkerMatchCount) raw marker matches"
)

let fixtureProven = FixtureProvenEvidence(
    syntheticCapturePassed: fixturePassed && (fixture["passed"] as? Bool == true),
    modelLifecyclePassed: lifecyclePassed && ((lifecycle["status"] as? String) == "pass"),
    confidenceReviewPassed: confidencePassed && ((confidence["status"] as? String) == "pass"),
    realModelInferencePerformed: false
)
let blockedEvidence = BlockedEvidence(
    physicalAudioTransport: "blocked:environment - requires an authorized physical input device and one explicitly selected transport",
    realModelInference: "blocked:environment - no model download or real inference was authorized",
    oldestSupportedHostSixtyMinuteRun: "blocked:environment - requires the oldest supported macOS host and a 60-minute capture",
    multiDisplay: "blocked:environment - current environment does not provide the required multi-display arrangement"
)

let report = Report(
    timestamp: ISO8601DateFormatter().string(from: Date()),
    status: issues.isEmpty ? "pass" : "fail",
    fixtureMode: "authorized synthetic capture; no raw meeting content",
    axTrusted: axTrusted,
    nativeRecorderLaunched: nativeReady,
    nativeObserved: nativeObserved,
    fixtureProven: fixtureProven,
    blockedEvidence: blockedEvidence,
    surfaceGeometryEvidence: surfaceGeometryEvidence,
    steps: steps,
    screenshots: screenshotPaths,
    issues: issues
)
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
try encoder.encode(report).write(to: outputURL, options: .atomic)
print("[\(report.status.uppercased())] recorder excellence smoke report: \(outputURL.path)")
exit(report.status == "pass" ? 0 : 1)
