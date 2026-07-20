import CryptoKit
import Darwin
import Foundation

public actor LocalModelInstallationService {
    public typealias AvailableCapacity = @Sendable (URL) throws -> Int64
    public typealias Clock = @Sendable () -> Date
    public typealias SelfCheckAdapter = @Sendable (String, URL) async throws -> Void
    public typealias TerminatingSelfCheckExecutor = @Sendable (String, URL, Duration) async throws -> Void
    public typealias AuditSink = @Sendable (PrivacyAuditAction, [String: String]) async -> Void
    public typealias SyncRegularFile = @Sendable (URL) throws -> Void
    public typealias RepairCopyDidOpenDescriptors = @Sendable (String) throws -> Void

    private static let supportedUnitIDs = [
        "automatic-speech-recognition",
        "offline-speaker-diarization",
        "streaming-speaker-diarization",
    ]

    private let modelsRoot: URL
    private let stagingRoot: URL
    private let unitsByID: [String: Unit]
    private let session: URLSession
    private let approvedHosts: Set<String>
    private let availableCapacity: AvailableCapacity
    private let now: Clock
    private let selfCheckAdapter: SelfCheckAdapter
    private let terminatingSelfCheckExecutor: TerminatingSelfCheckExecutor?
    private let selfCheckTimeout: Duration
    private let auditSink: AuditSink
    private let regularFileSynchronizer: SyncRegularFile
    private let repairCopyDidOpenDescriptors: RepairCopyDidOpenDescriptors
    private let leaseRegistry = LocalModelLeaseRegistry()
    private var states: [String: LocalModelAssetState]
    private var operations: [String: Operation] = [:]
    private var outstandingReservedBytes: Int64 = 0

    public init(
        manifest: LocalModelManifest,
        modelsRoot: URL,
        sessionConfiguration: URLSessionConfiguration,
        approvedHosts: Set<String>,
        availableCapacity: @escaping AvailableCapacity,
        now: @escaping Clock,
        selfCheck: @escaping SelfCheckAdapter,
        terminatingSelfCheckExecutor: TerminatingSelfCheckExecutor? = nil,
        selfCheckTimeout: Duration = .seconds(30),
        syncRegularFile: @escaping SyncRegularFile = LocalModelInstallationService.defaultSyncRegularFile,
        repairCopyDidOpenDescriptors: @escaping RepairCopyDidOpenDescriptors = { _ in },
        audit: @escaping AuditSink
    ) throws {
        let validated = try LocalModelManifestValidator.validate(manifest)
        let standardizedRoot = modelsRoot.standardizedFileURL
        try FileManager.default.createDirectory(
            at: standardizedRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Self.requirePrivateDirectory(standardizedRoot)
        let stagingRoot = standardizedRoot.appendingPathComponent(".staging", isDirectory: true)
        try FileManager.default.createDirectory(
            at: stagingRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Self.requirePrivateDirectory(stagingRoot)

        var units: [String: Unit] = [:]
        var initialStates: [String: LocalModelAssetState] = [:]
        for id in Self.supportedUnitIDs {
            let assets = validated.assets.filter { $0.feature == id }
            let total = assets.reduce(Int64(0)) { $0 + $1.expectedBytes }
            let status: LocalModelAssetStatus = assets.isEmpty ? .unsupported : .notInstalled
            initialStates[id] = LocalModelAssetState(
                id: id,
                status: status,
                completedBytes: 0,
                totalBytes: total
            )
            if !assets.isEmpty {
                units[id] = Unit(id: id, assets: assets)
            }
        }

        let configuration = sessionConfiguration
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        self.modelsRoot = standardizedRoot
        self.stagingRoot = stagingRoot
        unitsByID = units
        states = initialStates
        session = URLSession(configuration: configuration)
        self.approvedHosts = Set(approvedHosts.map { $0.lowercased() })
        self.availableCapacity = availableCapacity
        self.now = now
        self.selfCheckAdapter = selfCheck
        self.terminatingSelfCheckExecutor = terminatingSelfCheckExecutor
        self.selfCheckTimeout = selfCheckTimeout
        regularFileSynchronizer = syncRegularFile
        self.repairCopyDidOpenDescriptors = repairCopyDidOpenDescriptors
        auditSink = audit
    }

    public func snapshot() async -> [LocalModelAssetState] {
        for id in Self.supportedUnitIDs where operations[id] == nil {
            refreshState(id)
        }
        return Self.supportedUnitIDs.compactMap { states[$0] }
    }

    public func units() -> [LocalModelInstallUnit] {
        Self.supportedUnitIDs.compactMap { unitsByID[$0]?.descriptor }
    }

    public func install(_ id: String) -> AsyncThrowingStream<ModelInstallEvent, Error> {
        streamOperation(id: id, isRepair: false)
    }

    public func cancel(_ id: String) {
        operations[id]?.task?.cancel()
    }

    public func repair(_ id: String) -> AsyncThrowingStream<ModelInstallEvent, Error> {
        streamOperation(id: id, isRepair: true)
    }

    public func prewarm(_ id: String) async throws -> ModelSelfCheck {
        guard unitsByID[id] != nil else { throw LocalModelInstallationError.unknownUnit }
        refreshState(id)
        guard states[id]?.status == .ready else { throw LocalModelInstallationError.unitNotReady }

        guard let terminatingSelfCheckExecutor else {
            await auditSink(.modelPrewarm, ["assetID": id, "code": "executorUnavailable"])
            throw LocalModelInstallationError.selfCheckUnavailable
        }
        let lease = try await acquire([id])
        defer { lease.release() }
        let startedAt = now()
        do {
            try await terminatingSelfCheckExecutor(id, unitRoot(id), selfCheckTimeout)
            let result = ModelSelfCheck(
                assetID: id,
                passed: true,
                duration: max(0, now().timeIntervalSince(startedAt))
            )
            try persistSelfCheck(result)
            await auditSink(.modelPrewarm, ["assetID": id, "code": "passed"])
            return result
        } catch let error as LocalModelInstallationError {
            await auditSink(.modelPrewarm, ["assetID": id, "code": "failed"])
            throw error
        } catch {
            await auditSink(.modelPrewarm, ["assetID": id, "code": "failed"])
            throw LocalModelInstallationError.selfCheckFailed
        }
    }

    public func lastSelfCheck(_ id: String) async throws -> ModelSelfCheck? {
        guard unitsByID[id] != nil else { throw LocalModelInstallationError.unknownUnit }
        let url = selfCheckURL(id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard Self.isPrivateRegularFile(url),
              let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 1_024 else {
            throw LocalModelInstallationError.selfCheckFailed
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        return try JSONDecoder().decode(ModelSelfCheck.self, from: data)
    }

    public func remove(_ id: String) async throws {
        guard unitsByID[id] != nil else { throw LocalModelInstallationError.unknownUnit }
        guard operations[id] == nil else { throw LocalModelInstallationError.operationInProgress }
        guard !leaseRegistry.isActive(id) else { throw LocalModelInstallationError.unitInUse }
        let root = unitRoot(id)
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
            try Self.syncDirectory(modelsRoot)
        }
        let selfCheck = selfCheckURL(id)
        if FileManager.default.fileExists(atPath: selfCheck.path) {
            try FileManager.default.removeItem(at: selfCheck)
            try Self.syncDirectory(selfCheck.deletingLastPathComponent())
        }
        states[id]?.status = .notInstalled
        states[id]?.completedBytes = 0
        await auditSink(.modelRemove, ["assetID": id, "code": "removed"])
    }

    public func acquire(_ ids: Set<String>) async throws -> ModelUsageLease {
        for id in ids.sorted() {
            guard unitsByID[id] != nil else { throw LocalModelInstallationError.unknownUnit }
            guard operations[id] == nil else { throw LocalModelInstallationError.operationInProgress }
            refreshState(id)
            guard states[id]?.status == .ready else { throw LocalModelInstallationError.unitNotReady }
        }
        leaseRegistry.acquire(ids)
        return ModelUsageLease(assetIDs: ids) { [leaseRegistry] in
            leaseRegistry.release(ids)
        }
    }

    public func withRuntimeSession(
        _ ids: Set<String>,
        _ operation: @Sendable (LocalModelRuntimeAccess) async throws -> Void
    ) async throws {
        let lease = try await acquire(ids)
        defer { lease.release() }
        let roots = Dictionary(uniqueKeysWithValues: ids.map { ($0, unitRoot($0)) })
        let access = LocalModelRuntimeAccess(assetIDs: ids, roots: roots)
        do {
            try await operation(access)
            await access.invalidateAndWait()
        } catch {
            await access.invalidateAndWait()
            throw error
        }
    }

    private func streamOperation(id: String, isRepair: Bool) -> AsyncThrowingStream<ModelInstallEvent, Error> {
        guard unitsByID[id] != nil else {
            return AsyncThrowingStream { $0.finish(throwing: LocalModelInstallationError.unknownUnit) }
        }
        if isRepair, leaseRegistry.isActive(id) {
            return AsyncThrowingStream { $0.finish(throwing: LocalModelInstallationError.unitInUse) }
        }
        if !isRepair {
            refreshState(id)
            if states[id]?.status == .ready {
                let totalBytes = states[id]?.totalBytes ?? 0
                return AsyncThrowingStream { continuation in
                    continuation.yield(.progress(
                        completedBytes: totalBytes,
                        totalBytes: totalBytes
                    ))
                    continuation.yield(.status(.ready))
                    continuation.finish()
                }
            }
        }

        let observerID = UUID()
        let pair = AsyncThrowingStream<ModelInstallEvent, Error>.makeStream(
            bufferingPolicy: .bufferingNewest(8)
        )
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.detachObserver(observerID, from: id) }
        }
        if let operation = operations[id] {
            operation.observers[observerID] = pair.continuation
            if let state = states[id] {
                pair.continuation.yield(.status(state.status))
                pair.continuation.yield(.progress(completedBytes: state.completedBytes, totalBytes: state.totalBytes))
            }
            return pair.stream
        }

        let operation = Operation(observers: [observerID: pair.continuation])
        operations[id] = operation
        operation.task = Task { [self] in
            await runOperation(id: id, isRepair: isRepair)
        }
        return pair.stream
    }

    private func detachObserver(_ observerID: UUID, from id: String) {
        operations[id]?.observers.removeValue(forKey: observerID)
    }

    private func runOperation(id: String, isRepair: Bool) async {
        do {
            try await performOperation(id: id, isRepair: isRepair)
            finishOperation(id: id, error: nil)
        } catch is CancellationError {
            states[id]?.status = .notInstalled
            broadcast(.status(.notInstalled), for: id)
            finishOperation(id: id, error: CancellationError())
        } catch {
            states[id]?.status = .repairNeeded
            broadcast(.status(.repairNeeded), for: id)
            finishOperation(id: id, error: error)
        }
    }

    private func performOperation(id: String, isRepair: Bool) async throws {
        guard let unit = unitsByID[id] else { throw LocalModelInstallationError.unknownUnit }
        if isRepair, leaseRegistry.isActive(id) { throw LocalModelInstallationError.unitInUse }
        let finalRoot = unitRoot(id)
        let unitStagingRoot = stagingRoot.appendingPathComponent(id, isDirectory: true)
        let payloadRoot = unitStagingRoot.appendingPathComponent("payload", isDirectory: true)
        if isRepair {
            try Self.validateOwnedDirectoryReadOnly(modelsRoot)
            try Self.validateOwnedDirectoryReadOnly(stagingRoot)
        } else {
            try Self.requirePrivateDirectory(modelsRoot)
            try Self.requirePrivateDirectory(stagingRoot)
        }
        var reservedBytes: Int64?
        if isRepair {
            let replacementHeadroom = Self.existsNoFollow(finalRoot) ? unit.totalBytes : 0
            let conservativeRequirement = unit.totalBytes * 2 + replacementHeadroom
            try reserveDisk(conservativeRequirement)
            reservedBytes = conservativeRequirement
        }
        defer {
            if let reservedBytes { releaseDiskReservation(reservedBytes) }
        }
        if isRepair {
            try Self.requirePrivateDirectory(modelsRoot)
            try Self.requirePrivateDirectory(stagingRoot)
        }
        try recoverPromotionIfNeeded(id: id, unit: unit)
        let stagingRequiresCleanup = try stagingRequiresCleanup(unitStagingRoot, unit: unit)
        var completed: Int64 = 0
        var remaining: Int64 = 0
        for asset in unit.assets {
            if !stagingRequiresCleanup, isValid(asset, at: payloadRoot) {
                completed += asset.expectedBytes
                continue
            }
            let offset = stagingRequiresCleanup ? 0 : resumeOffset(for: asset, in: unitStagingRoot)
            completed += offset
            remaining += asset.expectedBytes - offset
        }

        if reservedBytes == nil {
            let replacementHeadroom = Self.existsNoFollow(finalRoot) ? unit.totalBytes : 0
            let required = remaining + unit.totalBytes + replacementHeadroom
            try reserveDisk(required)
            reservedBytes = required
        }
        if stagingRequiresCleanup {
            try FileManager.default.removeItem(at: unitStagingRoot)
            try Self.syncDirectory(stagingRoot)
        }
        try FileManager.default.createDirectory(
            at: payloadRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Self.requirePrivateDirectory(unitStagingRoot)
        try Self.requirePrivateDirectory(payloadRoot)

        if isRepair {
            for asset in unit.assets where !isValid(asset, at: payloadRoot) {
                do {
                    let access = try SecureRepairFileAccess(
                        modelsRoot: modelsRoot,
                        unitID: id,
                        asset: asset
                    )
                    try repairCopyDidOpenDescriptors(asset.relativeInstallPath)
                    try access.copyVerifiedSourceToStaging()
                    try validateStagingLayout(unitStagingRoot, unit: unit)
                } catch SecureRepairFileAccess.AccessError.sourceUnavailable {
                    continue
                }
            }
            completed = unit.assets.reduce(into: Int64(0)) { total, asset in
                total += isValid(asset, at: payloadRoot)
                    ? asset.expectedBytes
                    : resumeOffset(for: asset, in: unitStagingRoot)
            }
        }

        states[id] = LocalModelAssetState(id: id, status: .downloading, completedBytes: completed, totalBytes: unit.totalBytes)
        broadcast(.status(.downloading), for: id)
        if completed > 0 {
            broadcast(.progress(completedBytes: completed, totalBytes: unit.totalBytes), for: id)
        }
        for asset in unit.assets {
            try Task.checkCancellation()
            let destination = payloadRoot.appendingPathComponent(asset.relativeInstallPath)
            if isValid(asset, at: payloadRoot) { continue }
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try Self.requirePrivateDirectoryChain(
                from: payloadRoot,
                through: destination.deletingLastPathComponent()
            )
            let offset = resumeOffset(for: asset, in: unitStagingRoot)
            completed -= offset
            completed = try await download(
                asset,
                to: destination,
                stagingRoot: unitStagingRoot,
                unitCompleted: completed,
                unitTotal: unit.totalBytes,
                unitID: id
            )
        }

        states[id]?.status = .verifying
        broadcast(.status(.verifying), for: id)
        try LocalModelManifestValidator.validateInstallation(unit.manifest, at: payloadRoot)
        try validateStagingLayout(unitStagingRoot, unit: unit)
        try Self.rejectHardLinks(in: payloadRoot)
        try Self.syncTree(payloadRoot)
        try Self.requireSameVolume(modelsRoot, stagingRoot)
        let synchronizer = regularFileSynchronizer
        let promotion = try LocalModelAtomicPromoter.promote(
            payloadRoot: payloadRoot,
            finalRoot: finalRoot,
            unitStagingRoot: unitStagingRoot,
            recordPhase: { phase in
                try Self.persistPromotionPhase(
                    phase,
                    at: unitStagingRoot,
                    synchronizer: synchronizer
                )
            },
            syncDirectory: Self.syncDirectory
        )

        states[id] = LocalModelAssetState(id: id, status: .ready, completedBytes: unit.totalBytes, totalBytes: unit.totalBytes)
        broadcast(.progress(completedBytes: unit.totalBytes, totalBytes: unit.totalBytes), for: id)
        broadcast(.status(.ready), for: id)
        await auditSink(isRepair ? .modelRepair : .modelInstall, [
            "assetID": id,
            "code": promotion == .committed ? "ready" : "readyMaintenanceNeeded",
            "fileCount": String(unit.assets.count),
        ])
    }

    private func download(
        _ asset: LocalModelAsset,
        to destination: URL,
        stagingRoot: URL,
        unitCompleted: Int64,
        unitTotal: Int64,
        unitID: String
    ) async throws -> Int64 {
        guard LocalModelDownloadURLPolicy.isApprovedInitial(asset.sourceURL) else {
            throw LocalModelInstallationError.redirectRejected
        }
        let token = Self.stagingToken(asset.id)
        let partialURL = stagingRoot.appendingPathComponent("partials/\(token).partial")
        let metadataURL = stagingRoot.appendingPathComponent("metadata/\(token).json")
        try FileManager.default.createDirectory(
            at: partialURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createDirectory(
            at: metadataURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let secureAccess = try SecureStagingFileAccess(
            modelsRoot: modelsRoot,
            unitID: unitID,
            destinationRelativePath: asset.relativeInstallPath
        )
        let existingMetadata = loadResumeMetadata(for: asset, from: metadataURL)
        var offset = resumeOffset(for: asset, in: stagingRoot)
        var request = URLRequest(url: asset.sourceURL)
        request.httpMethod = "GET"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue(nil, forHTTPHeaderField: "Authorization")
        request.setValue(nil, forHTTPHeaderField: "Cookie")
        if offset > 0, let existingMetadata {
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
            request.setValue(existingMetadata.etag ?? existingMetadata.lastModified, forHTTPHeaderField: "If-Range")
        }

        let redirectDelegate = LocalModelRedirectDelegate(
            approvedHosts: approvedHosts,
            expectedInitialURL: asset.sourceURL
        )
        let (bytes, response) = try await session.bytes(for: request, delegate: redirectDelegate)
        try validateStagingLayout(stagingRoot, unit: unitsByID[unitID]!)
        guard !redirectDelegate.wasRejected else { throw LocalModelInstallationError.redirectRejected }
        guard let http = response as? HTTPURLResponse,
              let responseURL = http.url,
              redirectDelegate.isApprovedFinal(responseURL) else {
            throw LocalModelInstallationError.invalidResponse
        }
        if http.statusCode == 416 { throw LocalModelInstallationError.rangeRejected }
        if offset > 0, http.statusCode == 206 {
            guard Self.validContentRange(
                http.value(forHTTPHeaderField: "Content-Range"),
                offset: offset,
                total: asset.expectedBytes
            ),
            http.expectedContentLength == -1 || http.expectedContentLength == asset.expectedBytes - offset,
            existingMetadata?.etag == nil || http.value(forHTTPHeaderField: "ETag") == existingMetadata?.etag,
            existingMetadata?.lastModified == nil || http.value(forHTTPHeaderField: "Last-Modified") == existingMetadata?.lastModified else {
                throw LocalModelInstallationError.rangeRejected
            }
        } else if http.statusCode == 200 {
            offset = 0
            guard http.expectedContentLength == -1 || http.expectedContentLength == asset.expectedBytes else {
                throw LocalModelInstallationError.invalidResponse
            }
        } else {
            throw offset > 0 ? LocalModelInstallationError.rangeRejected : LocalModelInstallationError.invalidResponse
        }

        let handle = try secureAccess.writablePartial(named: partialURL.lastPathComponent)
        defer { try? handle.close() }
        if offset == 0 {
            try handle.truncate(atOffset: 0)
        } else {
            try handle.seekToEnd()
        }
        let responseMetadata = ResumeMetadata(
            originalURL: asset.sourceURL.absoluteString,
            etag: http.value(forHTTPHeaderField: "ETag") ?? existingMetadata?.etag,
            lastModified: http.value(forHTTPHeaderField: "Last-Modified") ?? existingMetadata?.lastModified,
            expectedBytes: asset.expectedBytes,
            sha256: asset.sha256,
            updatedAt: now().timeIntervalSince1970
        )
        try persistResumeMetadata(
            responseMetadata,
            to: metadataURL,
            secureAccess: secureAccess
        )
        var buffer = Data()
        buffer.reserveCapacity(64 * 1_024)
        var prefix = Data()
        var fileBytes = offset
        if offset > 0 {
            prefix = try secureAccess.readPartialPrefix(named: partialURL.lastPathComponent, count: 256)
        }
        do {
            for try await byte in bytes {
                try Task.checkCancellation()
                buffer.append(byte)
                fileBytes += 1
                if prefix.count < 256 { prefix.append(byte) }
                guard fileBytes <= asset.expectedBytes else {
                    throw LocalModelInstallationError.sizeMismatch
                }
                if buffer.count == 64 * 1_024 {
                    try handle.write(contentsOf: buffer)
                    buffer.removeAll(keepingCapacity: true)
                    updateProgress(unitID: unitID, completed: unitCompleted + fileBytes, total: unitTotal)
                }
            }
        } catch is CancellationError {
            if !buffer.isEmpty { try handle.write(contentsOf: buffer) }
            try handle.synchronize()
            let cancelledMetadata = ResumeMetadata(
                originalURL: responseMetadata.originalURL,
                etag: responseMetadata.etag,
                lastModified: responseMetadata.lastModified,
                expectedBytes: responseMetadata.expectedBytes,
                sha256: responseMetadata.sha256,
                updatedAt: now().timeIntervalSince1970
            )
            try persistResumeMetadata(
                cancelledMetadata,
                to: metadataURL,
                secureAccess: secureAccess
            )
            throw CancellationError()
        }
        if !buffer.isEmpty { try handle.write(contentsOf: buffer) }
        try handle.synchronize()
        guard fileBytes == asset.expectedBytes else { throw LocalModelInstallationError.sizeMismatch }
        let prefixText = String(decoding: prefix, as: UTF8.self)
        guard !prefixText.hasPrefix("version https://git-lfs.github.com/spec/v1\n"),
              !prefixText.hasPrefix("version https://git-lfs.github.com/spec/v1\r\n") else {
            throw LocalModelInstallationError.gitLFSPointer
        }
        try validateStagingLayout(stagingRoot, unit: unitsByID[unitID]!)
        try secureAccess.removeDestinationIfPresent(named: destination.lastPathComponent)
        try secureAccess.movePartial(
            named: partialURL.lastPathComponent,
            to: destination.lastPathComponent
        )
        try Self.requirePrivateRegularFile(destination)
        do {
            var validationRoot = destination
            for _ in asset.relativeInstallPath.split(separator: "/") {
                validationRoot.deleteLastPathComponent()
            }
            try LocalModelManifestValidator.validateAssetFile(asset, at: validationRoot)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            try? FileManager.default.removeItem(at: metadataURL)
            if error as? LocalModelManifestValidationError == .digestMismatch {
                throw LocalModelInstallationError.digestMismatch
            }
            if error as? LocalModelManifestValidationError == .gitLFSPointer {
                throw LocalModelInstallationError.gitLFSPointer
            }
            throw error
        }
        try secureAccess.removeMetadataIfPresent(named: metadataURL.lastPathComponent)
        updateProgress(unitID: unitID, completed: unitCompleted + fileBytes, total: unitTotal)
        return unitCompleted + fileBytes
    }

    private func updateProgress(unitID: String, completed: Int64, total: Int64) {
        let bounded = min(max(states[unitID]?.completedBytes ?? 0, completed), total)
        guard bounded != states[unitID]?.completedBytes || bounded == total else { return }
        states[unitID]?.completedBytes = bounded
        broadcast(.progress(completedBytes: bounded, totalBytes: total), for: unitID)
    }

    private func reserveDisk(_ bytes: Int64) throws {
        let available = try availableCapacity(modelsRoot)
        guard available - outstandingReservedBytes >= bytes else {
            throw LocalModelInstallationError.insufficientDisk
        }
        outstandingReservedBytes += bytes
    }

    private func releaseDiskReservation(_ bytes: Int64) {
        outstandingReservedBytes = max(0, outstandingReservedBytes - bytes)
    }

    private func broadcast(_ event: ModelInstallEvent, for id: String) {
        for continuation in operations[id]?.observers.values ?? [:].values {
            continuation.yield(event)
        }
    }

    private func finishOperation(id: String, error: Error?) {
        guard let operation = operations.removeValue(forKey: id) else { return }
        for continuation in operation.observers.values {
            if let error { continuation.finish(throwing: error) } else { continuation.finish() }
        }
    }

    private func refreshState(_ id: String) {
        guard let unit = unitsByID[id] else {
            states[id]?.status = .unsupported
            return
        }
        do {
            try recoverPromotionIfNeeded(id: id, unit: unit)
        } catch {
            states[id] = LocalModelAssetState(
                id: id,
                status: .repairNeeded,
                completedBytes: 0,
                totalBytes: unit.totalBytes
            )
            return
        }
        let root = unitRoot(id)
        guard FileManager.default.fileExists(atPath: root.path) else {
            let staging = stagingRoot.appendingPathComponent(id, isDirectory: true)
            do {
                try cleanStaleOrInvalidStaging(staging, unit: unit)
            } catch {
                states[id] = LocalModelAssetState(
                    id: id,
                    status: .repairNeeded,
                    completedBytes: 0,
                    totalBytes: unit.totalBytes
                )
                return
            }
            let payload = staging.appendingPathComponent("payload", isDirectory: true)
            var stagedBytes: Int64 = 0
            for asset in unit.assets {
                stagedBytes += isValid(asset, at: payload)
                    ? asset.expectedBytes
                    : resumeOffset(for: asset, in: staging)
            }
            states[id] = LocalModelAssetState(
                id: id,
                status: .notInstalled,
                completedBytes: min(stagedBytes, unit.totalBytes),
                totalBytes: unit.totalBytes
            )
            return
        }
        do {
            try LocalModelManifestValidator.validateInstallation(unit.manifest, at: root)
            try Self.rejectHardLinks(in: root)
            states[id] = LocalModelAssetState(id: id, status: .ready, completedBytes: unit.totalBytes, totalBytes: unit.totalBytes)
        } catch {
            states[id] = LocalModelAssetState(id: id, status: .repairNeeded, completedBytes: 0, totalBytes: unit.totalBytes)
        }
    }

    private func unitRoot(_ id: String) -> URL {
        modelsRoot.appendingPathComponent(id, isDirectory: true)
    }

    private static func persistPromotionPhase(
        _ phase: LocalModelAtomicPromoter.Phase,
        at unitStagingRoot: URL,
        synchronizer: SyncRegularFile
    ) throws {
        try Self.requirePrivateDirectory(unitStagingRoot)
        let data = try JSONEncoder().encode(PromotionJournal(phase: phase))
        let url = unitStagingRoot.appendingPathComponent("promotion-state.json")
        try Self.secureAtomicWrite(data, to: url)
        do {
            try synchronizer(url)
        } catch {
            throw LocalModelInstallationError.promotionFailed
        }
        try Self.syncDirectory(unitStagingRoot)
    }

    private func recoverPromotionIfNeeded(id: String, unit: Unit) throws {
        let unitStagingRoot = stagingRoot.appendingPathComponent(id, isDirectory: true)
        guard Self.existsNoFollow(unitStagingRoot) else { return }
        try Self.requirePrivateDirectory(unitStagingRoot)
        let finalRoot = unitRoot(id)
        let previous = unitStagingRoot.appendingPathComponent("previous", isDirectory: true)
        let journalURL = unitStagingRoot.appendingPathComponent("promotion-state.json")
        let phase: LocalModelAtomicPromoter.Phase? = {
            guard Self.existsNoFollow(journalURL),
                  let data = try? Self.secureRead(journalURL, maximumBytes: 256),
                  let journal = try? JSONDecoder().decode(PromotionJournal.self, from: data) else {
                return nil
            }
            return journal.phase
        }()

        let previousExists = Self.existsNoFollow(previous)
        let finalIsValid = isValidInstallation(unit, at: finalRoot)
        if previousExists {
            if finalIsValid {
                do {
                    try FileManager.default.removeItem(at: unitStagingRoot)
                    try Self.syncDirectory(modelsRoot)
                } catch {
                    // The committed root is valid and durable. Keep the marker
                    // for the next bounded cleanup retry without downgrading it.
                }
                return
            }
            if Self.existsNoFollow(finalRoot) {
                try FileManager.default.removeItem(at: finalRoot)
            }
            guard isValidInstallation(unit, at: previous) else {
                throw LocalModelInstallationError.promotionRecoveryRequired
            }
            do {
                try FileManager.default.moveItem(at: previous, to: finalRoot)
                try Self.syncDirectory(modelsRoot)
                try FileManager.default.removeItem(at: unitStagingRoot)
                try Self.syncDirectory(stagingRoot)
            } catch {
                throw LocalModelInstallationError.promotionRecoveryRequired
            }
            return
        }

        switch phase {
        case .committed, .committedNeedsMaintenance:
            guard finalIsValid else {
                throw LocalModelInstallationError.promotionRecoveryRequired
            }
            do {
                try FileManager.default.removeItem(at: unitStagingRoot)
                try Self.syncDirectory(stagingRoot)
            } catch {
                // Ready with persistent maintenance state; retry next snapshot.
            }
        case .previousMoved:
            throw LocalModelInstallationError.promotionRecoveryRequired
        case .prepared:
            try FileManager.default.removeItem(at: journalURL)
            try Self.syncDirectory(unitStagingRoot)
        case .none:
            break
        }
    }

    private func isValidInstallation(_ unit: Unit, at root: URL) -> Bool {
        guard Self.existsNoFollow(root) else { return false }
        do {
            try LocalModelManifestValidator.validateInstallation(unit.manifest, at: root)
            try Self.rejectHardLinks(in: root)
            return true
        } catch {
            return false
        }
    }

    private func isValid(_ asset: LocalModelAsset, at root: URL) -> Bool {
        (try? LocalModelManifestValidator.validateAssetFile(asset, at: root)) != nil
    }

    private func stagingRequiresCleanup(_ root: URL, unit: Unit) throws -> Bool {
        guard Self.existsNoFollow(root) else { return false }
        try validateStagingLayout(root, unit: unit)
        let metadataRoot = root.appendingPathComponent("metadata", isDirectory: true)
        if Self.existsNoFollow(metadataRoot), let files = try? FileManager.default.contentsOfDirectory(
            at: metadataRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ) {
            for file in files {
                guard let data = try? Self.secureRead(file, maximumBytes: 4_096),
                      data.count <= 4_096,
                      let metadata = try? JSONDecoder().decode(ResumeMetadata.self, from: data),
                      now().timeIntervalSince1970 - metadata.updatedAt <= 7 * 86_400 else {
                    return true
                }
            }
        }
        return false
    }

    private func cleanStaleOrInvalidStaging(_ root: URL, unit: Unit) throws {
        guard try stagingRequiresCleanup(root, unit: unit) else { return }
        try FileManager.default.removeItem(at: root)
        try Self.syncDirectory(stagingRoot)
    }

    private func validateStagingLayout(_ root: URL, unit: Unit) throws {
        try Self.requirePrivateDirectory(root)
        let allowedTopLevel = Set(["metadata", "partials", "payload", "previous", "promotion-state.json"])
        for item in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            guard allowedTopLevel.contains(item.lastPathComponent) else {
                throw LocalModelInstallationError.unsafeFile
            }
        }
        let journalURL = root.appendingPathComponent("promotion-state.json")
        if Self.existsNoFollow(journalURL) {
            try Self.requirePrivateRegularFile(journalURL)
        }
        let previousRoot = root.appendingPathComponent("previous", isDirectory: true)
        if Self.existsNoFollow(previousRoot) {
            try Self.requirePrivateDirectory(previousRoot)
            try Self.rejectHardLinks(in: previousRoot)
        }
        let allowedMetadata = Set(unit.assets.map { "\(Self.stagingToken($0.id)).json" })
        let metadataRoot = root.appendingPathComponent("metadata", isDirectory: true)
        if Self.existsNoFollow(metadataRoot) {
            try Self.requirePrivateDirectory(metadataRoot)
            for file in try FileManager.default.contentsOfDirectory(at: metadataRoot, includingPropertiesForKeys: nil) {
                guard allowedMetadata.contains(file.lastPathComponent) else {
                    throw LocalModelInstallationError.unsafeFile
                }
                try Self.requirePrivateRegularFile(file)
            }
        }
        let partialRoot = root.appendingPathComponent("partials", isDirectory: true)
        if Self.existsNoFollow(partialRoot) {
            try Self.requirePrivateDirectory(partialRoot)
            let partials = try FileManager.default.contentsOfDirectory(at: partialRoot, includingPropertiesForKeys: nil)
            let allowedNames = Set(unit.assets.map { "\(Self.stagingToken($0.id)).partial" })
            for partial in partials {
                guard allowedNames.contains(partial.lastPathComponent),
                      Self.isPrivateRegularFile(partial) else {
                    throw LocalModelInstallationError.unsafeFile
                }
            }
        }

        let allowedPayloadPaths = Set(unit.assets.map(\.relativeInstallPath))
        let allowedPayloadDirectories = Set(allowedPayloadPaths.flatMap { path -> [String] in
            let components = path.split(separator: "/").dropLast()
            return components.indices.map { index in
                components.prefix(index + 1).joined(separator: "/")
            }
        })
        let payloadRoot = root.appendingPathComponent("payload", isDirectory: true)
        if Self.existsNoFollow(payloadRoot) {
            try Self.requirePrivateDirectory(payloadRoot)
        }
        if Self.existsNoFollow(payloadRoot), let enumerator = FileManager.default.enumerator(
            at: payloadRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
        ) {
            let base = payloadRoot.standardizedFileURL.path + "/"
            for case let item as URL in enumerator {
                let path = item.standardizedFileURL.path
                guard path.hasPrefix(base) else { throw LocalModelInstallationError.unsafeFile }
                let relative = String(path.dropFirst(base.count))
                var info = stat()
                guard lstat(item.path, &info) == 0, info.st_uid == getuid() else {
                    throw LocalModelInstallationError.unsafeFile
                }
                switch info.st_mode & S_IFMT {
                case S_IFDIR:
                    guard allowedPayloadDirectories.contains(relative) else {
                        throw LocalModelInstallationError.unsafeFile
                    }
                    try Self.requirePrivateDirectory(item)
                case S_IFREG:
                    guard allowedPayloadPaths.contains(relative) else {
                        throw LocalModelInstallationError.unsafeFile
                    }
                    try Self.requirePrivateRegularFile(item)
                default:
                    throw LocalModelInstallationError.unsafeFile
                }
            }
        }
    }

    private func resumeOffset(for asset: LocalModelAsset, in root: URL) -> Int64 {
        let token = Self.stagingToken(asset.id)
        let metadataURL = root.appendingPathComponent("metadata/\(token).json")
        let partialURL = root.appendingPathComponent("partials/\(token).partial")
        guard loadResumeMetadata(for: asset, from: metadataURL) != nil,
              let values = try? partialURL.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
              ),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = values.fileSize,
              size > 0,
              Int64(size) < asset.expectedBytes else {
            return 0
        }
        var info = stat()
        guard lstat(partialURL.path, &info) == 0, info.st_nlink == 1 else { return 0 }
        return Int64(size)
    }

    private func loadResumeMetadata(for asset: LocalModelAsset, from url: URL) -> ResumeMetadata? {
        guard let data = try? Self.secureRead(url, maximumBytes: 4_096),
              let metadata = try? JSONDecoder().decode(ResumeMetadata.self, from: data),
              metadata.originalURL == asset.sourceURL.absoluteString,
              metadata.expectedBytes == asset.expectedBytes,
              metadata.sha256 == asset.sha256,
              metadata.etag?.isEmpty == false || metadata.lastModified?.isEmpty == false else {
            return nil
        }
        return metadata
    }

    private func persistResumeMetadata(
        _ metadata: ResumeMetadata,
        to url: URL,
        secureAccess: SecureStagingFileAccess
    ) throws {
        let data = try JSONEncoder().encode(metadata)
        guard data.count <= 4_096 else { throw LocalModelInstallationError.unsafeFile }
        try secureAccess.atomicWriteMetadata(data, named: url.lastPathComponent)
        do {
            try regularFileSynchronizer(url)
        } catch {
            throw LocalModelInstallationError.promotionFailed
        }
        try secureAccess.syncMetadataDirectory()
    }

    private func persistSelfCheck(_ result: ModelSelfCheck) throws {
        let url = selfCheckURL(result.assetID)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let data = try JSONEncoder().encode(result)
        guard data.count <= 1_024 else { throw LocalModelInstallationError.selfCheckFailed }
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try Self.syncDirectory(url.deletingLastPathComponent())
    }

    private func selfCheckURL(_ id: String) -> URL {
        modelsRoot.appendingPathComponent(".self-checks/\(id).json")
    }

    private static func validContentRange(_ value: String?, offset: Int64, total: Int64) -> Bool {
        guard let value else { return false }
        return value == "bytes \(offset)-\(total - 1)/\(total)"
    }

    private static func stagingToken(_ rawID: String) -> String {
        SHA256.hash(data: Data(rawID.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func isPrivateRegularFile(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
            && (info.st_mode & S_IFMT) == S_IFREG
            && info.st_uid == getuid()
            && info.st_nlink == 1
            && (info.st_mode & 0o777) == 0o600
    }

    private static func requirePrivateRegularFile(_ url: URL) throws {
        guard isPrivateRegularFile(url) else {
            throw LocalModelInstallationError.unsafeFile
        }
    }

    private static func existsNoFollow(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    private static func requirePrivateDirectoryChain(from root: URL, through leaf: URL) throws {
        let base = root.standardizedFileURL.path
        let target = leaf.standardizedFileURL.path
        guard target == base || target.hasPrefix(base + "/") else {
            throw LocalModelInstallationError.unsafeFile
        }
        try requirePrivateDirectory(root)
        guard target != base else { return }
        var current = root
        for component in target.dropFirst(base.count + 1).split(separator: "/") {
            current.appendPathComponent(String(component), isDirectory: true)
            try requirePrivateDirectory(current)
        }
    }

    private static func secureRead(_ url: URL, maximumBytes: Int) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw LocalModelInstallationError.unsafeFile }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(),
              info.st_nlink == 1,
              (info.st_mode & 0o777) == 0o600,
              info.st_size >= 0,
              info.st_size <= maximumBytes else {
            throw LocalModelInstallationError.unsafeFile
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        return try handle.readToEnd() ?? Data()
    }

    private static func secureAtomicWrite(_ data: Data, to url: URL) throws {
        let parent = url.deletingLastPathComponent()
        try requirePrivateDirectory(parent)
        let parentDescriptor = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard parentDescriptor >= 0 else { throw LocalModelInstallationError.unsafeFile }
        defer { close(parentDescriptor) }
        let temporaryName = ".\(url.lastPathComponent).\(UUID().uuidString).tmp"
        let descriptor = openat(parentDescriptor, temporaryName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw LocalModelInstallationError.unsafeFile }
        var shouldUnlink = true
        defer {
            close(descriptor)
            if shouldUnlink { unlinkat(parentDescriptor, temporaryName, 0) }
        }
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let written = Darwin.write(descriptor, base.advanced(by: offset), rawBuffer.count - offset)
                guard written > 0 else { throw LocalModelInstallationError.promotionFailed }
                offset += written
            }
        }
        guard fsync(descriptor) == 0,
              renameat(parentDescriptor, temporaryName, parentDescriptor, url.lastPathComponent) == 0 else {
            throw LocalModelInstallationError.promotionFailed
        }
        shouldUnlink = false
        try requirePrivateRegularFile(url)
    }

    /// Validate every writable directory by `lstat`, never by a symlink-following
    /// URL resource query. Reapply restrictive permissions after verification so
    /// inherited umasks cannot widen the local-model staging surface.
    private static func requirePrivateDirectory(_ directory: URL) throws {
        try validateOwnedDirectoryReadOnly(directory)
        guard chmod(directory.path, 0o700) == 0 else {
            throw LocalModelInstallationError.unsafeFile
        }
        var info = stat()
        guard lstat(directory.path, &info) == 0,
              (info.st_mode & 0o777) == 0o700 else {
            throw LocalModelInstallationError.unsafeFile
        }
    }

    private static func validateOwnedDirectoryReadOnly(_ directory: URL) throws {
        var info = stat()
        guard lstat(directory.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid() else {
            throw LocalModelInstallationError.unsafeFile
        }
    }

    private static func requireSameVolume(_ first: URL, _ second: URL) throws {
        let firstVolume = try first.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
        let secondVolume = try second.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
        guard let firstVolume, let secondVolume,
              String(describing: firstVolume) == String(describing: secondVolume) else {
            throw LocalModelInstallationError.crossVolumeStaging
        }
    }

    private static func rejectHardLinks(in root: URL) throws {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
            throw LocalModelInstallationError.unsafeFile
        }
        for case let file as URL in enumerator {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true else { throw LocalModelInstallationError.unsafeFile }
            var info = stat()
            guard lstat(file.path, &info) == 0, info.st_nlink == 1 else {
                throw LocalModelInstallationError.unsafeFile
            }
        }
    }

    private static func syncTree(_ root: URL) throws {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else {
            throw LocalModelInstallationError.unsafeFile
        }
        var directories = [root]
        var regularFiles: [URL] = []
        for case let item as URL in enumerator {
            let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw LocalModelInstallationError.unsafeFile }
            if values.isDirectory == true {
                directories.append(item)
            } else if values.isRegularFile == true {
                regularFiles.append(item)
            } else {
                throw LocalModelInstallationError.unsafeFile
            }
        }
        for file in regularFiles { try defaultSyncRegularFile(file) }
        for directory in directories.reversed() { try syncDirectory(directory) }
    }

    public static func defaultSyncRegularFile(_ file: URL) throws {
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw LocalModelInstallationError.promotionFailed }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1,
              fsync(descriptor) == 0 else {
            throw LocalModelInstallationError.promotionFailed
        }
    }

    private static func syncDirectory(_ directory: URL) throws {
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY)
        guard descriptor >= 0 else { throw LocalModelInstallationError.promotionFailed }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw LocalModelInstallationError.promotionFailed }
    }
}

