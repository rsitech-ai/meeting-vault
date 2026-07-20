import CryptoKit
import Foundation
import XCTest
@testable import MeetingVaultCore

final class LocalModelInstallationServiceTests: XCTestCase {
    func testSnapshotDerivesThreeStableInstallUnitsInsteadOfFortySevenFileDownloads() async throws {
        let fixture = try Fixture()
        let service = try fixture.makeService()

        let states = await service.snapshot()

        XCTAssertEqual(
            states.map(\.id),
            [
                "automatic-speech-recognition",
                "offline-speaker-diarization",
                "streaming-speaker-diarization",
            ]
        )
        XCTAssertEqual(states.map(\.status), [.notInstalled, .notInstalled, .notInstalled])
        XCTAssertEqual(states.map(\.totalBytes), [8, 7, 6])
    }

    func testInstallStreamsMonotonicProgressAndPromotesOnlyTheCompleteVerifiedUnit() async throws {
        let fixture = try Fixture()
        fixture.transport.respond(with: fixture.responses)
        let service = try fixture.makeService()

        let events = try await collect(await service.install("automatic-speech-recognition"))

        XCTAssertEqual(events.first, .status(.downloading))
        XCTAssertEqual(events.last, .status(.ready))
        let progress = events.compactMap { event -> (Int64, Int64)? in
            guard case let .progress(completed, total) = event else { return nil }
            return (completed, total)
        }
        XCTAssertFalse(progress.isEmpty)
        XCTAssertTrue(zip(progress, progress.dropFirst()).allSatisfy { $0.0.0 <= $0.1.0 })
        XCTAssertTrue(progress.allSatisfy { $0.1 == 8 })
        XCTAssertEqual(progress.last?.0, 8)
        let readySnapshot = await service.snapshot()
        XCTAssertEqual(readySnapshot.first?.status, .ready)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(".staging/automatic-speech-recognition/payload").path))
    }

    func testInsufficientDiskFailsBeforeStartingNetwork() async throws {
        let fixture = try Fixture()
        fixture.transport.respond(with: fixture.responses)
        let service = try fixture.makeService(availableCapacity: { _ in 1 })

        do {
            _ = try await collect(await service.install("automatic-speech-recognition"))
            XCTFail("Expected disk preflight rejection")
        } catch {
            XCTAssertEqual(error as? LocalModelInstallationError, .insufficientDisk)
        }
        XCTAssertEqual(fixture.transport.requestCount, 0)
    }

    func testExplicitLeaseReleaseBlocksThenAllowsRemovalExactlyOnce() async throws {
        let fixture = try Fixture()
        try fixture.installUnitDirectly(id: "automatic-speech-recognition")
        let service = try fixture.makeService()
        let lease = try await service.acquire(["automatic-speech-recognition"])

        do {
            try await service.remove("automatic-speech-recognition")
            XCTFail("Expected active-use rejection")
        } catch {
            XCTAssertEqual(error as? LocalModelInstallationError, .unitInUse)
        }

        lease.release()
        lease.release()
        try await service.remove("automatic-speech-recognition")
        let removedSnapshot = await service.snapshot()
        XCTAssertEqual(removedSnapshot.first?.status, .notInstalled)
    }

    func testOpaqueRuntimeSessionOwnsLeaseUntilExecutorEndsAndRemovalClearsSelfCheck() async throws {
        let fixture = try Fixture()
        try fixture.installUnitDirectly(id: "automatic-speech-recognition")
        let service = try fixture.makeService()
        let selfCheckURL = fixture.root.appendingPathComponent(".self-checks/automatic-speech-recognition.json")
        try FileManager.default.createDirectory(at: selfCheckURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"assetID\":\"automatic-speech-recognition\",\"passed\":true,\"duration\":0}".utf8).write(to: selfCheckURL)
        let escaped = LockedRuntimeSessionAccess()
        let relativePath = try XCTUnwrap(
            fixture.manifest.assets.first { $0.feature == "automatic-speech-recognition" }?.relativeInstallPath
        )
        try await service.withRuntimeSession(["automatic-speech-recognition"]) { access in
            escaped.store(access)
            try await access.withReadOnlyFileDescriptor(
                assetID: "automatic-speech-recognition",
                relativePath: relativePath
            ) { descriptor in
                var info = stat()
                XCTAssertEqual(fstat(descriptor, &info), 0)
                XCTAssertEqual(info.st_mode & S_IFMT, S_IFREG)
            }
            do {
                try await service.remove("automatic-speech-recognition")
                XCTFail("Expected scoped runtime lease to block removal")
            } catch {
                XCTAssertEqual(error as? LocalModelInstallationError, .unitInUse)
            }
        }
        do {
            try await escaped.value?.withReadOnlyFileDescriptor(
                assetID: "automatic-speech-recognition",
                relativePath: relativePath
            ) { _ in }
            XCTFail("Expected retained runtime access to be invalid")
        } catch {
            XCTAssertEqual(error as? LocalModelInstallationError, .unitNotReady)
        }

        try await service.remove("automatic-speech-recognition")
        let clearedSelfCheck = try await service.lastSelfCheck("automatic-speech-recognition")
        XCTAssertNil(clearedSelfCheck)
    }

    func testRuntimeSessionWaitsForUnstructuredDescriptorOperationBeforeReleasingLease() async throws {
        let fixture = try Fixture()
        try fixture.installUnitDirectly(id: "automatic-speech-recognition")
        let service = try fixture.makeService()
        let relativePath = try XCTUnwrap(
            fixture.manifest.assets.first { $0.feature == "automatic-speech-recognition" }?.relativeInstallPath
        )
        let operationGate = AsyncOperationGate()

        let sessionTask = Task {
            try await service.withRuntimeSession(["automatic-speech-recognition"]) { access in
                Task {
                    try await access.withReadOnlyFileDescriptor(
                        assetID: "automatic-speech-recognition",
                        relativePath: relativePath
                    ) { _ in
                        await operationGate.markStartedAndWait()
                    }
                }
                await operationGate.waitUntilStarted()
            }
        }
        await operationGate.waitUntilStarted()
        do {
            try await service.remove("automatic-speech-recognition")
            XCTFail("Runtime lease must survive an unstructured active descriptor operation")
        } catch {
            XCTAssertEqual(error as? LocalModelInstallationError, .unitInUse)
        }
        await operationGate.release()
        try await sessionTask.value
        try await service.remove("automatic-speech-recognition")
    }

    func testRepairReservesAllCopyBytesBeforeCopyingAndLeavesNoNewStagingOnFailure() async throws {
        let fixture = try Fixture()
        try fixture.installUnitDirectly(id: "automatic-speech-recognition")
        let first = try XCTUnwrap(fixture.manifest.assets.first { $0.feature == "automatic-speech-recognition" })
        try Data(repeating: 0xee, count: Int(first.expectedBytes)).write(
            to: fixture.unitRoot("automatic-speech-recognition").appendingPathComponent(first.relativeInstallPath)
        )
        let anchoredCopies = LockedCounter()
        let service = try fixture.makeService(
            availableCapacity: { _ in 1 },
            repairCopyDidOpenDescriptors: { _ in _ = anchoredCopies.incrementAndGet() }
        )

        do {
            _ = try await collect(await service.repair("automatic-speech-recognition"))
            XCTFail("Expected reservation rejection")
        } catch {
            XCTAssertEqual(error as? LocalModelInstallationError, .insufficientDisk)
        }
        XCTAssertEqual(anchoredCopies.incrementAndGet(), 1, "No copy may occur before reservation")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.root.appendingPathComponent(".staging/automatic-speech-recognition").path
            )
        )
    }

    func testRepairReservationFailureDoesNotCleanPreexistingStaleStaging() async throws {
        let fixture = try Fixture()
        try fixture.installUnitDirectly(id: "automatic-speech-recognition")
        let first = try XCTUnwrap(fixture.manifest.assets.first { $0.feature == "automatic-speech-recognition" })
        try fixture.seedResume(
            asset: first,
            bytes: Data(repeating: 0x31, count: 128)[...],
            etag: "stale",
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
        let partial = fixture.resumePartial(first)
        let service = try fixture.makeService(availableCapacity: { _ in 1 })

        do {
            _ = try await collect(await service.repair("automatic-speech-recognition"))
            XCTFail("Expected reservation rejection")
        } catch {
            XCTAssertEqual(error as? LocalModelInstallationError, .insufficientDisk)
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: partial.path),
            "Capacity rejection must happen before stale staging cleanup"
        )
    }

    func testRepairLowDiskDoesNotRecoverPreparedPromotionBeforeReservation() async throws {
        let fixture = try Fixture()
        try fixture.installUnitDirectly(id: "automatic-speech-recognition")
        let unitRoot = fixture.unitRoot("automatic-speech-recognition")
        let originalFinalFiles = try Dictionary(uniqueKeysWithValues: fixture.manifest.assets
            .filter { $0.feature == "automatic-speech-recognition" }
            .map { asset in
                (asset.relativeInstallPath, try Data(contentsOf: unitRoot.appendingPathComponent(asset.relativeInstallPath)))
            })
        let originalFinalMetadata = try Dictionary(uniqueKeysWithValues: fixture.manifest.assets
            .filter { $0.feature == "automatic-speech-recognition" }
            .map { asset in
                (asset.relativeInstallPath, try stableFileMetadata(
                    at: unitRoot.appendingPathComponent(asset.relativeInstallPath)
                ))
            })
        let staging = fixture.root.appendingPathComponent(
            ".staging/automatic-speech-recognition",
            isDirectory: true
        )
        let stagingRoot = fixture.root.appendingPathComponent(".staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let journal = staging.appendingPathComponent("promotion-state.json")
        let journalData = Data(#"{"phase":"prepared"}"#.utf8)
        try journalData.write(to: journal)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journal.path)
        let stagingEntries = try Set(FileManager.default.contentsOfDirectory(atPath: staging.path))
        let service = try fixture.makeService(availableCapacity: { _ in 1 })
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: stagingRoot.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: fixture.root.path)
        let rootMetadata = try stableFileMetadata(at: fixture.root)
        let stagingRootMetadata = try stableFileMetadata(at: stagingRoot)
        let unitRootMetadata = try stableFileMetadata(at: unitRoot)
        let unitStagingMetadata = try stableFileMetadata(at: staging)
        let journalMetadata = try stableFileMetadata(at: journal)

        do {
            _ = try await collect(await service.repair("automatic-speech-recognition"))
            XCTFail("Expected reservation rejection")
        } catch {
            XCTAssertEqual(error as? LocalModelInstallationError, .insufficientDisk)
        }

        XCTAssertEqual(try Set(FileManager.default.contentsOfDirectory(atPath: staging.path)), stagingEntries)
        XCTAssertEqual(try Data(contentsOf: journal), journalData)
        XCTAssertEqual(try stableFileMetadata(at: fixture.root), rootMetadata)
        XCTAssertEqual(try stableFileMetadata(at: stagingRoot), stagingRootMetadata)
        XCTAssertEqual(try stableFileMetadata(at: unitRoot), unitRootMetadata)
        XCTAssertEqual(try stableFileMetadata(at: staging), unitStagingMetadata)
        XCTAssertEqual(try stableFileMetadata(at: journal), journalMetadata)
        for (path, bytes) in originalFinalFiles {
            XCTAssertEqual(try Data(contentsOf: unitRoot.appendingPathComponent(path)), bytes)
            XCTAssertEqual(
                try stableFileMetadata(at: unitRoot.appendingPathComponent(path)),
                originalFinalMetadata[path]
            )
        }
    }

    func testReplacingUnitStagingAncestorAfterValidationCannotMutateOutsideDirectory() async throws {
        let payload = Data(repeating: 0x55, count: 70_000)
        let fixture = try Fixture(asrPayloads: [payload])
        let outside = fixture.root.deletingLastPathComponent()
            .appendingPathComponent("MeetingVault-Unit-Race-\(UUID().uuidString)", isDirectory: true)
        let displaced = fixture.root.appendingPathComponent(".staging/displaced", isDirectory: true)
        let unitRoot = fixture.root.appendingPathComponent(".staging/automatic-speech-recognition", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        fixture.transport.handle { _ in
            try? FileManager.default.moveItem(at: unitRoot, to: displaced)
            try? FileManager.default.createSymbolicLink(at: unitRoot, withDestinationURL: outside)
            return LocalModelHTTPFixtureResponse(status: 200, headers: ["Content-Length": "70000", "ETag": "v1"], body: payload)
        }
        let service = try fixture.makeService()

        do {
            _ = try await collect(await service.install("automatic-speech-recognition"))
            XCTFail("Expected intermediate-ancestor replacement rejection")
        } catch {
            XCTAssertEqual(error as? LocalModelInstallationError, .unsafeFile)
        }
        XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: outside.path)).isEmpty)
    }

    func testRepairCopyRetainsPayloadAncestorDescriptorsAcrossReplacementRace() async throws {
        let fixture = try Fixture()
        try fixture.installUnitDirectly(id: "automatic-speech-recognition")
        let assets = fixture.manifest.assets.filter { $0.feature == "automatic-speech-recognition" }
        let damaged = try XCTUnwrap(assets.first)
        try Data(repeating: 0xee, count: Int(damaged.expectedBytes)).write(
            to: fixture.unitRoot("automatic-speech-recognition")
                .appendingPathComponent(damaged.relativeInstallPath)
        )
        let outside = fixture.root.deletingLastPathComponent()
            .appendingPathComponent("MeetingVault-Repair-Race-\(UUID().uuidString)", isDirectory: true)
        let displaced = fixture.root.appendingPathComponent(".staging/repair-displaced", isDirectory: true)
        let fixtureRoot = fixture.root
        let swaps = LockedCounter()
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let service = try fixture.makeService(
            repairCopyDidOpenDescriptors: { relativePath in
                guard swaps.incrementAndGet() == 1 else { return }
                let payloadRoot = fixtureRoot.appendingPathComponent(
                    ".staging/automatic-speech-recognition/payload",
                    isDirectory: true
                )
                let parent = payloadRoot.appendingPathComponent(relativePath)
                    .deletingLastPathComponent()
                try FileManager.default.moveItem(at: parent, to: displaced)
                try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: outside)
            }
        )

        do {
            _ = try await collect(await service.repair("automatic-speech-recognition"))
            XCTFail("Expected repair ancestor replacement rejection")
        } catch {
            XCTAssertEqual(error as? LocalModelInstallationError, .unsafeFile)
        }
        XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: outside.path)).isEmpty)
        XCTAssertEqual(swaps.incrementAndGet(), 2, "Repair copy must reach the anchored descriptor boundary once")
    }

    func testResumeMetadataIsFsyncedAndFailurePreventsNetworkBodyPromotion() async throws {
        let payload = Data(repeating: 0x52, count: 70_000)
        let fixture = try Fixture(asrPayloads: [payload])
        fixture.transport.respond(with: fixture.responses)
        let synced = LockedURLs()
        let service = try fixture.makeService(syncRegularFile: { url in
            synced.append(url)
            if url.pathExtension == "json", url.deletingLastPathComponent().lastPathComponent == "metadata" {
                throw FixtureError.sync
            }
        })

        do {
            _ = try await collect(await service.install("automatic-speech-recognition"))
            XCTFail("Expected resume metadata durability failure")
        } catch {
            XCTAssertEqual(error as? LocalModelInstallationError, .promotionFailed)
        }
        XCTAssertTrue(synced.values.contains { $0.pathExtension == "json" })
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.unitRoot("automatic-speech-recognition").path))
    }

    func testRestartRecoversPreviousReadyTreeAfterInterruptedPromotion() async throws {
        let fixture = try Fixture()
        try fixture.installUnitDirectly(id: "automatic-speech-recognition")
        let staging = fixture.root.appendingPathComponent(".staging/automatic-speech-recognition", isDirectory: true)
        let previous = staging.appendingPathComponent("previous", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: fixture.unitRoot("automatic-speech-recognition"), to: previous)
        let journal = staging.appendingPathComponent("promotion-state.json")
        try Data(#"{"phase":"previousMoved"}"#.utf8).write(to: journal)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journal.path)

        let service = try fixture.makeService()
        let snapshot = await service.snapshot()

        XCTAssertEqual(snapshot.first?.status, .ready)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.unitRoot("automatic-speech-recognition").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
    }

    func testRestartRetriesCleanupForCommittedPromotionMaintenanceMarker() async throws {
        let fixture = try Fixture()
        try fixture.installUnitDirectly(id: "automatic-speech-recognition")
        let staging = fixture.root.appendingPathComponent(".staging/automatic-speech-recognition", isDirectory: true)
        let previous = staging.appendingPathComponent("previous", isDirectory: true)
        try FileManager.default.createDirectory(at: previous, withIntermediateDirectories: true)
        try Data("obsolete".utf8).write(to: previous.appendingPathComponent("marker"))
        let journal = staging.appendingPathComponent("promotion-state.json")
        try Data(#"{"phase":"committedNeedsMaintenance"}"#.utf8).write(to: journal)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journal.path)

        let service = try fixture.makeService()
        let snapshot = await service.snapshot()

        XCTAssertEqual(snapshot.first?.status, .ready)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
    }

    func testStagingRejectsUnexpectedMetadataNamesAndPermissivePartialsBeforeNetwork() async throws {
        let payload = Data(repeating: 0x53, count: 70_000)
        for attack in ["metadata", "mode"] {
            let fixture = try Fixture(asrPayloads: [payload])
            let asset = try XCTUnwrap(fixture.manifest.assets.first { $0.feature == "automatic-speech-recognition" })
            try fixture.seedResume(asset: asset, bytes: payload.prefix(20_000), etag: "fixture-v1")
            if attack == "metadata" {
                let unexpected = fixture.root.appendingPathComponent(".staging/automatic-speech-recognition/metadata/unexpected.json")
                try Data("{}".utf8).write(to: unexpected)
            } else {
                try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fixture.resumePartial(asset).path)
            }
            fixture.transport.respond(with: fixture.responses)
            let service = try fixture.makeService()

            do {
                _ = try await collect(await service.install("automatic-speech-recognition"))
                XCTFail("Expected strict staging rejection for \(attack)")
            } catch {
                XCTAssertEqual(error as? LocalModelInstallationError, .unsafeFile)
            }
            XCTAssertEqual(fixture.transport.requestCount, 0)
        }
    }

    func testStagingReplacementRaceAfterNetworkSuspensionCannotRedirectPartialWrite() async throws {
        let payload = Data(repeating: 0x54, count: 70_000)
        let fixture = try Fixture(asrPayloads: [payload])
        let outside = fixture.root.deletingLastPathComponent()
            .appendingPathComponent("MeetingVault-Race-\(UUID().uuidString)", isDirectory: true)
        let fixtureRoot = fixture.root
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        fixture.transport.handle { _ in
            let partials = fixtureRoot.appendingPathComponent(".staging/automatic-speech-recognition/partials", isDirectory: true)
            try? FileManager.default.removeItem(at: partials)
            try? FileManager.default.createSymbolicLink(at: partials, withDestinationURL: outside)
            return LocalModelHTTPFixtureResponse(status: 200, headers: ["Content-Length": "70000", "ETag": "v1"], body: payload)
        }
        let service = try fixture.makeService()

        do {
            _ = try await collect(await service.install("automatic-speech-recognition"))
            XCTFail("Expected replacement-race rejection")
        } catch {
            XCTAssertEqual(error as? LocalModelInstallationError, .unsafeFile)
        }
        XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: outside.path)).isEmpty)
    }

    func testResumeUsesRangeAndIfRangeAndAcceptsOnlyExact206() async throws {
        let payload = Data(repeating: 0x41, count: 131_072)
        let fixture = try Fixture(asrPayloads: [payload])
        let asset = try XCTUnwrap(fixture.manifest.assets.first { $0.feature == "automatic-speech-recognition" })
        try fixture.seedResume(asset: asset, bytes: payload.prefix(65_536), etag: "fixture-v1")
        fixture.transport.handle { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=65536-")
            XCTAssertEqual(request.value(forHTTPHeaderField: "If-Range"), "fixture-v1")
            return LocalModelHTTPFixtureResponse(
                status: 206,
                headers: [
                    "Content-Length": "65536",
                    "Content-Range": "bytes 65536-131071/131072",
                    "ETag": "fixture-v1",
                ],
                body: Data(payload.dropFirst(65_536))
            )
        }
        let service = try fixture.makeService()

        let events = try await collect(await service.install("automatic-speech-recognition"))

        XCTAssertEqual(events.last, .status(.ready))
        XCTAssertEqual(fixture.transport.requestCount, 1)
    }

    func testResumeRestartsFromZeroWhenServerReturns200() async throws {
        let payload = Data(repeating: 0x42, count: 70_000)
        let fixture = try Fixture(asrPayloads: [payload])
        let asset = try XCTUnwrap(fixture.manifest.assets.first { $0.feature == "automatic-speech-recognition" })
        try fixture.seedResume(asset: asset, bytes: payload.prefix(20_000), etag: "fixture-v1")
        fixture.transport.handle { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=20000-")
            return LocalModelHTTPFixtureResponse(
                status: 200,
                headers: ["Content-Length": "70000", "ETag": "fixture-v2"],
                body: payload
            )
        }
        let service = try fixture.makeService()

        _ = try await collect(await service.install("automatic-speech-recognition"))

        let snapshot = await service.snapshot()
        XCTAssertEqual(snapshot.first?.completedBytes, 70_000)
    }

    func testResumeRejects416ContentRangeAndETagMismatch() async throws {
        let payload = Data(repeating: 0x43, count: 80_000)
        for response in [
            LocalModelHTTPFixtureResponse(status: 416, headers: [:], body: Data()),
            LocalModelHTTPFixtureResponse(
                status: 206,
                headers: ["Content-Length": "40000", "Content-Range": "bytes 39999-79998/80000", "ETag": "fixture-v1"],
                body: Data(payload.dropFirst(40_000))
            ),
            LocalModelHTTPFixtureResponse(
                status: 206,
                headers: ["Content-Length": "40000", "Content-Range": "bytes 40000-79999/80000", "ETag": "drifted"],
                body: Data(payload.dropFirst(40_000))
            ),
        ] {
            let fixture = try Fixture(asrPayloads: [payload])
            let asset = try XCTUnwrap(fixture.manifest.assets.first { $0.feature == "automatic-speech-recognition" })
            try fixture.seedResume(asset: asset, bytes: payload.prefix(40_000), etag: "fixture-v1")
            fixture.transport.handle { _ in response }
            let service = try fixture.makeService()

            do {
                _ = try await collect(await service.install("automatic-speech-recognition"))
                XCTFail("Expected strict resume rejection")
            } catch {
                XCTAssertEqual(error as? LocalModelInstallationError, .rangeRejected)
            }
        }
    }

    func testRepairDownloadsOnlyInvalidFilesAndRejectsRepairWhileLeased() async throws {
        let fixture = try Fixture()
        try fixture.installUnitDirectly(id: "automatic-speech-recognition")
        let asrAssets = fixture.manifest.assets.filter { $0.feature == "automatic-speech-recognition" }
        let corrupt = try XCTUnwrap(asrAssets.first)
        try Data(repeating: 0x7f, count: Int(corrupt.expectedBytes)).write(
            to: fixture.unitRoot("automatic-speech-recognition").appendingPathComponent(corrupt.relativeInstallPath)
        )
        fixture.transport.respond(with: fixture.responses)
        let service = try fixture.makeService()
        let lease = try? await service.acquire(["automatic-speech-recognition"])
        XCTAssertNil(lease, "A corrupt unit must not be leasable")

        _ = try await collect(await service.repair("automatic-speech-recognition"))

        XCTAssertEqual(fixture.transport.requestCount, 1)
        let readyLease = try await service.acquire(["automatic-speech-recognition"])
        do {
            _ = try await collect(await service.repair("automatic-speech-recognition"))
            XCTFail("Expected active repair rejection")
        } catch {
            XCTAssertEqual(error as? LocalModelInstallationError, .unitInUse)
        }
        readyLease.release()
    }

    func testConcurrentObserversShareOneOperationAndReceiveExactTerminalProgress() async throws {
        let fixture = try Fixture()
        fixture.transport.respond(with: fixture.responses)
        let service = try fixture.makeService()

        let firstStream = await service.install("automatic-speech-recognition")
        let secondStream = await service.install("automatic-speech-recognition")
        async let first = collectModelEvents(firstStream)
        async let second = collectModelEvents(secondStream)
        let observed = try await [first, second]

        XCTAssertEqual(fixture.transport.requestCount, 2)
        XCTAssertTrue(observed.allSatisfy { $0.last == .status(.ready) })
        XCTAssertTrue(observed.allSatisfy { $0.contains(.progress(completedBytes: 8, totalBytes: 8)) })
    }

    func testReturnedStreamRetainsTemporaryServiceUntilDeterministicTermination() async throws {
        let fixture = try Fixture()
        fixture.transport.respond(with: fixture.responses)

        let stream = await (try fixture.makeService()).install("automatic-speech-recognition")
        let events = try await collect(stream)

        XCTAssertEqual(events.last, .status(.ready))
        XCTAssertEqual(fixture.transport.requestCount, 2)
    }

    func testPrewarmIsUnavailableWithoutTask9ExecutorAndNeverStartsInProcessAdapter() async throws {
        let fixture = try Fixture()
        try fixture.installUnitDirectly(id: "automatic-speech-recognition")
        let called = LockedCounter()
        let service = try fixture.makeService(selfCheck: { _, _ in
            _ = called.incrementAndGet()
        })

        do {
            _ = try await service.prewarm("automatic-speech-recognition")
            XCTFail("Expected Task 9 executor gate")
        } catch {
            XCTAssertEqual(error as? LocalModelInstallationError, .selfCheckUnavailable)
        }
        XCTAssertEqual(called.incrementAndGet(), 1, "The adapter must not be called")
        let selfCheck = try await service.lastSelfCheck("automatic-speech-recognition")
        XCTAssertNil(selfCheck)
    }

    func testPrewarmUsesTerminatingExecutorPersistsResultAndReleasesLease() async throws {
        let fixture = try Fixture()
        try fixture.installUnitDirectly(id: "automatic-speech-recognition")
        let called = LockedCounter()
        let expectedRoot = fixture.unitRoot("automatic-speech-recognition")
        let service = try fixture.makeService(terminatingSelfCheckExecutor: { id, root, timeout in
            XCTAssertEqual(id, "automatic-speech-recognition")
            XCTAssertEqual(root, expectedRoot)
            XCTAssertEqual(timeout, .seconds(7))
            _ = called.incrementAndGet()
        }, selfCheckTimeout: .seconds(7))

        let result = try await service.prewarm("automatic-speech-recognition")

        XCTAssertTrue(result.passed)
        XCTAssertEqual(called.incrementAndGet(), 2)
        let persisted = try await service.lastSelfCheck(result.assetID)
        XCTAssertEqual(persisted, result)
        let lease = try await service.acquire([result.assetID])
        lease.release()
    }

    func testCancellationPreservesPrivatePartialForCrashSafeResumeWithoutPromotion() async throws {
        let payload = Data(repeating: 0x44, count: 131_072)
        let fixture = try Fixture(asrPayloads: [payload])
        fixture.transport.handle { _ in
            LocalModelHTTPFixtureResponse(
                status: 200,
                headers: ["Content-Length": "131072", "ETag": "cancel-v1"],
                body: Data(payload.prefix(70_000)),
                finishDelay: 2
            )
        }
        let service = try fixture.makeService()
        let stream = await service.install("automatic-speech-recognition")
        do {
            for try await event in stream {
                if case let .progress(completed, _) = event, completed >= 65_536 {
                    await service.cancel("automatic-speech-recognition")
                }
            }
            XCTFail("Expected explicit cancellation")
        } catch is CancellationError {
            // Expected: cancellation preserves only private staging data.
        }

        let cancelledSnapshot = await service.snapshot()
        XCTAssertEqual(cancelledSnapshot.first?.status, .notInstalled)
        XCTAssertGreaterThan(cancelledSnapshot.first?.completedBytes ?? 0, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.unitRoot("automatic-speech-recognition").path))

        fixture.transport.handle { request in
            let range = request.value(forHTTPHeaderField: "Range") ?? ""
            let offset = Int(range.dropFirst("bytes=".count).dropLast()) ?? -1
            XCTAssertGreaterThan(offset, 0)
            XCTAssertEqual(request.value(forHTTPHeaderField: "If-Range"), "cancel-v1")
            return LocalModelHTTPFixtureResponse(
                status: 206,
                headers: [
                    "Content-Length": String(payload.count - offset),
                    "Content-Range": "bytes \(offset)-\(payload.count - 1)/\(payload.count)",
                    "ETag": "cancel-v1",
                ],
                body: Data(payload.dropFirst(offset))
            )
        }
        let recoveredService = try fixture.makeService()
        _ = try await collect(await recoveredService.install("automatic-speech-recognition"))
        let recoveredSnapshot = await recoveredService.snapshot()
        XCTAssertEqual(recoveredSnapshot.first?.status, .ready)
    }

    func testChecksumAndLFSPointerBodiesNeverBecomeReady() async throws {
        let good = Data("good".utf8)
        let corruptFixture = try Fixture(asrPayloads: [good])
        corruptFixture.transport.handle { _ in
            LocalModelHTTPFixtureResponse(
                status: 200,
                headers: ["Content-Length": "4"],
                body: Data("evil".utf8)
            )
        }
        let corruptService = try corruptFixture.makeService()
        do {
            _ = try await collect(await corruptService.install("automatic-speech-recognition"))
            XCTFail("Expected digest rejection")
        } catch {
            XCTAssertEqual(error as? LocalModelInstallationError, .digestMismatch)
        }

        let pointer = Data("version https://git-lfs.github.com/spec/v1\noid sha256:abcd\nsize 1\n".utf8)
        let pointerFixture = try Fixture(asrPayloads: [pointer])
        pointerFixture.transport.respond(with: pointerFixture.responses)
        let pointerService = try pointerFixture.makeService()
        do {
            _ = try await collect(await pointerService.install("automatic-speech-recognition"))
            XCTFail("Expected LFS pointer rejection")
        } catch {
            XCTAssertEqual(error as? LocalModelInstallationError, .gitLFSPointer)
        }
    }

    func testRedirectPolicyRejectsDowngradeHostPathCredentialsAndQueryDrift() throws {
        let revision = "aed02740059203c4a87495924f685de3722ae9ce"
        let original = URL(string: "https://huggingface.co/FluidInference/model/resolve/\(revision)/model.bin")!
        let approved: Set<String> = ["huggingface.co", "cdn-lfs.hf.co"]
        let attacks = [
            "http://huggingface.co/FluidInference/model/resolve/\(revision)/model.bin",
            "https://evil.example/model.bin",
            "https://user:secret@cdn-lfs.hf.co/model.bin",
            "https://huggingface.co/FluidInference/other/resolve/\(revision)/model.bin",
            "https://huggingface.co/FluidInference/model/resolve/\(revision)/model.bin?token=secret",
        ]
        for attack in attacks {
            var request = URLRequest(url: try XCTUnwrap(URL(string: attack)))
            request.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
            XCTAssertNil(LocalModelDownloadURLPolicy.sanitizedRedirect(request, from: original, approvedHosts: approved))
        }

        var approvedRequest = URLRequest(url: URL(string: "https://cdn-lfs.hf.co/objects/model.bin?X-Amz-Signature=opaque")!)
        approvedRequest.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        approvedRequest.setValue("session=secret", forHTTPHeaderField: "Cookie")
        let sanitized = try XCTUnwrap(
            LocalModelDownloadURLPolicy.sanitizedRedirect(approvedRequest, from: original, approvedHosts: approved)
        )
        XCTAssertNil(sanitized.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(sanitized.value(forHTTPHeaderField: "Cookie"))
    }

    func testAtomicPromoterRollsBackPreviousReadyUnitAndSyncsDirectories() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVault-Promotion-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = root.appendingPathComponent(".staging/unit", isDirectory: true)
        let payload = staging.appendingPathComponent("payload", isDirectory: true)
        let final = root.appendingPathComponent("unit", isDirectory: true)
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: final, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: payload.appendingPathComponent("marker"))
        try Data("old".utf8).write(to: final.appendingPathComponent("marker"))
        let syncs = LockedURLs()

        XCTAssertThrowsError(
            try LocalModelAtomicPromoter.promote(
                payloadRoot: payload,
                finalRoot: final,
                unitStagingRoot: staging,
                movePayload: { _, _ in throw FixtureError.promotion },
                syncDirectory: { syncs.append($0) }
            )
        )
        XCTAssertEqual(try Data(contentsOf: final.appendingPathComponent("marker")), Data("old".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.appendingPathComponent("previous").path))
        XCTAssertFalse(syncs.values.isEmpty)
    }

    func testAtomicPromoterRestoresPreviousReadyUnitWhenBackupDurabilitySyncFails() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVault-Promotion-Sync-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = root.appendingPathComponent(".staging/unit", isDirectory: true)
        let payload = staging.appendingPathComponent("payload", isDirectory: true)
        let final = root.appendingPathComponent("unit", isDirectory: true)
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: final, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: payload.appendingPathComponent("marker"))
        try Data("old".utf8).write(to: final.appendingPathComponent("marker"))
        let syncCount = LockedCounter()

        XCTAssertThrowsError(
            try LocalModelAtomicPromoter.promote(
                payloadRoot: payload,
                finalRoot: final,
                unitStagingRoot: staging,
                syncDirectory: { _ in
                    if syncCount.incrementAndGet() == 1 { throw FixtureError.promotion }
                }
            )
        )
        XCTAssertEqual(try Data(contentsOf: final.appendingPathComponent("marker")), Data("old".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.appendingPathComponent("previous").path))
    }

    func testAtomicPromoterReportsCommittedMaintenanceWhenOnlyCleanupFails() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVault-Promotion-Cleanup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = root.appendingPathComponent(".staging/unit", isDirectory: true)
        let payload = staging.appendingPathComponent("payload", isDirectory: true)
        let final = root.appendingPathComponent("unit", isDirectory: true)
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: final, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: payload.appendingPathComponent("marker"))
        try Data("old".utf8).write(to: final.appendingPathComponent("marker"))
        let calls = LockedCounter()

        let outcome = try LocalModelAtomicPromoter.promote(
            payloadRoot: payload,
            finalRoot: final,
            unitStagingRoot: staging,
            syncDirectory: { _ in
                if calls.incrementAndGet() >= 3 { throw FixtureError.promotion }
            }
        )

        XCTAssertEqual(outcome, .committedNeedsMaintenance)
        XCTAssertEqual(try Data(contentsOf: final.appendingPathComponent("marker")), Data("new".utf8))
    }

    func testAtomicPromoterFailureMatrixPreservesExplicitDurableState() throws {
        func roots(_ suffix: String) throws -> (URL, URL, URL) {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("MeetingVault-Promotion-Matrix-\(suffix)-\(UUID().uuidString)", isDirectory: true)
            let staging = root.appendingPathComponent(".staging/unit", isDirectory: true)
            let payload = staging.appendingPathComponent("payload", isDirectory: true)
            let final = root.appendingPathComponent("unit", isDirectory: true)
            try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: final, withIntermediateDirectories: true)
            try Data("new".utf8).write(to: payload.appendingPathComponent("marker"))
            try Data("old".utf8).write(to: final.appendingPathComponent("marker"))
            return (root, payload, final)
        }

        do {
            let (root, payload, final) = try roots("rollback")
            defer { try? FileManager.default.removeItem(at: root) }
            let staging = payload.deletingLastPathComponent()
            let moveCalls = LockedCounter()
            XCTAssertThrowsError(try LocalModelAtomicPromoter.promote(
                payloadRoot: payload,
                finalRoot: final,
                unitStagingRoot: staging,
                movePayload: { _, _ in throw FixtureError.promotion },
                moveItem: { source, destination in
                    if moveCalls.incrementAndGet() == 2 { throw FixtureError.promotion }
                    try FileManager.default.moveItem(at: source, to: destination)
                },
                syncDirectory: { _ in }
            )) {
                XCTAssertEqual($0 as? LocalModelInstallationError, .promotionRecoveryRequired)
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: staging.appendingPathComponent("previous").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: final.path))
        }

        do {
            let (root, payload, final) = try roots("commit-sync")
            defer { try? FileManager.default.removeItem(at: root) }
            let syncCalls = LockedCounter()
            XCTAssertThrowsError(try LocalModelAtomicPromoter.promote(
                payloadRoot: payload,
                finalRoot: final,
                unitStagingRoot: payload.deletingLastPathComponent(),
                syncDirectory: { _ in
                    if syncCalls.incrementAndGet() == 2 { throw FixtureError.sync }
                }
            )) {
                XCTAssertEqual($0 as? LocalModelInstallationError, .promotionFailed)
            }
            XCTAssertEqual(try Data(contentsOf: final.appendingPathComponent("marker")), Data("old".utf8))
        }

        do {
            let (root, payload, final) = try roots("remove")
            defer { try? FileManager.default.removeItem(at: root) }
            let phases = LockedPromotionPhases()
            let outcome = try LocalModelAtomicPromoter.promote(
                payloadRoot: payload,
                finalRoot: final,
                unitStagingRoot: payload.deletingLastPathComponent(),
                removeItem: { url in
                    if url.lastPathComponent == "previous" { throw FixtureError.promotion }
                    try FileManager.default.removeItem(at: url)
                },
                recordPhase: { phases.append($0) },
                syncDirectory: { _ in }
            )
            XCTAssertEqual(outcome, .committedNeedsMaintenance)
            XCTAssertEqual(phases.values.last, .committedNeedsMaintenance)
            XCTAssertEqual(try Data(contentsOf: final.appendingPathComponent("marker")), Data("new".utf8))
        }
    }

    func testPrewarmDoesNotLeaveLeaseWhenTask9ExecutorIsUnavailable() async throws {
        let fixture = try Fixture()
        try fixture.installUnitDirectly(id: "automatic-speech-recognition")
        let service = try fixture.makeService(
            selfCheck: { _, _ in try await Task.sleep(for: .seconds(1)) },
            selfCheckTimeout: .milliseconds(10)
        )

        do {
            _ = try await service.prewarm("automatic-speech-recognition")
            XCTFail("Expected unavailable executor")
        } catch {
            XCTAssertEqual(error as? LocalModelInstallationError, .selfCheckUnavailable)
        }
        try await service.remove("automatic-speech-recognition")
    }

    func testSymlinkAndHardLinkResumePartialsAreRejectedBeforeNetworkOrMutation() async throws {
        for attack in ["symlink", "hardlink"] {
            let payload = Data(repeating: 0x51, count: 70_000)
            let fixture = try Fixture(asrPayloads: [payload])
            let asset = try XCTUnwrap(fixture.manifest.assets.first { $0.feature == "automatic-speech-recognition" })
            try fixture.seedResume(asset: asset, bytes: payload.prefix(20_000), etag: "fixture-v1")
            let partial = fixture.resumePartial(asset)
            let marker = fixture.root.appendingPathComponent("private-marker")
            let markerBytes = Data("must-stay-private".utf8)
            try markerBytes.write(to: marker)
            try FileManager.default.removeItem(at: partial)
            if attack == "symlink" {
                try FileManager.default.createSymbolicLink(at: partial, withDestinationURL: marker)
            } else {
                try FileManager.default.linkItem(at: marker, to: partial)
            }
            fixture.transport.respond(with: fixture.responses)
            let service = try fixture.makeService()

            do {
                _ = try await collect(await service.install("automatic-speech-recognition"))
                XCTFail("Expected unsafe staging rejection")
            } catch {
                XCTAssertEqual(error as? LocalModelInstallationError, .unsafeFile)
            }
            XCTAssertEqual(fixture.transport.requestCount, 0)
            XCTAssertEqual(try Data(contentsOf: marker), markerBytes)
        }
    }

    func testSymlinkedStagingAncestorIsRejectedBeforeNetwork() async throws {
        let fixture = try Fixture()
        let outside = fixture.root.deletingLastPathComponent()
            .appendingPathComponent("MeetingVault-Staging-Out\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let staging = fixture.root.appendingPathComponent(".staging", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: staging, withDestinationURL: outside)
        fixture.transport.respond(with: fixture.responses)

        do {
            let service = try fixture.makeService()
            _ = try await collect(await service.install("automatic-speech-recognition"))
            XCTFail("Expected staging confinement rejection")
        } catch {
            XCTAssertEqual(error as? LocalModelInstallationError, .unsafeFile)
        }
        XCTAssertEqual(fixture.transport.requestCount, 0)
    }

    func testLifecycleAuditUsesOnlyStableActionsCodesCountsAndUnitIDs() async throws {
        let fixture = try Fixture()
        fixture.transport.respond(with: fixture.responses)
        let audit = LifecycleAuditProbe()
        let service = try fixture.makeService(audit: { action, metadata in
            audit.record(action, metadata)
        })

        _ = try await collect(await service.install("automatic-speech-recognition"))
        do {
            _ = try await service.prewarm("automatic-speech-recognition")
            XCTFail("Expected unavailable executor")
        } catch {
            XCTAssertEqual(error as? LocalModelInstallationError, .selfCheckUnavailable)
        }
        try await service.remove("automatic-speech-recognition")

        XCTAssertEqual(audit.records.map(\.0), [.modelInstall, .modelPrewarm, .modelRemove])
        let allowedKeys = Set(["assetID", "code", "fileCount"])
        XCTAssertTrue(audit.records.allSatisfy { Set($0.1.keys).isSubset(of: allowedKeys) })
        let values = audit.records.flatMap { $0.1.values }.joined(separator: " ")
        XCTAssertFalse(values.contains("https://"))
        XCTAssertFalse(values.contains("/Users/"))
        XCTAssertFalse(values.contains("transcript"))
        XCTAssertFalse(values.contains("private"))
    }

    func testSnapshotCleansStaleStagingAndDoesNotAdvertiseItsBytes() async throws {
        let payload = Data(repeating: 0x61, count: 70_000)
        let fixture = try Fixture(asrPayloads: [payload])
        let asset = try XCTUnwrap(fixture.manifest.assets.first { $0.feature == "automatic-speech-recognition" })
        try fixture.seedResume(
            asset: asset,
            bytes: payload.prefix(20_000),
            etag: "stale-v1",
            updatedAt: Date(timeIntervalSince1970: 1_780_000_000)
        )
        let service = try fixture.makeService()

        let snapshot = await service.snapshot()

        XCTAssertEqual(snapshot.first?.status, .notInstalled)
        XCTAssertEqual(snapshot.first?.completedBytes, 0)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.root.appendingPathComponent(".staging/automatic-speech-recognition").path
            )
        )
    }

    private func collect(
        _ stream: AsyncThrowingStream<ModelInstallEvent, Error>
    ) async throws -> [ModelInstallEvent] {
        var events: [ModelInstallEvent] = []
        for try await event in stream {
            events.append(event)
        }
        return events
    }
}

