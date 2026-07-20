import AVFoundation
import Foundation
import XCTest
@testable import MeetingVaultCore

final class TranscriptionPipelineTests: XCTestCase {
    func testFinalTranscriptionMergesContiguousWAVCheckpointsIntoBoundedContext() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultTranscriptionBatch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleStore = EncryptedMeetingBundleStore(
            rootDirectory: root,
            vault: AESGCMDataVault(keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 23, count: 32)))
        )
        let chunkWriter = EncryptedAudioChunkWriter(bundleStore: bundleStore)
        let meetingID = UUID()
        _ = try bundleStore.createBundle(.initialEncryptedBundle(meetingID: meetingID, title: "Batched transcription"))
        let wav = try makeTestWAV()
        let records = try (0..<3).map { index in
            try chunkWriter.writeChunk(
                wav,
                meetingID: meetingID,
                track: .remoteSystem,
                chunkIndex: index,
                startTime: TimeInterval(index * 15),
                duration: 15,
                codec: "WAV/PCM"
            )
        }
        let engine = MockTranscriptionEngine(responsesByAudioChunkPath: [:])
        let service = FinalTranscriptionService(
            engine: engine,
            bundleStore: bundleStore,
            chunkWriter: chunkWriter,
            searchIndex: try SQLiteSearchIndex(databaseURL: root.appendingPathComponent("search.sqlite"))
        )

        _ = try await service.transcribe(
            meeting: SearchMeeting(id: meetingID, title: "Batched transcription", startedAt: Date(), sourceApp: "Teams"),
            records: records,
            localeIdentifier: "en-US"
        )

        XCTAssertEqual(engine.requests.count, 1)
        XCTAssertEqual(engine.requests[0].trackKind, .remoteSystem)
        XCTAssertEqual(engine.requests[0].startTime, 0)
        XCTAssertEqual(engine.requests[0].duration, 45)
        let mergedData = try XCTUnwrap(engine.requests[0].audioData)
        XCTAssertGreaterThan(mergedData.count, wav.count)
        XCTAssertNoThrow(try AVAudioPlayer(data: mergedData))
    }

    func testFinalTranscriptionBoundsOneHourTwoTrackRecordingToFortyFiveSecondRequests() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultOneHourTranscription-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleStore = EncryptedMeetingBundleStore(
            rootDirectory: root,
            vault: AESGCMDataVault(keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 24, count: 32)))
        )
        let chunkWriter = EncryptedAudioChunkWriter(bundleStore: bundleStore)
        let meetingID = UUID()
        _ = try bundleStore.createBundle(.initialEncryptedBundle(meetingID: meetingID, title: "One hour transcription"))
        let wav = try makeTestWAV()
        var records: [AudioChunkRecord] = []
        for track in [TrackKind.remoteSystem, .microphone] {
            for index in 0..<240 {
                records.append(
                    try chunkWriter.writeChunk(
                        wav,
                        meetingID: meetingID,
                        track: track,
                        chunkIndex: index,
                        startTime: TimeInterval(index * 15),
                        duration: 15,
                        codec: "WAV/PCM"
                    )
                )
            }
        }
        let engine = MockTranscriptionEngine(responsesByAudioChunkPath: [:])
        let service = FinalTranscriptionService(
            engine: engine,
            bundleStore: bundleStore,
            chunkWriter: chunkWriter,
            searchIndex: try SQLiteSearchIndex(databaseURL: root.appendingPathComponent("search.sqlite"))
        )

        _ = try await service.transcribe(
            meeting: SearchMeeting(id: meetingID, title: "One hour transcription", startedAt: Date(), sourceApp: "Teams"),
            records: records,
            localeIdentifier: "en-US"
        )

        XCTAssertEqual(engine.requests.count, 160)
        XCTAssertTrue(engine.requests.allSatisfy { ($0.duration ?? 0) > 0 && ($0.duration ?? 0) <= 45 })
        XCTAssertEqual(engine.requests.filter { $0.trackKind == .remoteSystem }.count, 80)
        XCTAssertEqual(engine.requests.filter { $0.trackKind == .microphone }.count, 80)
    }


    func testFinalTranscriptionPersistsEncryptedTranscriptAndIndexesSegments() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultTranscription-\(UUID().uuidString)", isDirectory: true)
        let databaseURL = root.appendingPathComponent("search.sqlite")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let vault = AESGCMDataVault(
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 21, count: 32))
        )
        let bundleStore = EncryptedMeetingBundleStore(rootDirectory: root, vault: vault)
        let chunkWriter = EncryptedAudioChunkWriter(bundleStore: bundleStore)
        let searchIndex = try SQLiteSearchIndex(databaseURL: databaseURL)
        let meetingID = UUID()

        var manifest = MeetingBundleManifest.initialEncryptedBundle(
            meetingID: meetingID,
            title: "Roadmap sync"
        )
        manifest.createdAt = Date(timeIntervalSince1970: 1_780_000_400)
        _ = try bundleStore.createBundle(manifest)

        let remoteRecord = try chunkWriter.writeChunk(
            Data("remote pcm".utf8),
            meetingID: meetingID,
            track: .remoteSystem,
            chunkIndex: 0,
            startTime: 0,
            duration: 30,
            codec: "CAF/LPCM"
        )
        let microphoneRecord = try chunkWriter.writeChunk(
            Data("microphone pcm".utf8),
            meetingID: meetingID,
            track: .microphone,
            chunkIndex: 0,
            startTime: 0,
            duration: 30,
            codec: "CAF/LPCM"
        )

        let engine = MockTranscriptionEngine(
            responsesByAudioChunkPath: [
                remoteRecord.relativePath: [
                    TranscriptSegment(
                        id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                        speakerName: "Anna",
                        trackKind: .remoteSystem,
                        startTime: 2,
                        endTime: 8,
                        text: "The roadmap needs a searchable transcript before beta.",
                        confidence: 0.93,
                        isFinal: true
                    )
                ],
                microphoneRecord.relativePath: [
                    TranscriptSegment(
                        id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                        speakerName: "You",
                        trackKind: .microphone,
                        startTime: 9,
                        endTime: 13,
                        text: "I will connect the provider behind a privacy gate.",
                        confidence: 0.89,
                        isFinal: true
                    )
                ]
            ]
        )
        let service = FinalTranscriptionService(
            engine: engine,
            bundleStore: bundleStore,
            chunkWriter: chunkWriter,
            searchIndex: searchIndex,
            now: { Date(timeIntervalSince1970: 1_780_000_460) }
        )

        let result = try await service.transcribe(
            meeting: SearchMeeting(
                id: meetingID,
                title: "Roadmap sync",
                startedAt: manifest.createdAt,
                sourceApp: "Zoom.us"
            ),
            records: [remoteRecord, microphoneRecord],
            localeIdentifier: "en-US"
        )

        XCTAssertEqual(result.transcript.meetingID, meetingID)
        XCTAssertEqual(result.transcript.localeIdentifier, "en-US")
        XCTAssertEqual(result.transcript.segments.map(\.speakerName), ["Anna", "You"])
        XCTAssertEqual(engine.requests.map(\.audioChunkPath), [remoteRecord.relativePath, microphoneRecord.relativePath])
        XCTAssertEqual(engine.requests.map(\.audioData), [Data("remote pcm".utf8), Data("microphone pcm".utf8)])
        XCTAssertEqual(engine.requests.map(\.audioCodec), ["CAF/LPCM", "CAF/LPCM"])
        XCTAssertEqual(engine.requests.map(\.trackKind), [.remoteSystem, .microphone])
        XCTAssertEqual(engine.requests.map(\.startTime), [0, 0])
        XCTAssertEqual(engine.requests.map(\.duration), [30, 30])

        let stored = try bundleStore.readJSONArtifact(
            MeetingTranscript.self,
            meetingID: meetingID,
            relativePath: MeetingTranscript.finalTranscriptRelativePath,
            purpose: MeetingTranscript.finalTranscriptPurpose
        )
        XCTAssertEqual(stored, result.transcript)
        let reviewQueue = try TranscriptReviewRepository(bundleStore: bundleStore).load(meetingID: meetingID)
        XCTAssertEqual(reviewQueue.meetingID, meetingID)
        XCTAssertEqual(reviewQueue.transcriptVersion, result.transcript.transcriptVersion)
        XCTAssertFalse(reviewQueue.evidenceComplete)

        let transcriptURL = bundleStore.bundleURL(for: meetingID)
            .appendingPathComponent(MeetingTranscript.finalTranscriptRelativePath)
        let storedBytes = try Data(contentsOf: transcriptURL)
        XCTAssertFalse(String(decoding: storedBytes, as: UTF8.self).contains("searchable transcript"))

        let searchResults = try searchIndex.search("privacy")
        XCTAssertEqual(searchResults.count, 1)
        XCTAssertEqual(searchResults.first?.meetingTitle, "Roadmap sync")
        XCTAssertEqual(searchResults.first?.speakerName, "You")
    }

    func testAppleSpeechFinalEngineWritesDecryptedAudioToTemporaryFileAndDeletesIt() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultAppleSpeechFinal-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let authorization = CapturingFinalSpeechAuthorizationProvider(currentState: .authorized)
        let transcriber = CapturingSpeechFileTranscriber(
            segments: [
                TranscriptSegment(
                    speakerName: "You",
                    trackKind: .microphone,
                    startTime: 4,
                    endTime: 9,
                    text: "Final Apple Speech transcript",
                    confidence: 0.94,
                    isFinal: true
                )
            ]
        )
        let engine = AppleSpeechFinalTranscriptionEngine(
            authorizationProvider: authorization,
            fileTranscriber: transcriber,
            temporaryDirectory: temporaryDirectory
        )
        let request = TranscriptionRequest(
            meetingID: UUID(uuidString: "61616161-6161-6161-6161-616161616161")!,
            audioChunkPath: "audio/microphone-0.caf",
            audioData: Data("decrypted caf bytes".utf8),
            audioCodec: "CAF/LPCM",
            trackKind: .microphone,
            startTime: 4,
            duration: 5,
            localeIdentifier: "en-US"
        )

        let segments = try await engine.transcribe(request)

        XCTAssertEqual(segments.map(\.text), ["Final Apple Speech transcript"])
        XCTAssertEqual(authorization.requestCount, 0)
        XCTAssertEqual(transcriber.requests.map(\.audioChunkPath), ["audio/microphone-0.caf"])
        XCTAssertEqual(transcriber.locales.map(\.identifier), ["en-US"])
        XCTAssertEqual(transcriber.fileBytes, [Data("decrypted caf bytes".utf8)])
        let writtenURL = try XCTUnwrap(transcriber.urls.first)
        XCTAssertEqual(writtenURL.pathExtension, "caf")
        XCTAssertFalse(FileManager.default.fileExists(atPath: writtenURL.path))
    }

    func testAppleSpeechFinalEngineDoesNotRequestPermissionWhenNotDetermined() async throws {
        let authorization = CapturingFinalSpeechAuthorizationProvider(
            currentState: .notDetermined,
            requestedState: .authorized
        )
        let transcriber = CapturingSpeechFileTranscriber(segments: [])
        let engine = AppleSpeechFinalTranscriptionEngine(
            authorizationProvider: authorization,
            fileTranscriber: transcriber
        )

        do {
            _ = try await engine.transcribe(
                TranscriptionRequest(
                    meetingID: UUID(uuidString: "62626262-6262-6262-6262-626262626262")!,
                    audioChunkPath: "audio/remote-0.wav",
                    audioData: Data("wav bytes".utf8),
                    audioCodec: "WAV/LPCM",
                    trackKind: .remoteSystem
                )
            )
            XCTFail("Expected not determined Speech Recognition permission to fail closed")
        } catch {
            XCTAssertEqual(
                error as? AppleSpeechFinalTranscriptionError,
                .authorizationDenied(.notDetermined)
            )
        }

        XCTAssertEqual(authorization.requestCount, 0)
        XCTAssertTrue(transcriber.urls.isEmpty)
    }

    func testAppleSpeechFinalEngineFailsClosedBeforeWritingAudioWhenPermissionDenied() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultAppleSpeechDenied-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let authorization = CapturingFinalSpeechAuthorizationProvider(currentState: .denied)
        let transcriber = CapturingSpeechFileTranscriber(segments: [])
        let engine = AppleSpeechFinalTranscriptionEngine(
            authorizationProvider: authorization,
            fileTranscriber: transcriber,
            temporaryDirectory: temporaryDirectory
        )

        do {
            _ = try await engine.transcribe(
                TranscriptionRequest(
                    meetingID: UUID(uuidString: "63636363-6363-6363-6363-636363636363")!,
                    audioChunkPath: "audio/private.caf",
                    audioData: Data("should not be written".utf8),
                    audioCodec: "CAF/LPCM"
                )
            )
            XCTFail("Expected denied Speech Recognition permission to fail closed")
        } catch {
            XCTAssertEqual(
                error as? AppleSpeechFinalTranscriptionError,
                .authorizationDenied(.denied)
            )
        }

        XCTAssertEqual(authorization.requestCount, 0)
        XCTAssertTrue(transcriber.urls.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryDirectory.path))
    }

    func testAppleSpeechFinalEngineRejectsLocalOnlyBeforeReadingOrWritingAudio() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultAppleSpeechLocalOnly-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let authorization = CapturingFinalSpeechAuthorizationProvider(currentState: .authorized)
        let transcriber = CapturingSpeechFileTranscriber(segments: [])
        let engine = AppleSpeechFinalTranscriptionEngine(
            privacyBoundary: TranscriptionPrivacyBoundary(mode: .localOnly),
            authorizationProvider: authorization,
            fileTranscriber: transcriber,
            temporaryDirectory: temporaryDirectory
        )

        do {
            _ = try await engine.transcribe(TranscriptionRequest(
                meetingID: UUID(), audioChunkPath: "audio/private.caf", audioData: Data("private".utf8)
            ))
            XCTFail("Expected local-only rejection")
        } catch {
            XCTAssertEqual(error as? TranscriptionPrivacyBoundaryError, .localProviderUnavailable)
        }

        XCTAssertEqual(authorization.requestCount, 0)
        XCTAssertTrue(transcriber.urls.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryDirectory.path))
    }

    func testAppleSpeechFinalEngineRejectsUnsupportedOnDeviceBeforeScratchWrite() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingVaultFinalOnDevice-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriber = CapturingSpeechFileTranscriber(segments: [])
        let engine = AppleSpeechFinalTranscriptionEngine(
            privacyBoundary: TranscriptionPrivacyBoundary(mode: .appleOnDeviceOnly),
            authorizationProvider: CapturingFinalSpeechAuthorizationProvider(currentState: .authorized),
            onDeviceCapability: FixedFinalAppleSpeechOnDeviceCapability(supported: false),
            fileTranscriber: transcriber,
            temporaryDirectory: directory
        )
        do {
            _ = try await engine.transcribe(TranscriptionRequest(meetingID: UUID(), audioChunkPath: "a.caf", audioData: Data("x".utf8)))
            XCTFail("Expected on-device capability rejection")
        } catch {
            XCTAssertEqual(error as? TranscriptionPrivacyBoundaryError, .onDeviceRecognitionRequired)
        }
        XCTAssertTrue(transcriber.urls.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testSpeechAnalyzerFinalEngineWritesDecryptedAudioToTemporaryFileAndDeletesIt() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultSpeechAnalyzerFinal-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let transcriber = CapturingSpeechAnalyzerFileTranscriber(
            results: [
                SpeechAnalyzerTranscriptResult(
                    text: "SpeechAnalyzer final transcript",
                    startTime: 1.5,
                    endTime: 4.5,
                    confidence: 0.91,
                    isFinal: true
                )
            ]
        )
        let engine = SpeechAnalyzerFinalTranscriptionEngine(
            fileTranscriber: transcriber,
            temporaryDirectory: temporaryDirectory
        )
        let request = TranscriptionRequest(
            meetingID: UUID(uuidString: "64646464-6464-6464-6464-646464646464")!,
            audioChunkPath: "audio/remote-1.wav",
            audioData: Data("decrypted wav bytes".utf8),
            audioCodec: "WAV/LPCM",
            trackKind: .remoteSystem,
            startTime: 10,
            duration: 5,
            localeIdentifier: "en-US"
        )

        let segments = try await engine.transcribe(request)

        XCTAssertEqual(segments.map(\.text), ["SpeechAnalyzer final transcript"])
        XCTAssertEqual(segments.map(\.speakerName), ["Meeting audio"])
        XCTAssertEqual(segments.map(\.trackKind), [.remoteSystem])
        XCTAssertEqual(segments.map(\.startTime), [11.5])
        XCTAssertEqual(segments.map(\.endTime), [14.5])
        XCTAssertEqual(segments.map(\.confidence), [0.91])
        XCTAssertEqual(transcriber.requests.map(\.audioChunkPath), ["audio/remote-1.wav"])
        XCTAssertEqual(transcriber.locales.map(\.identifier), ["en-US"])
        XCTAssertEqual(transcriber.fileBytes, [Data("decrypted wav bytes".utf8)])
        let writtenURL = try XCTUnwrap(transcriber.urls.first)
        XCTAssertEqual(writtenURL.pathExtension, "wav")
        XCTAssertFalse(FileManager.default.fileExists(atPath: writtenURL.path))
    }

    func testSpeechAnalyzerFinalEngineFailsClosedBeforeWritingAudioWhenDataIsMissing() async throws {
        let transcriber = CapturingSpeechAnalyzerFileTranscriber(results: [])
        let engine = SpeechAnalyzerFinalTranscriptionEngine(fileTranscriber: transcriber)

        do {
            _ = try await engine.transcribe(
                TranscriptionRequest(
                    meetingID: UUID(uuidString: "65656565-6565-6565-6565-656565656565")!,
                    audioChunkPath: "audio/missing.caf",
                    audioData: nil,
                    audioCodec: "CAF/LPCM"
                )
            )
            XCTFail("Expected SpeechAnalyzer to fail closed without decrypted audio")
        } catch {
            XCTAssertEqual(
                error as? SpeechAnalyzerFinalTranscriptionError,
                .missingAudioData("audio/missing.caf")
            )
        }

        XCTAssertTrue(transcriber.urls.isEmpty)
    }
}