extension LocalModelInstallationService: LocalModelReadinessProviding {}

private extension LocalModelInstallationService {
    struct ResumeMetadata: Codable, Sendable {
        let originalURL: String
        let etag: String?
        let lastModified: String?
        let expectedBytes: Int64
        let sha256: String
        let updatedAt: TimeInterval
    }

    struct PromotionJournal: Codable, Sendable {
        let phase: LocalModelAtomicPromoter.Phase
    }

    struct Unit: Sendable {
        let id: String
        let assets: [LocalModelAsset]
        let manifest: LocalModelManifest
        let totalBytes: Int64
        let descriptor: LocalModelInstallUnit

        init(id: String, assets: [LocalModelAsset]) {
            self.id = id
            self.assets = assets
            manifest = LocalModelManifest(schemaVersion: LocalModelManifestValidator.supportedSchemaVersion, assets: assets)
            totalBytes = assets.reduce(0) { $0 + $1.expectedBytes }
            let first = assets[0]
            let source = first.sourceURL.pathComponents.dropFirst().prefix(2).joined(separator: "/")
            let digestInput = Data(assets.map(\.sha256).joined(separator: "\n").utf8)
            let aggregate = SHA256.hash(data: digestInput).map { String(format: "%02x", $0) }.joined()
            let model: String
            switch id {
            case "automatic-speech-recognition": model = "Parakeet TDT 0.6B v3"
            case "streaming-speaker-diarization": model = "LS-EEND 100 ms"
            default: model = "Offline Speaker Diarization"
            }
            descriptor = LocalModelInstallUnit(
                id: id,
                provider: "FluidAudio",
                model: model,
                version: first.version,
                source: source,
                licenseName: first.licenseName,
                licenseURL: first.licenseURL,
                expectedBytes: totalBytes,
                aggregateSHA256: aggregate,
                relativeLocation: "MeetingVault/Models/\(id)",
                fileCount: assets.count
            )
        }
    }

