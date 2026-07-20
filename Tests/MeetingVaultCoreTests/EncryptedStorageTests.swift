import Foundation
import Security
import XCTest
@testable import MeetingVaultCore

final class EncryptedStorageTests: XCTestCase {
    func testCopiedManifestIdentityFailsClosedAcrossStoreRecoveryIntelligenceAndExport() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultManifestIdentity-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EncryptedMeetingBundleStore(
            rootDirectory: root,
            vault: AESGCMDataVault(
                keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 91, count: 32))
            )
        )
        let requestedID = UUID()
        let privateID = UUID()
        _ = try store.createBundle(.initialEncryptedBundle(meetingID: requestedID, title: "Requested"))
        var privateManifest = MeetingBundleManifest.initialEncryptedBundle(
            meetingID: privateID,
            title: "Private board meeting"
        )
        privateManifest.bookmarks = [
            MeetingBookmark(
                meetingID: privateID,
                timestamp: 1,
                createdAt: Date(timeIntervalSince1970: 1_780_030_000),
                note: "Private acquisition note"
            )
        ]
        _ = try store.createBundle(privateManifest)
        let privateManifestURL = store.bundleURL(for: privateID).appendingPathComponent("manifest.json.enc")
        let requestedManifestURL = store.bundleURL(for: requestedID).appendingPathComponent("manifest.json.enc")
        try Data(contentsOf: privateManifestURL).write(to: requestedManifestURL, options: .atomic)

        let transcript = MeetingTranscript(
            meetingID: requestedID,
            localeIdentifier: "en-US",
            segments: [
                TranscriptSegment(
                    speakerName: "Anna",
                    trackKind: .remoteSystem,
                    startTime: 0,
                    endTime: 1,
                    text: "Safe transcript",
                    confidence: 0.9,
                    isFinal: true
                )
            ]
        )
        try store.writeJSONArtifact(
            transcript,
            meetingID: requestedID,
            relativePath: MeetingTranscript.finalTranscriptRelativePath,
            purpose: MeetingTranscript.finalTranscriptPurpose
        )
        try store.writeJSONArtifact(
            MeetingIntelligenceArtifact(
                meetingID: requestedID,
                providerID: "test",
                generatedAt: Date(),
                summary: MeetingSummary(
                    title: "Safe",
                    oneParagraph: "Safe summary",
                    bullets: ["Safe"],
                    decisions: [],
                    actionItems: []
                )
            ),
            meetingID: requestedID,
            relativePath: MeetingIntelligenceArtifact.summaryRelativePath,
            purpose: MeetingIntelligenceArtifact.summaryPurpose
        )

        XCTAssertThrowsError(try store.readManifest(meetingID: requestedID)) { error in
            XCTAssertEqual(error as? MeetingBundleStoreError, .manifestMeetingMismatch)
            XCTAssertFalse(error.localizedDescription.contains("acquisition"))
        }
        XCTAssertThrowsError(
            try RecordingRecoveryService(
                bundleStore: store,
                chunkWriter: EncryptedAudioChunkWriter(bundleStore: store)
            ).recoverableReport(for: requestedID)
        ) { error in
            XCTAssertEqual(error as? MeetingBundleStoreError, .manifestMeetingMismatch)
        }
        let provider = MockMeetingIntelligenceProvider(
            summary: MeetingSummary(
                title: "Unused",
                oneParagraph: "Unused",
                bullets: [],
                decisions: [],
                actionItems: []
            )
        )
        do {
            _ = try await MeetingIntelligenceService(provider: provider, bundleStore: store)
                .generateSummary(meetingID: requestedID)
            XCTFail("Expected copied manifest rejection")
        } catch {
            XCTAssertEqual(error as? MeetingBundleStoreError, .manifestMeetingMismatch)
        }
        XCTAssertTrue(provider.requests.isEmpty)

        let exportRoot = root.appendingPathComponent("Exports", isDirectory: true)
        XCTAssertThrowsError(
            try MeetingExportService(bundleStore: store).exportPackage(
                meeting: SearchMeeting(
                    id: requestedID,
                    title: "Requested",
                    startedAt: Date(),
                    sourceApp: "Test"
                ),
                to: exportRoot,
                formats: [.markdown]
            )
        ) { error in
            XCTAssertEqual(error as? MeetingBundleStoreError, .manifestMeetingMismatch)
            XCTAssertFalse(error.localizedDescription.contains("acquisition"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: exportRoot.path))
    }

    func testEncryptedPayloadRoundTripsWithoutSerializedPlaintext() throws {
        let keyProvider = InMemorySymmetricKeyProvider(keyData: Data(repeating: 7, count: 32))
        let vault = AESGCMDataVault(keyProvider: keyProvider)
        let plaintext = Data("private transcript for Project Atlas".utf8)

        let encrypted = try vault.seal(plaintext, purpose: "transcript")
        let serialized = try JSONEncoder().encode(encrypted)

        XCTAssertFalse(String(data: serialized, encoding: .utf8)?.contains("Project Atlas") ?? true)
        XCTAssertEqual(try vault.open(encrypted, purpose: "transcript"), plaintext)
        XCTAssertThrowsError(try vault.open(encrypted, purpose: "summary"))
    }

    func testEncryptedMeetingBundleStorePersistsManifestAndRejectsEscapes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let vault = AESGCMDataVault(
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 9, count: 32))
        )
        let store = EncryptedMeetingBundleStore(rootDirectory: root, vault: vault)
        let meetingID = UUID()
        var manifest = MeetingBundleManifest.initialEncryptedBundle(
            meetingID: meetingID,
            title: "Architecture review"
        )
        manifest.createdAt = Date(timeIntervalSince1970: 1_780_000_000)

        let bundleURL = try store.createBundle(manifest)
        let storedManifest = bundleURL.appendingPathComponent("manifest.json.enc")
        let rawManifest = try Data(contentsOf: storedManifest)

        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("audio").path))
        XCTAssertFalse(String(data: rawManifest, encoding: .utf8)?.contains("Architecture review") ?? true)
        XCTAssertEqual(try store.readManifest(meetingID: meetingID), manifest)
        XCTAssertThrowsError(
            try store.writeJSONArtifact(
                ["unsafe"],
                meetingID: meetingID,
                relativePath: "../escape.json.enc",
                purpose: "escape"
            )
        )
    }

    func testIncompletePreparationMarkerKeepsBundleOutOfHealthyReadsAndListings() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultIncompletePreparation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EncryptedMeetingBundleStore(
            rootDirectory: root,
            vault: AESGCMDataVault(
                keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 10, count: 32))
            )
        )
        let meetingID = UUID()
        var manifest = MeetingBundleManifest.initialEncryptedBundle(meetingID: meetingID, title: "Preparing")
        manifest.createdAt = Date(timeIntervalSince1970: 1_780_000_050)
        _ = try store.createPreparingBundle(manifest)

        XCTAssertThrowsError(try store.readManifest(meetingID: meetingID)) { error in
            XCTAssertEqual(error as? MeetingBundleStoreError, .bundlePreparationIncomplete)
        }
        XCTAssertFalse(try store.listMeetingBundleIDs().contains(meetingID))

        try store.markBundlePreparationComplete(meetingID: meetingID)

        XCTAssertEqual(try store.readManifest(meetingID: meetingID), manifest)
        XCTAssertTrue(try store.listMeetingBundleIDs().contains(meetingID))
    }

    func testBundleListingExcludesUnmarkedDirectoryWithoutManifest() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultUnmarkedIncomplete-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EncryptedMeetingBundleStore(
            rootDirectory: root,
            vault: AESGCMDataVault(
                keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 13, count: 32))
            )
        )
        let meetingID = UUID()
        try FileManager.default.createDirectory(
            at: store.bundleURL(for: meetingID),
            withIntermediateDirectories: true
        )

        XCTAssertFalse(try store.listMeetingBundleIDs().contains(meetingID))
    }

    func testKeychainProviderGeneratesAndReusesInstallMasterKey() throws {
        let keychain = InMemoryKeychainStore()
        let firstProvider = KeychainSymmetricKeyProvider(
            service: "com.andrzej.MeetingVault.tests",
            account: "install-master-key",
            keychain: keychain
        )
        let secondProvider = KeychainSymmetricKeyProvider(
            service: "com.andrzej.MeetingVault.tests",
            account: "install-master-key",
            keychain: keychain
        )

        let plaintext = Data("encrypted local meeting bundle".utf8)
        let encrypted = try AESGCMDataVault(keyProvider: firstProvider)
            .seal(plaintext, purpose: "manifest")

        XCTAssertEqual(keychain.savedItemCount, 1)
        XCTAssertEqual(
            try AESGCMDataVault(keyProvider: secondProvider).open(encrypted, purpose: "manifest"),
            plaintext
        )
    }

    func testFileBackedProviderGeneratesAndReusesLocalMasterKeyWithoutKeychain() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultFileKey-\(UUID().uuidString)", isDirectory: true)
        let keyURL = root.appendingPathComponent("local-master-key.bin")
        defer { try? FileManager.default.removeItem(at: root) }

        let firstProvider = FileBackedSymmetricKeyProvider(keyFileURL: keyURL)
        let secondProvider = FileBackedSymmetricKeyProvider(keyFileURL: keyURL)
        let plaintext = Data("encrypted local meeting bundle".utf8)
        let encrypted = try AESGCMDataVault(keyProvider: firstProvider)
            .seal(plaintext, purpose: "manifest")

        XCTAssertTrue(FileManager.default.fileExists(atPath: keyURL.path))
        XCTAssertEqual(try Data(contentsOf: keyURL).count, 32)
        XCTAssertEqual(
            try AESGCMDataVault(keyProvider: secondProvider).open(encrypted, purpose: "manifest"),
            plaintext
        )
    }

    func testConcurrentFileBackedProvidersConvergeOnOneMasterKey() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultConcurrentFileKey-\(UUID().uuidString)", isDirectory: true)
        let keyURL = root.appendingPathComponent("local-master-key.bin")
        defer { try? FileManager.default.removeItem(at: root) }

        let keys = try await withThrowingTaskGroup(of: Data.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    let key = try FileBackedSymmetricKeyProvider(keyFileURL: keyURL).loadKey()
                    return key.withUnsafeBytes { Data($0) }
                }
            }
            var results: [Data] = []
            for try await key in group {
                results.append(key)
            }
            return results
        }

        XCTAssertEqual(Set(keys).count, 1)
        XCTAssertEqual(try Data(contentsOf: keyURL), keys[0])
    }

    func testSystemKeychainQueriesSuppressAuthenticationPrompts() {
        let query = SystemKeychainStore.nonInteractiveQuery(
            service: "com.andrzej.MeetingVault.tests",
            account: "install-master-key"
        )

        XCTAssertEqual(query[kSecClass as String] as? String, kSecClassGenericPassword as String)
        XCTAssertEqual(query[kSecAttrService as String] as? String, "com.andrzej.MeetingVault.tests")
        XCTAssertEqual(query[kSecAttrAccount as String] as? String, "install-master-key")
        XCTAssertEqual(query[kSecUseAuthenticationUI as String] as? String, kSecUseAuthenticationUISkip as String)
    }

    func testKeychainProviderFailsClosedForInvalidStoredKey() throws {
        let keychain = InMemoryKeychainStore()
        try keychain.save(Data(repeating: 1, count: 8), service: "com.andrzej.MeetingVault.tests", account: "bad-key")
        let provider = KeychainSymmetricKeyProvider(
            service: "com.andrzej.MeetingVault.tests",
            account: "bad-key",
            keychain: keychain
        )

        XCTAssertThrowsError(try provider.loadKey()) { error in
            XCTAssertEqual(error as? EncryptionError, .invalidKeyLength(8))
        }
    }

    func testEncryptedAudioChunkWriterStoresChunksAndCheckpointWithoutPlaintext() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultAudioChunks-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let vault = AESGCMDataVault(
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 11, count: 32))
        )
        let bundleStore = EncryptedMeetingBundleStore(rootDirectory: root, vault: vault)
        let writer = EncryptedAudioChunkWriter(bundleStore: bundleStore)
        let meetingID = UUID()
        var manifest = MeetingBundleManifest.initialEncryptedBundle(
            meetingID: meetingID,
            title: "Long workshop"
        )
        manifest.createdAt = Date(timeIntervalSince1970: 1_780_000_100)
        _ = try bundleStore.createBundle(manifest)

        let firstChunk = Data("remote audio pcm chunk one".utf8)
        let secondChunk = Data("remote audio pcm chunk two".utf8)

        let first = try writer.writeChunk(
            firstChunk,
            meetingID: meetingID,
            track: .remoteSystem,
            chunkIndex: 0,
            startTime: 0,
            duration: 30,
            codec: "CAF/LPCM"
        )
        _ = try writer.writeChunk(
            secondChunk,
            meetingID: meetingID,
            track: .remoteSystem,
            chunkIndex: 1,
            startTime: 30,
            duration: 30,
            codec: "CAF/LPCM"
        )

        let bundleURL = bundleStore.bundleURL(for: meetingID)
        let rawChunk = try Data(contentsOf: bundleURL.appendingPathComponent(first.relativePath))
        let checkpoint = try writer.readCheckpoint(meetingID: meetingID, track: .remoteSystem)

        XCTAssertFalse(String(data: rawChunk, encoding: .utf8)?.contains("pcm chunk") ?? true)
        XCTAssertEqual(try writer.readChunk(first, meetingID: meetingID), firstChunk)
        XCTAssertEqual(checkpoint.chunks.map(\.chunkIndex), [0, 1])
        XCTAssertEqual(checkpoint.totalDuration, 60)
        XCTAssertThrowsError(
            try writer.writeChunk(
                Data("bad".utf8),
                meetingID: meetingID,
                track: .remoteSystem,
                chunkIndex: -1,
                startTime: 60,
                duration: 30,
                codec: "CAF/LPCM"
            )
        )
    }

    func testCorruptAudioCheckpointFailsClosedInsteadOfBeingTreatedAsEmpty() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultCorruptCheckpoint-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleStore = EncryptedMeetingBundleStore(
            rootDirectory: root,
            vault: AESGCMDataVault(
                keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 12, count: 32))
            )
        )
        let meetingID = UUID()
        _ = try bundleStore.createBundle(.initialEncryptedBundle(meetingID: meetingID, title: "Checkpoint"))
        let checkpointURL = bundleStore.bundleURL(for: meetingID)
            .appendingPathComponent("diagnostics/remoteSystem-chunks.json.enc")
        try Data("corrupt checkpoint".utf8).write(to: checkpointURL)

        XCTAssertThrowsError(
            try EncryptedAudioChunkWriter(bundleStore: bundleStore)
                .readCheckpoint(meetingID: meetingID, track: .remoteSystem)
        )
    }
}