private func makeTestWAV() throws -> Data {
    let format = try XCTUnwrap(
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: true)
    )
    var samples: [Float] = [0, 0.25, -0.25, 0]
    let accumulator = LinearPCMAudioChunkAccumulator()
    try samples.withUnsafeMutableBytes { bytes in
        var audioBufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: UInt32(bytes.count),
                mData: bytes.baseAddress
            )
        )
        try withUnsafePointer(to: &audioBufferList) {
            try accumulator.append(
                audioBufferList: $0,
                format: format.streamDescription.pointee,
                frameCount: 4
            )
        }
    }
    return try XCTUnwrap(accumulator.finishChunk()).data
}

private final class CapturingFinalSpeechAuthorizationProvider: SpeechRecognitionAuthorizationProviding, @unchecked Sendable {
    private let currentState: SpeechRecognitionAuthorizationState
    private let requestedState: SpeechRecognitionAuthorizationState
    private let lock = NSLock()
    private var _requestCount = 0

    var requestCount: Int {
        lock.withLock { _requestCount }
    }

    init(
        currentState: SpeechRecognitionAuthorizationState,
        requestedState: SpeechRecognitionAuthorizationState = .authorized
    ) {
        self.currentState = currentState
        self.requestedState = requestedState
    }

    func currentAuthorizationState() -> SpeechRecognitionAuthorizationState {
        currentState
    }

