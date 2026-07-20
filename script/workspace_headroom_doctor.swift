#!/usr/bin/env swift
import Foundation

struct DirectoryFootprint: Codable {
    var name: String
    var exists: Bool
    var bytes: Int64
}

struct CleanupCandidate: Codable {
    var name: String
    var pathHint: String
    var exists: Bool
    var bytes: Int64
    var safetyClass: String
    var requiresManualReview: Bool
    var cleanupAction: String
}

struct WorkspaceHeadroomDoctorReport: Codable {
    var timestamp: String
    var status: String
    var headroomStatus: String
    var sourceCommit: String
    var volumeAvailableBytes: Int64?
    var volumeTotalBytes: Int64?
    var requiredLongRecordingBytes: Int64
    var recommendedVerificationBytes: Int64
    var buildCacheFootprint: DirectoryFootprint
    var stagedAppFootprint: DirectoryFootprint
    var cleanupCandidates: [CleanupCandidate]
    var cleanupCandidateBytes: Int64
    var projectedAvailableBytesAfterCleanupCandidates: Int64?
    var wouldPassLongRecordingIfCleanupCandidatesCleared: Bool?
    var wouldPassRecommendedVerificationIfCleanupCandidatesCleared: Bool?
    var cleanupActions: [String]
    var deletionPerformed: Bool
    var privateAudioRecorded: Bool
    var microphoneOpened: Bool
    var externalNetworkRequested: Bool
    var externalUploadAttempted: Bool
    var rawTranscriptStored: Bool
    var rawAudioStored: Bool
    var rawLogsStored: Bool
    var rawUITextStored: Bool
    var issues: [String]
}

enum WorkspaceHeadroomDoctor {
    static let longRecordingDurationSeconds: Int64 = 3 * 60 * 60
    static let longRecordingTrackCount: Int64 = 2
    static let bytesPerSecondPerTrack: Int64 = 96_000
    static let artifactReserveBytes: Int64 = 1 * 1_024 * 1_024 * 1_024
    static let safetyReserveBytes: Int64 = 5 * 1_024 * 1_024 * 1_024
    static let recommendedVerificationExtraBytes: Int64 = 4 * 1_024 * 1_024 * 1_024

