import Foundation
import XCTest
@testable import MeetingVaultCore

final class MeetingContextTests: XCTestCase {
    func testFreshContextDefaultsToAutomaticLanguageAndEmptyPrivateFields() {
        let context = MeetingContext()

        XCTAssertNil(context.localeIdentifier)
        XCTAssertNil(context.expectedParticipantCount)
        XCTAssertEqual(context.participantNames, [])
        XCTAssertEqual(context.vocabulary, [])
    }

    func testValidationNormalizesSupportedLocaleRepresentations() throws {
        XCTAssertEqual(
            try MeetingContext(localeIdentifier: "  pl_pl ").validated().localeIdentifier,
            "pl-PL"
        )
        XCTAssertEqual(
            try MeetingContext(localeIdentifier: "EN-us").validated().localeIdentifier,
            "en-US"
        )
        XCTAssertEqual(
            try MeetingContext(localeIdentifier: "pl").validated().localeIdentifier,
            "pl-PL"
        )
        XCTAssertNil(try MeetingContext(localeIdentifier: "  ").validated().localeIdentifier)
    }

    func testValidationRejectsUnsupportedLocaleAndParticipantCountsOutsideOneThroughTen() {
        XCTAssertThrowsError(try MeetingContext(localeIdentifier: "de-DE").validated()) { error in
            XCTAssertEqual(error as? MeetingContextValidationError, .unsupportedLocale)
        }
        for count in [0, 11, Int.min, Int.max] {
            XCTAssertThrowsError(try MeetingContext(expectedParticipantCount: count).validated()) { error in
                XCTAssertEqual(error as? MeetingContextValidationError, .invalidParticipantCount)
            }
        }
        XCTAssertNoThrow(try MeetingContext(expectedParticipantCount: nil).validated())
        XCTAssertNoThrow(try MeetingContext(expectedParticipantCount: 1).validated())
        XCTAssertNoThrow(try MeetingContext(expectedParticipantCount: 10).validated())
    }

    func testValidationTrimsCollapsesAndDeduplicatesPrivateListsDeterministically() throws {
        let validated = try MeetingContext(
            participantNames: ["  Żaneta\n Kowalska ", "ALICE", " alice ", "", "Żaneta Kowalska"],
            vocabulary: ["  Projekt\tŻubr ", "API", "api", "  "]
        ).validated()

        XCTAssertEqual(validated.participantNames, ["Żaneta Kowalska", "ALICE"])
        XCTAssertEqual(validated.vocabulary, ["Projekt Żubr", "API"])
    }

    func testValidationAllowsBoundedUnicodeAndRejectsOverlongOrExcessiveInputs() throws {
        let unicode = String(repeating: "🙂", count: 32)
        XCTAssertEqual(
            try MeetingContext(participantNames: [unicode]).validated().participantNames,
            [unicode]
        )

        let overlong = String(repeating: "🙂", count: MeetingContext.maxPrivateEntryUTF8Bytes)
        XCTAssertThrowsError(try MeetingContext(participantNames: [overlong]).validated()) { error in
            XCTAssertEqual(error as? MeetingContextValidationError, .privateEntryTooLong)
        }
        XCTAssertThrowsError(
            try MeetingContext(
                participantNames: Array(repeating: "Person", count: MeetingContext.maxParticipantNames + 1)
            ).validated()
        ) { error in
            XCTAssertEqual(error as? MeetingContextValidationError, .tooManyParticipantNames)
        }
        XCTAssertThrowsError(
            try MeetingContext(
                vocabulary: Array(repeating: "term", count: MeetingContext.maxVocabularyEntries + 1)
            ).validated()
        ) { error in
            XCTAssertEqual(error as? MeetingContextValidationError, .tooManyVocabularyEntries)
        }
    }

    func testValidationRejectsOverlongLocaleBeforeNormalization() {
        let overlongLocale = String(repeating: "p", count: MeetingContext.maxLocaleIdentifierUTF8Bytes + 1)

        XCTAssertThrowsError(try MeetingContext(localeIdentifier: overlongLocale).validated()) { error in
            XCTAssertEqual(error as? MeetingContextValidationError, .localeIdentifierTooLong)
        }
    }

    func testValidationChecksAllRawBoundsBeforeNormalizingAnyPrivateEntry() {
        let overlongLocale = String(repeating: "p", count: MeetingContext.maxLocaleIdentifierUTF8Bytes + 1)
        let hugePrivateWhitespace = String(repeating: " ", count: 1_000_000)

        XCTAssertThrowsError(
            try MeetingContext(
                localeIdentifier: overlongLocale,
                participantNames: [hugePrivateWhitespace]
            ).validated()
        ) { error in
            XCTAssertEqual(error as? MeetingContextValidationError, .localeIdentifierTooLong)
        }
    }

    func testValidationRejectsHugeRawWhitespaceBeforeCollapsingItAway() {
        let rawWhitespace = String(repeating: " \n", count: 500_000)

        XCTAssertThrowsError(try MeetingContext(participantNames: [rawWhitespace]).validated()) { error in
            XCTAssertEqual(error as? MeetingContextValidationError, .privateEntryTooLong)
        }
    }