    final class Operation: @unchecked Sendable {
        var task: Task<Void, Never>?
        var observers: [UUID: AsyncThrowingStream<ModelInstallEvent, Error>.Continuation]

        init(observers: [UUID: AsyncThrowingStream<ModelInstallEvent, Error>.Continuation]) {
            self.observers = observers
        }
    }
}

private final class LocalModelLeaseRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    func acquire(_ ids: Set<String>) {
        lock.withLock {
            for id in ids { counts[id, default: 0] += 1 }
        }
    }

    func release(_ ids: Set<String>) {
        lock.withLock {
            for id in ids {
                let remaining = max(0, counts[id, default: 0] - 1)
                if remaining == 0 { counts.removeValue(forKey: id) } else { counts[id] = remaining }
            }
        }
    }

    func isActive(_ id: String) -> Bool {
        lock.withLock { counts[id, default: 0] > 0 }
    }
}

enum LocalModelDownloadURLPolicy {
    static func isApprovedInitial(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return components.scheme == "https"
            && components.host?.lowercased() == "huggingface.co"
            && components.user == nil
            && components.password == nil
            && components.query == nil
            && components.fragment == nil
    }

    static func sanitizedRedirect(
        _ request: URLRequest,
        from original: URL,
        approvedHosts: Set<String>
    ) -> URLRequest? {
        guard let url = request.url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "https",
              let host = components.host?.lowercased(),
              Set(approvedHosts.map { $0.lowercased() }).contains(host),
              components.user == nil,
              components.password == nil,
              components.fragment == nil else { return nil }
        if host == "huggingface.co" {
            guard url.path == original.path, components.query == nil else { return nil }
        } else if let queryItems = components.queryItems {
            let forbidden = Set(["token", "access_token", "authorization", "api_key", "key"])
            guard !queryItems.contains(where: { forbidden.contains($0.name.lowercased()) }) else { return nil }
        }
        var sanitized = request
        sanitized.setValue(nil, forHTTPHeaderField: "Authorization")
        sanitized.setValue(nil, forHTTPHeaderField: "Cookie")
        return sanitized
    }

