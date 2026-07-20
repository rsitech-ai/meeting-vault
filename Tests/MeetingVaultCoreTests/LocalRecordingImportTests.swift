import Foundation
import XCTest
@testable import MeetingVaultCore

final class LocalRecordingImportTests: XCTestCase {
    func testLocalRecordingImportSupportsCommonTranscriptAndAudioExtensions() throws {
        let supportedTranscriptExtensions = LocalRecordingImportService.supportedTranscriptExtensions
        let supportedAudioExtensions = LocalRecordingImportService.supportedAudioExtensions

        XCTAssertTrue(supportedTranscriptExtensions.isSuperset(of: ["txt", "srt", "vtt"]))
        XCTAssertTrue(supportedAudioExtensions.isSuperset(of: ["mp3", "m4a", "aac", "wav", "aif", "aiff", "aifc", "caf"]))
    }

    func testLocalRecordingSampleCatalogDiscoversMatchedTranscriptAudioPairsNewestFirst() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultLocalRecordingCatalog-\(UUID().uuidString)", isDirectory: true)
        let transcriptDirectory = root.appendingPathComponent("Transcript Captures", isDirectory: true)
        let audioDirectory = root.appendingPathComponent("Local Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: transcriptDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try "[00:00:01.00] Microsoft Teams:\tFirst matched sample.".write(
            to: transcriptDirectory.appendingPathComponent("20260226 1201 Transcription 1.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "[00:00:02.00] Microsoft Teams:\tNewest matched sample.".write(
            to: transcriptDirectory.appendingPathComponent("20260226 1207 Transcription.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "[00:00:03.00] Microsoft Teams:\tTranscript without audio.".write(
            to: transcriptDirectory.appendingPathComponent("20260227 1418 Transcription.txt"),
            atomically: true,
            encoding: .utf8
        )
        try Data(repeating: 1, count: 16).write(
            to: audioDirectory.appendingPathComponent("App Recording 20260226 1201.mp3")
        )
        try Data(repeating: 2, count: 32).write(
            to: audioDirectory.appendingPathComponent("Voice Chat 20260226 1201.mp3")
        )
        try Data(repeating: 3, count: 48).write(
            to: audioDirectory.appendingPathComponent("Voice Chat 20260226 1207.aiff")
        )

        let catalog = LocalRecordingSampleCatalogService(fileManager: .default)
        let samples = try catalog.discoverSamples(
            transcriptDirectory: transcriptDirectory,
            audioDirectory: audioDirectory,
            limit: 300
        )

        XCTAssertEqual(samples.map(\.timestampKey), ["20260226 1207", "20260226 1201"])
        XCTAssertEqual(samples.first?.title, "20260226 1207")
        XCTAssertEqual(samples.first?.audioURL.lastPathComponent, "Voice Chat 20260226 1207.aiff")
        XCTAssertEqual(samples.last?.audioURL.lastPathComponent, "Voice Chat 20260226 1201.mp3")
        XCTAssertEqual(samples.last?.audioByteCount, 32)
    }

    func testLocalRecordingSampleCatalogDiscoversSRTAndVTTTranscriptPairs() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultLocalRecordingCueCatalog-\(UUID().uuidString)", isDirectory: true)
        let transcriptDirectory = root.appendingPathComponent("Transcripts", isDirectory: true)
        let audioDirectory = root.appendingPathComponent("Audio", isDirectory: true)
        try FileManager.default.createDirectory(at: transcriptDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try """
        WEBVTT

        00:00:01.000 --> 00:00:04.000
        <v Anna>We can import a VTT transcript.
        """.write(
            to: transcriptDirectory.appendingPathComponent("20260703 1000 Transcription.vtt"),
            atomically: true,
            encoding: .utf8
        )
        try """
        1
        00:00:01,000 --> 00:00:04,000
        Sam: We can import an SRT transcript.
        """.write(
            to: transcriptDirectory.appendingPathComponent("20260703 1100 Transcription.srt"),
            atomically: true,
            encoding: .utf8
        )
        try Data(repeating: 1, count: 16).write(
            to: audioDirectory.appendingPathComponent("Voice Chat 20260703 1000.aac")
        )
        try Data(repeating: 2, count: 32).write(
            to: audioDirectory.appendingPathComponent("Voice Chat 20260703 1100.aifc")
        )

        let samples = try LocalRecordingSampleCatalogService().discoverSamples(
            transcriptDirectory: transcriptDirectory,
            audioDirectory: audioDirectory,
            limit: 20
        )

        XCTAssertEqual(samples.map(\.timestampKey), ["20260703 1100", "20260703 1000"])
        XCTAssertEqual(samples.map { $0.transcriptURL.pathExtension.lowercased() }, ["srt", "vtt"])
        XCTAssertEqual(samples.map { $0.audioURL.pathExtension.lowercased() }, ["aifc", "aac"])
    }

    func testLocalRecordingImportPersistsTranscriptIntoEncryptedSearchableLibrary() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultLocalRecordingImport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let transcriptURL = root.appendingPathComponent("20250718 1457 Transcription.txt")
        let audioURL = root.appendingPathComponent("Voice Chat 20250718 1457.mp3")
        try """
        [00:00:00.34] Microsoft Teams:\tSo you want to talk about the migration task.

        [00:00:30.58] Microsoft Teams:\tYesterday I sent you an email with a query.

        [00:01:21.58] Microsoft Teams:\tThe source flow will be changed with the new source query.
        """.write(to: transcriptURL, atomically: true, encoding: .utf8)
        try Data(repeating: 7, count: 256).write(to: audioURL)

        let keyProvider = InMemorySymmetricKeyProvider(keyData: Data(repeating: 99, count: 32))
        let vault = AESGCMDataVault(keyProvider: keyProvider)
        let bundleStore = EncryptedMeetingBundleStore(rootDirectory: root.appendingPathComponent("Library"), vault: vault)
        let chunkWriter = EncryptedAudioChunkWriter(bundleStore: bundleStore)
        let searchIndex = try SQLiteSearchIndex(databaseURL: root.appendingPathComponent("library.sqlite"))
        let repository = MeetingLibraryRepository(bundleStore: bundleStore, searchIndex: searchIndex)
        let service = LocalRecordingImportService(repository: repository, chunkWriter: chunkWriter)

        let result = try service.importRecording(
            LocalRecordingImportRequest(
                transcriptURL: transcriptURL,
                audioURL: audioURL,
                title: "Real Teams query migration",
                sourceName: "Microsoft Teams",
                consentStatus: .internalOnly,
                localeIdentifier: "en-US",
                importedAt: Date(timeIntervalSince1970: 1_780_010_000)
            )
        )

        XCTAssertEqual(result.record.title, "Real Teams query migration")
        XCTAssertEqual(result.record.sourceName, "Imported recording / Microsoft Teams")
        XCTAssertEqual(result.record.state, .ready)
        XCTAssertEqual(result.transcript.segments.count, 3)
        let firstSegment = try XCTUnwrap(result.transcript.segments.first)
        let lastSegment = try XCTUnwrap(result.transcript.segments.last)
        XCTAssertEqual(firstSegment.speakerName, "Microsoft Teams")
        XCTAssertEqual(firstSegment.trackKind, .mixedPlayback)
        XCTAssertEqual(firstSegment.startTime, 0.34, accuracy: 0.001)
        XCTAssertEqual(lastSegment.startTime, 81.58, accuracy: 0.001)
        XCTAssertEqual(result.record.durationSeconds, 86.58, accuracy: 0.001)
        XCTAssertEqual(result.metadata.audioByteCount, 256)
        XCTAssertEqual(result.metadata.transcriptLineCount, 3)
        XCTAssertFalse(result.audioChunks.isEmpty)
        XCTAssertEqual(result.audioChunks.reduce(0) { $0 + $1.byteCount }, result.metadata.audioByteCount)
        let importedAudioChunk = try XCTUnwrap(result.audioChunks.first)
        XCTAssertEqual(importedAudioChunk.track, .mixedPlayback)
        XCTAssertEqual(importedAudioChunk.codec, "mp3")
        XCTAssertEqual(importedAudioChunk.startTime, 0)
        XCTAssertEqual(importedAudioChunk.duration, result.record.durationSeconds, accuracy: 0.001)
        XCTAssertEqual(importedAudioChunk.byteCount, 256)
        XCTAssertTrue(importedAudioChunk.encrypted)

        let playbackTimeline = TranscriptPlaybackTimelineService().buildTimeline(
            transcript: result.transcript,
            audioChunks: result.audioChunks
        )
        XCTAssertTrue(playbackTimeline.isPlayable)
        XCTAssertEqual(playbackTimeline.warnings, [])
        XCTAssertTrue(playbackTimeline.cues.allSatisfy(\.isPlayable))
        let playbackEngine = LocalImportCapturingAudioEngine()
        let playbackService = TranscriptPlaybackSessionService(
            chunkWriter: chunkWriter,
            audioEngine: playbackEngine
        )
        let playing = try playbackService.playCue(firstSegment.id, in: playbackTimeline)
        XCTAssertEqual(playing.transportState, .playing)
        XCTAssertEqual(playbackEngine.playedAudioData, Data(repeating: 7, count: 256))

        let reloadedIndex = try SQLiteSearchIndex(databaseURL: root.appendingPathComponent("library.sqlite"))
        let reloadedRepository = MeetingLibraryRepository(bundleStore: bundleStore, searchIndex: reloadedIndex)
        let snapshot = try reloadedRepository.loadSnapshot()
        let importedSession = try XCTUnwrap(snapshot.editSessionsByMeetingID[result.record.id])
        XCTAssertEqual(importedSession.draft.segments.map(\.trimmedEditedText).last, "The source flow will be changed with the new source query.")

        let searchResults = try reloadedIndex.search("source query", limit: 3)
        XCTAssertEqual(searchResults.map(\.meetingID), [result.record.id])

        let rawTranscript = try Data(
            contentsOf: bundleStore.bundleURL(for: result.record.id)
                .appendingPathComponent(MeetingTranscript.finalTranscriptRelativePath)
        )
        let rawMetadata = try Data(
            contentsOf: bundleStore.bundleURL(for: result.record.id)
                .appendingPathComponent(LocalRecordingImportMetadata.relativePath)
        )
        let rawTranscriptText = String(data: rawTranscript, encoding: .utf8) ?? ""
        let rawMetadataText = String(data: rawMetadata, encoding: .utf8) ?? ""

        XCTAssertFalse(rawTranscriptText.contains("source flow"))
        XCTAssertFalse(rawMetadataText.contains(audioURL.path))

        let encryptedAudioData = try Data(
            contentsOf: bundleStore.bundleURL(for: result.record.id)
                .appendingPathComponent(importedAudioChunk.relativePath)
        )
        XCTAssertNotEqual(encryptedAudioData, Data(repeating: 7, count: 256))
    }