private func collectModelEvents(
    _ stream: AsyncThrowingStream<ModelInstallEvent, Error>
) async throws -> [ModelInstallEvent] {
    var events: [ModelInstallEvent] = []
    for try await event in stream { events.append(event) }
    return events
}

private final class Fixture {
    let root: URL
    let manifest: LocalModelManifest
    let responses: [URL: Data]
    let transport = LocalModelURLProtocolController()

    init(asrPayloads: [Data] = [Data("asr".utf8), Data("bytes".utf8)]) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVault-ModelLifecycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        var definitions: [(String, String, String, Data)] = asrPayloads.enumerated().map {
            ("asr-\($0.offset)", "automatic-speech-recognition", "parakeet-tdt-0.6b-v3/\($0.offset).bin", $0.element)
        }
        definitions.append(("offline", "offline-speaker-diarization", "speaker-diarization/model.bin", Data("offline".utf8)))
        definitions.append(("stream", "streaming-speaker-diarization", "ls-eend/dih3/optimized/dih3/100ms/model.bin", Data("stream".utf8)))
        var responseMap: [URL: Data] = [:]
        let revision = "aed02740059203c4a87495924f685de3722ae9ce"
        let assets = definitions.map { id, feature, path, bytes -> LocalModelAsset in
            let source = URL(string: "https://huggingface.co/FluidInference/fixture/resolve/\(revision)/\(path)")!
            responseMap[source] = bytes
            return LocalModelAsset(
                id: id,
                feature: feature,
                version: "1.0.0",
                sourceURL: source,
                sourceRevision: revision,
                licenseName: "MIT",
                licenseURL: URL(string: "https://opensource.org/license/mit")!,
                expectedBytes: Int64(bytes.count),
                sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
                relativeInstallPath: path
            )
        }.sorted { [$0.id, $0.relativeInstallPath].lexicographicallyPrecedes([$1.id, $1.relativeInstallPath]) }
        manifest = LocalModelManifest(schemaVersion: 1, assets: assets)
        responses = responseMap
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func makeService(
        availableCapacity: @escaping @Sendable (URL) throws -> Int64 = { _ in 10_000_000 },
        selfCheck: @escaping LocalModelInstallationService.SelfCheckAdapter = { _, _ in },
        terminatingSelfCheckExecutor: LocalModelInstallationService.TerminatingSelfCheckExecutor? = nil,
        selfCheckTimeout: Duration = .seconds(30),
        audit: @escaping LocalModelInstallationService.AuditSink = { _, _ in },
        syncRegularFile: @escaping LocalModelInstallationService.SyncRegularFile = LocalModelInstallationService.defaultSyncRegularFile,
        repairCopyDidOpenDescriptors: @escaping @Sendable (String) throws -> Void = { _ in }
    ) throws -> LocalModelInstallationService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LocalModelURLProtocol.self]
        LocalModelURLProtocol.controller = transport
        return try LocalModelInstallationService(
            manifest: manifest,
            modelsRoot: root,
            sessionConfiguration: configuration,
            approvedHosts: ["huggingface.co"],
            availableCapacity: availableCapacity,
            now: { Date(timeIntervalSince1970: 1_790_000_000) },
            selfCheck: selfCheck,
            terminatingSelfCheckExecutor: terminatingSelfCheckExecutor,
            selfCheckTimeout: selfCheckTimeout,
            syncRegularFile: syncRegularFile,
            repairCopyDidOpenDescriptors: repairCopyDidOpenDescriptors,
            audit: audit
        )
    }

    func unitRoot(_ id: String) -> URL {
        root.appendingPathComponent(id, isDirectory: true)
    }

    func seedResume(
        asset: LocalModelAsset,
        bytes: Data.SubSequence,
        etag: String,
        updatedAt: Date = Date(timeIntervalSince1970: 1_790_000_000)
    ) throws {
        let staging = root.appendingPathComponent(".staging/\(asset.feature)", isDirectory: true)
        let token = SHA256.hash(data: Data(asset.id.utf8)).map { String(format: "%02x", $0) }.joined()
        let partial = staging.appendingPathComponent("partials/\(token).partial")
        let metadata = staging.appendingPathComponent("metadata/\(token).json")
        try FileManager.default.createDirectory(at: partial.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: metadata.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(bytes).write(to: partial)
        let document: [String: Any] = [
            "originalURL": asset.sourceURL.absoluteString,
            "etag": etag,
            "expectedBytes": asset.expectedBytes,
            "sha256": asset.sha256,
            "updatedAt": updatedAt.timeIntervalSince1970,
        ]
        try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]).write(to: metadata)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: partial.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metadata.path)
    }

    func resumePartial(_ asset: LocalModelAsset) -> URL {
        let token = SHA256.hash(data: Data(asset.id.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(".staging/\(asset.feature)/partials/\(token).partial")
    }

    func installUnitDirectly(id: String) throws {
        let unit = manifest.assets.filter { $0.feature == id }
        let unitRoot = root.appendingPathComponent(id, isDirectory: true)
        for asset in unit {
            let file = unitRoot.appendingPathComponent(asset.relativeInstallPath)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try XCTUnwrap(responses[asset.sourceURL]).write(to: file)
        }
    }
}

private final class LocalModelURLProtocolController: @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [URL: Data] = [:]
    private var requests: [URLRequest] = []
    private var handler: (@Sendable (URLRequest) -> LocalModelHTTPFixtureResponse)?

    var requestCount: Int { lock.withLock { requests.count } }

    func respond(with responses: [URL: Data]) {
        lock.withLock {
            self.responses = responses
            handler = nil
        }
    }

    func handle(_ handler: @escaping @Sendable (URLRequest) -> LocalModelHTTPFixtureResponse) {
        lock.withLock { self.handler = handler }
    }

    func response(for request: URLRequest) -> LocalModelHTTPFixtureResponse? {
        lock.withLock {
            requests.append(request)
            if let handler { return handler(request) }
            return request.url.flatMap { responses[$0] }.map {
                LocalModelHTTPFixtureResponse(
                    status: 200,
                    headers: ["Content-Length": String($0.count), "ETag": "fixture-v1"],
                    body: $0
                )
            }
        }
    }
}

