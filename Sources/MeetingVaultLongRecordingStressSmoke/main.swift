import Foundation
import MeetingVaultCore

struct LongRecordingStressReport: Codable {
    var timestamp: String
    var status: String
    var durationSeconds: Int
    var trackCount: Int
    var chunkDurationSeconds: Int
    var chunkCountPerTrack: Int
    var totalChunkCount: Int
    var transcriptSegmentCount: Int
    var recoveryStatus: String
    var recoveryElapsedDurationSeconds: Int
    var recoveryRemoteChunkCount: Int
    var recoveryMicrophoneChunkCount: Int
    var timelineStatus: String
    var timelineCueCount: Int
    var timelineDurationSeconds: Int
    var timelineWarningCount: Int
    var exportStatus: String
    var exportedAudioFileCount: Int
    var exportedAudioManifestBytes: Int
    var encryptedChunkSampleStoredPlaintext: Bool
    var temporaryWorkspaceDeleted: Bool
    var privateAudioRecorded: Bool
    var microphoneOpened: Bool
    var externalNetworkRequested: Bool
    var rawTranscriptStored: Bool
    var rawAudioStored: Bool
    var rawLogsStored: Bool
    var issues: [String]
}

enum LongRecordingStressError: Error, LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case let .failed(message): message
        }
    }
}

