#!/usr/bin/env swift
import CoreGraphics
import Foundation
import ImageIO

enum CuratedScreenshotAppearance: String, Codable {
    case light
    case dark
}

struct CuratedScreenshotSpec {
    var fileName: String
    var appearance: CuratedScreenshotAppearance
    var minimumPixelWidth: Int = 1_200
    var minimumPixelHeight: Int = 700
    var allowsAlpha: Bool = false
    var surfaceMarkers: [String] = []
}

struct CuratedSurfaceGeometryEvidence: Codable {
    var surface: String
    var fileName: String
    var markerVisibility: [String: Bool]
    var withinWindowBounds: Bool
}

struct CuratedSurfaceGeometryEnvelope: Codable {
    var surfaceGeometryEvidence: [CuratedSurfaceGeometryEvidence]
}

struct SampledImageMetrics {
    var uniqueSampleColors: Int
    var nearBlackPixelRatio: Double
    var averageLuminance: Double
    var luminanceStandardDeviation: Double
}

struct CuratedScreenshotFileAudit: Codable {
    var fileName: String
    var repoRelativePath: String
    var expectedAppearance: String
    var status: String
    var fileBytes: Int
    var pixelWidth: Int
    var pixelHeight: Int
    var uniqueSampleColors: Int
    var nearBlackPixelRatio: Double
    var averageLuminance: Double
    var luminanceStandardDeviation: Double
    var opaque: Bool
    var nonBlank: Bool
    var pathSafe: Bool
    var artifactFree: Bool
    var lightIntegrityPassed: Bool?
    var darkIntegrityPassed: Bool?
    var surfaceGeometryPassed: Bool?
    var issues: [String]
}

struct CuratedScreenshotAuditReport: Codable {
    var timestamp: String
    var status: String
    var expectedFileNames: [String]
    var actualFileNames: [String]
    var lightNearBlackRatioUpperBound: Double
    var rawImageContentStored: Bool
    var surfaceGeometryEvidence: [CuratedSurfaceGeometryEvidence]
    var files: [CuratedScreenshotFileAudit]
    var issues: [String]
}

let expectedScreenshots = [
    CuratedScreenshotSpec(fileName: "meeting-console.png", appearance: .light),
    CuratedScreenshotSpec(
        fileName: "recording-setup.png",
        appearance: .light,
        allowsAlpha: true,
        surfaceMarkers: ["transcription-recovery-row"]
    ),
    CuratedScreenshotSpec(fileName: "transcript-agent.png", appearance: .light),
    CuratedScreenshotSpec(fileName: "health-recovery.png", appearance: .dark),
    CuratedScreenshotSpec(
        fileName: "mini-recorder.png",
        appearance: .dark,
        minimumPixelWidth: 800,
        minimumPixelHeight: 600,
        allowsAlpha: true
    ),
    CuratedScreenshotSpec(
        fileName: "confidence-review.png",
        appearance: .light,
        allowsAlpha: true,
        surfaceMarkers: ["confidence-review-title", "confidence-review-issue-content", "confidence-review-correction-controls"]
    ),
    CuratedScreenshotSpec(
        fileName: "models-privacy.png",
        appearance: .light,
        allowsAlpha: true,
        surfaceMarkers: ["settings-status-content"]
    )
]
let lightNearBlackRatioUpperBound = 0.08
let minimumFileBytes = 10_000
let minimumUniqueSampleColors = 64
let minimumLuminanceStandardDeviation = 0.05
let darkAverageLuminanceRange = 0.08...0.55
let darkNearBlackRatioUpperBound = 0.85

let rootURL = URL(fileURLWithPath: CommandLine.arguments[0])
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .standardizedFileURL
let screenshotDirectory = rootURL
    .appendingPathComponent("docs/screenshots", isDirectory: true)
let date = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
var outputURL = rootURL
    .appendingPathComponent("docs/evidence", isDirectory: true)
    .appendingPathComponent("curated-screenshot-audit-\(date).json")
var surfaceEvidenceURL: URL?

var iterator = CommandLine.arguments.dropFirst().makeIterator()
while let argument = iterator.next() {
    switch argument {
    case "--output":
        guard let path = iterator.next() else {
            fputs("--output requires a path\n", stderr)
            exit(2)
        }
        outputURL = URL(fileURLWithPath: path)
    case "--surface-evidence":
        guard let path = iterator.next() else {
            fputs("--surface-evidence requires a path\n", stderr)
            exit(2)
        }
        surfaceEvidenceURL = URL(fileURLWithPath: path)
    case "--help", "-h":
        print("""
        usage: script/curated_screenshot_audit.swift [--output PATH] [--surface-evidence PATH]

        Validates the four final repository screenshots directly and writes a
        bounded metrics-only JSON report. It stores no image pixels or UI text.
        """)
        exit(0)
    default:
        fputs("unknown argument: \(argument)\n", stderr)
        exit(2)
    }
}

