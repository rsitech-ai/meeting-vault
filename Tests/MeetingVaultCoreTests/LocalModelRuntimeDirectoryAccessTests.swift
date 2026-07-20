import Darwin
@preconcurrency import CoreML
import Foundation
import XCTest
@testable import MeetingVaultCore

final class LocalModelRuntimeDirectoryAccessTests: XCTestCase {
    func testLoadsARealValidCoreMLPackageThroughVerifiedNormalPathCapability() async throws {
        let systemModel = URL(fileURLWithPath: "/System/Library/DuetExpertCenter/Assets/Assets.bundle/AssetData/ATXModeWorkingSetupPredictionModel.mlmodelc", isDirectory: true)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: systemModel.path))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let copiedModel = root.appendingPathComponent("Valid.mlmodelc", isDirectory: true)
        try FileManager.default.copyItem(at: systemModel, to: copiedModel)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: copiedModel.path)
        let access = LocalModelRuntimeAccess(assetIDs: ["asr"], roots: ["asr": root])

        let observation = DirectoryObservation()
        try await access.withVerifiedModelPackageURL(assetID: "asr", relativePath: "Valid.mlmodelc") { url in
            _ = try MLModel(contentsOf: url, configuration: MLModelConfiguration())
            observation.markObserved()
        }

        XCTAssertTrue(observation.wasObserved)
        await access.invalidateAndWait()
    }

    func testVerifiedModelPackageCapabilityRejectsSymlinkAndGroupWritableAncestor() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let models = root.appendingPathComponent("Models", isDirectory: true)
        let package = models.appendingPathComponent("Model.mlmodelc", isDirectory: true)
        try FileManager.default.createDirectory(
            at: package,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let linkedPackage = root.appendingPathComponent("Linked.mlmodelc", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedPackage, withDestinationURL: package)
        let access = LocalModelRuntimeAccess(assetIDs: ["asr"], roots: ["asr": root])

        do {
            try await access.withVerifiedModelPackageURL(assetID: "asr", relativePath: "Linked.mlmodelc") { _ in
                XCTFail("A symlink must never reach the loader callback")
            }
            XCTFail("Expected symlink rejection")
        } catch {
            XCTAssertEqual(error as? LocalModelInstallationError, .unsafeFile)
        }

        try FileManager.default.setAttributes([.posixPermissions: 0o770], ofItemAtPath: models.path)
        do {
            try await access.withVerifiedModelPackageURL(assetID: "asr", relativePath: "Models/Model.mlmodelc") { _ in
                XCTFail("A group-writable ancestor must never reach the loader callback")
            }
            XCTFail("Expected unsafe ancestor mode rejection")
        } catch {
            XCTAssertEqual(error as? LocalModelInstallationError, .unsafeFile)
        }
    }

    func testProvidesScopedReadOnlyDirectoryDescriptorAndRejectsTraversalAndSymlinks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("Model.mlmodelc", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: package.appendingPathComponent("metadata.json"))
        let symlink = root.appendingPathComponent("linked.mlmodelc")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: package)
        let access = LocalModelRuntimeAccess(assetIDs: ["asr"], roots: ["asr": root])

        let observation = DirectoryObservation()
        try await access.withReadOnlyDirectoryDescriptor(assetID: "asr", relativePath: "Model.mlmodelc") { descriptor in
            var info = stat()
            XCTAssertEqual(fstat(descriptor, &info), 0)
            XCTAssertEqual(info.st_mode & S_IFMT, S_IFDIR)
            observation.markObserved()
        }
        XCTAssertTrue(observation.wasObserved)

        for unsafe in ["../Model.mlmodelc", "linked.mlmodelc", "Model.mlmodelc/metadata.json"] {
            do {
                try await access.withReadOnlyDirectoryDescriptor(assetID: "asr", relativePath: unsafe) { _ in }
                XCTFail("Expected unsafe directory rejection")
            } catch {
                XCTAssertEqual(error as? LocalModelInstallationError, .unsafeFile)
            }
        }
        await access.invalidateAndWait()
        do {
            try await access.withReadOnlyDirectoryDescriptor(assetID: "asr", relativePath: "Model.mlmodelc") { _ in }
            XCTFail("Expected invalidated access rejection")
        } catch {
            XCTAssertEqual(error as? LocalModelInstallationError, .unitNotReady)
        }
    }
}

private final class DirectoryObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var observed = false
    var wasObserved: Bool { lock.withLock { observed } }
    func markObserved() { lock.withLock { observed = true } }
}