private struct LocalModelHTTPFixtureResponse: Sendable {
    var status: Int
    var headers: [String: String]
    var body: Data
    var finishDelay: TimeInterval = 0
}

private final class LocalModelURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var controller: LocalModelURLProtocolController?
    private let stateLock = NSLock()
    private var stopped = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let fixture = Self.controller?.response(for: request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: fixture.status,
            httpVersion: "HTTP/1.1",
            headerFields: fixture.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: fixture.body)
        if fixture.finishDelay == 0 {
            client?.urlProtocolDidFinishLoading(self)
        } else {
            DispatchQueue.global().asyncAfter(deadline: .now() + fixture.finishDelay) { [self] in
                let shouldFinish = stateLock.withLock { !stopped }
                if shouldFinish { client?.urlProtocolDidFinishLoading(self) }
            }
        }
    }

    override func stopLoading() {
        stateLock.withLock { stopped = true }
    }
}

private enum FixtureError: Error {
    case selfCheck
    case promotion
    case sync
    case metadata
}

private struct StableFileMetadata: Equatable {
    let permissions: Int
    let size: UInt64
    let modificationDate: Date
}

private func stableFileMetadata(at url: URL) throws -> StableFileMetadata {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard let permissions = attributes[.posixPermissions] as? NSNumber,
          let size = attributes[.size] as? NSNumber,
          let modificationDate = attributes[.modificationDate] as? Date else {
        throw FixtureError.metadata
    }
    return StableFileMetadata(
        permissions: permissions.intValue,
        size: size.uint64Value,
        modificationDate: modificationDate
    )
}

private final class LockedRuntimeSessionAccess: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: LocalModelRuntimeAccess?
    var value: LocalModelRuntimeAccess? { lock.withLock { storage } }
    func store(_ access: LocalModelRuntimeAccess) { lock.withLock { storage = access } }
}

private actor AsyncOperationGate {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func markStartedAndWait() async {
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private final class LockedURLs: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL] = []
    var values: [URL] { lock.withLock { storage } }
    func append(_ url: URL) { lock.withLock { storage.append(url) } }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func incrementAndGet() -> Int {
        lock.withLock {
            value += 1
            return value
        }
    }
}

private final class LockedPromotionPhases: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [LocalModelAtomicPromoter.Phase] = []
    var values: [LocalModelAtomicPromoter.Phase] { lock.withLock { storage } }
    func append(_ phase: LocalModelAtomicPromoter.Phase) { lock.withLock { storage.append(phase) } }
}

private final class LifecycleAuditProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(PrivacyAuditAction, [String: String])] = []
    var records: [(PrivacyAuditAction, [String: String])] { lock.withLock { storage } }
    func record(_ action: PrivacyAuditAction, _ metadata: [String: String]) {
        lock.withLock { storage.append((action, metadata)) }
    }
}