    static func isApprovedFinal(_ url: URL, from original: URL, approvedHosts: Set<String>) -> Bool {
        sanitizedRedirect(URLRequest(url: url), from: original, approvedHosts: approvedHosts) != nil
    }
}

enum LocalModelAtomicPromoter {
    enum Phase: String, Codable, Equatable, Sendable {
        case prepared
        case previousMoved
        case committed
        case committedNeedsMaintenance
    }

    enum Outcome: Equatable, Sendable {
        case committed
        case committedNeedsMaintenance
    }
    typealias Move = @Sendable (URL, URL) throws -> Void
    typealias Sync = @Sendable (URL) throws -> Void

    static func promote(
        payloadRoot: URL,
        finalRoot: URL,
        unitStagingRoot: URL,
        movePayload: Move = { try FileManager.default.moveItem(at: $0, to: $1) },
        moveItem: Move = { try FileManager.default.moveItem(at: $0, to: $1) },
        removeItem: @Sendable (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) },
        recordPhase: @Sendable (Phase) throws -> Void = { _ in },
        syncDirectory: Sync
    ) throws -> Outcome {
        let backup = unitStagingRoot.appendingPathComponent("previous", isDirectory: true)
        let hadPrevious = FileManager.default.fileExists(atPath: finalRoot.path)
        if FileManager.default.fileExists(atPath: backup.path) {
            throw LocalModelInstallationError.promotionFailed
        }
        try recordPhase(.prepared)
        if hadPrevious {
            do {
                try moveItem(finalRoot, backup)
                try syncDirectory(finalRoot.deletingLastPathComponent())
                try recordPhase(.previousMoved)
            } catch {
                var rollbackFailed = false
                if !FileManager.default.fileExists(atPath: finalRoot.path),
                   FileManager.default.fileExists(atPath: backup.path) {
                    do {
                        try moveItem(backup, finalRoot)
                        try syncDirectory(finalRoot.deletingLastPathComponent())
                    } catch {
                        rollbackFailed = true
                    }
                }
                throw rollbackFailed
                    ? LocalModelInstallationError.promotionRecoveryRequired
                    : LocalModelInstallationError.promotionFailed
            }
        }
        do {
            try movePayload(payloadRoot, finalRoot)
            try syncDirectory(finalRoot.deletingLastPathComponent())
            try recordPhase(.committed)
        } catch {
            do {
                if FileManager.default.fileExists(atPath: finalRoot.path) {
                    try removeItem(finalRoot)
                }
                if hadPrevious {
                    try moveItem(backup, finalRoot)
                    try syncDirectory(finalRoot.deletingLastPathComponent())
                }
            } catch {
                throw LocalModelInstallationError.promotionRecoveryRequired
            }
            throw LocalModelInstallationError.promotionFailed
        }
        do {
            try recordPhase(.committedNeedsMaintenance)
            if hadPrevious { try removeItem(backup) }
            try removeItem(unitStagingRoot)
            try syncDirectory(finalRoot.deletingLastPathComponent())
        } catch {
            // The promoted tree is already durable. Preserve it and surface a
            // retryable maintenance state instead of lying that promotion failed.
            return .committedNeedsMaintenance
        }
        return .committed
    }
}

