import Foundation

public enum MeetingBundleStoreError: Error, Equatable {
    case unsafeRelativePath(String)
    case bundleNotFound(UUID)
    case bundlePreparationIncomplete
    case manifestMeetingMismatch
}

extension MeetingBundleStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsafeRelativePath:
            "The encrypted meeting bundle path is unsafe."
        case .bundleNotFound:
            "The encrypted meeting bundle was not found."
        case .bundlePreparationIncomplete:
            "The encrypted meeting bundle is not ready."
        case .manifestMeetingMismatch:
            "The encrypted meeting manifest belongs to a different meeting."
        }
    }
}

// FileManager is thread-safe for the independent filesystem operations used here.
// Encoders and decoders are created per operation so no mutable codec is shared.
public struct EncryptedMeetingBundleStore: @unchecked Sendable {
    public let rootDirectory: URL
    private let vault: AESGCMDataVault
    private let fileManager: FileManager

    public init(
        rootDirectory: URL,
        vault: AESGCMDataVault,
        fileManager: FileManager = .default
    ) {
        self.rootDirectory = rootDirectory
        self.vault = vault
        self.fileManager = fileManager
    }

    public func createBundle(_ manifest: MeetingBundleManifest) throws -> URL {
        let bundleURL = bundleURL(for: manifest.meetingID)
        try fileManager.createDirectory(
            at: bundleURL.appendingPathComponent("audio", isDirectory: true),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: bundleURL.appendingPathComponent("transcript", isDirectory: true),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: bundleURL.appendingPathComponent("ai", isDirectory: true),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: bundleURL.appendingPathComponent("diagnostics", isDirectory: true),
            withIntermediateDirectories: true
        )
        try writeJSONArtifact(
            manifest,
            meetingID: manifest.meetingID,
            relativePath: "manifest.json.enc",
            purpose: "manifest"
        )
        return bundleURL
    }

    public func createPreparingBundle(_ manifest: MeetingBundleManifest) throws -> URL {
        let bundleURL = bundleURL(for: manifest.meetingID)
        try fileManager.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try Data().write(to: preparationMarkerURL(for: manifest.meetingID), options: [.atomic])
        return try createBundle(manifest)
    }

    public func readManifest(meetingID: UUID) throws -> MeetingBundleManifest {
        guard fileManager.fileExists(atPath: bundleURL(for: meetingID).path) else {
            throw MeetingBundleStoreError.bundleNotFound(meetingID)
        }
        guard !fileManager.fileExists(atPath: preparationMarkerURL(for: meetingID).path) else {
            throw MeetingBundleStoreError.bundlePreparationIncomplete
        }
        let manifest: MeetingBundleManifest = try readJSONArtifact(
            MeetingBundleManifest.self,
            meetingID: meetingID,
            relativePath: "manifest.json.enc",
            purpose: "manifest"
        )
        guard manifest.meetingID == meetingID else {
            throw MeetingBundleStoreError.manifestMeetingMismatch
        }
        return manifest
    }

    public func listMeetingBundleIDs() throws -> [UUID] {
        guard fileManager.fileExists(atPath: rootDirectory.path) else {
            return []
        }

        let urls = try fileManager.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        return urls.compactMap { url in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  url.pathExtension == "meetingvault"
            else {
                return nil
            }
            let meetingID = UUID(uuidString: url.deletingPathExtension().lastPathComponent)
            guard let meetingID,
                  fileManager.fileExists(
                    atPath: url.appendingPathComponent("manifest.json.enc").path
                  ),
                  !fileManager.fileExists(atPath: preparationMarkerURL(for: meetingID).path)
            else {
                return nil
            }
            return meetingID
        }
        .sorted { $0.uuidString < $1.uuidString }
    }

    public func deleteBundle(meetingID: UUID) throws {
        let url = bundleURL(for: meetingID)
        guard fileManager.fileExists(atPath: url.path) else {
            throw MeetingBundleStoreError.bundleNotFound(meetingID)
        }
        try fileManager.removeItem(at: url)
    }