    func testLocalRecordingImportStillReturnsLibraryRecordWhenIntelligenceRejectsLanguage() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultLocalRecordingImportUnsupportedLanguage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let transcriptURL = root.appendingPathComponent("20260305 1012 Transcription.txt")
        let audioURL = root.appendingPathComponent("Voice Chat 20260305 1012.mp3")
        try """
        [00:00:01.00] Speaker:\tThis imported recording should still appear in the library.

        [00:00:12.00] Speaker:\tThe visible transcript should remain available for questions.
        """.write(to: transcriptURL, atomically: true, encoding: .utf8)
        try Data(repeating: 8, count: 256).write(to: audioURL)

        let keyProvider = InMemorySymmetricKeyProvider(keyData: Data(repeating: 121, count: 32))
        let vault = AESGCMDataVault(keyProvider: keyProvider)
        let bundleStore = EncryptedMeetingBundleStore(rootDirectory: root.appendingPathComponent("Library"), vault: vault)
        let chunkWriter = EncryptedAudioChunkWriter(bundleStore: bundleStore)
        let searchIndex = try SQLiteSearchIndex(databaseURL: root.appendingPathComponent("library.sqlite"))
        let repository = MeetingLibraryRepository(bundleStore: bundleStore, searchIndex: searchIndex)
        let service = LocalRecordingImportService(repository: repository, chunkWriter: chunkWriter)
        let intelligenceService = MeetingIntelligenceService(
            provider: FailingMeetingIntelligenceProvider(
                error: FoundationModelsMeetingIntelligenceError.generationFailed(
                    "This transcript language or locale is not supported."
                )
            ),
            bundleStore: bundleStore
        )