private final class SecureRepairFileAccess {
    enum AccessError: Error {
        case sourceUnavailable
    }

    private let source: Int32
    private let destinationParent: Int32
    private let destinationName: String
    private let asset: LocalModelAsset

    init(modelsRoot: URL, unitID: String, asset: LocalModelAsset) throws {
        let components = asset.relativeInstallPath
            .split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        guard !components.isEmpty, components.allSatisfy(Self.safeComponent) else {
            throw LocalModelInstallationError.unsafeFile
        }

        var opened: [Int32] = []
        do {
            let models = try Self.openDirectory(path: modelsRoot.path)
            opened.append(models)

            let source: Int32
            do {
                var sourceParent = try Self.openDirectory(named: unitID, relativeTo: models)
                opened.append(sourceParent)
                for component in components.dropLast() {
                    let next = try Self.openDirectory(named: component, relativeTo: sourceParent)
                    opened.append(next)
                    sourceParent = next
                }
                source = openat(sourceParent, components.last!, O_RDONLY | O_NOFOLLOW)
                guard source >= 0, Self.descriptor(source, matches: asset) else {
                    if source >= 0 { close(source) }
                    throw AccessError.sourceUnavailable
                }
                opened.append(source)
            } catch {
                throw AccessError.sourceUnavailable
            }

            let staging = try Self.openDirectory(named: ".staging", relativeTo: models)
            opened.append(staging)
            let unit = try Self.openDirectory(named: unitID, relativeTo: staging)
            opened.append(unit)
            var destination = try Self.openDirectory(named: "payload", relativeTo: unit)
            opened.append(destination)
            for component in components.dropLast() {
                let next = try Self.openOrCreateDirectory(named: component, relativeTo: destination)
                opened.append(next)
                destination = next
            }

            self.source = source
            destinationParent = destination
            destinationName = components.last!
            self.asset = asset
            let retained = Set([source, destination])
            for descriptor in opened where !retained.contains(descriptor) { close(descriptor) }
        } catch {
            Set(opened).forEach { close($0) }
            throw error
        }
    }

