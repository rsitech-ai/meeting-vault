import CryptoKit
import Foundation

public enum LocalModelManifestValidationError: Error, Equatable, Sendable {
    case unsupportedSchema
    case emptyManifest
    case missingRequiredValue
    case invalidURL
    case invalidDigest
    case invalidSize
    case invalidInstallPath
    case duplicateID
    case duplicateInstallPath
    case duplicateSourceFile
    case assetsNotDeterministicallyOrdered
    case installationRootMissing
    case missingFile
    case unexpectedFile
    case symbolicLink
    case nonRegularFile
    case sizeMismatch
    case digestMismatch
    case gitLFSPointer
    case bundledManifestMissing
    case bundledManifestUnreadable
}

extension LocalModelManifestValidationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema: "The local model manifest schema is unsupported."
        case .emptyManifest: "The local model manifest contains no assets."
        case .missingRequiredValue: "A local model manifest field is missing."
        case .invalidURL: "A local model manifest URL is invalid."
        case .invalidDigest: "A local model manifest digest is invalid."
        case .invalidSize: "A local model manifest size is invalid."
        case .invalidInstallPath: "A local model install path is invalid."
        case .duplicateID: "A local model asset identifier is duplicated."
        case .duplicateInstallPath: "A local model install path is duplicated."
        case .duplicateSourceFile: "A local model source file is duplicated."
        case .assetsNotDeterministicallyOrdered: "Local model assets are not canonically ordered."
        case .installationRootMissing: "The local model installation root is unavailable."
        case .missingFile: "A required local model file is missing."
        case .unexpectedFile: "The local model installation contains an unexpected file."
        case .symbolicLink: "The local model installation contains a symbolic link."
        case .nonRegularFile: "The local model installation contains a non-regular file."
        case .sizeMismatch: "A local model file size does not match its manifest."
        case .digestMismatch: "A local model file digest does not match its manifest."
        case .gitLFSPointer: "A local model file is a Git LFS pointer instead of model content."
        case .bundledManifestMissing: "The bundled local model manifest is missing."
        case .bundledManifestUnreadable: "The bundled local model manifest cannot be read."
        }
    }
}

public enum LocalModelManifestValidator {
    public static let supportedSchemaVersion = 1
    public static let maximumAssetBytes: Int64 = 4 * 1_024 * 1_024 * 1_024
    public static let maximumTotalBytes: Int64 = 16 * 1_024 * 1_024 * 1_024

    public static func validate(_ manifest: LocalModelManifest) throws -> LocalModelManifest {
        guard manifest.schemaVersion == supportedSchemaVersion else {
            throw LocalModelManifestValidationError.unsupportedSchema
        }
        guard !manifest.assets.isEmpty else {
            throw LocalModelManifestValidationError.emptyManifest
        }

        var ids = Set<String>()
        var installPaths = Set<String>()
        var sourceFiles = Set<String>()
        var totalBytes: Int64 = 0
        for asset in manifest.assets {
            try validate(asset)
            guard ids.insert(asset.id).inserted else {
                throw LocalModelManifestValidationError.duplicateID
            }
            guard installPaths.insert(asset.relativeInstallPath).inserted else {
                throw LocalModelManifestValidationError.duplicateInstallPath
            }
            guard sourceFiles.insert(asset.sourceURL.absoluteString).inserted else {
                throw LocalModelManifestValidationError.duplicateSourceFile
            }
            let (sum, overflow) = totalBytes.addingReportingOverflow(asset.expectedBytes)
            guard !overflow, sum <= maximumTotalBytes else {
                throw LocalModelManifestValidationError.invalidSize
            }
            totalBytes = sum
        }

        guard manifest.assets == manifest.assets.sorted(by: isCanonicallyOrdered) else {
            throw LocalModelManifestValidationError.assetsNotDeterministicallyOrdered
        }
        return manifest
    }

