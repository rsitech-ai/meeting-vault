import Foundation

public struct LocalModelManifest: Codable, Equatable, Sendable {
    public static let maximumEncodedBytes = 512 * 1_024
    public static let maximumAssetCount = 128
    public var schemaVersion: Int
    public var assets: [LocalModelAsset]

    public init(schemaVersion: Int, assets: [LocalModelAsset]) {
        self.schemaVersion = schemaVersion
        self.assets = assets
    }

    public static func loadBundled() throws -> LocalModelManifest {
        guard let url = bundledManifestURL(
            appResources: Bundle.main.resourceURL,
            moduleResources: { Bundle.module.resourceURL }
        ) else {
            throw LocalModelManifestValidationError.bundledManifestMissing
        }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1
            guard size >= 0, size <= maximumEncodedBytes else {
                throw LocalModelManifestValidationError.bundledManifestUnreadable
            }
            return try load(data: Data(contentsOf: url))
        } catch let error as LocalModelManifestValidationError {
            throw error
        } catch {
            throw LocalModelManifestValidationError.bundledManifestUnreadable
        }
    }

    static func bundledManifestURL(
        appResources: URL?,
        moduleResources: () -> URL?
    ) -> URL? {
        if let standardAppURL = appResources?
            .appendingPathComponent("MeetingVault_MeetingVaultCore.bundle", isDirectory: true)
            .appendingPathComponent("LocalModels.json"),
           FileManager.default.fileExists(atPath: standardAppURL.path) {
            return standardAppURL
        }
        return moduleResources()?.appendingPathComponent("LocalModels.json")
    }

    /// Decodes an untrusted manifest with exact top-level and asset key sets.
    public static func load(data: Data) throws -> LocalModelManifest {
        guard data.count <= maximumEncodedBytes else {
            throw LocalModelManifestValidationError.bundledManifestUnreadable
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["schemaVersion", "assets"],
              let assets = object["assets"] as? [[String: Any]],
              assets.count <= maximumAssetCount else {
            throw LocalModelManifestValidationError.bundledManifestUnreadable
        }
        let assetKeys: Set<String> = [
            "id", "feature", "version", "sourceURL", "sourceRevision", "licenseName",
            "licenseURL", "expectedBytes", "sha256", "relativeInstallPath"
        ]
        guard assets.allSatisfy({ Set($0.keys) == assetKeys }) else {
            throw LocalModelManifestValidationError.bundledManifestUnreadable
        }
        let manifest: LocalModelManifest
        do {
            manifest = try JSONDecoder().decode(LocalModelManifest.self, from: data)
        } catch {
            throw LocalModelManifestValidationError.bundledManifestUnreadable
        }
        return try LocalModelManifestValidator.validate(manifest)
    }
}

public struct LocalModelAsset: Codable, Equatable, Sendable {
    public var id: String
    public var feature: String
    public var version: String
    public var sourceURL: URL
    public var sourceRevision: String
    public var licenseName: String
    public var licenseURL: URL
    public var expectedBytes: Int64
    public var sha256: String
    public var relativeInstallPath: String

    public init(
        id: String,
        feature: String,
        version: String,
        sourceURL: URL,
        sourceRevision: String,
        licenseName: String,
        licenseURL: URL,
        expectedBytes: Int64,
        sha256: String,
        relativeInstallPath: String
    ) {
        self.id = id
        self.feature = feature
        self.version = version
        self.sourceURL = sourceURL
        self.sourceRevision = sourceRevision
        self.licenseName = licenseName
        self.licenseURL = licenseURL
        self.expectedBytes = expectedBytes
        self.sha256 = sha256
        self.relativeInstallPath = relativeInstallPath
    }
}