    deinit {
        Set([source, destinationParent]).forEach { close($0) }
    }

    func copyVerifiedSourceToStaging() throws {
        let temporary = ".repair-\(UUID().uuidString)"
        let destination = openat(
            destinationParent,
            temporary,
            O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW,
            0o600
        )
        guard destination >= 0 else { throw LocalModelInstallationError.unsafeFile }
        var unlinkTemporary = true
        defer {
            close(destination)
            if unlinkTemporary { unlinkat(destinationParent, temporary, 0) }
        }

        try Self.copyBytes(from: source, to: destination)
        guard fchmod(destination, 0o600) == 0,
              fsync(destination) == 0,
              Self.descriptor(destination, matches: asset, requiresPrivateMode: true) else {
            throw LocalModelInstallationError.unsafeFile
        }
        if unlinkat(destinationParent, destinationName, 0) != 0, errno != ENOENT {
            throw LocalModelInstallationError.unsafeFile
        }
        guard renameat(destinationParent, temporary, destinationParent, destinationName) == 0,
              fsync(destinationParent) == 0 else {
            throw LocalModelInstallationError.unsafeFile
        }
        unlinkTemporary = false
    }

    private static func copyBytes(from source: Int32, to destination: Int32) throws {
        guard lseek(source, 0, SEEK_SET) >= 0,
              ftruncate(destination, 0) == 0,
              lseek(destination, 0, SEEK_SET) >= 0 else {
            throw LocalModelInstallationError.unsafeFile
        }
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while true {
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(source, rawBuffer.baseAddress, rawBuffer.count)
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw LocalModelInstallationError.unsafeFile }
            if count == 0 { return }
            try buffer.withUnsafeBytes { rawBuffer in
                guard let base = rawBuffer.baseAddress else { return }
                var offset = 0
                while offset < count {
                    let written = Darwin.write(
                        destination,
                        base.advanced(by: offset),
                        count - offset
                    )
                    if written < 0, errno == EINTR { continue }
                    guard written > 0 else { throw LocalModelInstallationError.unsafeFile }
                    offset += written
                }
            }
        }
    }

    private static func descriptor(
        _ descriptor: Int32,
        matches asset: LocalModelAsset,
        requiresPrivateMode: Bool = false
    ) -> Bool {
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(),
              info.st_nlink == 1,
              (!requiresPrivateMode || (info.st_mode & 0o777) == 0o600),
              info.st_size == asset.expectedBytes,
              lseek(descriptor, 0, SEEK_SET) >= 0 else {
            return false
        }

        var hasher = SHA256()
        var prefix = Data()
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while true {
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(descriptor, rawBuffer.baseAddress, rawBuffer.count)
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { return false }
            if count == 0 { break }
            let chunk = Data(buffer.prefix(count))
            if prefix.count < 256 { prefix.append(chunk.prefix(256 - prefix.count)) }
            hasher.update(data: chunk)
        }
        let prefixText = String(decoding: prefix, as: UTF8.self)
        guard !prefixText.hasPrefix("version https://git-lfs.github.com/spec/v1\n"),
              !prefixText.hasPrefix("version https://git-lfs.github.com/spec/v1\r\n") else {
            return false
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return digest == asset.sha256
    }

    private static func openDirectory(path: String) throws -> Int32 {
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        try validateDirectory(descriptor)
        return descriptor
    }

    private static func openDirectory(named name: String, relativeTo parent: Int32) throws -> Int32 {
        guard safeComponent(name) else { throw LocalModelInstallationError.unsafeFile }
        let descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        try validateDirectory(descriptor)
        return descriptor
    }

    private static func openOrCreateDirectory(named name: String, relativeTo parent: Int32) throws -> Int32 {
        guard safeComponent(name) else { throw LocalModelInstallationError.unsafeFile }
        if mkdirat(parent, name, 0o700) != 0, errno != EEXIST {
            throw LocalModelInstallationError.unsafeFile
        }
        return try openDirectory(named: name, relativeTo: parent)
    }

    private static func validateDirectory(_ descriptor: Int32) throws {
        guard descriptor >= 0 else { throw LocalModelInstallationError.unsafeFile }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid(),
              fchmod(descriptor, 0o700) == 0 else {
            close(descriptor)
            throw LocalModelInstallationError.unsafeFile
        }
    }

    private static func safeComponent(_ component: String) -> Bool {
        !component.isEmpty && component != "." && component != ".."
            && !component.contains("/") && !component.contains("\0")
    }
}

