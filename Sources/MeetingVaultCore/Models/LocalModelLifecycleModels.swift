import Darwin
import Foundation

public enum LocalModelAssetStatus: String, Codable, Sendable {
    case notInstalled
    case downloading
    case verifying
    case ready
    case repairNeeded
    case unsupported
}

public struct LocalModelAssetState: Codable, Equatable, Sendable {
    public var id: String
    public var status: LocalModelAssetStatus
    public var completedBytes: Int64
    public var totalBytes: Int64

    public init(id: String, status: LocalModelAssetStatus, completedBytes: Int64, totalBytes: Int64) {
        self.id = id
        self.status = status
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
    }
}

public protocol LocalModelReadinessProviding: Sendable {
    func snapshot() async -> [LocalModelAssetState]
}

public enum ModelInstallEvent: Equatable, Sendable {
    case progress(completedBytes: Int64, totalBytes: Int64)
    case status(LocalModelAssetStatus)
}

public struct ModelSelfCheck: Codable, Equatable, Sendable {
    public var assetID: String
    public var passed: Bool
    public var duration: TimeInterval

    public init(assetID: String, passed: Bool, duration: TimeInterval) {
        self.assetID = assetID
        self.passed = passed
        self.duration = duration
    }
}

public struct LocalModelInstallUnit: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var provider: String
    public var model: String
    public var version: String
    public var source: String
    public var licenseName: String
    public var licenseURL: URL
    public var expectedBytes: Int64
    public var aggregateSHA256: String
    public var relativeLocation: String
    public var fileCount: Int

    public init(
        id: String,
        provider: String,
        model: String,
        version: String,
        source: String,
        licenseName: String,
        licenseURL: URL,
        expectedBytes: Int64,
        aggregateSHA256: String,
        relativeLocation: String,
        fileCount: Int
    ) {
        self.id = id
        self.provider = provider
        self.model = model
        self.version = version
        self.source = source
        self.licenseName = licenseName
        self.licenseURL = licenseURL
        self.expectedBytes = expectedBytes
        self.aggregateSHA256 = aggregateSHA256
        self.relativeLocation = relativeLocation
        self.fileCount = fileCount
    }
}

public enum LocalModelInstallationError: Error, Equatable, Sendable {
    case unknownUnit
    case operationInProgress
    case insufficientDisk
    case invalidResponse
    case redirectRejected
    case rangeRejected
    case sizeMismatch
    case digestMismatch
    case gitLFSPointer
    case unsafeFile
    case crossVolumeStaging
    case promotionFailed
    case promotionRecoveryRequired
    case unitNotReady
    case unitInUse
    case selfCheckFailed
    case selfCheckTimedOut
    case selfCheckUnavailable
}

extension LocalModelInstallationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unknownUnit: "The requested local model unit is unknown."
        case .operationInProgress: "A local model operation is already running."
        case .insufficientDisk: "There is not enough free disk space for this model operation."
        case .invalidResponse: "The approved model source returned an invalid response."
        case .redirectRejected: "The model source redirect was rejected."
        case .rangeRejected: "The model source did not honor the requested resume range."
        case .sizeMismatch: "The downloaded model file has an unexpected size."
        case .digestMismatch: "The downloaded model file failed integrity verification."
        case .gitLFSPointer: "The model source returned a Git LFS pointer instead of model bytes."
        case .unsafeFile: "The local model staging area contains an unsafe file."
        case .crossVolumeStaging: "The model staging directory is not on the model volume."
        case .promotionFailed: "The verified local model could not be promoted safely."
        case .promotionRecoveryRequired: "Local model promotion was interrupted and requires restart recovery."
        case .unitNotReady: "The local model unit is not ready."
        case .unitInUse: "The local model unit is currently in use."
        case .selfCheckFailed: "The local model self-check failed."
        case .selfCheckTimedOut: "The local model self-check timed out."
        case .selfCheckUnavailable: "Local provider integration is unavailable until Task 9 installs a terminating executor."
        }
    }
}

public final class ModelUsageLease: @unchecked Sendable {
    public let assetIDs: Set<String>
    private let lock = NSLock()
    private var releaseAction: (@Sendable () -> Void)?

