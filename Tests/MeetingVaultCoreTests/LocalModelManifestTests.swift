import CryptoKit
import Foundation
import XCTest
@testable import MeetingVaultCore

final class LocalModelManifestTests: XCTestCase {
    func testValidManifestIsAcceptedAndCanonicalOrderingIsRequired() throws {
        let first = makeAsset(id: "a-model", installPath: "asr/config.json", sourceFile: "config.json")
        let second = makeAsset(id: "b-model", installPath: "asr/model.bin", sourceFile: "model.bin")

        XCTAssertEqual(
            try LocalModelManifestValidator.validate(
                LocalModelManifest(schemaVersion: 1, assets: [first, second])
            ).assets,
            [first, second]
        )
        XCTAssertThrowsError(
            try LocalModelManifestValidator.validate(
                LocalModelManifest(schemaVersion: 1, assets: [second, first])
            )
        ) { error in
            XCTAssertEqual(error as? LocalModelManifestValidationError, .assetsNotDeterministicallyOrdered)
        }
    }

    func testRejectsUnsupportedSchemaAndEmptyRequiredFields() throws {
        XCTAssertThrowsError(
            try LocalModelManifestValidator.validate(
                LocalModelManifest(schemaVersion: 2, assets: [makeAsset()])
            )
        )

        let mutations: [(inout LocalModelAsset) -> Void] = [
            { $0.id = "" },
            { $0.id = "   " },
            { $0.feature = "" },
            { $0.version = "\n" },
            { $0.sourceRevision = "" },
            { $0.licenseName = "\t" },
        ]
        for mutate in mutations {
            var asset = makeAsset()
            mutate(&asset)
            XCTAssertThrowsError(
                try LocalModelManifestValidator.validate(
                    LocalModelManifest(schemaVersion: 1, assets: [asset])
                )
            )
        }
    }

    func testRejectsNonHTTPSAndCredentialBearingSourceOrLicenseURLs() throws {
        let invalidURLs = [
            URL(string: "http://huggingface.co/example/model")!,
            URL(string: "file:///tmp/model.bin")!,
            URL(string: "https://user:password@huggingface.co/example/model")!,
            URL(string: "https://huggingface.co/example/model?token=private")!,
            URL(string: "https://huggingface.co/example/model#fragment")!,
        ]
        for url in invalidURLs {
            var sourceAsset = makeAsset()
            sourceAsset.sourceURL = url
            XCTAssertThrowsError(try validated(sourceAsset))

            var licenseAsset = makeAsset()
            licenseAsset.licenseURL = url
            XCTAssertThrowsError(try validated(licenseAsset))
        }
    }

    func testRejectsNonExactSourceRevisions() throws {
        for revision in ["main", String(repeating: "a", count: 39), String(repeating: "A", count: 40)] {
            var asset = makeAsset()
            asset.sourceRevision = revision
            XCTAssertThrowsError(try validated(asset))
        }
    }

    func testRejectsSourceURLThatDoesNotBindTheExactRevisionOrApprovedHost() throws {
        var mismatched = makeAsset()
        mismatched.sourceRevision = String(repeating: "b", count: 40)
        XCTAssertThrowsError(try validated(mismatched))

        var foreignHost = makeAsset()
        foreignHost.sourceURL = URL(
            string: "https://example.com/FluidInference/parakeet-tdt-0.6b-v3-coreml/resolve/\(foreignHost.sourceRevision)/config.json"
        )!
        XCTAssertThrowsError(try validated(foreignHost))
    }

    func testRejectsInvalidSHA256AndNonpositiveOrUnboundedSizes() throws {
        let invalidDigests = [
            "",
            String(repeating: "a", count: 63),
            String(repeating: "a", count: 65),
            String(repeating: "A", count: 64),
            String(repeating: "g", count: 64),
        ]
        for digest in invalidDigests {
            var asset = makeAsset()
            asset.sha256 = digest
            XCTAssertThrowsError(try validated(asset))
        }

        for size in [Int64.min, -1, 0, LocalModelManifestValidator.maximumAssetBytes + 1] {
            var asset = makeAsset()
            asset.expectedBytes = size
            XCTAssertThrowsError(try validated(asset))
        }
    }