private final class SecureStagingFileAccess: @unchecked Sendable {
    private let unit: Int32
    private let partials: Int32
    private let metadata: Int32
    private let destinationParent: Int32

    init(modelsRoot: URL, unitID: String, destinationRelativePath: String) throws {
        var opened: [Int32] = []
        do {
            let models = try Self.openDirectory(path: modelsRoot.path)
            opened.append(models)
            let staging = try Self.openDirectory(named: ".staging", relativeTo: models)
            opened.append(staging)
            let unit = try Self.openDirectory(named: unitID, relativeTo: staging)
            opened.append(unit)
            let partials = try Self.openDirectory(named: "partials", relativeTo: unit)
            opened.append(partials)
            let metadata = try Self.openDirectory(named: "metadata", relativeTo: unit)
            opened.append(metadata)
            var destination = try Self.openDirectory(named: "payload", relativeTo: unit)
            opened.append(destination)
            let components = destinationRelativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard !components.isEmpty,
                  components.allSatisfy(Self.safeComponent) else {
                throw LocalModelInstallationError.unsafeFile
            }
            for component in components.dropLast() {
                let next = try Self.openDirectory(named: component, relativeTo: destination)
                opened.append(next)
                destination = next
            }
            self.unit = unit
            self.partials = partials
            self.metadata = metadata
            destinationParent = destination
            let retained = Set([unit, partials, metadata, destination])
            for descriptor in opened where !retained.contains(descriptor) { close(descriptor) }
        } catch {
            opened.forEach { close($0) }
            throw error
        }
    }