        let result = try await service.importRecording(
            LocalRecordingImportRequest(
                transcriptURL: transcriptURL,
                audioURL: audioURL,
                title: "Unsupported language smoke",
                sourceName: "Local Recording",
                consentStatus: .internalOnly,
                localeIdentifier: "en-US",
                importedAt: Date(timeIntervalSince1970: 1_780_020_000)
            ),
            intelligenceService: intelligenceService
        )

        XCTAssertEqual(result.record.title, "Unsupported language smoke")
        XCTAssertNil(result.record.summary)
        XCTAssertEqual(result.transcript.segments.count, 2)
        let snapshot = try repository.loadSnapshot()
        XCTAssertEqual(snapshot.records.map(\.id), [result.record.id])
        XCTAssertEqual(snapshot.searchMeetingsByID[result.record.id]?.title, "Unsupported language smoke")
        XCTAssertTrue(try searchIndex.search("questions").contains { $0.meetingID == result.record.id })
    }

    func testLocalRecordingImportParsesSRTAndWebVTTTranscripts() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultLocalRecordingCueImport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let cases: [(transcriptName: String, transcriptText: String, audioName: String, expectedSpeaker: String, expectedText: String)] = [
            (
                "20260703 1000 Transcription.srt",
                """
                1
                00:00:01,250 --> 00:00:04,750
                Anna: Import the Teams recording and ask the Agent about decisions.
                """,
                "Voice Chat 20260703 1000.wav",
                "Anna",
                "Import the Teams recording and ask the Agent about decisions."
            ),
            (
                "20260703 1100 Transcription.vtt",
                """
                WEBVTT

                00:00:02.000 --> 00:00:05.500
                <v Alex>Agent should answer from imported transcript evidence.
                """,
                "Voice Chat 20260703 1100.m4a",
                "Alex",
                "Agent should answer from imported transcript evidence."
            )
        ]

        for item in cases {
            let workspace = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            let transcriptURL = workspace.appendingPathComponent(item.transcriptName)
            let audioURL = workspace.appendingPathComponent(item.audioName)
            try item.transcriptText.write(to: transcriptURL, atomically: true, encoding: .utf8)
            try Data(repeating: 9, count: 64).write(to: audioURL)

            let keyProvider = InMemorySymmetricKeyProvider(keyData: Data(repeating: UInt8(item.audioName.count), count: 32))
            let bundleStore = EncryptedMeetingBundleStore(
                rootDirectory: workspace.appendingPathComponent("Library"),
                vault: AESGCMDataVault(keyProvider: keyProvider)
            )
            let repository = MeetingLibraryRepository(
                bundleStore: bundleStore,
                searchIndex: try SQLiteSearchIndex(databaseURL: workspace.appendingPathComponent("library.sqlite"))
            )
            let service = LocalRecordingImportService(
                repository: repository,
                chunkWriter: EncryptedAudioChunkWriter(bundleStore: bundleStore)
            )

            let result = try service.importRecording(
                LocalRecordingImportRequest(
                    transcriptURL: transcriptURL,
                    audioURL: audioURL,
                    sourceName: "External meeting import",
                    consentStatus: .internalOnly,
                    localeIdentifier: "en-US"
                )
            )

            let segment = try XCTUnwrap(result.transcript.segments.first)
            XCTAssertEqual(segment.speakerName, item.expectedSpeaker)
            XCTAssertEqual(segment.text, item.expectedText)
            XCTAssertGreaterThan(segment.endTime, segment.startTime)
            XCTAssertEqual(result.audioChunks.first?.codec, audioURL.pathExtension.lowercased())
        }
    }

    func testLocalRecordingImportSplitsLongPlainTextIntoAgentSizedSegments() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultPlainTextImport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let words = (0..<205).map { "word\($0)" }
        let transcriptURL = root.appendingPathComponent("plain-transcript.txt")
        let audioURL = root.appendingPathComponent("plain-recording.mp3")
        try words.joined(separator: " ").write(to: transcriptURL, atomically: true, encoding: .utf8)
        try Data(repeating: 3, count: 64).write(to: audioURL)

        let bundleStore = EncryptedMeetingBundleStore(
            rootDirectory: root.appendingPathComponent("Library"),
            vault: AESGCMDataVault(
                keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 33, count: 32))
            )
        )
        let result = try LocalRecordingImportService(
            repository: MeetingLibraryRepository(
                bundleStore: bundleStore,
                searchIndex: try SQLiteSearchIndex(databaseURL: root.appendingPathComponent("library.sqlite"))
            ),
            chunkWriter: EncryptedAudioChunkWriter(bundleStore: bundleStore)
        ).importRecording(
            LocalRecordingImportRequest(
                transcriptURL: transcriptURL,
                audioURL: audioURL,
                sourceName: "Plain text import",
                consentStatus: .internalOnly
            )
        )

        XCTAssertEqual(result.transcript.segments.count, 3)
        XCTAssertTrue(result.transcript.segments.allSatisfy {
            $0.text.split(whereSeparator: \.isWhitespace).count <= 80
        })
        XCTAssertEqual(result.transcript.segments.map(\.text).joined(separator: " "), words.joined(separator: " "))
    }

    func testLocalRecordingImportRejectsUnsupportedFileExtensionsBeforePersistence() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultLocalRecordingUnsupported-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let keyProvider = InMemorySymmetricKeyProvider(keyData: Data(repeating: 111, count: 32))
        let bundleStore = EncryptedMeetingBundleStore(
            rootDirectory: root.appendingPathComponent("Library"),
            vault: AESGCMDataVault(keyProvider: keyProvider)
        )
        let service = LocalRecordingImportService(
            repository: MeetingLibraryRepository(
                bundleStore: bundleStore,
                searchIndex: try SQLiteSearchIndex(databaseURL: root.appendingPathComponent("library.sqlite"))
            ),
            chunkWriter: EncryptedAudioChunkWriter(bundleStore: bundleStore)
        )

        let transcriptURL = root.appendingPathComponent("20260703 1000 Transcription.docx")
        let audioURL = root.appendingPathComponent("Voice Chat 20260703 1000.flac")
        try "[00:00:01.00] Anna:\tUnsupported file type.".write(to: transcriptURL, atomically: true, encoding: .utf8)
        try Data(repeating: 1, count: 8).write(to: audioURL)

        XCTAssertThrowsError(
            try service.importRecording(
                LocalRecordingImportRequest(
                    transcriptURL: transcriptURL,
                    audioURL: root.appendingPathComponent("Voice Chat 20260703 1000.mp3"),
                    sourceName: "External meeting import",
                    consentStatus: .internalOnly
                )
            )
        ) { error in
            XCTAssertEqual(error as? LocalRecordingImportError, .unsupportedTranscriptExtension("docx"))
        }

        let supportedTranscriptURL = root.appendingPathComponent("20260703 1000 Transcription.txt")
        try "[00:00:01.00] Anna:\tUnsupported audio file type.".write(to: supportedTranscriptURL, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(
            try service.importRecording(
                LocalRecordingImportRequest(
                    transcriptURL: supportedTranscriptURL,
                    audioURL: audioURL,
                    sourceName: "External meeting import",
                    consentStatus: .internalOnly
                )
            )
        ) { error in
            XCTAssertEqual(error as? LocalRecordingImportError, .unsupportedAudioExtension("flac"))
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Library").path))
    }

    func testLocalRecordingImportCanLoadLocalSampleWhenAvailable() throws {
        let sample = try firstEnvironmentConfiguredLocalSample(minimumTranscriptLineCount: 50)
        let sourceTranscriptURL = sample.transcriptURL
        let sourceAudioURL = sample.audioURL

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultLocalRecordingLocalSample-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let keyProvider = InMemorySymmetricKeyProvider(keyData: Data(repeating: 102, count: 32))
        let vault = AESGCMDataVault(keyProvider: keyProvider)
        let bundleStore = EncryptedMeetingBundleStore(rootDirectory: root.appendingPathComponent("Library"), vault: vault)
        let chunkWriter = EncryptedAudioChunkWriter(bundleStore: bundleStore)
        let searchIndex = try SQLiteSearchIndex(databaseURL: root.appendingPathComponent("library.sqlite"))
        let repository = MeetingLibraryRepository(bundleStore: bundleStore, searchIndex: searchIndex)
        let service = LocalRecordingImportService(repository: repository, chunkWriter: chunkWriter)

        let result = try service.importRecording(
            LocalRecordingImportRequest(
                transcriptURL: sourceTranscriptURL,
                audioURL: sourceAudioURL,
                title: "Local Teams recording sample",
                sourceName: "Microsoft Teams",
                consentStatus: .internalOnly,
                localeIdentifier: "en-US",
                importedAt: Date(timeIntervalSince1970: 1_780_011_000)
            )
        )

        XCTAssertGreaterThan(result.transcript.segments.count, 50)
        XCTAssertGreaterThan(result.metadata.audioByteCount, 1_000_000)
        XCTAssertFalse(result.audioChunks.isEmpty)
        XCTAssertEqual(result.audioChunks.reduce(0) { $0 + $1.byteCount }, result.metadata.audioByteCount)
        XCTAssertEqual(result.audioChunks.first?.codec, sourceAudioURL.pathExtension.lowercased())
        XCTAssertEqual(result.audioChunks.first?.track, .mixedPlayback)
        XCTAssertGreaterThan(result.record.durationSeconds, 60)

        let searchTerm = result.transcript.segments.first?.text.components(separatedBy: .whitespacesAndNewlines)
            .first { $0.count > 4 } ?? ""
        let searchResults = try searchIndex.search(searchTerm, limit: 5)
        XCTAssertTrue(searchResults.contains { $0.meetingID == result.record.id })

        let playbackTimeline = TranscriptPlaybackTimelineService().buildTimeline(
            transcript: result.transcript,
            audioChunks: result.audioChunks
        )
        XCTAssertTrue(playbackTimeline.isPlayable)
        XCTAssertTrue(playbackTimeline.cues.prefix(10).allSatisfy(\.isPlayable))
    }

    func testLocalRecordingSampleCatalogCanScanLocalLibraryWhenAvailable() throws {
        let directories = try environmentConfiguredLocalSampleDirectories()

        let catalog = LocalRecordingSampleCatalogService(fileManager: .default)
        let samples = try catalog.discoverSamples(
            transcriptDirectory: directories.transcriptDirectory,
            audioDirectory: directories.audioDirectory,
            limit: 300
        )

        XCTAssertGreaterThan(samples.count, 50)
        XCTAssertTrue(samples.allSatisfy { FileManager.default.fileExists(atPath: $0.transcriptURL.path) })
        XCTAssertTrue(samples.allSatisfy { FileManager.default.fileExists(atPath: $0.audioURL.path) })
    }

    private func firstEnvironmentConfiguredLocalSample(
        minimumTranscriptLineCount: Int? = nil
    ) throws -> LocalRecordingSampleCandidate {
        let directories = try environmentConfiguredLocalSampleDirectories()
        let catalog = LocalRecordingSampleCatalogService(fileManager: .default)
        let samples = try catalog.discoverSamples(
            transcriptDirectory: directories.transcriptDirectory,
            audioDirectory: directories.audioDirectory,
            limit: 300
        )
        if let minimumTranscriptLineCount {
            guard let sample = samples.first(where: { transcriptLineCount(at: $0.transcriptURL) > minimumTranscriptLineCount }) else {
                throw XCTSkip("Environment-configured local recording sample folders did not contain a long transcript sample.")
            }
            return sample
        }
        guard let sample = samples.first else {
            throw XCTSkip("Environment-configured local recording sample folders did not contain matched pairs.")
        }
        return sample
    }

    private func transcriptLineCount(at url: URL) -> Int {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return 0
        }
        return text
            .components(separatedBy: .newlines)
            .filter { $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[") }
            .count
    }

    private func environmentConfiguredLocalSampleDirectories() throws -> (
        transcriptDirectory: URL,
        audioDirectory: URL
    ) {
        let environment = ProcessInfo.processInfo.environment
        guard let transcriptPath = environment["MEETINGVAULT_LOCAL_TRANSCRIPT_SAMPLE_DIR"],
              let audioPath = environment["MEETINGVAULT_LOCAL_RECORDING_DIR"],
              !transcriptPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !audioPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw XCTSkip("Set MEETINGVAULT_LOCAL_TRANSCRIPT_SAMPLE_DIR and MEETINGVAULT_LOCAL_RECORDING_DIR to run local sample smoke tests.")
        }

        let transcriptDirectory = URL(fileURLWithPath: (transcriptPath as NSString).expandingTildeInPath)
        let audioDirectory = URL(fileURLWithPath: (audioPath as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: transcriptDirectory.path),
              FileManager.default.fileExists(atPath: audioDirectory.path)
        else {
            throw XCTSkip("Environment-configured local recording sample folders are not available on this machine.")
        }
        return (transcriptDirectory, audioDirectory)
    }
}

private final class LocalImportCapturingAudioEngine: TranscriptAudioEngine, @unchecked Sendable {
    private(set) var playedAudioData: Data?

    func play(audioFragments: [TranscriptPlaybackAudioDataFragment], cue _: TranscriptPlaybackCue) throws {
        playedAudioData = audioFragments.first?.audioData
    }

    func playRange(audioFragments: [TranscriptPlaybackAudioDataFragment], range _: TranscriptPlaybackRange) throws {
        playedAudioData = audioFragments.first?.audioData
    }

    func pause() throws {}

    func stop() throws {}
}

private final class FailingMeetingIntelligenceProvider: MeetingIntelligenceProvider, @unchecked Sendable {
    let id = "failing-intelligence"
    private let error: Error

    init(error: Error) {
        self.error = error
    }

    func summarize(segments: [TranscriptSegment], meetingID: UUID) async throws -> MeetingSummary {
        throw error
    }

    func summarize(
        segments: [TranscriptSegment],
        bookmarkEvidence: [MeetingIntelligenceBookmarkEvidence],
        meetingID: UUID
    ) async throws -> MeetingSummary {
        throw error
    }
}