    func testValidationRejectsWhitespacePaddedShortValueByRawUTF8Size() {
        let rawValue = String(repeating: " ", count: MeetingContext.maxPrivateEntryUTF8Bytes) + "API"

        XCTAssertThrowsError(try MeetingContext(vocabulary: [rawValue]).validated()) { error in
            XCTAssertEqual(error as? MeetingContextValidationError, .privateEntryTooLong)
        }
    }

    func testValidationRejectsRawCollectionTotalBeforeDeduplication() {
        let repeatedPrivateValue = String(
            repeating: "x",
            count: MeetingContext.maxPrivateCollectionUTF8Bytes / MeetingContext.maxVocabularyEntries + 1
        )
        let rawValues = Array(
            repeating: repeatedPrivateValue,
            count: MeetingContext.maxVocabularyEntries
        )

        XCTAssertThrowsError(try MeetingContext(vocabulary: rawValues).validated()) { error in
            XCTAssertEqual(error as? MeetingContextValidationError, .privateCollectionTooLarge)
        }
    }

    func testValidationMeasuresRawAndNormalizedUnicodeInUTF8Bytes() throws {
        let boundaryUnicode = String(repeating: "🙂", count: MeetingContext.maxPrivateEntryUTF8Bytes / 4)
        let overlongUnicode = boundaryUnicode + "🙂"

        XCTAssertEqual(
            try MeetingContext(participantNames: [boundaryUnicode]).validated().participantNames,
            [boundaryUnicode]
        )
        XCTAssertThrowsError(try MeetingContext(participantNames: [overlongUnicode]).validated()) { error in
            XCTAssertEqual(error as? MeetingContextValidationError, .privateEntryTooLong)
        }
    }

    func testValidationErrorsAndDiagnosticsNeverEchoPrivateValues() {
        let secret = "Project Nightingale participant"
        do {
            _ = try MeetingContext(
                participantNames: [String(repeating: secret, count: 100)]
            ).validated()
            XCTFail("Expected private entry size validation to fail")
        } catch {
            let diagnostic = [
                String(describing: error),
                error.localizedDescription,
                String(describing: error as NSError)
            ].joined(separator: "\n")
            XCTAssertFalse(diagnostic.contains(secret))
        }
    }

    func testRecordingSessionMetadataRejectsNonFiniteBookmarkTimestampsWithoutPrivateDiagnostics() {
        let secret = "private decision text"
        let metadata = RecordingSessionMetadata(
            meetingID: UUID(),
            startedAt: Date(timeIntervalSince1970: 1_780_010_000),
            context: MeetingContext(participantNames: [secret]),
            bookmarks: [
                MeetingBookmark(
                    meetingID: UUID(),
                    timestamp: .nan,
                    createdAt: Date(timeIntervalSince1970: 1_780_010_100),
                    category: .decision,
                    note: secret
                )
            ],
            revision: 0
        )

        XCTAssertThrowsError(try metadata.validated()) { error in
            XCTAssertEqual(error as? RecordingSessionMetadataValidationError, .invalidBookmarkTimestamp)
            XCTAssertFalse(error.localizedDescription.contains(secret))
        }
    }

    func testRecordingSessionMetadataRejectsOverlongPrivateBookmarkNotes() {
        let metadata = RecordingSessionMetadata(
            meetingID: UUID(),
            startedAt: Date(timeIntervalSince1970: 1_780_010_000),
            context: MeetingContext(),
            bookmarks: [
                MeetingBookmark(
                    meetingID: UUID(),
                    timestamp: 1,
                    createdAt: Date(timeIntervalSince1970: 1_780_010_100),
                    note: String(repeating: "🙂", count: RecordingSessionMetadata.maxBookmarkNoteUTF8Bytes)
                )
            ]
        )

        XCTAssertThrowsError(try metadata.validated()) { error in
            XCTAssertEqual(error as? RecordingSessionMetadataValidationError, .bookmarkNoteTooLong)
        }
    }