    func testRejectsNoncanonicalInstallPathsAndControlCharacters() throws {
        let invalidPaths = [
            "",
            "/absolute/model.bin",
            "../model.bin",
            "models/../model.bin",
            "models/./model.bin",
            "models//model.bin",
            "models\\model.bin",
            "models/model.bin/",
            "./models/model.bin",
            "models/\u{0000}model.bin",
            "models/\nmodel.bin",
        ]
        for path in invalidPaths {
            var asset = makeAsset()
            asset.relativeInstallPath = path
            XCTAssertThrowsError(try validated(asset), "Expected rejection for path: \(path.debugDescription)")
        }
    }

    func testRejectsDuplicateIDsInstallPathsAndSourceFileEntries() throws {
        let first = makeAsset(id: "a-model", installPath: "a/model.bin", sourceFile: "a.bin")

        var duplicateID = makeAsset(id: first.id, installPath: "b/model.bin", sourceFile: "b.bin")
        XCTAssertThrowsError(try validated([first, duplicateID]))

        duplicateID.id = "b-model"
        duplicateID.relativeInstallPath = first.relativeInstallPath
        XCTAssertThrowsError(try validated([first, duplicateID]))

        duplicateID.relativeInstallPath = "b/model.bin"
        duplicateID.sourceURL = first.sourceURL
        XCTAssertThrowsError(try validated([first, duplicateID]))
    }

    func testInstalledDirectoryRejectsMissingUnexpectedSymlinkSizeHashAndLFSPointerFiles() throws {
        let fixture = try makeInstallationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        XCTAssertNoThrow(try LocalModelManifestValidator.validateInstallation(fixture.manifest, at: fixture.root))

        try FileManager.default.removeItem(at: fixture.file)
        assertInstallError(fixture, equals: .missingFile)

        try fixture.bytes.write(to: fixture.file)
        let unexpected = fixture.root.appendingPathComponent("unexpected.bin")
        try Data("unexpected".utf8).write(to: unexpected)
        assertInstallError(fixture, equals: .unexpectedFile)
        try FileManager.default.removeItem(at: unexpected)

        try FileManager.default.removeItem(at: fixture.file)
        try FileManager.default.createSymbolicLink(at: fixture.file, withDestinationURL: URL(fileURLWithPath: "/tmp/escape"))
        assertInstallError(fixture, equals: .symbolicLink)

        try FileManager.default.removeItem(at: fixture.file)
        try Data("short".utf8).write(to: fixture.file)
        assertInstallError(fixture, equals: .sizeMismatch)

        try Data(repeating: 0x78, count: fixture.bytes.count).write(to: fixture.file)
        assertInstallError(fixture, equals: .digestMismatch)

        let pointer = Data("version https://git-lfs.github.com/spec/v1\noid sha256:\(String(repeating: "a", count: 64))\nsize 123\n".utf8)
        var pointerAsset = fixture.manifest.assets[0]
        pointerAsset.expectedBytes = Int64(pointer.count)
        pointerAsset.sha256 = SHA256.hash(data: pointer).hexString
        try pointer.write(to: fixture.file)
        XCTAssertThrowsError(
            try LocalModelManifestValidator.validateInstallation(
                LocalModelManifest(schemaVersion: 1, assets: [pointerAsset]),
                at: fixture.root
            )
        ) { error in
            XCTAssertEqual(error as? LocalModelManifestValidationError, .gitLFSPointer)
        }
    }

