import CryptoKit
import Foundation
import XCTest
@testable import MeetingVaultCore

final class LocalModelSupplyChainReviewTests: XCTestCase {
    func testBundledManifestPrefersStandardMacAppResourcesWithoutEvaluatingSwiftPMFallback() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultStandardResources-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let standardBundle = root.appendingPathComponent("MeetingVault_MeetingVaultCore.bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: standardBundle, withIntermediateDirectories: true)
        let standardManifest = standardBundle.appendingPathComponent("LocalModels.json")
        try validManifestData().write(to: standardManifest)

        var fallbackEvaluated = false
        let resolved = LocalModelManifest.bundledManifestURL(
            appResources: root,
            moduleResources: {
                fallbackEvaluated = true
                return nil
            }
        )

        XCTAssertEqual(resolved, standardManifest)
        XCTAssertFalse(fallbackEvaluated)
    }

    func testStageAppBundlePlacesSwiftPMBundlesInsideContentsResources() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("script/stage_app_bundle.sh"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("$APP_RESOURCES/$(basename \"$resource_bundle\")"))
        XCTAssertFalse(source.contains("$APP_BUNDLE/$(basename \"$resource_bundle\")"))
    }

    func testRuntimeLayoutReturnsTheExactTask9AdapterRoots() {
        let root = URL(fileURLWithPath: "/tmp/meetingvault-models")
        let layout = LocalModelRuntimeLayout(root: root)

        XCTAssertEqual(layout.parakeetASR.path, "/tmp/meetingvault-models/parakeet-tdt-0.6b-v3")
        XCTAssertEqual(layout.lsEENDCache.path, "/tmp/meetingvault-models")
        XCTAssertEqual(layout.lsEENDModel.path, "/tmp/meetingvault-models/ls-eend/dih3/optimized/dih3/100ms")
        XCTAssertEqual(layout.offlineDiarization.path, "/tmp/meetingvault-models")
    }

    func testStrictManifestLoaderRejectsUnknownAndOversizedPayloads() throws {
        let asset = try XCTUnwrap(LocalModelManifest.load(data: validManifestData()).assets.first)
        XCTAssertEqual(asset.id, "fixture")

        var unknownTopLevel = try JSONSerialization.jsonObject(with: validManifestData()) as! [String: Any]
        unknownTopLevel["untrusted"] = true
        XCTAssertThrowsError(try LocalModelManifest.load(data: JSONSerialization.data(withJSONObject: unknownTopLevel)))

        XCTAssertThrowsError(try LocalModelManifest.load(data: Data(repeating: 0x20, count: LocalModelManifest.maximumEncodedBytes + 1)))
    }

    func testStrictManifestLoaderRejectsUnknownAssetKeysMissingKeysAndTypeDrift() throws {
        let document = try manifestObject()

        var unknownAssetKey = document
        var unknownAsset = try asset(from: unknownAssetKey)
        unknownAsset["untrusted"] = true
        unknownAssetKey["assets"] = [unknownAsset]
        assertUnreadable(unknownAssetKey)

        var missingTopLevelKey = document
        missingTopLevelKey.removeValue(forKey: "assets")
        assertUnreadable(missingTopLevelKey)

        var missingAssetKey = document
        var missingAsset = try asset(from: missingAssetKey)
        missingAsset.removeValue(forKey: "licenseURL")
        missingAssetKey["assets"] = [missingAsset]
        assertUnreadable(missingAssetKey)

        var typeDrift = document
        var driftedAsset = try asset(from: typeDrift)
        driftedAsset["expectedBytes"] = "1"
        typeDrift["assets"] = [driftedAsset]
        assertUnreadable(typeDrift)
    }

    func testStrictManifestLoaderRejectsMoreThan128AssetsBeforeValidation() throws {
        let document = try manifestObject()
        let fixture = try asset(from: document)
        var overLimit = document
        overLimit["assets"] = Array(repeating: fixture, count: LocalModelManifest.maximumAssetCount + 1)

        assertUnreadable(overLimit)
    }
    func testGeneratedAssetsUseThePinnedFluidAudioLoaderRoots() throws {
        let manifestURL = try XCTUnwrap(
            Bundle.module.url(forResource: "LocalModels", withExtension: "json")
        )
        let manifest = try JSONDecoder().decode(
            LocalModelManifest.self,
            from: Data(contentsOf: manifestURL)
        )

        for asset in manifest.assets {
            let sourcePath = try XCTUnwrap(asset.sourceURL.path.removingPercentEncoding)
            let marker = "/resolve/\(asset.sourceRevision)/"
            let markerRange = try XCTUnwrap(sourcePath.range(of: marker))
            let sourceFilePath = sourcePath[markerRange.upperBound...]
            if sourcePath.contains("/FluidInference/parakeet-tdt-0.6b-v3-coreml/") {
                XCTAssertEqual(asset.relativeInstallPath, "parakeet-tdt-0.6b-v3/" + sourceFilePath)
            } else if sourcePath.contains("/FluidInference/ls-eend-coreml/") {
                let optimizedPrefix = "optimized/dih3/"
                XCTAssertTrue(sourceFilePath.hasPrefix(optimizedPrefix))
                XCTAssertEqual(
                    asset.relativeInstallPath,
                    "ls-eend/dih3/" + sourceFilePath
                )
                XCTAssertFalse(asset.relativeInstallPath.contains("optimized/dih3/optimized/dih3/"))
            } else if sourcePath.contains("/FluidInference/speaker-diarization-coreml/") {
                XCTAssertEqual(asset.relativeInstallPath, "speaker-diarization/" + sourceFilePath)
            } else {
                XCTFail("Asset came from an unapproved repository")
            }
        }
    }

    func testRequiredFluidAudioThirdPartyNoticesAreBundledVerbatim() throws {
        let notices = try XCTUnwrap(Bundle.module.resourceURL)
        let expectedDigests = [
            "fastcluster-LICENSE.md": "67594dbe4a7477719c8160373e7767c2c319ef966a6042f76846a18af02cde0a",
            "vbx-LICENSE.md": "08e57fdb5187c816e937916f1e176aadb400ca76f4b3b493d69730ec8f10dd80"
        ]
        for (name, expectedDigest) in expectedDigests {
            let data = try Data(contentsOf: notices.appendingPathComponent(name))
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(digest, expectedDigest)
        }
    }

    private func validManifestData() -> Data {
        Data("""
        {"schemaVersion":1,"assets":[{"id":"fixture","feature":"fixture","version":"1","sourceURL":"https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml/resolve/aed02740059203c4a87495924f685de3722ae9ce/config.json","sourceRevision":"aed02740059203c4a87495924f685de3722ae9ce","licenseName":"MIT","licenseURL":"https://opensource.org/license/mit","expectedBytes":1,"sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","relativeInstallPath":"fixture/config.json"}]}
        """.utf8)
    }

    private func manifestObject() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: validManifestData()) as? [String: Any])
    }

    private func asset(from document: [String: Any]) throws -> [String: Any] {
        try XCTUnwrap((document["assets"] as? [[String: Any]])?.first)
    }

    private func assertUnreadable(
        _ document: [String: Any],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try LocalModelManifest.load(data: JSONSerialization.data(withJSONObject: document)),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? LocalModelManifestValidationError,
                .bundledManifestUnreadable,
                file: file,
                line: line
            )
        }
    }
}
