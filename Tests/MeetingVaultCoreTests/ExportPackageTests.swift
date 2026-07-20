import Foundation
import XCTest
@testable import MeetingVaultCore

final class ExportPackageTests: XCTestCase {
    func testLegacyJSONPayloadWithoutBookmarksDecodesWithEmptyDefault() throws {
        let meetingID = UUID()
        let legacy = LegacyMeetingExportPayload(
            meeting: SearchMeeting(
                id: meetingID,
                title: "Legacy export",
                startedAt: Date(timeIntervalSince1970: 1_780_000_000),
                sourceApp: "Zoom"
            ),
            transcript: MeetingTranscript(meetingID: meetingID, localeIdentifier: "en-US", segments: []),
            intelligence: MeetingIntelligenceArtifact(
                meetingID: meetingID,
                providerID: "legacy",
                generatedAt: Date(timeIntervalSince1970: 1_780_000_010),
                summary: MeetingSummary(
                    title: "Legacy export",
                    oneParagraph: "Legacy payload has no bookmark field.",
                    bullets: [],
                    decisions: [],
                    actionItems: []
                )
            )
        )

        let data = try JSONEncoder.meetingVaultExport.encode(legacy)
        let decoded = try JSONDecoder.meetingVaultExport.decode(MeetingExportPayload.self, from: data)

        XCTAssertEqual(decoded.meeting.id, meetingID)
        XCTAssertEqual(decoded.bookmarks, [])
    }

