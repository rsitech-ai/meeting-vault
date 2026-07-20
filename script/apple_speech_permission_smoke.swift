#!/usr/bin/env swift
import AppKit
import ApplicationServices
import Foundation

struct PermissionSmokeStep: Codable {
    var name: String
    var status: String
    var detail: String
}

struct AppleSpeechPermissionSmokeReport: Codable {
    var timestamp: String
    var status: String
    var requirePass: Bool = false
    var approvedReportPath: String? = nil
    var validatedReport: AppleSpeechPermissionApprovedReport? = nil
    var appName: String
    var bundleIdentifier: String
    var pid: Int?
    var axTrusted: Bool
    var launchedByScript: Bool
    var approvalFlagProvided: Bool
    var authorizationBefore: String
    var authorizationAfter: String
    var promptPolicyVisible: Bool
    var requestButtonPressed: Bool
    var recordingStartDidNotRequestPermission: Bool
    var transcriptionStartDidNotRequestPermission: Bool
    var requestOnceNotRepeatedAfterResolved: Bool
    var systemPromptApproved: Bool
    var privateAudioRecorded: Bool
    var microphoneOpened: Bool
    var externalNetworkRequested: Bool = false
    var externalUploadAttempted: Bool = false
    var rawUITextStored: Bool
    var rawTranscriptStored: Bool = false
    var rawAudioStored: Bool = false
    var rawLogsStored: Bool = false
    var steps: [PermissionSmokeStep]
    var issues: [String]
}

struct AppleSpeechPermissionApprovedReport: Codable {
    var status: String
    var sourceCommit: String?
    var appVersion: String?
    var tester: String?
    var testedAt: String?
    var machineDescription: String?
    var evidenceArtifacts: [String]
    var authorizationBefore: String
    var authorizationAfter: String
    var appLaunched: Bool
    var axTrusted: Bool
    var healthRecoveryVisible: Bool
    var appSpeechStateInspected: Bool
    var promptPolicyVisible: Bool
    var requestButtonPressed: Bool
    var recordingStartDidNotRequestPermission: Bool
    var transcriptionStartDidNotRequestPermission: Bool
    var requestOnceNotRepeatedAfterResolved: Bool
    var systemPromptApproved: Bool
    var privateAudioRecorded: Bool
    var microphoneOpened: Bool
    var externalNetworkRequested: Bool
    var externalUploadAttempted: Bool
    var rawUITextStored: Bool
    var rawTranscriptStored: Bool
    var rawAudioStored: Bool
    var rawLogsStored: Bool
    var notes: [String]?
}

let appName = "MeetingVault"
let bundleIdentifier = "com.andrzej.MeetingVault"
let rootURL = URL(fileURLWithPath: CommandLine.arguments[0])
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let date = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
var outputURL = rootURL
    .appendingPathComponent("docs", isDirectory: true)
    .appendingPathComponent("evidence", isDirectory: true)
    .appendingPathComponent("apple-speech-permission-smoke-\(date).json")
var approvedReportURL: URL?
var templateURL: URL?
var approveSystemPrompt = false
var launchApp = true
var requirePass = false

