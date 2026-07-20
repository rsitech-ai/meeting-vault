import Foundation
import MeetingVaultCore

struct FoundationModelsSmokeReport: Codable {
    var timestamp: String
    var status: String
    var availabilityStatus: String
    var availabilityReason: String?
    var intelligenceStatus: String
    var transcriptQuestionAnswerStatus: String
    var usedSyntheticTranscriptFixture: Bool
    var usedLocalImportSampleFixture: Bool
    var usedGeneratedEnglishImportFixture: Bool
    var importFixtureKind: String
    var localImportStatus: String
    var localSampleMatchedCount: Int
    var selectedAudioExtension: String?
    var selectedAudioByteCount: Int?
    var selectedTranscriptLanguage: String?
    var transcriptLineCount: Int
    var importedAudioChunkCount: Int
    var encryptedLibraryCreated: Bool
    var generatedFixtureCreated: Bool
    var temporaryWorkspaceDeleted: Bool
    var privateAudioRecorded: Bool
    var microphoneOpened: Bool
    var externalNetworkRequested: Bool
    var rawTranscriptStored: Bool
    var rawModelOutputStored: Bool
    var meetingID: String
    var segmentCount: Int
    var expectedEvidenceKinds: [String]
    var summaryTitleGenerated: Bool
    var summaryBulletCount: Int
    var decisionEvidenceCount: Int
    var actionEvidenceCount: Int
    var openQuestionEvidenceCount: Int
    var riskEvidenceCount: Int
    var answerEvidenceCount: Int
    var allEvidenceQuotesFoundInTranscript: Bool
    var issues: [String]
}

private struct LocalImportFixture {
    var transcript: MeetingTranscript
    var temporaryWorkspaceURL: URL
    var matchedSampleCount: Int
    var selectedAudioExtension: String
    var selectedAudioByteCount: Int
    var selectedTranscriptLanguage: String?
    var transcriptLineCount: Int
    var importedAudioChunkCount: Int
    var encryptedLibraryCreated: Bool
    var generatedFixtureCreated: Bool
    var fixtureKind: String
}

enum FoundationModelsSmokeError: Error, LocalizedError {
    case timeout(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case let .timeout(label):
            return "\(label) timed out"
        case let .failed(message):
            return message
        }
    }
}