    deinit {
        Set([unit, partials, metadata, destinationParent]).forEach { close($0) }
    }

    func writablePartial(named name: String) throws -> FileHandle {
        guard Self.safeComponent(name) else { throw LocalModelInstallationError.unsafeFile }
        let descriptor = openat(partials, name, O_WRONLY | O_CREAT | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw LocalModelInstallationError.unsafeFile }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(),
              info.st_nlink == 1,
              fchmod(descriptor, 0o600) == 0 else {
            close(descriptor)
            throw LocalModelInstallationError.unsafeFile
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    func readPartialPrefix(named name: String, count: Int) throws -> Data {
        guard Self.safeComponent(name) else { throw LocalModelInstallationError.unsafeFile }
        let descriptor = openat(partials, name, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw LocalModelInstallationError.unsafeFile }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(),
              info.st_nlink == 1 else {
            throw LocalModelInstallationError.unsafeFile
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        return try handle.read(upToCount: count) ?? Data()
    }

    func atomicWriteMetadata(_ data: Data, named name: String) throws {
        try Self.atomicWrite(data, named: name, relativeTo: metadata)
    }

    func syncMetadataDirectory() throws {
        guard fsync(metadata) == 0 else { throw LocalModelInstallationError.promotionFailed }
    }

    func removeMetadataIfPresent(named name: String) throws {
        try Self.unlinkIfPresent(name, relativeTo: metadata)
        guard fsync(metadata) == 0 else { throw LocalModelInstallationError.promotionFailed }
    }

    func removeDestinationIfPresent(named name: String) throws {
        try Self.unlinkIfPresent(name, relativeTo: destinationParent)
    }

    func movePartial(named source: String, to destination: String) throws {
        guard Self.safeComponent(source), Self.safeComponent(destination),
              renameat(partials, source, destinationParent, destination) == 0,
              fsync(destinationParent) == 0,
              fsync(partials) == 0 else {
            throw LocalModelInstallationError.unsafeFile
        }
    }

    private static func openDirectory(path: String) throws -> Int32 {
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        try validateDirectory(descriptor)
        return descriptor
    }

    private static func openDirectory(named name: String, relativeTo parent: Int32) throws -> Int32 {
        guard safeComponent(name) else { throw LocalModelInstallationError.unsafeFile }
        let descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        try validateDirectory(descriptor)
        return descriptor
    }

    private static func validateDirectory(_ descriptor: Int32) throws {
        guard descriptor >= 0 else { throw LocalModelInstallationError.unsafeFile }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid(),
              fchmod(descriptor, 0o700) == 0 else {
            close(descriptor)
            throw LocalModelInstallationError.unsafeFile
        }
    }

    private static func atomicWrite(_ data: Data, named name: String, relativeTo parent: Int32) throws {
        guard safeComponent(name) else { throw LocalModelInstallationError.unsafeFile }
        let temporary = ".\(name).\(UUID().uuidString).tmp"
        let descriptor = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw LocalModelInstallationError.unsafeFile }
        var unlinkTemporary = true
        defer {
            close(descriptor)
            if unlinkTemporary { unlinkat(parent, temporary, 0) }
        }
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(descriptor, base.advanced(by: offset), buffer.count - offset)
                guard written > 0 else { throw LocalModelInstallationError.promotionFailed }
                offset += written
            }
        }
        guard fsync(descriptor) == 0,
              renameat(parent, temporary, parent, name) == 0,
              fsync(parent) == 0 else {
            throw LocalModelInstallationError.promotionFailed
        }
        unlinkTemporary = false
    }

    private static func unlinkIfPresent(_ name: String, relativeTo parent: Int32) throws {
        guard safeComponent(name) else { throw LocalModelInstallationError.unsafeFile }
        if unlinkat(parent, name, 0) != 0, errno != ENOENT {
            throw LocalModelInstallationError.unsafeFile
        }
    }

    private static func safeComponent(_ component: String) -> Bool {
        !component.isEmpty && component != "." && component != ".."
            && !component.contains("/") && !component.contains("\0")
    }
}

private final class LocalModelRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let approvedHosts: Set<String>
    private let expectedInitialURL: URL
    private var rejected = false

    init(approvedHosts: Set<String>, expectedInitialURL: URL) {
        self.approvedHosts = Set(approvedHosts.map { $0.lowercased() })
        self.expectedInitialURL = expectedInitialURL
    }

    var wasRejected: Bool { lock.withLock { rejected } }

    func isApprovedFinal(_ url: URL) -> Bool {
        LocalModelDownloadURLPolicy.isApprovedFinal(
            url,
            from: expectedInitialURL,
            approvedHosts: approvedHosts
        )
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let sanitized = LocalModelDownloadURLPolicy.sanitizedRedirect(
            request,
            from: expectedInitialURL,
            approvedHosts: approvedHosts
        ) else {
            lock.withLock { rejected = true }
            completionHandler(nil)
            return
        }
        completionHandler(sanitized)
    }
}