@main
struct LongRecordingStressSmoke {
    static func main() {
        let rootURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let date = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
        var outputURL = rootURL
            .appendingPathComponent("docs", isDirectory: true)
            .appendingPathComponent("evidence", isDirectory: true)
            .appendingPathComponent("long-recording-stress-smoke-\(date).json")
        var durationSeconds = 10_800
        var chunkDurationSeconds = 30
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
            case "--duration-seconds":
                guard let value = iterator.next(), let seconds = Int(value), seconds > 0 else {
                    fputs("--duration-seconds requires a positive integer\n", stderr)
                    exit(2)
                }
                durationSeconds = seconds
            case "--chunk-duration-seconds":
                guard let value = iterator.next(), let seconds = Int(value), seconds > 0 else {
                    fputs("--chunk-duration-seconds requires a positive integer\n", stderr)
                    exit(2)
                }
                chunkDurationSeconds = seconds
            case "--require-pass":
                requirePass = true
            case "--help", "-h":
                print("""
                usage: script/long_recording_stress_smoke.swift [--output PATH] [--duration-seconds N] [--chunk-duration-seconds N] [--require-pass]

                Builds a non-private synthetic long-recording fixture through
                MeetingVaultCore services. It writes encrypted remote-system and
                microphone checkpoints, scans recovery diagnostics, builds a
                playback timeline, exports an audio package, and writes bounded
                JSON evidence without recording audio, opening the microphone,
                using network services, or storing raw transcript/audio/log text.
                """)
                exit(0)
            default:
                fputs("unknown argument: \(argument)\n", stderr)
                exit(2)
            }
        }

        var report = baseReport(
            durationSeconds: durationSeconds,
            chunkDurationSeconds: chunkDurationSeconds
        )
        let workspaceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultLongRecordingStress-\(UUID().uuidString)", isDirectory: true)

        do {
            report = try runStress(
                workspaceURL: workspaceURL,
                durationSeconds: durationSeconds,
                chunkDurationSeconds: chunkDurationSeconds,
                report: report
            )
            report.status = report.issues.isEmpty ? "pass" : "fail"
        } catch {
            report.status = "fail"
            report.issues.append(error.localizedDescription)
        }

        do {
            if FileManager.default.fileExists(atPath: workspaceURL.path) {
                try FileManager.default.removeItem(at: workspaceURL)
            }
            report.temporaryWorkspaceDeleted = true
        } catch {
            report.temporaryWorkspaceDeleted = false
            report.status = "fail"
            report.issues.append("Temporary workspace cleanup failed: \(error.localizedDescription)")
        }

        write(report: report, to: outputURL)
        if report.status == "pass" {
            print("[OK] long recording stress smoke passed: chunks=\(report.totalChunkCount) cues=\(report.timelineCueCount) evidence=\(outputURL.path)")
            exit(0)
        }
        fputs("[\(report.status.uppercased())] long recording stress smoke issues: \(report.issues.joined(separator: "; "))\n", stderr)
        exit(requirePass ? 1 : 0)
    }

    private static func runStress(
        workspaceURL: URL,
        durationSeconds: Int,
        chunkDurationSeconds: Int,
        report inputReport: LongRecordingStressReport
    ) throws -> LongRecordingStressReport {
        var report = inputReport
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: workspaceURL, withIntermediateDirectories: true)

        let bundleRoot = workspaceURL.appendingPathComponent("bundles", isDirectory: true)
        let exportRoot = workspaceURL.appendingPathComponent("exports", isDirectory: true)
        let meetingID = UUID(uuidString: "A1A1A1A1-A1A1-A1A1-A1A1-A1A1A1A1A1A1")!
        let bundleStore = EncryptedMeetingBundleStore(
            rootDirectory: bundleRoot,
            vault: AESGCMDataVault(
                keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 141, count: 32))
            )
        )
        let chunkWriter = EncryptedAudioChunkWriter(bundleStore: bundleStore)
        let meeting = SearchMeeting(
            id: meetingID,
            title: "Synthetic 3 hour recovery stress",
            startedAt: Date(timeIntervalSince1970: 1_780_050_000),
            sourceApp: "Synthetic Fixture"
        )
        var manifest = MeetingBundleManifest.initialEncryptedBundle(
            meetingID: meetingID,
            title: meeting.title
        )
        manifest.createdAt = meeting.startedAt
        _ = try bundleStore.createBundle(manifest)

        let chunkCount = Int(ceil(Double(durationSeconds) / Double(chunkDurationSeconds)))
        report.chunkCountPerTrack = chunkCount
        report.totalChunkCount = chunkCount * 2

        for index in 0..<chunkCount {
            let start = index * chunkDurationSeconds
            let remaining = max(0, durationSeconds - start)
            let duration = min(chunkDurationSeconds, remaining)
            guard duration > 0 else { continue }
            try writeSyntheticChunk(
                writer: chunkWriter,
                meetingID: meetingID,
                track: .remoteSystem,
                index: index,
                start: start,
                duration: duration
            )
            try writeSyntheticChunk(
                writer: chunkWriter,
                meetingID: meetingID,
                track: .microphone,
                index: index,
                start: start,
                duration: duration
            )
        }

        let sampleRecord = try chunkWriter.readCheckpoint(meetingID: meetingID, track: .remoteSystem).chunks[0]
        let rawEncryptedSample = try Data(
            contentsOf: bundleStore.bundleURL(for: meetingID)
                .appendingPathComponent(sampleRecord.relativePath)
        )
        report.encryptedChunkSampleStoredPlaintext = String(decoding: rawEncryptedSample, as: UTF8.self)
            .contains("synthetic")

        let transcript = syntheticTranscript(meetingID: meetingID, durationSeconds: durationSeconds)
        report.transcriptSegmentCount = transcript.segments.count
        try bundleStore.writeJSONArtifact(
            transcript,
            meetingID: meetingID,
            relativePath: MeetingTranscript.finalTranscriptRelativePath,
            purpose: MeetingTranscript.finalTranscriptPurpose
        )
        try bundleStore.writeJSONArtifact(
            syntheticIntelligence(meetingID: meetingID, segmentID: transcript.segments[0].id),
            meetingID: meetingID,
            relativePath: MeetingIntelligenceArtifact.summaryRelativePath,
            purpose: MeetingIntelligenceArtifact.summaryPurpose
        )

        let recovery = try RecordingRecoveryService(
            bundleStore: bundleStore,
            chunkWriter: chunkWriter
        ).recoverableReport(for: meetingID)
        report.recoveryStatus = recovery.warnings.isEmpty ? "pass" : "warning"
        report.recoveryElapsedDurationSeconds = Int(recovery.totalRecordedDuration)
        report.recoveryRemoteChunkCount = recovery.trackReports.first { $0.track == .remoteSystem }?.chunkCount ?? 0
        report.recoveryMicrophoneChunkCount = recovery.trackReports.first { $0.track == .microphone }?.chunkCount ?? 0
        if report.recoveryElapsedDurationSeconds != durationSeconds {
            report.issues.append("Recovery elapsed duration \(report.recoveryElapsedDurationSeconds) did not match expected \(durationSeconds).")
        }

        let audioRecords = try TrackKind.allCases.flatMap {
            try chunkWriter.readCheckpoint(meetingID: meetingID, track: $0).chunks
        }
        let timeline = TranscriptPlaybackTimelineService().buildTimeline(
            transcript: transcript,
            audioChunks: audioRecords
        )
        report.timelineStatus = timeline.warnings.isEmpty ? "pass" : "warning"
        report.timelineCueCount = timeline.cues.count
        report.timelineDurationSeconds = Int(timeline.duration)
        report.timelineWarningCount = timeline.warnings.count
        if !timeline.warnings.isEmpty {
            report.issues.append("Timeline produced \(timeline.warnings.count) warning(s).")
        }

        let package = try MeetingExportService(bundleStore: bundleStore).exportPackage(
            meeting: meeting,
            to: exportRoot,
            formats: [.audioPackage]
        )
        let audioPackageURL = package.fileURL(for: .audioPackage)
        let manifestURL = audioPackageURL.appendingPathComponent("manifest.json")
        let audioManifestData = try Data(contentsOf: manifestURL)
        let audioManifest = try JSONDecoder.meetingVaultExport.decode(
            MeetingAudioExportManifest.self,
            from: audioManifestData
        )
        report.exportStatus = "pass"
        report.exportedAudioFileCount = audioManifest.files.count
        report.exportedAudioManifestBytes = audioManifestData.count
        if audioManifest.files.count != report.totalChunkCount {
            report.issues.append("Audio export manifest listed \(audioManifest.files.count) files, expected \(report.totalChunkCount).")
        }
        if report.encryptedChunkSampleStoredPlaintext {
            report.issues.append("Encrypted chunk sample appeared to contain plaintext fixture content.")
        }

        return report
    }

    private static func writeSyntheticChunk(
        writer: EncryptedAudioChunkWriter,
        meetingID: UUID,
        track: TrackKind,
        index: Int,
        start: Int,
        duration: Int
    ) throws {
        let bytes = Data("synthetic-\(track.rawValue)-\(index)".utf8)
        _ = try writer.writeChunk(
            bytes,
            meetingID: meetingID,
            track: track,
            chunkIndex: index,
            startTime: TimeInterval(start),
            duration: TimeInterval(duration),
            codec: "synthetic/pcm"
        )
    }

    private static func syntheticTranscript(meetingID: UUID, durationSeconds: Int) -> MeetingTranscript {
        let segmentCount = durationSeconds / 60
        let segments = (0..<segmentCount).map { index in
            let start = TimeInterval(index * 60 + 5)
            let track: TrackKind = index.isMultiple(of: 2) ? .remoteSystem : .microphone
            return TranscriptSegment(
                id: deterministicUUID(index: index),
                speakerName: track == .remoteSystem ? "Remote" : "You",
                trackKind: track,
                startTime: start,
                endTime: start + 12,
                text: "Synthetic long recording checkpoint \(index)",
                confidence: 0.99,
                isFinal: true
            )
        }
        return MeetingTranscript(
            meetingID: meetingID,
            localeIdentifier: "en-US",
            generatedAt: Date(timeIntervalSince1970: 1_780_050_300),
            segments: segments
        )
    }

    private static func syntheticIntelligence(meetingID: UUID, segmentID: UUID) -> MeetingIntelligenceArtifact {
        let evidence = EvidenceRef(
            meetingID: meetingID,
            segmentID: segmentID,
            startTime: 5,
            endTime: 17,
            quote: "Synthetic long recording checkpoint 0"
        )
        return MeetingIntelligenceArtifact(
            meetingID: meetingID,
            providerID: "synthetic-long-recording-stress",
            generatedAt: Date(timeIntervalSince1970: 1_780_050_360),
            summary: MeetingSummary(
                title: "Synthetic long recording stress",
                oneParagraph: "Synthetic long recording checkpoint recovery, playback, and export were exercised.",
                bullets: ["Encrypted checkpoints stayed recoverable across a long two-track fixture."],
                decisions: [
                    Decision(
                        title: "Long recording fixture passed",
                        details: "Synthetic long recording checkpoint 0 was available for evidence validation.",
                        evidence: [evidence],
                        confidence: 0.99
                    )
                ],
                actionItems: []
            )
        )
    }

    private static func deterministicUUID(index: Int) -> UUID {
        UUID(uuidString: String(format: "BBBBBBBB-BBBB-BBBB-BBBB-%012d", index))!
    }

    private static func baseReport(
        durationSeconds: Int,
        chunkDurationSeconds: Int
    ) -> LongRecordingStressReport {
        LongRecordingStressReport(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            status: "fail",
            durationSeconds: durationSeconds,
            trackCount: 2,
            chunkDurationSeconds: chunkDurationSeconds,
            chunkCountPerTrack: 0,
            totalChunkCount: 0,
            transcriptSegmentCount: 0,
            recoveryStatus: "not-run",
            recoveryElapsedDurationSeconds: 0,
            recoveryRemoteChunkCount: 0,
            recoveryMicrophoneChunkCount: 0,
            timelineStatus: "not-run",
            timelineCueCount: 0,
            timelineDurationSeconds: 0,
            timelineWarningCount: 0,
            exportStatus: "not-run",
            exportedAudioFileCount: 0,
            exportedAudioManifestBytes: 0,
            encryptedChunkSampleStoredPlaintext: false,
            temporaryWorkspaceDeleted: false,
            privateAudioRecorded: false,
            microphoneOpened: false,
            externalNetworkRequested: false,
            rawTranscriptStored: false,
            rawAudioStored: false,
            rawLogsStored: false,
            issues: []
        )
    }

    private static func write(report: LongRecordingStressReport, to outputURL: URL) {
        do {
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: outputURL, options: .atomic)
        } catch {
            fputs("failed to write long recording stress report: \(error.localizedDescription)\n", stderr)
        }
    }
}