var iterator = CommandLine.arguments.dropFirst().makeIterator()
while let argument = iterator.next() {
    switch argument {
    case "--output":
        guard let path = iterator.next() else {
            fputs("--output requires a path\n", stderr)
            exit(2)
        }
        outputURL = URL(fileURLWithPath: path)
    case "--approved-report":
        guard let path = iterator.next() else {
            fputs("--approved-report requires a path\n", stderr)
            exit(2)
        }
        approvedReportURL = URL(fileURLWithPath: path)
    case "--write-template":
        guard let path = iterator.next() else {
            fputs("--write-template requires a path\n", stderr)
            exit(2)
        }
        templateURL = URL(fileURLWithPath: path)
    case "--approve-system-prompt":
        approveSystemPrompt = true
    case "--skip-launch":
        launchApp = false
    case "--require-pass":
        requirePass = true
    case "--help", "-h":
        print("""
        usage: script/apple_speech_permission_smoke.swift [--approve-system-prompt] [--approved-report PATH] [--write-template PATH] [--output PATH] [--skip-launch] [--require-pass]

        Launches MeetingVault in Health & Recovery, presses the app-owned
        Apple Speech Permission > Request Once control when Speech Recognition
        is notDetermined, and optionally approves the macOS system Speech
        Recognition prompt. It never opens the microphone or records audio.

        The macOS permission prompt is approved only when --approve-system-prompt
        is supplied. Without that flag, the smoke records a blocked report before
        changing system permission state.

        Release-candidate pass claims can also provide --approved-report from a
        bounded manual app-permission QA run. That path validates the report and
        does not launch MeetingVault or change system permissions.
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
            domain: "AppleSpeechPermissionSmoke",
            code: Int(process.terminationStatus),
            userInfo: [NSLocalizedDescriptionKey: "\(executable) \(arguments.joined(separator: " ")) failed"]
        )
    }
}

func writeReport(_ report: AppleSpeechPermissionSmokeReport) {
    do {
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: outputURL, options: .atomic)
    } catch {
        fputs("failed to write Apple Speech permission smoke report: \(error)\n", stderr)
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
    guard depth <= 14, output.count < 2_500 else { return }
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
    var roots = elementsAttribute(appElement, kAXWindowsAttribute as String)
    if let menuBar = attribute(appElement, kAXMenuBarAttribute as String) {
        roots.append(menuBar as! AXUIElement)
    }
    var output: [AXUIElement] = []
    for root in roots {
        walk(root, output: &output)
    }
    return output
}

func firstElement(role: String? = nil, containing text: String, appElement: AXUIElement) -> AXUIElement? {
    allElements(appElement: appElement).first { element in
        if let role, stringAttribute(element, kAXRoleAttribute as String) != role {
            return false
        }
        return textForSearch(element).localizedCaseInsensitiveContains(text)
    }
}

func appReportedSpeechAuthorizationState(appElement: AXUIElement) -> String {
    let text = allElements(appElement: appElement)
        .map { textForSearch($0) }
        .joined(separator: " ")
    let lowercasedText = text.lowercased()
    if text.localizedCaseInsensitiveContains("Speech Recognition is authorized") {
        return "authorized"
    }
    if text.localizedCaseInsensitiveContains("Speech Recognition was denied") {
        return "denied"
    }
    if text.localizedCaseInsensitiveContains("Speech Recognition is restricted") {
        return "restricted"
    }
    if text.localizedCaseInsensitiveContains("Speech Recognition has not been requested") {
        return "notDetermined"
    }
    if text.localizedCaseInsensitiveContains("Speech Recognition authorization is unknown") {
        return "unknown"
    }
    if lowercasedText.contains("current state authorized")
        || lowercasedText.contains("apple speech authorized") {
        return "authorized"
    }
    if lowercasedText.contains("current state denied")
        || lowercasedText.contains("apple speech denied") {
        return "denied"
    }
    if lowercasedText.contains("current state restricted")
        || lowercasedText.contains("apple speech restricted") {
        return "restricted"
    }
    if lowercasedText.contains("current state notdetermined")
        || lowercasedText.contains("apple speech notdetermined") {
        return "notDetermined"
    }
    if lowercasedText.contains("current state unknown")
        || lowercasedText.contains("apple speech unknown") {
        return "unknown"
    }
    return "unavailable"
}

func waitForMarker(_ marker: String, appElement: AXUIElement, timeout: TimeInterval = 12) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if firstElement(containing: marker, appElement: appElement) != nil {
            return true
        }
        Thread.sleep(forTimeInterval: 0.25)
    }
    return firstElement(containing: marker, appElement: appElement) != nil
}

func pressElement(role: String? = nil, containing text: String, appElement: AXUIElement) -> Bool {
    guard let element = firstElement(role: role, containing: text, appElement: appElement) else {
        return false
    }
    let error = AXUIElementPerformAction(element, kAXPressAction as CFString)
    Thread.sleep(forTimeInterval: 0.8)
    return error == .success
}

func allPromptRoots() -> [AXUIElement] {
    NSWorkspace.shared.runningApplications.flatMap { app -> [AXUIElement] in
        guard !app.isTerminated else { return [] }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var roots = elementsAttribute(appElement, kAXWindowsAttribute as String)
        if let menuBar = attribute(appElement, kAXMenuBarAttribute as String) {
            roots.append(menuBar as! AXUIElement)
        }
        return roots
    }
}

func flattenedElements(from root: AXUIElement) -> [AXUIElement] {
    var output: [AXUIElement] = []
    walk(root, output: &output)
    return output
}

func promptText(from root: AXUIElement) -> String {
    flattenedElements(from: root)
        .map { textForSearch($0) }
        .filter { !$0.isEmpty }
        .joined(separator: " ")
}

func approveSpeechSystemPrompt(timeout: TimeInterval = 12) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        for root in allPromptRoots() {
            let rootText = promptText(from: root)
            guard rootText.localizedCaseInsensitiveContains(appName),
                  rootText.localizedCaseInsensitiveContains("Speech")
            else {
                continue
            }

            let button = flattenedElements(from: root).first { element in
                guard stringAttribute(element, kAXRoleAttribute as String) == (kAXButtonRole as String) else {
                    return false
                }
                let text = textForSearch(element)
                return text.localizedCaseInsensitiveContains("Allow")
            }
            if let button {
                let error = AXUIElementPerformAction(button, kAXPressAction as CFString)
                Thread.sleep(forTimeInterval: 1.0)
                return error == .success
            }
        }
        Thread.sleep(forTimeInterval: 0.25)
    }
    return false
}

func addStep(_ name: String, _ passed: Bool, _ detail: String, steps: inout [PermissionSmokeStep], issues: inout [String]) {
    steps.append(PermissionSmokeStep(name: name, status: passed ? "pass" : "fail", detail: detail))
    if !passed {
        issues.append("\(name): \(detail)")
    }
}

func writeTemplate(to outputURL: URL) throws {
    let report = AppleSpeechPermissionApprovedReport(
        status: "draft",
        sourceCommit: "REPLACE_WITH_TESTED_SOURCE_COMMIT",
        appVersion: "REPLACE_WITH_TESTED_APP_VERSION",
        tester: "REPLACE_WITH_TESTER_OR_QA_ROLE",
        testedAt: "REPLACE_WITH_ISO8601_TEST_TIME",
        machineDescription: "REPLACE_WITH_MACHINE_MACOS_APP_INSTALL_AND_SPEECH_RECOGNITION_SETUP",
        evidenceArtifacts: [
            "REPLACE_WITH_BOUNDED_APP_SPEECH_PERMISSION_EVIDENCE_PATH"
        ],
        authorizationBefore: "REPLACE_WITH_notDetermined_OR_authorized_OR_denied",
        authorizationAfter: "REPLACE_WITH_authorized",
        appLaunched: false,
        axTrusted: false,
        healthRecoveryVisible: false,
        appSpeechStateInspected: false,
        promptPolicyVisible: false,
        requestButtonPressed: false,
        recordingStartDidNotRequestPermission: false,
        transcriptionStartDidNotRequestPermission: false,
        requestOnceNotRepeatedAfterResolved: false,
        systemPromptApproved: false,
        privateAudioRecorded: false,
        microphoneOpened: false,
        externalNetworkRequested: false,
        externalUploadAttempted: false,
        rawUITextStored: false,
        rawTranscriptStored: false,
        rawAudioStored: false,
        rawLogsStored: false,
        notes: [
            "REPLACE_WITH_BOUNDED_PERMISSION_QA_NOTES_NO_RAW_UI_OR_PRIVATE_CONTENT"
        ]
    )
    try FileManager.default.createDirectory(
        at: outputURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(report).write(to: outputURL, options: .atomic)
}

func appendPlaceholderIssues(values: [String], label: String, to issues: inout [String]) {
    for value in values {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.isEmpty {
            issues.append("\(label) is empty.")
        } else if normalized.contains("replace_with")
            || normalized.contains("placeholder")
            || normalized.contains("todo")
            || normalized.contains("<") {
            issues.append("\(label) contains a template placeholder: \(value)")
        }
    }
}

func validateApprovedReport(at url: URL?) -> (report: AppleSpeechPermissionApprovedReport?, issues: [String]) {
    guard let url else {
        return (nil, ["Apple Speech permission gate requires --approved-report with bounded app permission QA evidence."])
    }
    guard let data = try? Data(contentsOf: url) else {
        return (nil, ["Approved report could not be read at \(url.path)."])
    }
    let decoder = JSONDecoder()
    guard let report = try? decoder.decode(AppleSpeechPermissionApprovedReport.self, from: data) else {
        return (nil, ["Approved report is not valid AppleSpeechPermissionApprovedReport JSON."])
    }

    var issues: [String] = []
    if report.status != "pass" {
        issues.append("Approved report status is \(report.status); expected pass.")
    }
    if report.sourceCommit?.isEmpty ?? true {
        issues.append("Approved report must identify the tested source commit.")
    }
    if report.appVersion?.isEmpty ?? true {
        issues.append("Approved report must identify the tested app version.")
    }
    if report.tester?.isEmpty ?? true {
        issues.append("Approved report must identify the tester or QA role.")
    }
    if report.testedAt?.isEmpty ?? true {
        issues.append("Approved report must identify when permission QA was run.")
    }
    if report.machineDescription?.isEmpty ?? true {
        issues.append("Approved report must describe the Mac, OS build, app install, and Speech Recognition setup.")
    }
    if report.evidenceArtifacts.isEmpty {
        issues.append("Approved report must list bounded evidence artifacts.")
    }
    appendPlaceholderIssues(
        values: report.evidenceArtifacts,
        label: "Approved report evidence artifact",
        to: &issues
    )
    if let notes = report.notes {
        appendPlaceholderIssues(values: notes, label: "Approved report note", to: &issues)
    }

    if report.authorizationAfter != "authorized" {
        issues.append("Approved report authorizationAfter is \(report.authorizationAfter); expected authorized.")
    }
    if !report.appLaunched {
        issues.append("Approved report must confirm MeetingVault.app was launched.")
    }
    if !report.axTrusted {
        issues.append("Approved report must confirm Accessibility inspection was trusted.")
    }
    if !report.healthRecoveryVisible {
        issues.append("Approved report must confirm Health & Recovery was visible.")
    }
    if !report.appSpeechStateInspected {
        issues.append("Approved report must confirm the app-reported Speech Recognition state was inspected.")
    }
    if !report.promptPolicyVisible {
        issues.append("Approved report must confirm the app showed the Speech Recognition prompt policy: Only from Request Once.")
    }
    if report.authorizationBefore == "notDetermined", !report.requestButtonPressed {
        issues.append("Approved report started notDetermined but did not press the app-owned Request Once control.")
    }
    if report.authorizationBefore == "notDetermined", !report.systemPromptApproved {
        issues.append("Approved report started notDetermined but did not approve the macOS Speech Recognition prompt.")
    }
    if !report.recordingStartDidNotRequestPermission {
        issues.append("Approved report must prove Start Recording did not request Speech Recognition permission implicitly.")
    }
    if !report.transcriptionStartDidNotRequestPermission {
        issues.append("Approved report must prove live/final transcription start did not request Speech Recognition permission implicitly.")
    }
    if !report.requestOnceNotRepeatedAfterResolved {
        issues.append("Approved report must prove Request Once was not shown again after Speech Recognition permission resolved.")
    }
    if report.privateAudioRecorded {
        issues.append("Approved report recorded private audio.")
    }
    if report.microphoneOpened {
        issues.append("Approved report opened the microphone; permission proof must not capture audio.")
    }
    if report.externalNetworkRequested {
        issues.append("Approved report requested external network.")
    }
    if report.externalUploadAttempted {
        issues.append("Approved report attempted external upload.")
    }
    if report.rawUITextStored {
        issues.append("Approved report stored raw UI text.")
    }
    if report.rawTranscriptStored {
        issues.append("Approved report stored raw transcript text.")
    }
    if report.rawAudioStored {
        issues.append("Approved report stored raw audio.")
    }
    if report.rawLogsStored {
        issues.append("Approved report stored raw logs.")
    }

    return (report, issues)
}

if let templateURL {
    do {
        try writeTemplate(to: templateURL)
        print("Wrote template \(templateURL.path)")
        exit(0)
    } catch {
        fputs("failed to write Apple Speech permission template: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

if approvedReportURL != nil {
    let validation = validateApprovedReport(at: approvedReportURL)
    let report = validation.report
    let status = validation.issues.isEmpty ? "pass" : "blocked"
    let steps = [
        PermissionSmokeStep(
            name: "Approved report validated",
            status: validation.issues.isEmpty ? "pass" : "fail",
            detail: validation.issues.isEmpty
                ? "bounded Apple Speech permission report proved authorized state"
                : "bounded Apple Speech permission report did not satisfy release gate"
        )
    ]
    let smokeReport = AppleSpeechPermissionSmokeReport(
        timestamp: ISO8601DateFormatter().string(from: Date()),
        status: status,
        requirePass: requirePass,
        approvedReportPath: approvedReportURL?.path,
        validatedReport: report,
        appName: appName,
        bundleIdentifier: bundleIdentifier,
        pid: nil,
        axTrusted: report?.axTrusted ?? false,
        launchedByScript: report?.appLaunched ?? false,
        approvalFlagProvided: approveSystemPrompt,
        authorizationBefore: report?.authorizationBefore ?? "unavailable",
        authorizationAfter: report?.authorizationAfter ?? "unavailable",
        promptPolicyVisible: report?.promptPolicyVisible ?? false,
        requestButtonPressed: report?.requestButtonPressed ?? false,
        recordingStartDidNotRequestPermission: report?.recordingStartDidNotRequestPermission ?? false,
        transcriptionStartDidNotRequestPermission: report?.transcriptionStartDidNotRequestPermission ?? false,
        requestOnceNotRepeatedAfterResolved: report?.requestOnceNotRepeatedAfterResolved ?? false,
        systemPromptApproved: report?.systemPromptApproved ?? false,
        privateAudioRecorded: report?.privateAudioRecorded ?? false,
        microphoneOpened: report?.microphoneOpened ?? false,
        externalNetworkRequested: report?.externalNetworkRequested ?? false,
        externalUploadAttempted: report?.externalUploadAttempted ?? false,
        rawUITextStored: report?.rawUITextStored ?? false,
        rawTranscriptStored: report?.rawTranscriptStored ?? false,
        rawAudioStored: report?.rawAudioStored ?? false,
        rawLogsStored: report?.rawLogsStored ?? false,
        steps: steps,
        issues: validation.issues
    )
    writeReport(smokeReport)
    print("[\(status == "pass" ? "OK" : "BLOCKED")] Apple Speech permission approved-report gate \(status): \(outputURL.path)")
    exit(status == "pass" || !requirePass ? 0 : 1)
}

var authorizationBefore = "unavailable"
var steps: [PermissionSmokeStep] = []
var issues: [String] = []
var launchedByScript = false
var requestButtonPressed = false
var systemPromptApproved = false
var pid: Int?

if launchApp {
    do {
        try run("/bin/bash", ["script/build_and_run.sh", "--verify", "--workspace", "diagnostics"], workingDirectory: rootURL)
        launchedByScript = true
        Thread.sleep(forTimeInterval: 2.0)
    } catch {
        let report = AppleSpeechPermissionSmokeReport(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            status: "fail",
            appName: appName,
            bundleIdentifier: bundleIdentifier,
            pid: nil,
            axTrusted: AXIsProcessTrusted(),
            launchedByScript: false,
            approvalFlagProvided: approveSystemPrompt,
            authorizationBefore: authorizationBefore,
            authorizationAfter: "unavailable",
            promptPolicyVisible: false,
            requestButtonPressed: false,
            recordingStartDidNotRequestPermission: false,
            transcriptionStartDidNotRequestPermission: false,
            requestOnceNotRepeatedAfterResolved: false,
            systemPromptApproved: false,
            privateAudioRecorded: false,
            microphoneOpened: false,
            rawUITextStored: false,
            steps: [],
            issues: ["launch failed: \(error.localizedDescription)"]
        )
        writeReport(report)
        fputs("[FAIL] Apple Speech permission smoke launch failed: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

guard let app = waitForRunningApp() else {
    let report = AppleSpeechPermissionSmokeReport(
        timestamp: ISO8601DateFormatter().string(from: Date()),
        status: "blocked",
        appName: appName,
        bundleIdentifier: bundleIdentifier,
        pid: nil,
        axTrusted: AXIsProcessTrusted(),
        launchedByScript: launchedByScript,
        approvalFlagProvided: approveSystemPrompt,
        authorizationBefore: authorizationBefore,
        authorizationAfter: "unavailable",
        promptPolicyVisible: false,
        requestButtonPressed: false,
        recordingStartDidNotRequestPermission: false,
        transcriptionStartDidNotRequestPermission: false,
        requestOnceNotRepeatedAfterResolved: false,
        systemPromptApproved: false,
        privateAudioRecorded: false,
        microphoneOpened: false,
        rawUITextStored: false,
        steps: [],
        issues: ["MeetingVault process not running"]
    )
    writeReport(report)
    fputs("[BLOCKED] MeetingVault process not running\n", stderr)
    exit(3)
}

pid = Int(app.processIdentifier)
guard AXIsProcessTrusted() else {
    let report = AppleSpeechPermissionSmokeReport(
        timestamp: ISO8601DateFormatter().string(from: Date()),
        status: "blocked",
        appName: appName,
        bundleIdentifier: bundleIdentifier,
        pid: pid,
        axTrusted: false,
        launchedByScript: launchedByScript,
        approvalFlagProvided: approveSystemPrompt,
        authorizationBefore: authorizationBefore,
        authorizationAfter: "unavailable",
        promptPolicyVisible: false,
        requestButtonPressed: false,
        recordingStartDidNotRequestPermission: false,
        transcriptionStartDidNotRequestPermission: false,
        requestOnceNotRepeatedAfterResolved: false,
        systemPromptApproved: false,
        privateAudioRecorded: false,
        microphoneOpened: false,
        rawUITextStored: false,
        steps: [],
        issues: ["Accessibility is not trusted for this terminal/app."]
    )
    writeReport(report)
    fputs("[BLOCKED] Accessibility permission is not trusted\n", stderr)
    exit(3)
}

let appElement = AXUIElementCreateApplication(app.processIdentifier)
AXUIElementSetMessagingTimeout(appElement, 0.8)
let healthVisible = waitForMarker("Health & Recovery", appElement: appElement)
addStep("Health & Recovery visible", healthVisible, "Diagnostics focus section was visible", steps: &steps, issues: &issues)
if !waitForMarker("Apple Speech Permission", appElement: appElement, timeout: 2) {
    let expanded = pressElement(containing: "Health & Recovery", appElement: appElement)
    addStep("Health & Recovery expanded", expanded, "Health & Recovery details were opened", steps: &steps, issues: &issues)
}
let permissionPanelVisible = waitForMarker("Apple Speech Permission", appElement: appElement, timeout: 6)
addStep("Apple Speech Permission visible", permissionPanelVisible, "Apple Speech permission recovery panel was visible", steps: &steps, issues: &issues)
let promptPolicyVisible = waitForMarker("Only from Request Once", appElement: appElement, timeout: 2)
addStep("Request Once policy visible", promptPolicyVisible, "Speech Recognition prompt policy was visible in the app", steps: &steps, issues: &issues)
let checkPressed = pressElement(role: kAXButtonRole as String, containing: "Check", appElement: appElement)
addStep("Permission Check pressed", checkPressed, "app-owned Speech Recognition status refresh was invoked without prompting", steps: &steps, issues: &issues)

authorizationBefore = appReportedSpeechAuthorizationState(appElement: appElement)
addStep("App speech state inspected", authorizationBefore != "unavailable", "MeetingVault reported Speech Recognition as \(authorizationBefore)", steps: &steps, issues: &issues)

if authorizationBefore == "notDetermined", !approveSystemPrompt {
    issues.append("Speech Recognition is notDetermined and --approve-system-prompt was not supplied.")
} else if authorizationBefore == "denied" {
    issues.append("Speech Recognition is denied for MeetingVault. Open System Settings > Privacy & Security > Speech Recognition, allow MeetingVault, then rerun.")
}

let beforeRequest = authorizationBefore
if beforeRequest == "notDetermined" {
    if approveSystemPrompt {
        requestButtonPressed = pressElement(role: kAXButtonRole as String, containing: "Request Once", appElement: appElement)
        addStep("Request Once pressed", requestButtonPressed, "app-owned Apple Speech permission action was invoked", steps: &steps, issues: &issues)
    } else {
        addStep("Request Once skipped", true, "approval flag was not supplied, so the app-owned permission prompt action was not invoked", steps: &steps, issues: &issues)
    }
    if requestButtonPressed, approveSystemPrompt {
        systemPromptApproved = approveSpeechSystemPrompt()
        addStep("System prompt approved", systemPromptApproved, "macOS Speech Recognition prompt Allow button was pressed", steps: &steps, issues: &issues)
    }
} else {
    addStep("Permission already resolved", true, "Speech Recognition state was \(beforeRequest)", steps: &steps, issues: &issues)
}

Thread.sleep(forTimeInterval: 1.5)
let authorizationAfter = appReportedSpeechAuthorizationState(appElement: appElement)
let passed = authorizationAfter == "authorized"
if !passed {
    issues.append("Speech Recognition authorization is \(authorizationAfter), expected authorized.")
}

let report = AppleSpeechPermissionSmokeReport(
    timestamp: ISO8601DateFormatter().string(from: Date()),
    status: passed ? "pass" : "blocked",
    appName: appName,
    bundleIdentifier: bundleIdentifier,
    pid: pid,
    axTrusted: true,
    launchedByScript: launchedByScript,
    approvalFlagProvided: approveSystemPrompt,
    authorizationBefore: authorizationBefore,
    authorizationAfter: authorizationAfter,
    promptPolicyVisible: promptPolicyVisible,
    requestButtonPressed: requestButtonPressed,
    recordingStartDidNotRequestPermission: false,
    transcriptionStartDidNotRequestPermission: false,
    requestOnceNotRepeatedAfterResolved: false,
    systemPromptApproved: systemPromptApproved,
    privateAudioRecorded: false,
    microphoneOpened: false,
    rawUITextStored: false,
    steps: steps,
    issues: issues
)
writeReport(report)

if passed {
    print("[OK] Apple Speech permission smoke passed: \(outputURL.path)")
    exit(0)
}

print("[BLOCKED] Apple Speech permission smoke blocked: \(issues.joined(separator: "; ")) evidence=\(outputURL.path)")
exit(0)