let surfaceGeometryEvidence: [CuratedSurfaceGeometryEvidence] = surfaceEvidenceURL.flatMap { url in
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(CuratedSurfaceGeometryEnvelope.self, from: data).surfaceGeometryEvidence
} ?? []
let surfaceGeometryByFile = Dictionary(
    uniqueKeysWithValues: surfaceGeometryEvidence.map { ($0.fileName, $0) }
)

func repoRelativePath(for url: URL) -> String? {
    let rootPath = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
    let path = url.standardizedFileURL.path
    guard path.hasPrefix(rootPath) else { return nil }
    let relativePath = String(path.dropFirst(rootPath.count))
    guard !relativePath.hasPrefix("/"),
          !relativePath.split(separator: "/").contains(".."),
          !relativePath.contains("/Users/") else {
        return nil
    }
    return relativePath
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

func sampledImageMetrics(
    _ image: CGImage,
    appearance: CuratedScreenshotAppearance
) -> SampledImageMetrics? {
    let width = 128
    let height = 128
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
        let background: CGColor = appearance == .light
            ? CGColor(gray: 1, alpha: 1)
            : CGColor(gray: 0.12, alpha: 1)
        context.setFillColor(background)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    guard rendered else { return nil }

    var uniqueColors = Set<UInt32>()
    var nearBlackPixels = 0
    var luminanceValues: [Double] = []
    luminanceValues.reserveCapacity(width * height)
    for offset in stride(from: 0, to: bytes.count, by: 4) {
        let red = Double(bytes[offset]) / 255
        let green = Double(bytes[offset + 1]) / 255
        let blue = Double(bytes[offset + 2]) / 255
        let packed = UInt32(bytes[offset]) << 24
            | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8
            | UInt32(bytes[offset + 3])
        uniqueColors.insert(packed)
        if bytes[offset] < 24,
           bytes[offset + 1] < 24,
           bytes[offset + 2] < 24 {
            nearBlackPixels += 1
        }
        luminanceValues.append((0.2126 * red) + (0.7152 * green) + (0.0722 * blue))
    }

    let averageLuminance = luminanceValues.reduce(0, +) / Double(luminanceValues.count)
    let variance = luminanceValues.reduce(0) { partial, value in
        let distance = value - averageLuminance
        return partial + (distance * distance)
    } / Double(luminanceValues.count)
    return SampledImageMetrics(
        uniqueSampleColors: uniqueColors.count,
        nearBlackPixelRatio: Double(nearBlackPixels) / Double(width * height),
        averageLuminance: averageLuminance,
        luminanceStandardDeviation: sqrt(variance)
    )
}

func auditScreenshot(_ spec: CuratedScreenshotSpec) -> CuratedScreenshotFileAudit {
    let screenshotURL = screenshotDirectory.appendingPathComponent(spec.fileName)
    var issues: [String] = []
    let relativePath = repoRelativePath(for: screenshotURL)
    let pathSafe = relativePath != nil
    let geometryEvidence = surfaceGeometryByFile[spec.fileName]
    let surfaceGeometryPassed: Bool? = spec.surfaceMarkers.isEmpty ? nil : geometryEvidence.map { evidence in
        evidence.withinWindowBounds
            && Set(evidence.markerVisibility.keys) == Set(spec.surfaceMarkers)
            && spec.surfaceMarkers.allSatisfy { evidence.markerVisibility[$0] == true }
    } ?? false
    if !pathSafe {
        issues.append("Screenshot path is outside the repository or unsafe.")
    }

    let fileBytes = ((try? FileManager.default.attributesOfItem(atPath: screenshotURL.path)[.size]) as? NSNumber)?.intValue ?? 0
    guard let source = CGImageSourceCreateWithURL(screenshotURL as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
          let metrics = sampledImageMetrics(image, appearance: spec.appearance) else {
        issues.append("Screenshot is missing, unreadable, or could not be sampled.")
        return CuratedScreenshotFileAudit(
            fileName: spec.fileName,
            repoRelativePath: relativePath ?? "invalid",
            expectedAppearance: spec.appearance.rawValue,
            status: "fail",
            fileBytes: fileBytes,
            pixelWidth: 0,
            pixelHeight: 0,
            uniqueSampleColors: 0,
            nearBlackPixelRatio: 1,
            averageLuminance: 0,
            luminanceStandardDeviation: 0,
            opaque: false,
            nonBlank: false,
            pathSafe: pathSafe,
            artifactFree: false,
            lightIntegrityPassed: spec.appearance == .light ? false : nil,
            darkIntegrityPassed: spec.appearance == .dark ? false : nil,
            surfaceGeometryPassed: surfaceGeometryPassed,
            issues: issues
        )
    }

    let opaque = !imageHasAlpha(image)
    let nonBlank = fileBytes >= minimumFileBytes
        && image.width >= spec.minimumPixelWidth
        && image.height >= spec.minimumPixelHeight
        && metrics.uniqueSampleColors >= minimumUniqueSampleColors
        && metrics.luminanceStandardDeviation >= minimumLuminanceStandardDeviation
    if !opaque && !spec.allowsAlpha {
        issues.append("Screenshot contains an alpha channel outside the approved native-window captures.")
    }
    if !nonBlank { issues.append("Screenshot lacks the required size or sampled detail.") }

    let lightIntegrityPassed: Bool? = spec.appearance == .light
        ? metrics.nearBlackPixelRatio <= lightNearBlackRatioUpperBound
        : nil
    if lightIntegrityPassed == false {
        issues.append("Light screenshot exceeds the near-black artifact threshold.")
    }

    let darkIntegrityPassed: Bool? = spec.appearance == .dark
        ? darkAverageLuminanceRange.contains(metrics.averageLuminance)
            && metrics.nearBlackPixelRatio <= darkNearBlackRatioUpperBound
            && metrics.luminanceStandardDeviation >= minimumLuminanceStandardDeviation
        : nil
    if darkIntegrityPassed == false {
        issues.append("Dark screenshot falls outside the bounded luminance/detail envelope.")
    }
    if surfaceGeometryPassed == false {
        issues.append("Required native surface markers were not proven visible within the captured window bounds.")
    }

    let artifactFree = (lightIntegrityPassed ?? darkIntegrityPassed) == true
    return CuratedScreenshotFileAudit(
        fileName: spec.fileName,
        repoRelativePath: relativePath ?? "invalid",
        expectedAppearance: spec.appearance.rawValue,
        status: issues.isEmpty ? "pass" : "fail",
        fileBytes: fileBytes,
        pixelWidth: image.width,
        pixelHeight: image.height,
        uniqueSampleColors: metrics.uniqueSampleColors,
        nearBlackPixelRatio: metrics.nearBlackPixelRatio,
        averageLuminance: metrics.averageLuminance,
        luminanceStandardDeviation: metrics.luminanceStandardDeviation,
        opaque: opaque,
        nonBlank: nonBlank,
        pathSafe: pathSafe,
        artifactFree: artifactFree,
        lightIntegrityPassed: lightIntegrityPassed,
        darkIntegrityPassed: darkIntegrityPassed,
        surfaceGeometryPassed: surfaceGeometryPassed,
        issues: issues
    )
}

let expectedFileNames = expectedScreenshots.map(\.fileName).sorted()
let actualFileNames = ((try? FileManager.default.contentsOfDirectory(
    at: screenshotDirectory,
    includingPropertiesForKeys: nil
)) ?? [])
    .filter { $0.pathExtension.lowercased() == "png" }
    .map(\.lastPathComponent)
    .sorted()
var reportIssues: [String] = []
if actualFileNames != expectedFileNames {
    reportIssues.append("PNG file membership does not match the expected curated set.")
}

let fileAudits = expectedScreenshots.map(auditScreenshot)
for fileAudit in fileAudits where fileAudit.status != "pass" {
    reportIssues.append("\(fileAudit.fileName) failed curated integrity checks.")
}
let report = CuratedScreenshotAuditReport(
    timestamp: ISO8601DateFormatter().string(from: Date()),
    status: reportIssues.isEmpty ? "pass" : "fail",
    expectedFileNames: expectedFileNames,
    actualFileNames: actualFileNames,
    lightNearBlackRatioUpperBound: lightNearBlackRatioUpperBound,
    rawImageContentStored: false,
    surfaceGeometryEvidence: surfaceGeometryEvidence,
    files: fileAudits,
    issues: reportIssues
)

do {
    try FileManager.default.createDirectory(
        at: outputURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(report).write(to: outputURL, options: .atomic)
} catch {
    fputs("failed to write curated screenshot audit: \(error.localizedDescription)\n", stderr)
    exit(1)
}

print("[\(report.status.uppercased())] curated screenshot audit: files=\(fileAudits.count) evidence=\(repoRelativePath(for: outputURL) ?? "external-output")")
exit(report.status == "pass" ? 0 : 1)