    func testInstallationRejectsSymlinkedRootAndIntermediateDirectories() throws {
        let fixture = try makeInstallationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let symlinkRoot = fixture.root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: symlinkRoot) }
        try FileManager.default.createSymbolicLink(at: symlinkRoot, withDestinationURL: fixture.root)
        XCTAssertThrowsError(try LocalModelManifestValidator.validateInstallation(fixture.manifest, at: symlinkRoot)) {
            XCTAssertEqual($0 as? LocalModelManifestValidationError, .symbolicLink)
        }

        try FileManager.default.removeItem(at: fixture.file.deletingLastPathComponent())
        try FileManager.default.createSymbolicLink(
            at: fixture.file.deletingLastPathComponent(),
            withDestinationURL: URL(fileURLWithPath: "/tmp")
        )
        XCTAssertThrowsError(try LocalModelManifestValidator.validateInstallation(fixture.manifest, at: fixture.root)) {
            XCTAssertEqual($0 as? LocalModelManifestValidationError, .symbolicLink)
        }
    }

    func testInstallationRejectsCRLFGitLFSPointerContent() throws {
        let fixture = try makeInstallationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let pointer = Data(
            "version https://git-lfs.github.com/spec/v1\r\noid sha256:\(String(repeating: "a", count: 64))\r\nsize 123\r\n".utf8
        )
        var asset = fixture.manifest.assets[0]
        asset.expectedBytes = Int64(pointer.count)
        asset.sha256 = SHA256.hash(data: pointer).hexString
        try pointer.write(to: fixture.file)

        XCTAssertThrowsError(
            try LocalModelManifestValidator.validateInstallation(
                LocalModelManifest(schemaVersion: 1, assets: [asset]),
                at: fixture.root
            )
        ) { error in
            XCTAssertEqual(error as? LocalModelManifestValidationError, .gitLFSPointer)
        }
    }

    func testBundledManifestLoadsFromMeetingVaultCoreResources() throws {
        let manifest = try LocalModelManifest.loadBundled()
        XCTAssertFalse(manifest.assets.isEmpty)
        XCTAssertNoThrow(try LocalModelManifestValidator.validate(manifest))
    }

    func testValidationDiagnosticsDoNotEchoPrivateOrCredentialValues() throws {
        let privateMarker = "BOARD-ACQUISITION-SECRET"
        var asset = makeAsset()
        asset.id = privateMarker
        asset.relativeInstallPath = "../\(privateMarker)"
        asset.sourceURL = URL(string: "https://user:\(privateMarker)@huggingface.co/model")!

        do {
            _ = try validated(asset)
            XCTFail("Expected manifest rejection")
        } catch {
            XCTAssertFalse(error.localizedDescription.contains(privateMarker))
            XCTAssertFalse(String(describing: error).contains(privateMarker))
        }
    }

    private func validated(_ asset: LocalModelAsset) throws -> LocalModelManifest {
        try validated([asset])
    }

    private func validated(_ assets: [LocalModelAsset]) throws -> LocalModelManifest {
        try LocalModelManifestValidator.validate(LocalModelManifest(schemaVersion: 1, assets: assets))
    }

    private func makeAsset(
        id: String = "parakeet-config",
        installPath: String = "parakeet/config.json",
        sourceFile: String = "config.json",
        bytes: Data = Data("trusted model bytes".utf8)
    ) -> LocalModelAsset {
        LocalModelAsset(
            id: id,
            feature: "automatic-speech-recognition",
            version: "aed02740059203c4a87495924f685de3722ae9ce",
            sourceURL: URL(string: "https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml/resolve/aed02740059203c4a87495924f685de3722ae9ce/\(sourceFile)")!,
            sourceRevision: "aed02740059203c4a87495924f685de3722ae9ce",
            licenseName: "CC-BY-4.0",
            licenseURL: URL(string: "https://creativecommons.org/licenses/by/4.0/legalcode.txt")!,
            expectedBytes: Int64(bytes.count),
            sha256: SHA256.hash(data: bytes).hexString,
            relativeInstallPath: installPath
        )
    }

    private func makeInstallationFixture() throws -> (root: URL, file: URL, bytes: Data, manifest: LocalModelManifest) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVault-LocalModels-\(UUID().uuidString)", isDirectory: true)
        let file = root.appendingPathComponent("parakeet/config.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data("trusted model bytes".utf8)
        try bytes.write(to: file)
        return (root, file, bytes, LocalModelManifest(schemaVersion: 1, assets: [makeAsset(bytes: bytes)]))
    }

    private func assertInstallError(
        _ fixture: (root: URL, file: URL, bytes: Data, manifest: LocalModelManifest),
        equals expected: LocalModelManifestValidationError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try LocalModelManifestValidator.validateInstallation(fixture.manifest, at: fixture.root),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(error as? LocalModelManifestValidationError, expected, file: file, line: line)
        }
    }
}

private extension SHA256.Digest {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