    func testExportPackageWritesMarkdownVTTPDFDOCXJSONAndAudioPackageFromStoredArtifacts() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultExport-\(UUID().uuidString)", isDirectory: true)
        let exportRoot = root.appendingPathComponent("exports", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let vault = AESGCMDataVault(
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 41, count: 32))
        )
        let bundleStore = EncryptedMeetingBundleStore(rootDirectory: root, vault: vault)
        let meetingID = UUID()
        let meeting = SearchMeeting(
            id: meetingID,
            title: "Launch review",
            startedAt: Date(timeIntervalSince1970: 1_780_001_000),
            sourceApp: "Zoom.us"
        )
        _ = try bundleStore.createBundle(
            MeetingBundleManifest.initialEncryptedBundle(
                meetingID: meetingID,
                title: meeting.title
            )
        )

        let segmentID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        let transcript = MeetingTranscript(
            meetingID: meetingID,
            localeIdentifier: "en-US",
            generatedAt: Date(timeIntervalSince1970: 1_780_001_060),
            segments: [
                TranscriptSegment(
                    id: segmentID,
                    speakerName: "Anna",
                    trackKind: .remoteSystem,
                    startTime: 65.4,
                    endTime: 70.9,
                    text: "QA sign-off is required before release.",
                    confidence: 0.95,
                    isFinal: true
                )
            ]
        )
        try bundleStore.writeJSONArtifact(
            transcript,
            meetingID: meetingID,
            relativePath: MeetingTranscript.finalTranscriptRelativePath,
            purpose: MeetingTranscript.finalTranscriptPurpose
        )

        let evidence = EvidenceRef(
            meetingID: meetingID,
            segmentID: segmentID,
            startTime: 65.4,
            endTime: 70.9,
            quote: "QA sign-off is required before release."
        )
        let artifact = MeetingIntelligenceArtifact(
            meetingID: meetingID,
            providerID: "mock-intelligence",
            generatedAt: Date(timeIntervalSince1970: 1_780_001_120),
            summary: MeetingSummary(
                title: "Launch review",
                oneParagraph: "Release remains gated by QA sign-off.",
                bullets: ["QA sign-off is required before release."],
                decisions: [
                    Decision(
                        title: "Wait for QA",
                        details: "Do not release before QA approval.",
                        evidence: [evidence],
                        confidence: 0.93
                    )
                ],
                actionItems: [
                    ActionItem(
                        title: "Get QA sign-off",
                        ownerName: "You",
                        evidence: [evidence],
                        confidence: 0.9
                    )
                ],
                openQuestions: [
                    OpenQuestion(
                        question: "Who signs off QA?",
                        context: "Release cannot proceed until QA ownership is clear.",
                        evidence: [evidence],
                        confidence: 0.82
                    )
                ],
                risks: [
                    MeetingRisk(
                        title: "Release may slip",
                        details: "QA sign-off can delay the release.",
                        severity: .high,
                        evidence: [evidence],
                        confidence: 0.78
                    )
                ]
            )
        )
        try bundleStore.writeJSONArtifact(
            artifact,
            meetingID: meetingID,
            relativePath: MeetingIntelligenceArtifact.summaryRelativePath,
            purpose: MeetingIntelligenceArtifact.summaryPurpose
        )
        let unsafeNote = "Review <script> & [owners]\nwithout duplicate rows"
        let bookmarks = [
            MeetingBookmark(
                meetingID: meetingID,
                timestamp: 65.4,
                createdAt: Date(timeIntervalSince1970: 1_780_001_030),
                category: .important,
                note: unsafeNote
            ),
            MeetingBookmark(
                meetingID: meetingID,
                timestamp: 12,
                createdAt: Date(timeIntervalSince1970: 1_780_001_020),
                category: .question,
                note: "Earlier question"
            )
        ]
        try bundleStore.writeJSONArtifact(
            RecordingSessionMetadata(
                meetingID: meetingID,
                startedAt: meeting.startedAt,
                context: MeetingContext(),
                bookmarks: bookmarks,
                revision: 2,
                isFinalized: true
            ),
            meetingID: meetingID,
            relativePath: RecordingSessionMetadata.relativePath,
            purpose: RecordingSessionMetadata.purpose
        )
        let chunkWriter = EncryptedAudioChunkWriter(bundleStore: bundleStore)
        let remoteAudio = Data("remote pcm export".utf8)
        let microphoneAudio = Data("microphone pcm export".utf8)
        _ = try chunkWriter.writeChunk(
            remoteAudio,
            meetingID: meetingID,
            track: .remoteSystem,
            chunkIndex: 0,
            startTime: 0,
            duration: 30,
            codec: "CAF/LPCM"
        )
        _ = try chunkWriter.writeChunk(
            microphoneAudio,
            meetingID: meetingID,
            track: .microphone,
            chunkIndex: 0,
            startTime: 0,
            duration: 30,
            codec: "CAF/LPCM"
        )

        let service = MeetingExportService(bundleStore: bundleStore)
        let package = try service.exportPackage(
            meeting: meeting,
            to: exportRoot,
            formats: [.markdown, .webVTT, .pdf, .docx, .json, .audioPackage]
        )

        XCTAssertEqual(Set(package.files.map(\.format)), [.markdown, .webVTT, .pdf, .docx, .json, .audioPackage])
        XCTAssertTrue(package.directory.lastPathComponent.contains("Launch-review"))

        let markdown = try String(contentsOf: package.fileURL(for: .markdown), encoding: .utf8)
        XCTAssertTrue(markdown.contains("# Launch review"))
        XCTAssertTrue(markdown.contains("Release remains gated by QA sign-off."))
        XCTAssertTrue(markdown.contains("- [ ] Get QA sign-off"))
        XCTAssertTrue(markdown.contains("## Open Questions"))
        XCTAssertTrue(markdown.contains("- Who signs off QA?"))
        XCTAssertTrue(markdown.contains("## Risks"))
        XCTAssertTrue(markdown.contains("- [high] Release may slip: QA sign-off can delay the release."))
        XCTAssertTrue(markdown.contains("[01:05.400] Anna: QA sign-off is required before release."))
        XCTAssertTrue(markdown.contains("## Marked Moments"))
        XCTAssertTrue(markdown.contains("[00:12.000] question — Earlier question"))
        XCTAssertEqual(markdown.components(separatedBy: "Review &lt;script&gt;").count, 2)

        let vtt = try String(contentsOf: package.fileURL(for: .webVTT), encoding: .utf8)
        XCTAssertTrue(vtt.contains("WEBVTT"))
        XCTAssertTrue(vtt.contains("00:01:05.400 --> 00:01:10.900"))
        XCTAssertTrue(vtt.contains("<v Anna>QA sign-off is required before release."))
        XCTAssertTrue(vtt.contains("NOTE bookmark 00:00:12.000 question Earlier question"))
        XCTAssertTrue(vtt.contains("NOTE bookmark 00:01:05.400 important Review <script> & [owners] without duplicate rows"))

        let json = try Data(contentsOf: package.fileURL(for: .json))
        let decoded = try JSONDecoder.meetingVaultExport.decode(MeetingExportPayload.self, from: json)
        XCTAssertEqual(decoded.meeting.id, meetingID)
        XCTAssertEqual(decoded.transcript.segments.count, 1)
        XCTAssertEqual(decoded.intelligence.summary.actionItems.first?.title, "Get QA sign-off")
        XCTAssertEqual(decoded.intelligence.summary.openQuestions.first?.question, "Who signs off QA?")
        XCTAssertEqual(decoded.intelligence.summary.risks.first?.severity, .high)
        XCTAssertEqual(decoded.bookmarks.map(\.timestamp), [12, 65.4])
        XCTAssertEqual(decoded.bookmarks.last?.note, unsafeNote)

        let pdf = try Data(contentsOf: package.fileURL(for: .pdf))
        XCTAssertTrue(String(decoding: pdf.prefix(5), as: UTF8.self).hasPrefix("%PDF-"))
        XCTAssertTrue(String(decoding: pdf, as: UTF8.self).contains("Launch review"))
        XCTAssertTrue(String(decoding: pdf, as: UTF8.self).contains("Marked Moments"))

        let docx = try Data(contentsOf: package.fileURL(for: .docx))
        XCTAssertEqual(String(decoding: docx.prefix(2), as: UTF8.self), "PK")
        XCTAssertTrue(String(decoding: docx, as: UTF8.self).contains("word/document.xml"))

        let audioPackageURL = package.fileURL(for: .audioPackage)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioPackageURL.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        let audioManifest = try JSONDecoder.meetingVaultExport.decode(
            MeetingAudioExportManifest.self,
            from: Data(contentsOf: audioPackageURL.appendingPathComponent("manifest.json"))
        )
        XCTAssertEqual(audioManifest.meetingID, meetingID)
        XCTAssertEqual(audioManifest.files.map(\.track), [.remoteSystem, .microphone])
        XCTAssertEqual(audioManifest.files.map(\.codec), ["CAF/LPCM", "CAF/LPCM"])
        XCTAssertEqual(audioManifest.files.map { URL(fileURLWithPath: $0.relativePath).pathExtension }, ["caf", "caf"])
        XCTAssertEqual(
            try Data(contentsOf: audioPackageURL.appendingPathComponent(audioManifest.files[0].relativePath)),
            remoteAudio
        )
        XCTAssertEqual(
            try Data(contentsOf: audioPackageURL.appendingPathComponent(audioManifest.files[1].relativePath)),
            microphoneAudio
        )
    }

    func testExportPackageWritesRedactedAuditEvent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultExportAudit-\(UUID().uuidString)", isDirectory: true)
        let exportRoot = root.appendingPathComponent("exports", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let vault = AESGCMDataVault(
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 43, count: 32))
        )
        let bundleStore = EncryptedMeetingBundleStore(rootDirectory: root, vault: vault)
        let meetingID = UUID()
        let meeting = SearchMeeting(
            id: meetingID,
            title: "Secret customer launch transcript",
            startedAt: Date(timeIntervalSince1970: 1_780_001_200),
            sourceApp: "Teams"
        )
        _ = try bundleStore.createBundle(
            MeetingBundleManifest.initialEncryptedBundle(
                meetingID: meetingID,
                title: meeting.title
            )
        )

        let segmentID = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
        let transcript = MeetingTranscript(
            meetingID: meetingID,
            localeIdentifier: "en-US",
            generatedAt: Date(timeIntervalSince1970: 1_780_001_260),
            segments: [
                TranscriptSegment(
                    id: segmentID,
                    speakerName: "Anna",
                    trackKind: .remoteSystem,
                    startTime: 4,
                    endTime: 8,
                    text: "Secret launch detail should stay out of audit logs.",
                    confidence: 0.95,
                    isFinal: true
                )
            ]
        )
        try bundleStore.writeJSONArtifact(
            transcript,
            meetingID: meetingID,
            relativePath: MeetingTranscript.finalTranscriptRelativePath,
            purpose: MeetingTranscript.finalTranscriptPurpose
        )

        let evidence = EvidenceRef(
            meetingID: meetingID,
            segmentID: segmentID,
            startTime: 4,
            endTime: 8,
            quote: "Secret launch detail should stay out of audit logs."
        )
        let artifact = MeetingIntelligenceArtifact(
            meetingID: meetingID,
            providerID: "mock-intelligence",
            generatedAt: Date(timeIntervalSince1970: 1_780_001_300),
            summary: MeetingSummary(
                title: "Secret customer launch transcript",
                oneParagraph: "Secret launch detail should not appear in audit.",
                bullets: [],
                decisions: [
                    Decision(
                        title: "Keep launch private",
                        details: "Use audit metadata only.",
                        evidence: [evidence],
                        confidence: 0.9
                    )
                ],
                actionItems: []
            )
        )
        try bundleStore.writeJSONArtifact(
            artifact,
            meetingID: meetingID,
            relativePath: MeetingIntelligenceArtifact.summaryRelativePath,
            purpose: MeetingIntelligenceArtifact.summaryPurpose
        )

        let auditURL = root.appendingPathComponent("privacy-audit.jsonl")
        let auditWriter = PrivacyAuditLogWriter(
            logURL: auditURL,
            now: { Date(timeIntervalSince1970: 1_780_001_360) }
        )
        let service = MeetingExportService(bundleStore: bundleStore, auditWriter: auditWriter)

        _ = try service.exportPackage(meeting: meeting, to: exportRoot, formats: [.markdown, .json])

        let rawLog = try String(contentsOf: auditURL, encoding: .utf8)
        XCTAssertTrue(rawLog.contains("export.package"))
        XCTAssertTrue(rawLog.contains(meetingID.uuidString))
        XCTAssertFalse(rawLog.contains("Secret customer"))
        XCTAssertFalse(rawLog.contains("Secret launch detail"))
        XCTAssertFalse(rawLog.contains(exportRoot.path))

        let event = try XCTUnwrap(PrivacyAuditLogReader(logURL: auditURL).readEvents().first)
        XCTAssertEqual(event.action, .exportPackage)
        XCTAssertEqual(event.meetingID, meetingID)
        XCTAssertEqual(event.metadata["formats"], "markdown,json")
        XCTAssertEqual(event.metadata["fileCount"], "2")
    }

    func testAudioPackageExportPreservesImportedAudioExtensionAndMixedPlaybackTrack() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultImportedAudioExport-\(UUID().uuidString)", isDirectory: true)
        let exportRoot = root.appendingPathComponent("exports", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let vault = AESGCMDataVault(
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 44, count: 32))
        )
        let bundleStore = EncryptedMeetingBundleStore(rootDirectory: root, vault: vault)
        let meetingID = UUID()
        let meeting = SearchMeeting(
            id: meetingID,
            title: "Imported MP3 playback",
            startedAt: Date(timeIntervalSince1970: 1_780_002_000),
            sourceApp: "Imported recording / Microsoft Teams"
        )
        _ = try bundleStore.createBundle(
            MeetingBundleManifest.initialEncryptedBundle(
                meetingID: meetingID,
                title: meeting.title
            )
        )

        let segmentID = UUID(uuidString: "77777777-7777-7777-7777-777777777777")!
        try bundleStore.writeJSONArtifact(
            MeetingTranscript(
                meetingID: meetingID,
                localeIdentifier: "en-US",
                generatedAt: Date(timeIntervalSince1970: 1_780_002_060),
                segments: [
                    TranscriptSegment(
                        id: segmentID,
                        speakerName: "Microsoft Teams",
                        trackKind: .mixedPlayback,
                        startTime: 0,
                        endTime: 12,
                        text: "Imported MP3 audio should export as an MP3 file.",
                        confidence: 0.88,
                        isFinal: true
                    )
                ]
            ),
            meetingID: meetingID,
            relativePath: MeetingTranscript.finalTranscriptRelativePath,
            purpose: MeetingTranscript.finalTranscriptPurpose
        )
        let importedAudio = Data([0x49, 0x44, 0x33, 0x04, 0x00, 0x00])
        _ = try EncryptedAudioChunkWriter(bundleStore: bundleStore).writeChunk(
            importedAudio,
            meetingID: meetingID,
            track: .mixedPlayback,
            chunkIndex: 0,
            startTime: 0,
            duration: 12,
            codec: "mp3"
        )
        try bundleStore.writeJSONArtifact(
            MeetingIntelligenceArtifact(
                meetingID: meetingID,
                providerID: "mock-intelligence",
                generatedAt: Date(timeIntervalSince1970: 1_780_002_120),
                summary: MeetingSummary(
                    title: "Imported MP3 playback",
                    oneParagraph: "Imported audio export remained local.",
                    bullets: ["Imported MP3 audio should export as an MP3 file."],
                    decisions: [],
                    actionItems: [],
                    openQuestions: [],
                    risks: []
                )
            ),
            meetingID: meetingID,
            relativePath: MeetingIntelligenceArtifact.summaryRelativePath,
            purpose: MeetingIntelligenceArtifact.summaryPurpose
        )

        let package = try MeetingExportService(bundleStore: bundleStore).exportPackage(
            meeting: meeting,
            to: exportRoot,
            formats: [.audioPackage]
        )
        let audioPackageURL = package.fileURL(for: .audioPackage)
        let manifest = try JSONDecoder.meetingVaultExport.decode(
            MeetingAudioExportManifest.self,
            from: Data(contentsOf: audioPackageURL.appendingPathComponent("manifest.json"))
        )

        XCTAssertEqual(manifest.files.count, 1)
        let exportedFile = try XCTUnwrap(manifest.files.first)
        XCTAssertEqual(exportedFile.track, .mixedPlayback)
        XCTAssertEqual(exportedFile.codec, "mp3")
        XCTAssertEqual(exportedFile.relativePath, "mixedPlayback/chunk-000000.mp3")
        XCTAssertEqual(
            try Data(contentsOf: audioPackageURL.appendingPathComponent(exportedFile.relativePath)),
            importedAudio
        )
    }

    func testPDFExportPaginatesAndIncludesFinalTranscriptSegment() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultPDFPagination-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let meetingID = UUID()
        let bundleStore = EncryptedMeetingBundleStore(
            rootDirectory: root,
            vault: AESGCMDataVault(
                keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 45, count: 32))
            )
        )
        let meeting = SearchMeeting(
            id: meetingID,
            title: "Long transcript export",
            startedAt: Date(timeIntervalSince1970: 1_780_003_000),
            sourceApp: "Microsoft Teams"
        )
        _ = try bundleStore.createBundle(.initialEncryptedBundle(meetingID: meetingID, title: meeting.title))
        var segments: [TranscriptSegment] = []
        for index in 0..<80 {
            segments.append(TranscriptSegment(
                speakerName: "Speaker",
                trackKind: .remoteSystem,
                startTime: Double(index * 5),
                endTime: Double(index * 5 + 4),
                text: index == 79 ? "FINAL PDF TRANSCRIPT MARKER" : "Transcript line \(index)",
                confidence: 0.9,
                isFinal: true
            ))
        }
        try bundleStore.writeJSONArtifact(
            MeetingTranscript(meetingID: meetingID, localeIdentifier: "en-US", segments: segments),
            meetingID: meetingID,
            relativePath: MeetingTranscript.finalTranscriptRelativePath,
            purpose: MeetingTranscript.finalTranscriptPurpose
        )
        try bundleStore.writeJSONArtifact(
            MeetingIntelligenceArtifact(
                meetingID: meetingID,
                providerID: "test",
                generatedAt: Date(timeIntervalSince1970: 1_780_003_100),
                summary: MeetingSummary(
                    title: meeting.title,
                    oneParagraph: "Long transcript PDF pagination test.",
                    bullets: [],
                    decisions: [],
                    actionItems: []
                )
            ),
            meetingID: meetingID,
            relativePath: MeetingIntelligenceArtifact.summaryRelativePath,
            purpose: MeetingIntelligenceArtifact.summaryPurpose
        )

        let package = try MeetingExportService(bundleStore: bundleStore).exportPackage(
            meeting: meeting,
            to: root.appendingPathComponent("Exports", isDirectory: true),
            formats: [.pdf]
        )
        let pdf = try String(contentsOf: package.fileURL(for: .pdf), encoding: .utf8)

        XCTAssertTrue(pdf.contains("/Count 2") || pdf.contains("/Count 3"))
        XCTAssertTrue(pdf.contains("FINAL PDF TRANSCRIPT MARKER"))
    }

    func testExportRejectsCopiedValidSessionMetadataIdentityWithoutWritingPrivateOutput() throws {
        let fixture = try makeMinimalExportFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let privateMeetingID = UUID()
        try fixture.store.writeJSONArtifact(
            RecordingSessionMetadata(
                meetingID: privateMeetingID,
                startedAt: fixture.meeting.startedAt,
                context: MeetingContext(),
                bookmarks: [
                    MeetingBookmark(
                        meetingID: privateMeetingID,
                        timestamp: 1,
                        createdAt: fixture.meeting.startedAt,
                        note: "Private board export note"
                    )
                ]
            ),
            meetingID: fixture.meeting.id,
            relativePath: RecordingSessionMetadata.relativePath,
            purpose: RecordingSessionMetadata.purpose
        )

        XCTAssertThrowsError(
            try MeetingExportService(bundleStore: fixture.store).exportPackage(
                meeting: fixture.meeting,
                to: fixture.root.appendingPathComponent("Exports", isDirectory: true),
                formats: [.markdown]
            )
        ) { error in
            XCTAssertEqual(error as? MeetingExportError, .metadataMeetingMismatch)
            XCTAssertFalse(error.localizedDescription.contains("Private board export note"))
        }
    }

    func testExportDeduplicatesValidBookmarkProjectionBeforeStrictDuplicateIDValidation() throws {
        let fixture = try makeMinimalExportFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let duplicateID = UUID()
        let first = MeetingBookmark(
            id: duplicateID,
            meetingID: fixture.meeting.id,
            timestamp: 1,
            createdAt: fixture.meeting.startedAt,
            note: "first projection"
        )
        let duplicate = MeetingBookmark(
            id: duplicateID,
            meetingID: fixture.meeting.id,
            timestamp: 2,
            createdAt: fixture.meeting.startedAt.addingTimeInterval(1),
            note: "later duplicate"
        )
        try fixture.store.writeJSONArtifact(
            RecordingSessionMetadata(
                meetingID: fixture.meeting.id,
                startedAt: fixture.meeting.startedAt,
                context: MeetingContext(),
                bookmarks: [duplicate, first],
                revision: 2,
                isFinalized: true
            ),
            meetingID: fixture.meeting.id,
            relativePath: RecordingSessionMetadata.relativePath,
            purpose: RecordingSessionMetadata.purpose
        )

        let package = try MeetingExportService(bundleStore: fixture.store).exportPackage(
            meeting: fixture.meeting,
            to: fixture.root.appendingPathComponent("Exports", isDirectory: true),
            formats: [.json]
        )
        let payload = try JSONDecoder.meetingVaultExport.decode(
            MeetingExportPayload.self,
            from: Data(contentsOf: package.fileURL(for: .json))
        )

        XCTAssertEqual(payload.bookmarks, [first])
    }

    func testExportSanitizesMarkdownVTTAndDOCXControlSyntaxWithoutChangingJSONAuthoredValue() throws {
        let fixture = try makeMinimalExportFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let injection = "`code` *bold* [link](file:///private)\n# injected\n-->\n\n00:00:00.000 --> 99:00:00.000\u{0001}"
        let bookmark = MeetingBookmark(
            meetingID: fixture.meeting.id,
            timestamp: 1,
            createdAt: fixture.meeting.startedAt,
            category: .question,
            note: injection
        )
        try fixture.store.writeJSONArtifact(
            MeetingIntelligenceArtifact(
                meetingID: fixture.meeting.id,
                providerID: "injection-test",
                generatedAt: fixture.meeting.startedAt,
                summary: MeetingSummary(
                    title: "# injected title",
                    oneParagraph: "Paragraph\n## injected section",
                    bullets: ["*injected emphasis*"],
                    decisions: [
                        Decision(
                            title: "[link](file:///private)",
                            details: "- injected item",
                            evidence: [],
                            confidence: 0.5
                        )
                    ],
                    actionItems: [
                        ActionItem(title: "# injected action", evidence: [], confidence: 0.5)
                    ],
                    openQuestions: [
                        OpenQuestion(
                            question: "> injected quote",
                            context: "`code`",
                            evidence: [],
                            confidence: 0.5
                        )
                    ],
                    risks: [
                        MeetingRisk(
                            title: "---",
                            details: "![image](file:///private)",
                            severity: .high,
                            evidence: [],
                            confidence: 0.5
                        )
                    ]
                )
            ),
            meetingID: fixture.meeting.id,
            relativePath: MeetingIntelligenceArtifact.summaryRelativePath,
            purpose: MeetingIntelligenceArtifact.summaryPurpose
        )
        try fixture.store.writeJSONArtifact(
            RecordingSessionMetadata(
                meetingID: fixture.meeting.id,
                startedAt: fixture.meeting.startedAt,
                context: MeetingContext(),
                bookmarks: [bookmark],
                revision: 1,
                isFinalized: true
            ),
            meetingID: fixture.meeting.id,
            relativePath: RecordingSessionMetadata.relativePath,
            purpose: RecordingSessionMetadata.purpose
        )

        let package = try MeetingExportService(bundleStore: fixture.store).exportPackage(
            meeting: fixture.meeting,
            to: fixture.root.appendingPathComponent("Exports", isDirectory: true),
            formats: [.markdown, .webVTT, .docx, .json]
        )
        let markdown = try String(contentsOf: package.fileURL(for: .markdown), encoding: .utf8)
        XCTAssertFalse(markdown.contains("`code`"))
        XCTAssertFalse(markdown.contains("*bold*"))
        XCTAssertFalse(markdown.contains("[link](file:///private)"))
        XCTAssertFalse(markdown.contains("\n# injected"))
        XCTAssertFalse(markdown.contains("\n## injected section"))
        XCTAssertFalse(markdown.contains("*injected emphasis*"))
        XCTAssertFalse(markdown.contains("[link](file:///private)"))
        XCTAssertFalse(markdown.contains("![image](file:///private)"))

        let vtt = try String(contentsOf: package.fileURL(for: .webVTT), encoding: .utf8)
        let noteLines = vtt.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.hasPrefix("NOTE bookmark") }
        XCTAssertEqual(noteLines.count, 1)
        XCTAssertFalse(noteLines[0].contains("-->"))
        XCTAssertFalse(vtt.unicodeScalars.contains { $0.value == 1 })

        let docx = try Data(contentsOf: package.fileURL(for: .docx))
        let docxText = String(decoding: docx, as: UTF8.self)
        let documentStart = try XCTUnwrap(docxText.range(of: "<w:document"))
        let documentEnd = try XCTUnwrap(
            docxText.range(of: "</w:document>", range: documentStart.lowerBound..<docxText.endIndex)
        )
        let documentXML = docxText[documentStart.lowerBound..<documentEnd.upperBound]
        XCTAssertFalse(documentXML.unicodeScalars.contains { $0.value == 1 })

        let payload = try JSONDecoder.meetingVaultExport.decode(
            MeetingExportPayload.self,
            from: Data(contentsOf: package.fileURL(for: .json))
        )
        XCTAssertEqual(payload.bookmarks.first?.note, injection)
    }

    private func makeMinimalExportFixture() throws -> MinimalExportFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultExportHardening-\(UUID().uuidString)", isDirectory: true)
        let store = EncryptedMeetingBundleStore(
            rootDirectory: root,
            vault: AESGCMDataVault(
                keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 74, count: 32))
            )
        )
        let meeting = SearchMeeting(
            id: UUID(),
            title: "Export hardening",
            startedAt: Date(timeIntervalSince1970: 1_780_020_000),
            sourceApp: "Zoom"
        )
        _ = try store.createBundle(.initialEncryptedBundle(meetingID: meeting.id, title: meeting.title))
        try store.writeJSONArtifact(
            MeetingTranscript(meetingID: meeting.id, localeIdentifier: "en-US", segments: []),
            meetingID: meeting.id,
            relativePath: MeetingTranscript.finalTranscriptRelativePath,
            purpose: MeetingTranscript.finalTranscriptPurpose
        )
        try store.writeJSONArtifact(
            MeetingIntelligenceArtifact(
                meetingID: meeting.id,
                providerID: "test",
                generatedAt: meeting.startedAt,
                summary: MeetingSummary(
                    title: meeting.title,
                    oneParagraph: "Safe summary",
                    bullets: [],
                    decisions: [],
                    actionItems: []
                )
            ),
            meetingID: meeting.id,
            relativePath: MeetingIntelligenceArtifact.summaryRelativePath,
            purpose: MeetingIntelligenceArtifact.summaryPurpose
        )
        return MinimalExportFixture(root: root, store: store, meeting: meeting)
    }
}

private struct MinimalExportFixture {
    var root: URL
    var store: EncryptedMeetingBundleStore
    var meeting: SearchMeeting
}

private struct LegacyMeetingExportPayload: Encodable {
    var meeting: SearchMeeting
    var transcript: MeetingTranscript
    var intelligence: MeetingIntelligenceArtifact
}