    static func main() {
        let rootURL = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let date = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
        var outputURL = rootURL
            .appendingPathComponent("docs", isDirectory: true)
            .appendingPathComponent("evidence", isDirectory: true)
            .appendingPathComponent("workspace-headroom-doctor-\(date).json")
        var requirePass = false

        var iterator = CommandLine.arguments.dropFirst().makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--output":
                guard let value = iterator.next() else {
                    fputs("--output requires a path\n", stderr)
                    exit(2)
                }
                outputURL = URL(fileURLWithPath: value)
            case "--require-pass":
                requirePass = true
            case "--help", "-h":
                print("""
                usage: script/workspace_headroom_doctor.swift [--output PATH] [--require-pass]

                Writes a bounded operator report for the current workspace volume.
                The doctor checks whether the volume has enough free space for
                MeetingVault's three-hour two-track recording budget plus release
                verification headroom. It does not delete files, record audio,
                open microphones, request network access, upload, or store raw
                transcript/audio/log/UI text.
                """)
                exit(0)
            default:
                fputs("unknown argument: \(argument)\n", stderr)
                exit(2)
            }
        }

        let report = buildReport(rootURL: rootURL)
        do {
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: outputURL, options: .atomic)
        } catch {
            fputs("failed to write workspace headroom report: \(error.localizedDescription)\n", stderr)
            exit(1)
        }

        print("Wrote \(outputURL.path)")
        print("status=\(report.status) headroomStatus=\(report.headroomStatus) availableBytes=\(report.volumeAvailableBytes ?? -1) recommendedBytes=\(report.recommendedVerificationBytes)")
        if requirePass && report.headroomStatus != "pass" {
            exit(1)
        }
        exit(0)
    }

    private static func buildReport(rootURL: URL) -> WorkspaceHeadroomDoctorReport {
        let capacity = volumeCapacity(for: rootURL)
        let requiredLongRecordingBytes = longRecordingBytes
        let recommendedVerificationBytes = requiredLongRecordingBytes + recommendedVerificationExtraBytes
        let buildFootprint = footprint(name: ".build", url: rootURL.appendingPathComponent(".build", isDirectory: true))
        let distFootprint = footprint(name: "dist", url: rootURL.appendingPathComponent("dist", isDirectory: true))
        let candidates = cleanupCandidates(rootURL: rootURL)
        let cleanupCandidateBytes = candidates.reduce(Int64(0)) { $0 + $1.bytes }
        let availableBytes = capacity.availableBytes
        let projectedAvailableBytes = availableBytes.map { $0 + cleanupCandidateBytes }

        var issues: [String] = []
        let headroomStatus: String
        if let availableBytes {
            if availableBytes >= recommendedVerificationBytes {
                headroomStatus = "pass"
            } else if availableBytes >= requiredLongRecordingBytes {
                headroomStatus = "warning"
                issues.append("Workspace volume can satisfy the app long-recording budget, but release verification headroom is below the recommended threshold.")
            } else {
                headroomStatus = "blocked"
                issues.append("Workspace volume is below the app's three-hour two-track recording budget plus transcript/artifact reserve.")
            }
        } else {
            headroomStatus = "blocked"
            issues.append("Workspace volume capacity could not be measured.")
        }

        return WorkspaceHeadroomDoctorReport(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            status: "pass",
            headroomStatus: headroomStatus,
            sourceCommit: gitCommit(rootURL: rootURL),
            volumeAvailableBytes: availableBytes,
            volumeTotalBytes: capacity.totalBytes,
            requiredLongRecordingBytes: requiredLongRecordingBytes,
            recommendedVerificationBytes: recommendedVerificationBytes,
            buildCacheFootprint: buildFootprint,
            stagedAppFootprint: distFootprint,
            cleanupCandidates: candidates,
            cleanupCandidateBytes: cleanupCandidateBytes,
            projectedAvailableBytesAfterCleanupCandidates: projectedAvailableBytes,
            wouldPassLongRecordingIfCleanupCandidatesCleared: projectedAvailableBytes.map { $0 >= requiredLongRecordingBytes },
            wouldPassRecommendedVerificationIfCleanupCandidatesCleared: projectedAvailableBytes.map { $0 >= recommendedVerificationBytes },
            cleanupActions: cleanupActions(
                headroomStatus: headroomStatus,
                buildFootprint: buildFootprint,
                distFootprint: distFootprint,
                cleanupCandidateBytes: cleanupCandidateBytes,
                projectedAvailableBytes: projectedAvailableBytes,
                recommendedVerificationBytes: recommendedVerificationBytes
            ),
            deletionPerformed: false,
            privateAudioRecorded: false,
            microphoneOpened: false,
            externalNetworkRequested: false,
            externalUploadAttempted: false,
            rawTranscriptStored: false,
            rawAudioStored: false,
            rawLogsStored: false,
            rawUITextStored: false,
            issues: issues
        )
    }

    private static var longRecordingBytes: Int64 {
        longRecordingDurationSeconds * longRecordingTrackCount * bytesPerSecondPerTrack
            + artifactReserveBytes
            + safetyReserveBytes
    }

    private static func volumeCapacity(for url: URL) -> (availableBytes: Int64?, totalBytes: Int64?) {
        let keys: Set<URLResourceKey> = [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
            .volumeTotalCapacityKey
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else {
            return (nil, nil)
        }
        let available = values.volumeAvailableCapacityForImportantUsage
            ?? values.volumeAvailableCapacity.map(Int64.init)
        return (available, values.volumeTotalCapacity.map(Int64.init))
    }

    private static func footprint(name: String, url: URL) -> DirectoryFootprint {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return DirectoryFootprint(name: name, exists: false, bytes: 0)
        }
        return DirectoryFootprint(name: name, exists: true, bytes: directorySize(url))
    }

    private static func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(
                forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
            ), values.isRegularFile == true else {
                continue
            }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }

    private static func cleanupActions(
        headroomStatus: String,
        buildFootprint: DirectoryFootprint,
        distFootprint: DirectoryFootprint,
        cleanupCandidateBytes: Int64,
        projectedAvailableBytes: Int64?,
        recommendedVerificationBytes: Int64
    ) -> [String] {
        guard headroomStatus != "pass" else {
            return ["No cleanup required before normal MeetingVault verification."]
        }
        var actions = [
            "Free workspace volume space before clean-checkout, long-recording, or visual matrix evidence refresh.",
            "Review cleanupCandidates with Finder or a disk usage tool; every candidate in this report requires manual review and the doctor deletes nothing."
        ]
        if cleanupCandidateBytes > 0 {
            let projected = projectedAvailableBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "unknown"
            let recommended = ByteCountFormatter.string(fromByteCount: recommendedVerificationBytes, countStyle: .file)
            actions.append("Cleanup candidates total \(ByteCountFormatter.string(fromByteCount: cleanupCandidateBytes, countStyle: .file)); projected available space after reviewed cleanup is \(projected) against \(recommended) recommended.")
        }
        if buildFootprint.bytes > 0 {
            actions.append("If rebuilding from scratch is acceptable, move the .build directory to Trash after review.")
        }
        if distFootprint.bytes > 0 {
            actions.append("If staged apps are no longer needed, move the dist directory to Trash after review.")
        }
        actions.append("Rerun script/workspace_headroom_doctor.swift --require-pass after cleanup.")
        return actions
    }

    private static func cleanupCandidates(rootURL: URL) -> [CleanupCandidate] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates: [(name: String, url: URL, pathHint: String, safetyClass: String, cleanupAction: String)] = [
            (
                ".build",
                rootURL.appendingPathComponent(".build", isDirectory: true),
                "workspace/.build",
                "buildProduct",
                "Move to Trash only if rebuilding SwiftPM products from scratch is acceptable."
            ),
            (
                "dist",
                rootURL.appendingPathComponent("dist", isDirectory: true),
                "workspace/dist",
                "stagedAppBundle",
                "Move to Trash only if staged app bundles are no longer needed."
            ),
            (
                "CoreSimulator devices and runtimes",
                home.appendingPathComponent("Library/Developer/CoreSimulator", isDirectory: true),
                "~/Library/Developer/CoreSimulator",
                "simulatorData",
                "Review in Finder or Xcode Devices and Simulators; remove only unused simulator data/runtimes."
            ),
            (
                "Xcode DerivedData",
                home.appendingPathComponent("Library/Developer/Xcode/DerivedData", isDirectory: true),
                "~/Library/Developer/Xcode/DerivedData",
                "generatedCache",
                "Move to Trash only if rebuilding Xcode indexes and intermediates is acceptable."
            ),
            (
                "Xcode Archives",
                home.appendingPathComponent("Library/Developer/Xcode/Archives", isDirectory: true),
                "~/Library/Developer/Xcode/Archives",
                "distributionArchive",
                "Review archived apps first; keep archives still needed for release or symbolication."
            ),
            (
                "SwiftPM cache",
                home.appendingPathComponent("Library/Caches/org.swift.swiftpm", isDirectory: true),
                "~/Library/Caches/org.swift.swiftpm",
                "generatedCache",
                "Move to Trash only if refetching or rebuilding SwiftPM cache is acceptable."
            ),
            (
                "User cache",
                home.appendingPathComponent(".cache", isDirectory: true),
                "~/.cache",
                "generatedCache",
                "Review contents first; remove only tool caches you recognize as safe to rebuild."
            ),
            (
                "SwiftPM working state",
                home.appendingPathComponent(".swiftpm", isDirectory: true),
                "~/.swiftpm",
                "generatedCache",
                "Review contents first; remove only disposable SwiftPM state."
            )
        ]

        return candidates.map { candidate in
            let footprint = footprint(name: candidate.name, url: candidate.url)
            return CleanupCandidate(
                name: candidate.name,
                pathHint: candidate.pathHint,
                exists: footprint.exists,
                bytes: footprint.bytes,
                safetyClass: candidate.safetyClass,
                requiresManualReview: true,
                cleanupAction: candidate.cleanupAction
            )
        }
    }

    private static func gitCommit(rootURL: URL) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["rev-parse", "HEAD"]
        process.currentDirectoryURL = rootURL
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let output = String(data: data, encoding: .utf8) else {
                return "unknown"
            }
            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return "unknown"
        }
    }
}

WorkspaceHeadroomDoctor.main()