    func testSchemaV1ManifestDecodesWithEmptyContextWithoutMigration() throws {
        let meetingID = UUID()
        let payload = """
        {
          "meetingID":"\(meetingID.uuidString)",
          "schemaVersion":1,
          "createdAt":"2026-07-17T08:00:00Z",
          "title":"Legacy meeting",
          "tracks":[],
          "transcriptPath":"transcript/segments.json.enc",
          "auditLogPath":"diagnostics/audit.jsonl",
          "recovered":false
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(MeetingBundleManifest.self, from: Data(payload.utf8))

        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertEqual(decoded.context, MeetingContext())
        XCTAssertEqual(decoded.sessionMetadataPath, RecordingSessionMetadata.relativePath)
    }

    func testManifestWithoutSchemaVersionDecodesAsV1Compatibility() throws {
        let payload = """
        {
          "meetingID":"\(UUID().uuidString)",
          "createdAt":"2026-07-17T08:00:00Z",
          "title":"Legacy meeting without schema",
          "tracks":[]
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(MeetingBundleManifest.self, from: Data(payload.utf8))

        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertEqual(decoded.context, MeetingContext())
        XCTAssertEqual(decoded.sessionMetadataPath, RecordingSessionMetadata.relativePath)
    }

    func testManifestRejectsExplicitUnsupportedSchemaVersionsWithPrivateSafeTypedError() {
        let privateValue = "Project Nightingale private participant"
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for schemaVersion in [-1, 0, 3, Int.max] {
            let payload = """
            {
              "meetingID":"\(UUID().uuidString)",
              "schemaVersion":\(schemaVersion),
              "createdAt":"2026-07-17T08:00:00Z",
              "title":"\(privateValue)",
              "tracks":[],
              "context":{"participantNames":["\(privateValue)"],"vocabulary":[]},
              "sessionMetadataPath":"metadata/active-session.json.enc"
            }
            """

            XCTAssertThrowsError(
                try decoder.decode(MeetingBundleManifest.self, from: Data(payload.utf8))
            ) { error in
                XCTAssertEqual(
                    error as? MeetingBundleManifestDecodingError,
                    .unsupportedSchemaVersion
                )
                let diagnostic = [
                    String(describing: error),
                    error.localizedDescription,
                    String(describing: error as NSError)
                ].joined(separator: "\n")
                XCTAssertFalse(diagnostic.contains(privateValue))
                XCTAssertFalse(diagnostic.contains("active-session.json.enc"))
            }
        }
    }

    func testSchemaV2ManifestRoundTripsContextAndMetadataPath() throws {
        let manifest = MeetingBundleManifest(
            meetingID: UUID(),
            schemaVersion: 2,
            createdAt: Date(timeIntervalSince1970: 1_780_010_200),
            title: "Context meeting",
            tracks: [],
            context: MeetingContext(
                localeIdentifier: "pl-PL",
                expectedParticipantCount: 5,
                participantNames: ["Ala", "Olek"],
                vocabulary: ["MeetingVault"]
            ),
            sessionMetadataPath: RecordingSessionMetadata.relativePath
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        XCTAssertEqual(
            try decoder.decode(MeetingBundleManifest.self, from: encoder.encode(manifest)),
            manifest
        )
    }

    func testSchemaV2ManifestRejectsMissingContextFieldsInsteadOfSilentlyDowngrading() throws {
        let payload = """
        {
          "meetingID":"\(UUID().uuidString)",
          "schemaVersion":2,
          "createdAt":"2026-07-17T08:00:00Z",
          "title":"Incomplete v2 meeting",
          "tracks":[],
          "transcriptPath":"transcript/segments.json.enc",
          "auditLogPath":"diagnostics/audit.jsonl",
          "recovered":false
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        XCTAssertThrowsError(
            try decoder.decode(MeetingBundleManifest.self, from: Data(payload.utf8))
        )
    }

    func testSchemaV2ManifestRejectsNoncanonicalSessionMetadataPath() throws {
        let manifest = MeetingBundleManifest(
            meetingID: UUID(),
            schemaVersion: 2,
            title: "Unsafe metadata path",
            tracks: [],
            context: MeetingContext(),
            sessionMetadataPath: "metadata/other.json.enc"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        XCTAssertThrowsError(
            try decoder.decode(MeetingBundleManifest.self, from: encoder.encode(manifest))
        )
    }

    func testMetadataServiceWritesValidatedEncryptedArtifactAtExactPathAndPurpose() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultMeetingContext-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleStore = EncryptedMeetingBundleStore(
            rootDirectory: root,
            vault: AESGCMDataVault(
                keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 29, count: 32))
            )
        )
        let meetingID = UUID()
        _ = try bundleStore.createBundle(.initialEncryptedBundle(meetingID: meetingID, title: "Private"))
        let service = RecordingSessionMetadataService(bundleStore: bundleStore)
        let privateName = "Żaneta Private"

        let metadata = try await service.create(
            meetingID: meetingID,
            startedAt: Date(timeIntervalSince1970: 1_780_010_300),
            context: MeetingContext(participantNames: ["  \(privateName)  "])
        )

        XCTAssertEqual(metadata.context.participantNames, [privateName])
        XCTAssertEqual(metadata.bookmarks, [])
        XCTAssertEqual(metadata.revision, 0)
        let artifactURL = bundleStore.bundleURL(for: meetingID)
            .appendingPathComponent(RecordingSessionMetadata.relativePath)
        let raw = try Data(contentsOf: artifactURL)
        XCTAssertFalse(String(decoding: raw, as: UTF8.self).contains(privateName))
        XCTAssertEqual(
            try bundleStore.readJSONArtifact(
                RecordingSessionMetadata.self,
                meetingID: meetingID,
                relativePath: RecordingSessionMetadata.relativePath,
                purpose: RecordingSessionMetadata.purpose
            ),
            metadata
        )
    }
}