    public func markBundlePreparationComplete(meetingID: UUID) throws {
        let markerURL = preparationMarkerURL(for: meetingID)
        guard fileManager.fileExists(atPath: markerURL.path) else { return }
        try fileManager.removeItem(at: markerURL)
    }

    public func artifactExists(meetingID: UUID, relativePath: String) throws -> Bool {
        let url = try resolvedBundleFileURL(meetingID: meetingID, relativePath: relativePath)
        return fileManager.fileExists(atPath: url.path)
    }

    public func deleteArtifact(meetingID: UUID, relativePath: String) throws {
        let url = try resolvedBundleFileURL(meetingID: meetingID, relativePath: relativePath)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    public func writeJSONArtifact<Value: Encodable>(
        _ value: Value,
        meetingID: UUID,
        relativePath: String,
        purpose: String
    ) throws {
        let targetURL = try resolvedBundleFileURL(meetingID: meetingID, relativePath: relativePath)
        try fileManager.createDirectory(
            at: targetURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = Self.makeEncoder()
        let encoded = try encoder.encode(value)
        let encrypted = try vault.seal(encoded, purpose: purpose)
        let blob = try encoder.encode(encrypted)
        try blob.write(to: targetURL, options: [.atomic])
    }

    public func writeEncryptedData(
        _ data: Data,
        meetingID: UUID,
        relativePath: String,
        purpose: String
    ) throws {
        let targetURL = try resolvedBundleFileURL(meetingID: meetingID, relativePath: relativePath)
        try fileManager.createDirectory(
            at: targetURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = Self.makeEncoder()
        let encrypted = try vault.seal(data, purpose: purpose)
        let blob = try encoder.encode(encrypted)
        try blob.write(to: targetURL, options: [.atomic])
    }

    public func readJSONArtifact<Value: Decodable>(
        _ type: Value.Type,
        meetingID: UUID,
        relativePath: String,
        purpose: String
    ) throws -> Value {
        let targetURL = try resolvedBundleFileURL(meetingID: meetingID, relativePath: relativePath)
        let blobData = try Data(contentsOf: targetURL)
        let decoder = Self.makeDecoder()
        let encrypted = try decoder.decode(EncryptedBlob.self, from: blobData)
        let plaintext = try vault.open(encrypted, purpose: purpose)
        return try decoder.decode(Value.self, from: plaintext)
    }

    public func readEncryptedData(
        meetingID: UUID,
        relativePath: String,
        purpose: String
    ) throws -> Data {
        let targetURL = try resolvedBundleFileURL(meetingID: meetingID, relativePath: relativePath)
        let blobData = try Data(contentsOf: targetURL)
        let encrypted = try Self.makeDecoder().decode(EncryptedBlob.self, from: blobData)
        return try vault.open(encrypted, purpose: purpose)
    }

    public func bundleURL(for meetingID: UUID) -> URL {
        rootDirectory.appendingPathComponent("\(meetingID.uuidString).meetingvault", isDirectory: true)
    }

    private func preparationMarkerURL(for meetingID: UUID) -> URL {
        bundleURL(for: meetingID).appendingPathComponent(".preparation-incomplete")
    }

    private func resolvedBundleFileURL(meetingID: UUID, relativePath: String) throws -> URL {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.split(separator: "/").contains("..")
        else {
            throw MeetingBundleStoreError.unsafeRelativePath(relativePath)
        }

        let bundleURL = bundleURL(for: meetingID).standardizedFileURL
        let targetURL = bundleURL.appendingPathComponent(relativePath).standardizedFileURL

        guard targetURL.path == bundleURL.path || targetURL.path.hasPrefix(bundleURL.path + "/") else {
            throw MeetingBundleStoreError.unsafeRelativePath(relativePath)
        }

        return targetURL
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