    init(assetIDs: Set<String>, releaseAction: @escaping @Sendable () -> Void) {
        self.assetIDs = assetIDs
        self.releaseAction = releaseAction
    }

    public func release() {
        let action = lock.withLock { () -> (@Sendable () -> Void)? in
            defer { releaseAction = nil }
            return releaseAction
        }
        action?()
    }

    var isReleased: Bool {
        lock.withLock { releaseAction == nil }
    }

    deinit {
        release()
    }
}

/// Opaque, descriptor-backed access for a provider runtime session. No model
/// URL escapes this object; the service invalidates it before releasing leases.
public final class LocalModelRuntimeAccess: @unchecked Sendable {
    public let assetIDs: Set<String>
    private let roots: [String: URL]
    private let state = LocalModelRuntimeAccessState()

    init(assetIDs: Set<String>, roots: [String: URL]) {
        self.assetIDs = assetIDs
        self.roots = roots
    }

    public func withReadOnlyFileDescriptor(
        assetID: String,
        relativePath: String,
        _ operation: @Sendable (Int32) async throws -> Void
    ) async throws {
        try await state.beginOperation()
        do {
            try await performDescriptorOperation(
                assetID: assetID,
                relativePath: relativePath,
                expectedType: S_IFREG,
                operation
            )
            await state.finishOperation()
        } catch {
            await state.finishOperation()
            throw error
        }
    }

    /// Provides a lease-scoped descriptor for a verified directory. Every path
    /// component is opened with `O_NOFOLLOW`.
    public func withReadOnlyDirectoryDescriptor(
        assetID: String,
        relativePath: String,
        _ operation: @Sendable (Int32) async throws -> Void
    ) async throws {
        try await state.beginOperation()
        do {
            try await performDescriptorOperation(
                assetID: assetID,
                relativePath: relativePath,
                expectedType: S_IFDIR,
                operation
            )
            await state.finishOperation()
        } catch {
            await state.finishOperation()
            throw error
        }
    }

    /// Invokes a synchronous model loader with a normal filesystem URL after
    /// verifying the managed root and every package path component. The URL is
    /// intentionally package-internal and cannot escape this non-escaping
    /// callback; the runtime lease remains held by the owning session.
    func withVerifiedModelPackageURL(
        assetID: String,
        relativePath: String,
        _ operation: @Sendable (URL) throws -> Void
    ) async throws {
        try await state.beginOperation()
        do {
            try performVerifiedModelPackageOperation(
                assetID: assetID,
                relativePath: relativePath,
                operation
            )
            await state.finishOperation()
        } catch {
            await state.finishOperation()
            throw error
        }
    }

    private func performVerifiedModelPackageOperation(
        assetID: String,
        relativePath: String,
        _ operation: @Sendable (URL) throws -> Void
    ) throws {
        guard let configuredRoot = roots[assetID], configuredRoot.isFileURL else {
            throw LocalModelInstallationError.unitNotReady
        }
        let components = try validatedPathComponents(relativePath)
        let root = configuredRoot.standardizedFileURL
        var descriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw LocalModelInstallationError.unitNotReady }
        defer { close(descriptor) }

        try verifyPathAndDescriptor(root, descriptor: descriptor, expectedType: S_IFDIR)
        var packageURL = root
        for component in components {
            let nextURL = packageURL.appendingPathComponent(component, isDirectory: true)
            let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard next >= 0 else { throw LocalModelInstallationError.unsafeFile }
            close(descriptor)
            descriptor = next
            try verifyPathAndDescriptor(nextURL, descriptor: descriptor, expectedType: S_IFDIR)
            packageURL = nextURL
        }