@main
struct FoundationModelsFixtureSmoke {
    static func main() async {
        let rootURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let date = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
        var outputURL = rootURL
            .appendingPathComponent("docs", isDirectory: true)
            .appendingPathComponent("evidence", isDirectory: true)
            .appendingPathComponent("foundation-models-fixture-smoke-\(date).json")
        var requirePass = false
        var timeoutSeconds: TimeInterval = 75
        var useLocalImportSample = false
        var useGeneratedEnglishImportFixture = false
        var transcriptDirectory: URL?
        var recordingDirectory: URL?
        var outputWasProvided = false

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
            case "--timeout":
                guard let value = iterator.next(), let seconds = TimeInterval(value), seconds > 0 else {
                    fputs("--timeout requires a positive number of seconds\n", stderr)
                    exit(2)
                }
                timeoutSeconds = seconds
            case "--local-import-sample":
                useLocalImportSample = true
            case "--english-import-fixture":
                useLocalImportSample = true
                useGeneratedEnglishImportFixture = true
            case "--transcript-dir":
                guard let value = iterator.next(), !value.isEmpty else {
                    fputs("--transcript-dir requires a path\n", stderr)
                    exit(2)
                }
                transcriptDirectory = URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
            case "--recording-dir":
                guard let value = iterator.next(), !value.isEmpty else {
                    fputs("--recording-dir requires a path\n", stderr)
                    exit(2)
                }
                recordingDirectory = URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
            case "--require-pass":
                requirePass = true
            case "--help", "-h":
                print("""
                usage: script/foundation_models_fixture_smoke.swift [--output PATH] [--timeout SECONDS] [--require-pass] [--local-import-sample --transcript-dir PATH --recording-dir PATH] [--english-import-fixture]

                Runs MeetingVault's real Foundation Models meeting-intelligence
                provider and transcript Q&A provider against either a non-private
                synthetic transcript fixture, an explicitly provided local
                MP3/TXT import sample, or a generated privacy-safe English
                external MP3/TXT fixture. The smoke does not open the
                microphone, record audio, request external network services, or
                store raw transcript/model output in evidence.

                By default, unavailable Foundation Models writes status=blocked
                and exits 0. Use --require-pass for a release gate that must fail
                unless both real provider calls pass.
                """)
                exit(0)
            default:
                fputs("unknown argument: \(argument)\n", stderr)
                exit(2)
            }
        }

        if useLocalImportSample, !outputWasProvided {
            let evidenceFileName = useGeneratedEnglishImportFixture
                ? "foundation-models-english-import-smoke-\(date).json"
                : "foundation-models-local-import-smoke-\(date).json"
            outputURL = rootURL
                .appendingPathComponent("docs", isDirectory: true)
                .appendingPathComponent("evidence", isDirectory: true)
                .appendingPathComponent(evidenceFileName)
        }

        var transcript = fixtureTranscript
        var report = baseReport(
            meetingID: transcript.meetingID,
            segmentCount: transcript.segments.count,
            expectedEvidenceKinds: ["decision", "action", "openQuestion", "risk", "answer"]
        )
        var temporaryWorkspaceURL: URL?
        if useLocalImportSample {
            do {
                let fixture = try useGeneratedEnglishImportFixture
                    ? makeGeneratedEnglishImportFixture()
                    : makeLocalImportFixture(
                        transcriptDirectory: transcriptDirectory,
                        recordingDirectory: recordingDirectory
                    )
                transcript = fixture.transcript
                temporaryWorkspaceURL = fixture.temporaryWorkspaceURL
                report = baseReport(
                    meetingID: transcript.meetingID,
                    segmentCount: transcript.segments.count,
                    expectedEvidenceKinds: useGeneratedEnglishImportFixture
                        ? ["decision", "action", "openQuestion", "risk", "answer"]
                        : ["summaryTitle", "summaryBullet", "answer"]
                )
                report.usedSyntheticTranscriptFixture = false
                report.usedLocalImportSampleFixture = true
                report.usedGeneratedEnglishImportFixture = useGeneratedEnglishImportFixture
                report.importFixtureKind = fixture.fixtureKind
                report.localImportStatus = "pass"
                report.localSampleMatchedCount = fixture.matchedSampleCount
                report.selectedAudioExtension = fixture.selectedAudioExtension
                report.selectedAudioByteCount = fixture.selectedAudioByteCount
                report.selectedTranscriptLanguage = fixture.selectedTranscriptLanguage
                report.transcriptLineCount = fixture.transcriptLineCount
                report.importedAudioChunkCount = fixture.importedAudioChunkCount
                report.encryptedLibraryCreated = fixture.encryptedLibraryCreated
                report.generatedFixtureCreated = fixture.generatedFixtureCreated
            } catch {
                report = baseReport(
                    meetingID: UUID(uuidString: "91919191-9191-9191-9191-919191919191")!,
                    segmentCount: 0,
                    expectedEvidenceKinds: ["summaryTitle", "summaryBullet", "answer"]
                )
                report.usedSyntheticTranscriptFixture = false
                report.usedLocalImportSampleFixture = true
                report.usedGeneratedEnglishImportFixture = useGeneratedEnglishImportFixture
                report.importFixtureKind = useGeneratedEnglishImportFixture ? "generated-english" : "local-sample"
                report.localImportStatus = "blocked"
                report.status = "blocked"
                report.issues.append(error.localizedDescription)
                write(report: report, to: outputURL)
                finish(report: report, requirePass: requirePass)
            }
        }
        let availability = SystemFoundationModelsAvailabilityProvider().currentAvailability()
        report.availabilityStatus = availability.isAvailable ? "available" : "unavailable"
        report.availabilityReason = availability.reason

        guard availability.isAvailable else {
            report.status = "blocked"
            report.issues.append(availability.reason ?? "Foundation Models are unavailable.")
            cleanupLocalWorkspace(temporaryWorkspaceURL, report: &report)
            write(report: report, to: outputURL)
            finish(report: report, requirePass: requirePass)
        }

        let modelTranscript = transcript
        var summary: MeetingSummary?
        do {
            summary = try await withTimeout(seconds: timeoutSeconds, label: "Foundation Models intelligence fixture") {
                try await FoundationModelsMeetingIntelligenceProvider().summarize(
                    segments: modelTranscript.segments,
                    meetingID: modelTranscript.meetingID
                )
            }
            report.intelligenceStatus = "pass"
        } catch {
            recordProviderFailure(error, provider: "intelligence", report: &report)
        }

        var answer: TranscriptQuestionAnswer?
        let transcriptQuestion = "What blocks release, and who owns the next action?"
        do {
            answer = try await withTimeout(seconds: timeoutSeconds, label: "Foundation Models transcript Q&A fixture") {
                try await FoundationModelsTranscriptQuestionAnsweringProvider().answer(
                    question: transcriptQuestion,
                    transcript: modelTranscript
                )
            }
            report.transcriptQuestionAnswerStatus = "pass"
        } catch {
            recordProviderFailure(error, provider: "transcriptQuestionAnswer", report: &report)
        }

        if let summary {
            report.summaryTitleGenerated = !summary.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            report.summaryBulletCount = summary.bullets.count
            report.decisionEvidenceCount = summary.decisions.flatMap(\.evidence).count
            report.actionEvidenceCount = summary.actionItems.flatMap(\.evidence).count
            report.openQuestionEvidenceCount = summary.openQuestions.flatMap(\.evidence).count
            report.riskEvidenceCount = summary.risks.flatMap(\.evidence).count
        }
        if let answer {
            report.answerEvidenceCount = answer.evidence.count
        }
        report.allEvidenceQuotesFoundInTranscript = allEvidenceQuotesFound(
            summary: summary,
            answer: answer,
            transcript: modelTranscript
        )

        let missingKinds = missingExpectedEvidenceKinds(report: report)
        if !report.issues.isEmpty {
            if !missingKinds.isEmpty {
                report.issues.append("Missing expected evidence kinds: \(missingKinds.joined(separator: ", ")).")
            }
        } else if !missingKinds.isEmpty {
            report.status = "fail"
            report.issues.append("Missing expected evidence kinds: \(missingKinds.joined(separator: ", ")).")
        } else if !report.allEvidenceQuotesFoundInTranscript {
            report.status = "fail"
            report.issues.append("At least one returned evidence quote was not found in the synthetic transcript.")
        } else {
            report.status = "pass"
        }

        cleanupLocalWorkspace(temporaryWorkspaceURL, report: &report)
        write(report: report, to: outputURL)
        finish(report: report, requirePass: requirePass)
    }

    private static let fixtureTranscript = MeetingTranscript(
        meetingID: UUID(uuidString: "91919191-9191-9191-9191-919191919191")!,
        localeIdentifier: "en-US",
        generatedAt: Date(timeIntervalSince1970: 1_783_036_800),
        segments: [
            TranscriptSegment(
                id: UUID(uuidString: "92929292-9292-9292-9292-929292929292")!,
                speakerName: "Anna",
                trackKind: .remoteSystem,
                startTime: 4,
                endTime: 12,
                text: "Decision: we will ship the private beta only after QA signs off.",
                confidence: 0.97,
                isFinal: true
            ),
            TranscriptSegment(
                id: UUID(uuidString: "93939393-9393-9393-9393-939393939393")!,
                speakerName: "Alex",
                trackKind: .microphone,
                startTime: 16,
                endTime: 24,
                text: "Action: Alex will prepare the notarization checklist by Friday.",
                confidence: 0.96,
                isFinal: true
            ),
            TranscriptSegment(
                id: UUID(uuidString: "94949494-9494-9494-9494-949494949494")!,
                speakerName: "Maya",
                trackKind: .remoteSystem,
                startTime: 28,
                endTime: 36,
                text: "Open question: who owns the privacy label review before submission?",
                confidence: 0.95,
                isFinal: true
            ),
            TranscriptSegment(
                id: UUID(uuidString: "95959595-9595-9595-9595-959595959595")!,
                speakerName: "Sam",
                trackKind: .remoteSystem,
                startTime: 40,
                endTime: 49,
                text: "Risk: the release is blocked if SpeechAnalyzer assets are not installed.",
                confidence: 0.94,
                isFinal: true
            )
        ]
    )

    private static func baseReport(
        meetingID: UUID,
        segmentCount: Int,
        expectedEvidenceKinds: [String]
    ) -> FoundationModelsSmokeReport {
        FoundationModelsSmokeReport(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            status: "blocked",
            availabilityStatus: "not-checked",
            availabilityReason: nil,
            intelligenceStatus: "not-run",
            transcriptQuestionAnswerStatus: "not-run",
            usedSyntheticTranscriptFixture: true,
            usedLocalImportSampleFixture: false,
            usedGeneratedEnglishImportFixture: false,
            importFixtureKind: "synthetic",
            localImportStatus: "not-run",
            localSampleMatchedCount: 0,
            selectedAudioExtension: nil,
            selectedAudioByteCount: nil,
            selectedTranscriptLanguage: nil,
            transcriptLineCount: 0,
            importedAudioChunkCount: 0,
            encryptedLibraryCreated: false,
            generatedFixtureCreated: false,
            temporaryWorkspaceDeleted: false,
            privateAudioRecorded: false,
            microphoneOpened: false,
            externalNetworkRequested: false,
            rawTranscriptStored: false,
            rawModelOutputStored: false,
            meetingID: meetingID.uuidString,
            segmentCount: segmentCount,
            expectedEvidenceKinds: expectedEvidenceKinds,
            summaryTitleGenerated: false,
            summaryBulletCount: 0,
            decisionEvidenceCount: 0,
            actionEvidenceCount: 0,
            openQuestionEvidenceCount: 0,
            riskEvidenceCount: 0,
            answerEvidenceCount: 0,
            allEvidenceQuotesFoundInTranscript: false,
            issues: []
        )
    }

    private static func missingExpectedEvidenceKinds(report: FoundationModelsSmokeReport) -> [String] {
        var missing: [String] = []
        if report.expectedEvidenceKinds.contains("summaryTitle"), !report.summaryTitleGenerated {
            missing.append("summaryTitle")
        }
        if report.expectedEvidenceKinds.contains("summaryBullet"), report.summaryBulletCount == 0 {
            missing.append("summaryBullet")
        }
        if report.expectedEvidenceKinds.contains("decision"), report.decisionEvidenceCount == 0 {
            missing.append("decision")
        }
        if report.expectedEvidenceKinds.contains("action"), report.actionEvidenceCount == 0 {
            missing.append("action")
        }
        if report.expectedEvidenceKinds.contains("openQuestion"), report.openQuestionEvidenceCount == 0 {
            missing.append("openQuestion")
        }
        if report.expectedEvidenceKinds.contains("risk"), report.riskEvidenceCount == 0 {
            missing.append("risk")
        }
        if report.expectedEvidenceKinds.contains("answer"), report.answerEvidenceCount == 0 {
            missing.append("answer")
        }
        return missing
    }

    private static func makeLocalImportFixture(
        transcriptDirectory: URL?,
        recordingDirectory: URL?
    ) throws -> LocalImportFixture {
        guard let transcriptDirectory,
              let recordingDirectory else {
            throw FoundationModelsSmokeError.failed("Local import sample mode requires --transcript-dir and --recording-dir.")
        }
        let samples = try LocalRecordingSampleCatalogService().discoverSamples(
            transcriptDirectory: transcriptDirectory,
            audioDirectory: recordingDirectory,
            limit: 200
        )
        guard let selected = samples.first(where: {
            $0.audioURL.pathExtension.lowercased() == "mp3"
                && transcriptLineCount(at: $0.transcriptURL) > 50
        }) ?? samples.first(where: { $0.audioURL.pathExtension.lowercased() == "mp3" }) else {
            throw FoundationModelsSmokeError.failed("No matched local MP3/TXT sample was found.")
        }
        let selectedTranscriptLineCount = transcriptLineCount(at: selected.transcriptURL)

        let temporaryWorkspaceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultFoundationModelsLocalImport-\(UUID().uuidString)", isDirectory: true)
        let libraryURL = temporaryWorkspaceURL.appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createDirectory(at: libraryURL, withIntermediateDirectories: true)

        let vault = AESGCMDataVault(
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 211, count: 32))
        )
        let bundleStore = EncryptedMeetingBundleStore(rootDirectory: libraryURL, vault: vault)
        let searchIndex = try SQLiteSearchIndex(databaseURL: libraryURL.appendingPathComponent("library.sqlite"))
        let repository = MeetingLibraryRepository(bundleStore: bundleStore, searchIndex: searchIndex)
        let chunkWriter = EncryptedAudioChunkWriter(bundleStore: bundleStore)
        let service = LocalRecordingImportService(repository: repository, chunkWriter: chunkWriter)
        let result = try service.importRecording(
            LocalRecordingImportRequest(
                transcriptURL: selected.transcriptURL,
                audioURL: selected.audioURL,
                title: selected.title,
                sourceName: "Audio Hijack local import",
                consentStatus: .internalOnly,
                localeIdentifier: "en-US",
                importedAt: Date()
            )
        )
        return LocalImportFixture(
            transcript: result.transcript,
            temporaryWorkspaceURL: temporaryWorkspaceURL,
            matchedSampleCount: samples.count,
            selectedAudioExtension: selected.audioURL.pathExtension.lowercased(),
            selectedAudioByteCount: selected.audioByteCount,
            selectedTranscriptLanguage: nil,
            transcriptLineCount: max(result.metadata.transcriptLineCount, selectedTranscriptLineCount),
            importedAudioChunkCount: result.audioChunks.count,
            encryptedLibraryCreated: FileManager.default.fileExists(atPath: bundleStore.bundleURL(for: result.record.id).path),
            generatedFixtureCreated: false,
            fixtureKind: "local-sample"
        )
    }

    private static func makeGeneratedEnglishImportFixture() throws -> LocalImportFixture {
        let temporaryWorkspaceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultFoundationModelsEnglishImport-\(UUID().uuidString)", isDirectory: true)
        let transcriptDirectory = temporaryWorkspaceURL.appendingPathComponent("External Transcripts", isDirectory: true)
        let audioDirectory = temporaryWorkspaceURL.appendingPathComponent("External Recordings", isDirectory: true)
        let libraryURL = temporaryWorkspaceURL.appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createDirectory(at: transcriptDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: libraryURL, withIntermediateDirectories: true)

        let transcriptURL = transcriptDirectory.appendingPathComponent("20260702 1200 Transcription.txt")
        let audioURL = audioDirectory.appendingPathComponent("Voice Chat 20260702 1200.mp3")
        try generatedEnglishTranscriptText.write(to: transcriptURL, atomically: true, encoding: .utf8)
        try generatedMP3FixtureData.write(to: audioURL, options: .atomic)

        let samples = try LocalRecordingSampleCatalogService().discoverSamples(
            transcriptDirectory: transcriptDirectory,
            audioDirectory: audioDirectory,
            limit: 20
        )
        guard let selected = samples.first(where: { $0.audioURL.pathExtension.lowercased() == "mp3" }) else {
            throw FoundationModelsSmokeError.failed("Generated English external MP3/TXT fixture was not discoverable.")
        }

        let vault = AESGCMDataVault(
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 212, count: 32))
        )
        let bundleStore = EncryptedMeetingBundleStore(rootDirectory: libraryURL, vault: vault)
        let searchIndex = try SQLiteSearchIndex(databaseURL: libraryURL.appendingPathComponent("library.sqlite"))
        let repository = MeetingLibraryRepository(bundleStore: bundleStore, searchIndex: searchIndex)
        let chunkWriter = EncryptedAudioChunkWriter(bundleStore: bundleStore)
        let service = LocalRecordingImportService(repository: repository, chunkWriter: chunkWriter)
        let result = try service.importRecording(
            LocalRecordingImportRequest(
                transcriptURL: selected.transcriptURL,
                audioURL: selected.audioURL,
                title: "English Import Core AI Fixture",
                sourceName: "Generated external MP3/TXT fixture",
                consentStatus: .internalOnly,
                localeIdentifier: "en-US",
                importedAt: Date(timeIntervalSince1970: 1_783_100_800)
            )
        )

        return LocalImportFixture(
            transcript: result.transcript,
            temporaryWorkspaceURL: temporaryWorkspaceURL,
            matchedSampleCount: samples.count,
            selectedAudioExtension: selected.audioURL.pathExtension.lowercased(),
            selectedAudioByteCount: selected.audioByteCount,
            selectedTranscriptLanguage: "en-US",
            transcriptLineCount: result.metadata.transcriptLineCount,
            importedAudioChunkCount: result.audioChunks.count,
            encryptedLibraryCreated: FileManager.default.fileExists(atPath: bundleStore.bundleURL(for: result.record.id).path),
            generatedFixtureCreated: true,
            fixtureKind: "generated-english"
        )
    }

    private static let generatedEnglishTranscriptText = """
    [00:00:02.00] Anna: Decision: we will ship the onboarding update after the accessibility review passes.
    [00:00:07.00] Alex: Action: Alex will prepare the release checklist and send it to QA by Friday.
    [00:00:12.00] Maya: Open question: who owns the privacy label review before submission?
    [00:00:17.00] Sam: Risk: the release is blocked if speech assets are not installed.
    """

    private static let generatedMP3FixtureData = Data([
        0x49, 0x44, 0x33, 0x04, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x21, 0x54, 0x49, 0x54, 0x32, 0x00, 0x00,
        0x00, 0x17, 0x00, 0x00, 0x03, 0x45, 0x6E, 0x67,
        0x6C, 0x69, 0x73, 0x68, 0x20, 0x49, 0x6D, 0x70,
        0x6F, 0x72, 0x74, 0x20, 0x46, 0x69, 0x78, 0x74,
        0x75, 0x72, 0x65, 0xFF, 0xFB, 0x90, 0x64, 0x00,
        0x0F, 0xF0, 0x00, 0x00, 0x69, 0x00, 0x00, 0x00,
        0x08, 0x00, 0x00, 0x0D, 0x20, 0x00, 0x00, 0x01,
        0xA4, 0x00, 0x00, 0x00, 0x34, 0x80, 0x00, 0x00,
        0x06, 0x90, 0x00, 0x00, 0x00, 0xD2, 0x00, 0x00,
        0x00, 0x1A, 0x40, 0x00, 0x00, 0x03, 0x48, 0x00,
        0x00, 0x00, 0x69, 0x00, 0x00, 0x00, 0x0D, 0x20,
        0x00, 0x00, 0x01, 0xA4, 0x00, 0x00, 0x00, 0x34,
        0x80, 0x00, 0x00, 0x06, 0x90, 0x00, 0x00, 0x00,
        0xD2, 0x00, 0x00, 0x00, 0x1A, 0x40, 0x00, 0x00,
        0x03, 0x48, 0x00, 0x00, 0x00, 0x69
    ])

    private static func transcriptLineCount(at url: URL) -> Int {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return 0
        }
        return text
            .components(separatedBy: .newlines)
            .filter { $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[") }
            .count
    }

    private static func cleanupLocalWorkspace(
        _ url: URL?,
        report: inout FoundationModelsSmokeReport
    ) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
        report.temporaryWorkspaceDeleted = !FileManager.default.fileExists(atPath: url.path)
    }

    private static func recordProviderFailure(
        _ error: Error,
        provider: String,
        report: inout FoundationModelsSmokeReport
    ) {
        let message = error.localizedDescription
        let status = blockedProviderMessagesContain(message) ? "blocked" : "fail"
        report.status = status
        switch provider {
        case "intelligence":
            report.intelligenceStatus = status
        case "transcriptQuestionAnswer":
            report.transcriptQuestionAnswerStatus = status
        default:
            break
        }
        report.issues.append(message)
    }

    private static func blockedProviderMessagesContain(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return [
            "unavailable",
            "not available",
            "not enabled",
            "not eligible",
            "not ready",
            "downloading",
            "preparing",
            "temporarily",
            "rate limited",
            "concurrent",
            "not supported",
            "unsupported language",
            "unsupported locale"
        ].contains { lowered.contains($0) }
    }

    private static func allEvidenceQuotesFound(
        summary: MeetingSummary?,
        answer: TranscriptQuestionAnswer?,
        transcript: MeetingTranscript
    ) -> Bool {
        let segmentsByID = Dictionary(uniqueKeysWithValues: transcript.segments.map { ($0.id, $0.text) })
        var summaryEvidence: [EvidenceRef] = []
        if let summary {
            summaryEvidence.append(contentsOf: summary.decisions.flatMap(\.evidence))
            summaryEvidence.append(contentsOf: summary.actionItems.flatMap(\.evidence))
            summaryEvidence.append(contentsOf: summary.openQuestions.flatMap(\.evidence))
            summaryEvidence.append(contentsOf: summary.risks.flatMap(\.evidence))
        }
        let answerEvidence = (answer?.evidence ?? []).map { evidence in
            EvidenceRef(
                meetingID: transcript.meetingID,
                segmentID: evidence.segmentID,
                startTime: evidence.startTime,
                endTime: evidence.endTime,
                quote: evidence.quote
            )
        }
        return (summaryEvidence + answerEvidence).allSatisfy { evidence in
            guard let text = segmentsByID[evidence.segmentID] else {
                return false
            }
            return text.contains(evidence.quote)
        }
    }

    private static func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        label: String,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw FoundationModelsSmokeError.timeout(label)
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private static func write(report: FoundationModelsSmokeReport, to outputURL: URL) {
        do {
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(report).write(to: outputURL, options: .atomic)
            print("Wrote \(outputURL.path)")
            print("status=\(report.status)")
        } catch {
            fputs("failed to write \(outputURL.path): \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func finish(report: FoundationModelsSmokeReport, requirePass: Bool) -> Never {
        if report.status == "pass" {
            exit(0)
        }
        exit(requirePass ? 1 : 0)
    }
}