    func requestAuthorizationState() async -> SpeechRecognitionAuthorizationState {
        lock.withLock {
            _requestCount += 1
        }
        return requestedState
    }
}

private struct FixedFinalAppleSpeechOnDeviceCapability: AppleSpeechOnDeviceCapabilityProviding {
    let supported: Bool
    func supportsOnDeviceRecognition(for locale: Locale) -> Bool { supported }
}

private final class CapturingSpeechFileTranscriber: SpeechFileTranscribing, @unchecked Sendable {
    private let segments: [TranscriptSegment]
    private let lock = NSLock()
    private var _urls: [URL] = []
    private var _locales: [Locale] = []
    private var _requests: [TranscriptionRequest] = []
    private var _fileBytes: [Data] = []

    var urls: [URL] {
        lock.withLock { _urls }
    }

    var locales: [Locale] {
        lock.withLock { _locales }
    }

    var requests: [TranscriptionRequest] {
        lock.withLock { _requests }
    }

    var fileBytes: [Data] {
        lock.withLock { _fileBytes }
    }

    init(segments: [TranscriptSegment]) {
        self.segments = segments
    }

    func transcribeAudioFile(
        at url: URL,
        locale: Locale,
        request: TranscriptionRequest
    ) async throws -> [TranscriptSegment] {
        let bytes = try Data(contentsOf: url)
        lock.withLock {
            _urls.append(url)
            _locales.append(locale)
            _requests.append(request)
            _fileBytes.append(bytes)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        return segments
    }
}

private final class CapturingSpeechAnalyzerFileTranscriber: SpeechAnalyzerFileTranscribing, @unchecked Sendable {
    private let results: [SpeechAnalyzerTranscriptResult]
    private let lock = NSLock()
    private var _urls: [URL] = []
    private var _locales: [Locale] = []
    private var _requests: [TranscriptionRequest] = []
    private var _fileBytes: [Data] = []

    var urls: [URL] {
        lock.withLock { _urls }
    }

    var locales: [Locale] {
        lock.withLock { _locales }
    }

    var requests: [TranscriptionRequest] {
        lock.withLock { _requests }
    }

    var fileBytes: [Data] {
        lock.withLock { _fileBytes }
    }

    init(results: [SpeechAnalyzerTranscriptResult]) {
        self.results = results
    }

    func transcribeAudioFile(
        at url: URL,
        locale: Locale,
        request: TranscriptionRequest
    ) async throws -> [SpeechAnalyzerTranscriptResult] {
        let bytes = try Data(contentsOf: url)
        lock.withLock {
            _urls.append(url)
            _locales.append(locale)
            _requests.append(request)
            _fileBytes.append(bytes)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        return results
    }
}