        // Re-check the complete chain immediately before handing the path to
        // Core ML. Private, non-group/world-writable ancestors prevent another
        // user from replacing components between this check and the sync load.
        var ancestor = root
        var ancestorDescriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard ancestorDescriptor >= 0 else { throw LocalModelInstallationError.unsafeFile }
        defer { close(ancestorDescriptor) }
        try verifyPathAndDescriptor(ancestor, descriptor: ancestorDescriptor, expectedType: S_IFDIR)
        for component in components {
            ancestor = ancestor.appendingPathComponent(component, isDirectory: true)
            let next = openat(ancestorDescriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard next >= 0 else { throw LocalModelInstallationError.unsafeFile }
            close(ancestorDescriptor)
            ancestorDescriptor = next
            try verifyPathAndDescriptor(ancestor, descriptor: ancestorDescriptor, expectedType: S_IFDIR)
        }
        try operation(packageURL)
    }

    private func validatedPathComponents(_ relativePath: String) throws -> [String] {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }) else {
            throw LocalModelInstallationError.unsafeFile
        }
        return components
    }

    private func verifyPathAndDescriptor(_ url: URL, descriptor: Int32, expectedType: mode_t) throws {
        var descriptorInfo = stat()
        var pathInfo = stat()
        guard fstat(descriptor, &descriptorInfo) == 0,
              lstat(url.path, &pathInfo) == 0,
              (descriptorInfo.st_mode & S_IFMT) == expectedType,
              (pathInfo.st_mode & S_IFMT) == expectedType,
              descriptorInfo.st_uid == getuid(),
              pathInfo.st_uid == getuid(),
              descriptorInfo.st_dev == pathInfo.st_dev,
              descriptorInfo.st_ino == pathInfo.st_ino,
              descriptorInfo.st_mode & 0o022 == 0,
              pathInfo.st_mode & 0o022 == 0 else {
            throw LocalModelInstallationError.unsafeFile
        }
    }

    private func performDescriptorOperation(
        assetID: String,
        relativePath: String,
        expectedType: mode_t,
        _ operation: @Sendable (Int32) async throws -> Void
    ) async throws {
        guard let root = roots[assetID] else {
            throw LocalModelInstallationError.unitNotReady
        }
        let components = try validatedPathComponents(relativePath)
        var descriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw LocalModelInstallationError.unitNotReady }
        var rootInfo = stat()
        guard fstat(descriptor, &rootInfo) == 0,
              (rootInfo.st_mode & S_IFMT) == S_IFDIR,
              rootInfo.st_uid == getuid() else {
            close(descriptor)
            throw LocalModelInstallationError.unsafeFile
        }
        for (index, component) in components.enumerated() {
            let isFinal = index == components.count - 1
            let requiresDirectory = !isFinal || expectedType == S_IFDIR
            let flags = O_RDONLY | O_NOFOLLOW | (requiresDirectory ? O_DIRECTORY : 0)
            let next = openat(descriptor, component, flags)
            close(descriptor)
            guard next >= 0 else { throw LocalModelInstallationError.unsafeFile }
            var componentInfo = stat()
            let componentExpectedType: mode_t = isFinal ? expectedType : S_IFDIR
            guard fstat(next, &componentInfo) == 0,
                  (componentInfo.st_mode & S_IFMT) == componentExpectedType,
                  componentInfo.st_uid == getuid(),
                  componentExpectedType != S_IFREG || componentInfo.st_nlink == 1 else {
                close(next)
                throw LocalModelInstallationError.unsafeFile
            }
            descriptor = next
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == expectedType,
              info.st_uid == getuid(),
              expectedType != S_IFREG || info.st_nlink == 1 else {
            throw LocalModelInstallationError.unsafeFile
        }
        try await operation(descriptor)
    }

    func invalidateAndWait() async {
        await state.invalidateAndWait()
    }
}

private actor LocalModelRuntimeAccessState {
    private var valid = true
    private var activeOperations = 0
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []

    func beginOperation() throws {
        guard valid else { throw LocalModelInstallationError.unitNotReady }
        activeOperations += 1
    }

    func finishOperation() {
        activeOperations = max(0, activeOperations - 1)
        if !valid, activeOperations == 0 {
            drainWaiters.forEach { $0.resume() }
            drainWaiters.removeAll()
        }
    }

    func invalidateAndWait() async {
        valid = false
        guard activeOperations > 0 else { return }
        await withCheckedContinuation { drainWaiters.append($0) }
    }
}