    public static func validateInstallation(_ manifest: LocalModelManifest, at root: URL) throws {
        let validated = try validate(manifest)
        let rootValues: URLResourceValues
        do {
            rootValues = try root.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        } catch {
            throw LocalModelManifestValidationError.installationRootMissing
        }
        guard rootValues.isSymbolicLink != true else {
            throw LocalModelManifestValidationError.symbolicLink
        }
        guard rootValues.isDirectory == true else {
            throw LocalModelManifestValidationError.installationRootMissing
        }

        let expectedPaths = Set(validated.assets.map(\.relativeInstallPath))
        var enumerationFailed = false
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey],
            options: [],
            errorHandler: { _, _ in
                enumerationFailed = true
                return false
            }
        ) else {
            throw LocalModelManifestValidationError.installationRootMissing
        }

        let rootPath = root.standardizedFileURL.path
        while let item = enumerator.nextObject() as? URL {
            let values: URLResourceValues
            do {
                values = try item.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
            } catch {
                throw LocalModelManifestValidationError.nonRegularFile
            }
            guard values.isSymbolicLink != true else {
                throw LocalModelManifestValidationError.symbolicLink
            }
            if values.isDirectory == true {
                continue
            }
            guard values.isRegularFile == true else {
                throw LocalModelManifestValidationError.nonRegularFile
            }
            let itemPath = item.standardizedFileURL.path
            guard itemPath.hasPrefix(rootPath + "/") else {
                throw LocalModelManifestValidationError.invalidInstallPath
            }
            let relativePath = String(itemPath.dropFirst(rootPath.count + 1))
            guard expectedPaths.contains(relativePath) else {
                throw LocalModelManifestValidationError.unexpectedFile
            }
        }
        guard !enumerationFailed else {
            throw LocalModelManifestValidationError.nonRegularFile
        }

        for asset in validated.assets {
            let fileURL = root.appendingPathComponent(asset.relativeInstallPath, isDirectory: false)
            try rejectSymlinks(from: root, through: asset.relativeInstallPath)
            try validateFile(fileURL, against: asset)
        }
    }

    /// Validates one manifest-bound file without relaxing whole-installation exact-file checks.
    /// Lifecycle repair uses this to copy only already-valid files into a fresh atomic staging tree,
    /// then calls `validateInstallation` on the complete unit before promotion.
    public static func validateAssetFile(_ asset: LocalModelAsset, at root: URL) throws {
        try validate(asset)
        let values: URLResourceValues
        do {
            values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        } catch {
            throw LocalModelManifestValidationError.installationRootMissing
        }
        guard values.isDirectory == true else {
            throw LocalModelManifestValidationError.installationRootMissing
        }
        guard values.isSymbolicLink != true else {
            throw LocalModelManifestValidationError.symbolicLink
        }
        try rejectSymlinks(from: root, through: asset.relativeInstallPath)
        try validateFile(root.appendingPathComponent(asset.relativeInstallPath), against: asset)
    }

    private static func validate(_ asset: LocalModelAsset) throws {
        for value in [asset.id, asset.feature, asset.version, asset.sourceRevision, asset.licenseName] {
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw LocalModelManifestValidationError.missingRequiredValue
            }
        }
        guard isSafeHTTPSURL(asset.sourceURL), isSafeHTTPSURL(asset.licenseURL) else {
            throw LocalModelManifestValidationError.invalidURL
        }
        guard asset.sourceRevision.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil else {
            throw LocalModelManifestValidationError.missingRequiredValue
        }
        guard asset.sourceURL.host?.lowercased() == "huggingface.co",
              asset.sourceURL.path.contains("/resolve/\(asset.sourceRevision)/") else {
            throw LocalModelManifestValidationError.invalidURL
        }
        guard asset.expectedBytes > 0, asset.expectedBytes <= maximumAssetBytes else {
            throw LocalModelManifestValidationError.invalidSize
        }
        guard asset.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            throw LocalModelManifestValidationError.invalidDigest
        }
        guard isNormalizedRelativePath(asset.relativeInstallPath) else {
            throw LocalModelManifestValidationError.invalidInstallPath
        }
    }

    private static func isSafeHTTPSURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return false
        }
        return components.scheme == "https"
            && components.host?.isEmpty == false
            && components.user == nil
            && components.password == nil
            && components.query == nil
            && components.fragment == nil
    }

    private static func isNormalizedRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.hasSuffix("/"),
              !path.contains("\\"),
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            return false
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return false
        }
        return NSString(string: path).standardizingPath == path
    }

    private static func isCanonicallyOrdered(_ lhs: LocalModelAsset, _ rhs: LocalModelAsset) -> Bool {
        let left = [lhs.id, lhs.relativeInstallPath, lhs.sourceURL.absoluteString]
        let right = [rhs.id, rhs.relativeInstallPath, rhs.sourceURL.absoluteString]
        return left.lexicographicallyPrecedes(right)
    }

    private static func rejectSymlinks(from root: URL, through relativePath: String) throws {
        var cursor = root
        for component in relativePath.split(separator: "/") {
            cursor.appendPathComponent(String(component))
            let values: URLResourceValues
            do {
                values = try cursor.resourceValues(forKeys: [.isSymbolicLinkKey])
            } catch {
                throw LocalModelManifestValidationError.missingFile
            }
            guard values.isSymbolicLink != true else {
                throw LocalModelManifestValidationError.symbolicLink
            }
        }
    }

    private static func validateFile(_ url: URL, against asset: LocalModelAsset) throws {
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        } catch {
            throw LocalModelManifestValidationError.missingFile
        }
        guard values.isRegularFile == true else {
            throw LocalModelManifestValidationError.nonRegularFile
        }
        guard Int64(values.fileSize ?? -1) == asset.expectedBytes else {
            throw LocalModelManifestValidationError.sizeMismatch
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw LocalModelManifestValidationError.missingFile
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        var prefix = Data()
        do {
            while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
                if prefix.count < 256 {
                    prefix.append(chunk.prefix(256 - prefix.count))
                }
                hasher.update(data: chunk)
            }
        } catch {
            throw LocalModelManifestValidationError.digestMismatch
        }
        let prefixText = String(decoding: prefix, as: UTF8.self)
        if prefixText.hasPrefix("version https://git-lfs.github.com/spec/v1\n")
            || prefixText.hasPrefix("version https://git-lfs.github.com/spec/v1\r\n") {
            throw LocalModelManifestValidationError.gitLFSPointer
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == asset.sha256 else {
            throw LocalModelManifestValidationError.digestMismatch
        }
    }
}
