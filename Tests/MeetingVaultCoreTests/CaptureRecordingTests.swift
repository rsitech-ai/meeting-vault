import AVFoundation
import Foundation
import XCTest
@testable import MeetingVaultCore

final class CaptureRecordingTests: XCTestCase {
    func testScreenCaptureKitStopFailureFailsClosedWithoutDrainOrFinalization() async throws {
        let events = CoreAudioShutdownEventRecorder()
        let fanout = CaptureFrameFanout()
        let emitter = CaptureFrameEmitter(fanout: fanout)
        let pcm = [Float(0.25), -0.25].withUnsafeBytes { Data($0) }
        XCTAssertEqual(
            try emitter.emitCanonicalPCM(
                pcm,
                sampleRate: 48_000,
                channelCount: 1,
                frameCount: 2,
                track: .remoteSystem
            ),
            .accepted
        )
        let shutdown = ScreenCaptureKitCaptureShutdown {
            events.append("stop")
            throw CallbackRelayTestError.screenCaptureStopFailed
        }

        let result: Result<Int, Error> = await shutdown.resolve(
            afterProducerStopped: { makeResult in
                events.append("drain")
                return makeResult()
            },
            withoutProducerStopped: { result in
                events.append("no-drain")
                return result
            },
            clearStoppedStream: {
                events.append("clear-stream")
            },
            retainFailedStream: {
                events.append("retain-stream")
            },
            rejectFurtherFrames: {
                events.append("reject-frames")
                emitter.finishProducerAfterFailedStop()
            },
            makeProposedResult: {
                events.append("read-metrics")
                events.append("flush")
                events.append("finalize")
                return .success(42)
            }
        )

        XCTAssertThrowsError(try result.get()) { error in
            XCTAssertEqual(
                error as? ScreenCaptureKitSystemAudioCaptureError,
                .stopCaptureFailed("screenCaptureStopFailed")
            )
        }
        XCTAssertEqual(
            events.values,
            ["stop", "retain-stream", "reject-frames", "no-drain"]
        )
        XCTAssertThrowsError(
            try emitter.emitCanonicalPCM(
                pcm,
                sampleRate: 48_000,
                channelCount: 1,
                frameCount: 2,
                track: .remoteSystem
            )
        ) { error in
            XCTAssertEqual(error as? CaptureFrameEmissionError, .durabilityRejected)
        }
        try await fanout.finish()
    }

    func testScreenCaptureKitStopFailurePreservesLatchedCallbackFailurePrecedence() async {
        let callbackQueue = DispatchQueue(label: "CaptureRecordingTests.sck-stop-callback")
        let controlQueue = DispatchQueue(label: "CaptureRecordingTests.sck-stop-control")
        let relay = CaptureCallbackFailureRelay(
            callbackQueue: callbackQueue,
            controlQueue: controlQueue
        ) { _ in }
        callbackQueue.sync {
            XCTAssertTrue(relay.report(CallbackRelayTestError.durabilityRejected))
        }
        let shutdown = ScreenCaptureKitCaptureShutdown {
            throw CallbackRelayTestError.screenCaptureStopFailed
        }

        let result: Result<Int, Error> = await shutdown.resolve(
            afterProducerStopped: { makeResult in makeResult() },
            withoutProducerStopped: { relay.arbitrate($0) },
            clearStoppedStream: {},
            retainFailedStream: {},
            rejectFurtherFrames: {},
            makeProposedResult: { .success(42) }
        )

        XCTAssertThrowsError(try result.get()) { error in
            XCTAssertEqual(error as? CallbackRelayTestError, .durabilityRejected)
        }
    }

    func testCoreAudioStopFailureDetachesAndFailsWithoutFinalizingCapture() {
        let events = CoreAudioShutdownEventRecorder()
        let shutdown = CoreAudioCaptureShutdown(
            stop: {
                events.append("stop")
                return OSStatus(-7_001)
            },
            detach: {
                events.append("detach")
                return noErr
            }
        )

        let result: Result<Int, Error> = shutdown.resolve(
            afterProducerStopped: { makeResult in
                events.append("drain")
                return makeResult()
            },
            withoutProducerStopped: { result in
                events.append("no-drain")
                return result
            },
            cleanupAfterProducerStopped: {
                events.append("cleanup")
            },
            makeProposedResult: {
                events.append("finalize")
                return .success(42)
            }
        )

        XCTAssertThrowsError(try result.get()) { error in
            XCTAssertEqual(error as? CoreAudioTapCaptureError, .stopDeviceFailed(-7_001))
        }
        XCTAssertEqual(events.values, ["stop", "detach", "drain", "cleanup"])
    }

    func testCoreAudioStopAndDetachFailureDoesNotDrainOrFinalizeCapture() {
        let events = CoreAudioShutdownEventRecorder()
        let shutdown = CoreAudioCaptureShutdown(
            stop: {
                events.append("stop")
                return OSStatus(-7_002)
            },
            detach: {
                events.append("detach")
                return OSStatus(-7_003)
            }
        )

        let result: Result<Int, Error> = shutdown.resolve(
            afterProducerStopped: { makeResult in
                events.append("drain")
                return makeResult()
            },
            withoutProducerStopped: { result in
                events.append("no-drain")
                return result
            },
            cleanupAfterProducerStopped: {
                events.append("cleanup")
            },
            makeProposedResult: {
                events.append("finalize")
                return .success(42)
            }
        )

        XCTAssertThrowsError(try result.get()) { error in
            XCTAssertEqual(
                error as? CoreAudioTapCaptureError,
                .shutdownFailed(stopStatus: -7_002, detachStatus: -7_003)
            )
        }
        XCTAssertEqual(events.values, ["stop", "detach", "no-drain"])
    }

    func testCoreAudioStopSuccessAndDetachFailureRetainsResourcesWithoutDrainOrFinalization() {
        let events = CoreAudioShutdownEventRecorder()
        let shutdown = CoreAudioCaptureShutdown(
            stop: {
                events.append("stop")
                return noErr
            },
            detach: {
                events.append("detach")
                return OSStatus(-7_004)
            }
        )

        let result: Result<Int, Error> = shutdown.resolve(
            afterProducerStopped: { makeResult in
                events.append("drain")
                return makeResult()
            },
            withoutProducerStopped: { result in
                events.append("no-drain")
                return result
            },
            cleanupAfterProducerStopped: {
                events.append("cleanup")
            },
            makeProposedResult: {
                events.append("finalize")
                return .success(42)
            }
        )

        XCTAssertThrowsError(try result.get()) { error in
            XCTAssertEqual(
                error as? CoreAudioTapCaptureError,
                .shutdownFailed(stopStatus: noErr, detachStatus: -7_004)
            )
        }
        XCTAssertEqual(events.values, ["stop", "detach", "no-drain"])
    }

    func testCallbackTerminalizerIncludesFinalQueuedCallbackExactlyOnce() throws {
        let callbackQueue = DispatchQueue(label: "CaptureRecordingTests.final-callback")
        let controlQueue = DispatchQueue(label: "CaptureRecordingTests.final-callback-control")
        let recorder = CallbackFrameRecorder()
        let relay = CaptureCallbackFailureRelay(controlQueue: controlQueue) { _ in }
        let terminalizer = CaptureCallbackTerminalizer<Int>(
            callbackQueue: callbackQueue,
            failureRelay: relay
        )
        let producer = DeterministicFinalCallbackProducer(
            callbackQueue: callbackQueue,
            recorder: recorder
        )

        producer.stop()
        let result = terminalizer.resolveAfterProducerStopped {
            .success(recorder.count)
        }

        XCTAssertEqual(try result.get(), 1)
        callbackQueue.sync {}
        XCTAssertEqual(recorder.count, 1)
    }

    func testCallbackTerminalizerLetsFinalQueuedFailureWinOverProposedSuccess() {
        let callbackQueue = DispatchQueue(label: "CaptureRecordingTests.final-failure")
        let controlQueue = DispatchQueue(label: "CaptureRecordingTests.final-failure-control")
        let relay = CaptureCallbackFailureRelay(controlQueue: controlQueue) { _ in }
        let terminalizer = CaptureCallbackTerminalizer<Int>(
            callbackQueue: callbackQueue,
            failureRelay: relay
        )

        callbackQueue.async {
            relay.report(CallbackRelayTestError.durabilityRejected)
        }
        let result = terminalizer.resolveAfterProducerStopped { .success(42) }

        XCTAssertThrowsError(try result.get()) { error in
            XCTAssertEqual(error as? CallbackRelayTestError, .durabilityRejected)
        }
    }

    func testCallbackFailureRelayLetsFailureWinWhenStopWasQueuedBeforeTeardownDispatch() async throws {
        let callbackQueue = DispatchQueue(label: "CaptureRecordingTests.terminal-race-callback")
        let controlQueue = DispatchQueue(label: "CaptureRecordingTests.terminal-race-control")
        let controlGate = DispatchSemaphore(value: 0)
        let completionGate = DispatchSemaphore(value: 0)
        let resolution = CallbackFailureRecorder()
        controlQueue.async {
            controlGate.wait()
        }
        let relay = CaptureCallbackFailureRelay(
            callbackQueue: callbackQueue,
            controlQueue: controlQueue
        ) { _ in }

        controlQueue.async {
            let proposed: Result<Int, Error> = .success(42)
            switch relay.arbitrate(proposed) {
            case .success:
                resolution.append("success")
            case let .failure(error):
                resolution.append(String(describing: error))
            }
            completionGate.signal()
        }

        callbackQueue.sync {
            XCTAssertTrue(relay.report(CallbackRelayTestError.durabilityRejected))
        }

        controlGate.signal()
        XCTAssertEqual(completionGate.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(resolution.failures, ["durabilityRejected"])
    }

    func testRealtimeCaptureAdaptersUseSharedBehaviorallyTestedTerminalizer() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let adapterPaths = [
            "Sources/MeetingVaultCore/Services/AVFoundationSelectedMicrophoneCaptureEngine.swift",
            "Sources/MeetingVaultCore/Services/CoreAudioTapCaptureEngine.swift",
            "Sources/MeetingVaultCore/Services/ScreenCaptureKitSystemAudioCaptureEngine.swift"
        ]

        for adapterPath in adapterPaths {
            let source = try String(
                contentsOf: repositoryRoot.appendingPathComponent(adapterPath),
                encoding: .utf8
            )
            XCTAssertTrue(
                source.contains("callbackTerminalizer.resolveAfterProducerStopped"),
                "\(adapterPath) must use the shared drain-before-build-and-arbitrate seam"
            )
        }
    }

    func testCallbackFailureRelayOnlyLatchesAndSchedulesFirstFailureOffCallback() async throws {
        let callbackQueue = DispatchQueue(label: "CaptureRecordingTests.audio-callback")
        let controlQueue = DispatchQueue(label: "CaptureRecordingTests.callback-control")
        let queueGate = DispatchSemaphore(value: 0)
        controlQueue.async {
            queueGate.wait()
        }
        let recorder = CallbackFailureRecorder()
        let relay = CaptureCallbackFailureRelay(
            callbackQueue: callbackQueue,
            controlQueue: controlQueue
        ) { error in
            recorder.append(String(describing: error))
        }

        let reportResults = callbackQueue.sync {
            (
                relay.report(CallbackRelayTestError.conversionFailed),
                relay.report(CallbackRelayTestError.durabilityRejected)
            )
        }
        XCTAssertTrue(reportResults.0)
        XCTAssertFalse(reportResults.1)
        XCTAssertTrue(relay.hasLatchedFailure)
        XCTAssertTrue(recorder.failures.isEmpty)

        queueGate.signal()
        try await waitUntil("the control queue handles the latched callback failure") {
            recorder.failures == ["conversionFailed"]
        }
    }

    func testCaptureRecordingConvertsDurableFanoutFailureIntoRecoverableInterruption() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultDurableFanoutFailure-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = AESGCMDataVault(
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 0x41, count: 32))
        )
        let bundleStore = EncryptedMeetingBundleStore(rootDirectory: root, vault: vault)
        let writer = EncryptedAudioChunkWriter(bundleStore: bundleStore)
        let meetingID = UUID()
        _ = try bundleStore.createBundle(.initialEncryptedBundle(meetingID: meetingID, title: "Fanout failure"))
        let engine = SingleFrameCaptureRecordingEngine()
        let service = CaptureRecordingService(engine: engine, chunkWriter: writer)

        do {
            _ = try await service.record(
                CaptureRecordingRequest(
                    meetingID: meetingID,
                    sourceID: engine.source.id,
                    includeMicrophone: false,
                    frameConsumers: [FailingServiceFrameConsumer()]
                )
            )
            XCTFail("Expected durable delivery failure to interrupt capture")
        } catch let error as CaptureRecordingError {
            guard case let .interrupted(sourceID, _, reason) = error else {
                return XCTFail("Expected recoverable interruption, got \(error)")
            }
            XCTAssertEqual(sourceID, engine.source.id)
            XCTAssertTrue(reason.contains("failing-service-consumer"))
            XCTAssertTrue(reason.contains("consumerFailed"))
        }
    }

    func testCanonicalPCMConverterInterleavesFloat32AndComputesExactRMS() throws {
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 2,
                interleaved: false
            )
        )
        var left: [Float] = [0.5, -0.5]
        var right: [Float] = [0.25, -0.25]

        let frame = try left.withUnsafeMutableBytes { leftBytes in
            try right.withUnsafeMutableBytes { rightBytes in
                let buffers = AudioBufferList.allocate(maximumBuffers: 2)
                defer { free(buffers.unsafeMutablePointer) }
                buffers[0] = AudioBuffer(
                    mNumberChannels: 1,
                    mDataByteSize: UInt32(leftBytes.count),
                    mData: leftBytes.baseAddress
                )
                buffers[1] = AudioBuffer(
                    mNumberChannels: 1,
                    mDataByteSize: UInt32(rightBytes.count),
                    mData: rightBytes.baseAddress
                )
                return try CanonicalPCMFrameConverter.frame(
                    audioBufferList: UnsafePointer(buffers.unsafeMutablePointer),
                    format: format.streamDescription.pointee,
                    frameCount: 2,
                    sequence: 4,
                    track: .microphone,
                    meetingTime: 1.25
                )
            }
        }

        XCTAssertEqual(frame.sequence, 4)
        XCTAssertEqual(frame.sampleRate, 16_000)
        XCTAssertEqual(frame.channelCount, 2)
        XCTAssertEqual(frame.frameCount, 2)
        XCTAssertEqual(frame.floatSamples, [0.5, 0.25, -0.5, -0.25])
        XCTAssertEqual(frame.rmsLevel, sqrt(0.15625), accuracy: 0.000_001)
    }

    func testDirectAudioBufferGeometryRejectsMalformedLayoutsBeforeAllocationOrCopy() throws {
        let stereoInterleaved = testFloat32Format(channelCount: 2, isNonInterleaved: false)
        let stereoPlanar = testFloat32Format(channelCount: 2, isNonInterleaved: true)
        let cases: [(String, AudioStreamBasicDescription, [UInt32], [Int])] = [
            ("trailing partial interleaved frame", stereoInterleaved, [2], [12]),
            ("unequal planar byte sizes", stereoPlanar, [1, 1], [8, 4]),
            ("extra planar buffer", stereoPlanar, [1, 1, 1], [8, 8, 8]),
            ("mismatched planar channel metadata", stereoPlanar, [2, 1], [8, 8]),
            ("extra interleaved buffer", stereoInterleaved, [2, 0], [16, 16]),
            ("mismatched interleaved channel metadata", stereoInterleaved, [1], [16]),
        ]

        for (name, format, channelCounts, byteCounts) in cases {
            var allocationOrCopyAttempted = false
            XCTAssertThrowsError(
                try withTestAudioBufferList(channelCounts: channelCounts, byteCounts: byteCounts) { list in
                    try CanonicalPCMFrameConverter.withValidatedAudioBufferListGeometry(
                        audioBufferList: list,
                        format: format
                    ) { _ in
                        allocationOrCopyAttempted = true
                    }
                },
                name
            )
            XCTAssertFalse(allocationOrCopyAttempted, "\(name) reached allocation/copy")
        }
    }

    func testDirectAudioBufferGeometryAcceptsExactMonoAndStereoLayouts() throws {
        let layouts: [(String, AVAudioChannelCount, Bool, [UInt32], [Int])] = [
            ("mono interleaved", 1, true, [1], [8]),
            ("stereo interleaved", 2, true, [2], [16]),
            ("mono planar", 1, false, [1], [8]),
            ("stereo planar", 2, false, [1, 1], [8, 8]),
        ]

        for (name, channels, interleaved, channelCounts, byteCounts) in layouts {
            let format = testFloat32Format(
                channelCount: UInt32(channels),
                isNonInterleaved: !interleaved
            )
            let frame: CapturedPCMFrame
            do {
                frame = try withTestAudioBufferList(
                    channelCounts: channelCounts,
                    byteCounts: byteCounts
                ) { list in
                    try CanonicalPCMFrameConverter.withValidatedAudioBufferListGeometry(
                        audioBufferList: list,
                        format: format
                    ) { geometry in
                        XCTAssertEqual(geometry.frameCount, 2, name)
                        return try CanonicalPCMFrameConverter.frame(
                            audioBufferList: list,
                            format: format,
                            frameCount: geometry.frameCount,
                            sequence: 0,
                            track: .remoteSystem,
                            meetingTime: 0
                        )
                    }
                }
            } catch {
                XCTFail("\(name) failed: \(error)")
                continue
            }

            XCTAssertEqual(frame.channelCount, Int(channels), name)
            XCTAssertEqual(frame.frameCount, 2, name)
            XCTAssertEqual(frame.pcm.count, 2 * Int(channels) * MemoryLayout<Float>.size, name)
        }
    }

    func testSampleBufferGeometryRejectsMalformedPaddedAndExcessiveASBDBeforeAllocation() {
        let valid = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8,
            mFramesPerPacket: 1,
            mBytesPerFrame: 8,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        let cases: [(String, AudioStreamBasicDescription, Int, Int)] = [
            ("non-linear PCM", replacing(valid, formatID: kAudioFormatMPEG4AAC), 2, 16),
            ("unpacked PCM", replacing(valid, formatFlags: kAudioFormatFlagIsFloat), 2, 16),
            ("padded frame stride", replacing(valid, bytesPerPacket: 12, bytesPerFrame: 12), 2, 24),
            ("mismatched packet stride", replacing(valid, bytesPerPacket: 12), 2, 16),
            (
                "overflowing packet geometry",
                replacing(valid, bytesPerPacket: UInt32.max, framesPerPacket: UInt32.max),
                2,
                16
            ),
            ("excessive frames", valid, CapturedPCMFrame.maximumFrameCount + 1, 16),
            (
                "excessive channels",
                replacing(
                    valid,
                    bytesPerPacket: UInt32((CapturedPCMFrame.maximumChannelCount + 1) * 4),
                    bytesPerFrame: UInt32((CapturedPCMFrame.maximumChannelCount + 1) * 4),
                    channelsPerFrame: UInt32(CapturedPCMFrame.maximumChannelCount + 1)
                ),
                1,
                (CapturedPCMFrame.maximumChannelCount + 1) * 4
            ),
            ("insufficient source bytes", valid, 2, 15),
            ("padded source bytes", valid, 2, 20),
        ]

        for (name, format, frameCount, sourceByteCount) in cases {
            var allocationAttempted = false
            XCTAssertThrowsError(
                try CanonicalPCMFrameConverter.withValidatedSampleBufferGeometry(
                    format: format,
                    frameCount: frameCount,
                    sourceByteCount: sourceByteCount
                ) { _ in
                    allocationAttempted = true
                },
                name
            )
            XCTAssertFalse(allocationAttempted, "\(name) reached allocation/copy")
        }
    }

    func testProductionFrameConsumerSeamKeepsMeterASRAndDiarizationPreviewLanesIndependentAndNonfatal() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultPreviewConsumers-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = AESGCMDataVault(
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 0x52, count: 32))
        )
        let bundleStore = EncryptedMeetingBundleStore(rootDirectory: root, vault: vault)
        let writer = EncryptedAudioChunkWriter(bundleStore: bundleStore)
        let meetingID = UUID()
        _ = try bundleStore.createBundle(.initialEncryptedBundle(meetingID: meetingID, title: "Preview lanes"))

        let meter = BoundedPreviewFrameConsumer(id: "meter")
        let asr = BoundedPreviewFrameConsumer(id: "asr-preview")
        let diarization = BoundedPreviewFrameConsumer(id: "diarization-preview")
        let engine = PreviewLaneBurstCaptureEngine(consumers: [meter, asr, diarization])
        let drops = PreviewDropCountRecorder()
        let service = CaptureRecordingService(engine: engine, chunkWriter: writer)

        let result = try await service.record(
            CaptureRecordingRequest(
                meetingID: meetingID,
                sourceID: engine.source.id,
                includeMicrophone: false,
                frameConsumers: [meter, asr, diarization],
                previewDropHandler: { drops.record($0) }
            )
        )

        XCTAssertEqual(result.records.count, 1, "preview overflow must not fail durable capture")
        for consumer in [meter, asr, diarization] {
            let sequences = await consumer.sequences()
            let finishCount = await consumer.finishCount()
            let cancelCount = await consumer.cancelCount()
            XCTAssertEqual(sequences, [0, 5, 6, 7, 8, 9, 10, 11, 12])
            XCTAssertEqual(finishCount, 1)
            XCTAssertEqual(cancelCount, 0)
        }
        try await waitUntil("all independent preview drops are published") {
            drops.latest == 12
        }
    }

    func testRecordingLevelMonitorDistinguishesSilentFramesFromMissingFrames() async throws {
        let snapshots = RecordingLevelSnapshotRecorder()
        let monitor = RecordingLevelMonitor { snapshot in
            snapshots.append(snapshot)
        }
        let loud = try CapturedPCMFrame(
            sequence: 0,
            track: .microphone,
            meetingTime: 0,
            sampleRate: 48_000,
            channelCount: 1,
            frameCount: 2,
            pcm: [Float(0.5), -0.5].withUnsafeBytes { Data($0) }
        )
        let silent = try CapturedPCMFrame(
            sequence: 0,
            track: .remoteSystem,
            meetingTime: 0.01,
            sampleRate: 48_000,
            channelCount: 1,
            frameCount: 2,
            pcm: [Float(0), 0].withUnsafeBytes { Data($0) }
        )

        try await monitor.consume(loud)
        try await monitor.consume(silent)

        let snapshot = try XCTUnwrap(snapshots.values.last)
        XCTAssertEqual(snapshot.microphone, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.systemAudio, 0, accuracy: 0.000_001)
        XCTAssertNotNil(snapshot.lastMicrophoneFrameAt)
        XCTAssertNotNil(snapshot.lastSystemFrameAt)
    }

    func testMockActiveCaptureEmitsChangingSyntheticMicrophoneLevelsUntilStopped() async throws {
        let source = CaptureSource(id: "mock-levels", displayName: "Mock Levels", mode: .microphone)
        let engine = MockCaptureRecordingEngine(
            sources: [source],
            chunks: [],
            healthReport: .healthyMock,
            emitsSyntheticFramesDuringActiveRecording: true
        )
        let snapshots = RecordingLevelSnapshotRecorder()
        let monitor = RecordingLevelMonitor { snapshot in snapshots.append(snapshot) }
        let fanout = CaptureFrameFanout()
        fanout.register(monitor, capacity: 8)
        let stopSignal = CaptureRecordingStopSignal()
        let task = Task {
            try await engine.record(CaptureRecordingRequest(
                meetingID: UUID(),
                sourceID: source.id,
                includeMicrophone: true,
                stopSignal: stopSignal,
                frameEmitter: CaptureFrameEmitter(fanout: fanout)
            ))
        }

        try await Task.sleep(for: .milliseconds(550))
        stopSignal.requestStop()
        _ = try await task.value
        try await fanout.finish()

        XCTAssertGreaterThanOrEqual(Set(snapshots.values.map(\.microphone)).count, 2)
        XCTAssertTrue(snapshots.values.contains { $0.microphone > 0.1 })
    }

    func testAuthoritativeFramesAreCheckpointedAsEncryptedPlayableWAV() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultAuthoritativeFrames-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = AESGCMDataVault(
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 0x37, count: 32))
        )
        let bundleStore = EncryptedMeetingBundleStore(rootDirectory: root, vault: vault)
        let writer = EncryptedAudioChunkWriter(bundleStore: bundleStore)
        let meetingID = UUID()
        _ = try bundleStore.createBundle(.initialEncryptedBundle(meetingID: meetingID, title: "Frames"))
        let source = CaptureSource(
            id: "authoritative-frames",
            displayName: "Authoritative Frames",
            mode: .microphone,
            isRecommended: true
        )
        let engine = AuthoritativeFrameCaptureEngine(source: source)
        let service = CaptureRecordingService(engine: engine, chunkWriter: writer)

        let result = try await service.record(
            CaptureRecordingRequest(
                meetingID: meetingID,
                sourceID: source.id,
                includeMicrophone: true,
                microphoneDeviceID: "test-mic"
            )
        )

        XCTAssertEqual(result.records.map(\.track), [.microphone, .microphone])
        XCTAssertGreaterThan(result.records[1].startTime, result.records[0].startTime)
        let decrypted = try writer.readChunk(try XCTUnwrap(result.records.first), meetingID: meetingID)
        XCTAssertEqual(String(decoding: decrypted.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: decrypted.dropFirst(8).prefix(4), as: UTF8.self), "WAVE")
        XCTAssertEqual(engine.fanoutWasProvided, true)
    }

    func testLinearPCMAccumulatorProducesPlayableWAVCheckpoint() throws {
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 2,
                interleaved: true
            )
        )
        var samples: [Float] = [0, 0, 0.25, -0.25, 0.5, -0.5, 0, 0]
        let accumulator = LinearPCMAudioChunkAccumulator()

        try samples.withUnsafeMutableBytes { bytes in
            var audioBufferList = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 2,
                    mDataByteSize: UInt32(bytes.count),
                    mData: bytes.baseAddress
                )
            )
            try withUnsafePointer(to: &audioBufferList) {
                try accumulator.append(
                    audioBufferList: $0,
                    format: format.streamDescription.pointee,
                    frameCount: 4
                )
            }
        }

        let chunk = try XCTUnwrap(accumulator.finishChunk())
        XCTAssertEqual(String(decoding: chunk.data.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: chunk.data.dropFirst(8).prefix(4), as: UTF8.self), "WAVE")
        XCTAssertEqual(chunk.duration, 4.0 / 16_000.0, accuracy: 0.000_001)
        let player = try AVAudioPlayer(data: chunk.data)
        XCTAssertEqual(player.format.sampleRate, 16_000)
        XCTAssertEqual(player.format.channelCount, 2)
    }

    func testSystemAndMicrophoneEngineCapturesIncomingAudioAndSelectedMicrophoneTogether() async throws {
        let systemEngine = MockCaptureRecordingEngine(
            id: "system",
            mode: .systemAudio,
            sources: [CaptureSource(id: "system", displayName: "System", mode: .systemAudio, isRecommended: true, level: 0)],
            chunks: [CapturedAudioChunk(track: .remoteSystem, data: Data("teams audio".utf8), startTime: 0, duration: 2, codec: "PCM")],
            healthReport: CaptureHealthReport(remoteDropouts: 0, microphoneDropouts: 0, remoteClippingPercent: 0, microphoneClippingPercent: 0, silentPeriods: [], deviceChanges: [], transcriptionEngine: "pending", intelligenceProvider: "pending")
        )
        let microphoneEngine = MockCaptureRecordingEngine(
            id: "microphone",
            mode: .microphone,
            sources: [CaptureSource(id: "microphone", displayName: "Microphone", mode: .microphone, isRecommended: true, level: 0)],
            chunks: [CapturedAudioChunk(track: .microphone, data: Data("my voice".utf8), startTime: 0, duration: 2, codec: "PCM")],
            healthReport: CaptureHealthReport(remoteDropouts: 0, microphoneDropouts: 0, remoteClippingPercent: 0, microphoneClippingPercent: 0, silentPeriods: [], deviceChanges: [], transcriptionEngine: "pending", intelligenceProvider: "pending")
        )
        let source = CaptureSource(
            id: "combined",
            displayName: "Meeting Audio + Selected Microphone",
            mode: .systemAudio,
            isRecommended: true,
            level: 0
        )
        let engine = SystemAndMicrophoneCaptureEngine(
            source: source,
            systemSourceID: "system",
            microphoneSourceID: "microphone",
            systemEngine: systemEngine,
            microphoneEngine: microphoneEngine
        )

        let output = try await engine.record(
            CaptureRecordingRequest(
                meetingID: UUID(),
                sourceID: "combined",
                includeMicrophone: true,
                microphoneDeviceID: "airpods"
            )
        )

        XCTAssertEqual(Set(output.chunks.map(\.track)), [.remoteSystem, .microphone])
        XCTAssertEqual(systemEngine.recordingRequests.map(\.sourceID), ["system"])
        XCTAssertEqual(microphoneEngine.recordingRequests.map(\.sourceID), ["microphone"])
    }

    func testSystemAndMicrophoneEngineStopsSiblingCaptureWhenOneTrackFails() async throws {
        let stopSignal = CaptureRecordingStopSignal()
        let waitingEngine = StopObservingCaptureRecordingEngine()
        let source = CaptureSource(id: "combined", displayName: "Combined", mode: .systemAudio, isRecommended: true, level: 0)
        let engine = SystemAndMicrophoneCaptureEngine(
            source: source,
            systemSourceID: "system",
            microphoneSourceID: "microphone",
            systemEngine: ImmediateFailingCaptureRecordingEngine(),
            microphoneEngine: waitingEngine
        )

        do {
            _ = try await engine.record(
                CaptureRecordingRequest(
                    meetingID: UUID(),
                    sourceID: "combined",
                    includeMicrophone: true,
                    stopSignal: stopSignal
                )
            )
            XCTFail("Expected combined capture to surface the failed track")
        } catch {
            XCTAssertTrue(stopSignal.isStopRequested)
            XCTAssertTrue(waitingEngine.didObserveStop)
        }
    }

    func testCoreAudioCaptureEngineReportsReleaseGateAdapterID() {
        XCTAssertEqual(CoreAudioTapCaptureEngine().id, "core-audio-process-tap")
    }

    func testMockCaptureRecordingPersistsRemoteAndMicrophoneChunks() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultCapture-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let vault = AESGCMDataVault(
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 13, count: 32))
        )
        let bundleStore = EncryptedMeetingBundleStore(rootDirectory: root, vault: vault)
        let writer = EncryptedAudioChunkWriter(bundleStore: bundleStore)
        let meetingID = UUID()
        var manifest = MeetingBundleManifest.initialEncryptedBundle(
            meetingID: meetingID,
            title: "Capture mock"
        )
        manifest.createdAt = Date(timeIntervalSince1970: 1_780_000_300)
        _ = try bundleStore.createBundle(manifest)

        let engine = MockCaptureRecordingEngine(
            sources: [
                CaptureSource(
                    id: "zoom",
                    displayName: "Zoom.us",
                    bundleIdentifier: "us.zoom.xos",
                    mode: .selectedApplication,
                    isRecommended: true,
                    level: 0.8
                )
            ],
            chunks: [
                CapturedAudioChunk(track: .remoteSystem, data: Data("remote pcm".utf8), startTime: 0, duration: 30, codec: "CAF/LPCM"),
                CapturedAudioChunk(track: .microphone, data: Data("mic pcm".utf8), startTime: 0, duration: 30, codec: "CAF/LPCM")
            ],
            healthReport: CaptureHealthReport(
                remoteDropouts: 0,
                microphoneDropouts: 0,
                remoteClippingPercent: 0,
                microphoneClippingPercent: 0,
                silentPeriods: [],
                deviceChanges: [],
                transcriptionEngine: "mock",
                intelligenceProvider: "mock"
            )
        )
        let service = CaptureRecordingService(engine: engine, chunkWriter: writer)

        let sources = try await service.availableSources()
        let result = try await service.record(
            CaptureRecordingRequest(
                meetingID: meetingID,
                sourceID: "zoom",
                includeMicrophone: true,
                microphoneDeviceID: "airpods-pro",
                microphoneDeviceName: "Sikor AirPods Pro"
            )
        )

        XCTAssertEqual(sources.first?.displayName, "Zoom.us")
        XCTAssertEqual(result.records.map(\.track), [.remoteSystem, .microphone])
        XCTAssertEqual(result.microphoneDeviceID, "airpods-pro")
        XCTAssertEqual(result.microphoneDeviceName, "Sikor AirPods Pro")
        XCTAssertEqual(result.healthReport.severity, .healthy)
        XCTAssertEqual(try writer.readCheckpoint(meetingID: meetingID, track: .remoteSystem).chunks.count, 1)
        XCTAssertEqual(try writer.readCheckpoint(meetingID: meetingID, track: .microphone).chunks.count, 1)
        XCTAssertEqual(try writer.readChunk(result.records[0], meetingID: meetingID), Data("remote pcm".utf8))
        XCTAssertEqual(engine.recordingRequests.map(\.sourceID), ["zoom"])
        XCTAssertEqual(engine.recordingRequests.map(\.microphoneDeviceID), ["airpods-pro"])
    }

    func testCaptureRecordingCheckpointsStreamedChunkBeforeEngineFinishes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultStreamingCapture-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let vault = AESGCMDataVault(
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 31, count: 32))
        )
        let bundleStore = EncryptedMeetingBundleStore(rootDirectory: root, vault: vault)
        let writer = EncryptedAudioChunkWriter(bundleStore: bundleStore)
        let meetingID = UUID()
        _ = try bundleStore.createBundle(.initialEncryptedBundle(meetingID: meetingID, title: "Streaming capture"))
        let releaseEngine = CaptureRecordingStopSignal()
        let engine = StreamingCheckpointCaptureRecordingEngine(
            releaseSignal: releaseEngine,
            source: CaptureSource(
                id: "coreaudio-system-audio",
                displayName: "Core Audio System Audio",
                mode: .systemAudio,
                isRecommended: true,
                level: 0
            ),
            chunk: CapturedAudioChunk(
                track: .remoteSystem,
                data: Data("streamed remote pcm".utf8),
                startTime: 0,
                duration: 2,
                codec: "CoreAudioTap/PCM"
            )
        )
        let service = CaptureRecordingService(engine: engine, chunkWriter: writer)

        let task = Task {
            try await service.record(
                CaptureRecordingRequest(
                    meetingID: meetingID,
                    sourceID: "coreaudio-system-audio",
                    includeMicrophone: false
                )
            )
        }
        try await waitUntil("streamed checkpoint is written before capture finishes") {
            (try? writer.readCheckpoint(meetingID: meetingID, track: .remoteSystem).chunks.count) == 1
        }
        XCTAssertFalse(engine.didFinish)

        releaseEngine.requestStop()
        let result = try await task.value

        XCTAssertEqual(result.records.map(\.track), [.remoteSystem])
        XCTAssertEqual(try writer.readChunk(result.records[0], meetingID: meetingID), Data("streamed remote pcm".utf8))
        XCTAssertTrue(engine.didFinish)
    }

    func testCaptureRecordingReportsInterruptedCaptureAfterCheckpointedChunks() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultInterruptedCapture-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let vault = AESGCMDataVault(
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 32, count: 32))
        )
        let bundleStore = EncryptedMeetingBundleStore(rootDirectory: root, vault: vault)
        let writer = EncryptedAudioChunkWriter(bundleStore: bundleStore)
        let meetingID = UUID()
        _ = try bundleStore.createBundle(.initialEncryptedBundle(meetingID: meetingID, title: "Interrupted capture"))
        let engine = FailingAfterStreamingCaptureRecordingEngine(
            source: CaptureSource(
                id: "coreaudio-system-audio",
                displayName: "Core Audio System Audio",
                mode: .systemAudio,
                isRecommended: true,
                level: 0
            ),
            chunk: CapturedAudioChunk(
                track: .remoteSystem,
                data: Data("checkpoint before disconnect".utf8),
                startTime: 0,
                duration: 3,
                codec: "CoreAudioTap/PCM"
            )
        )
        let service = CaptureRecordingService(engine: engine, chunkWriter: writer)

        do {
            _ = try await service.record(
                CaptureRecordingRequest(
                    meetingID: meetingID,
                    sourceID: "coreaudio-system-audio",
                    includeMicrophone: false
                )
            )
            XCTFail("Expected interrupted capture to throw")
        } catch {
            XCTAssertEqual(
                error as? CaptureRecordingError,
                .interrupted(
                    sourceID: "coreaudio-system-audio",
                    checkpointedChunkCount: 1,
                    reason: "System source disappeared during capture"
                )
            )
        }

        let checkpoint = try writer.readCheckpoint(meetingID: meetingID, track: .remoteSystem)
        XCTAssertEqual(checkpoint.chunks.count, 1)
        XCTAssertEqual(
            try writer.readChunk(checkpoint.chunks[0], meetingID: meetingID),
            Data("checkpoint before disconnect".utf8)
        )
    }

    func testMockCaptureRecordingFailsWhenRequestedSourceIsUnavailable() async throws {
        let engine = MockCaptureRecordingEngine(sources: [], chunks: [], healthReport: .healthyMock)
        let service = CaptureRecordingService(
            engine: engine,
            chunkWriter: EncryptedAudioChunkWriter(
                bundleStore: EncryptedMeetingBundleStore(
                    rootDirectory: FileManager.default.temporaryDirectory,
                    vault: AESGCMDataVault(
                        keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 15, count: 32))
                    )
                )
            )
        )

        do {
            _ = try await service.record(
                CaptureRecordingRequest(meetingID: UUID(), sourceID: "missing", includeMicrophone: false)
            )
            XCTFail("Expected missing source to fail")
        } catch {
            XCTAssertEqual(error as? CaptureRecordingError, .sourceUnavailable("missing"))
        }
    }

    func testCaptureRecordingFailsWhenSelectedMicrophoneIsUnavailable() async throws {
        let engine = MockCaptureRecordingEngine(
            sources: [
                CaptureSource(
                    id: "teams",
                    displayName: "Microsoft Teams",
                    bundleIdentifier: "com.microsoft.teams2",
                    mode: .selectedApplication,
                    isRecommended: true,
                    level: 0.71
                )
            ],
            chunks: [
                CapturedAudioChunk(track: .remoteSystem, data: Data("remote pcm".utf8), startTime: 0, duration: 30, codec: "CAF/LPCM")
            ],
            healthReport: .healthyMock
        )
        let provider = MockAudioInputDeviceProvider(
            devices: [
                AudioInputDevice(
                    id: "studio",
                    displayName: "Studio Display Microphone",
                    transportLabel: "Built-in",
                    isDefault: true
                )
            ]
        )
        let service = CaptureRecordingService(
            engine: engine,
            chunkWriter: EncryptedAudioChunkWriter(
                bundleStore: EncryptedMeetingBundleStore(
                    rootDirectory: FileManager.default.temporaryDirectory,
                    vault: AESGCMDataVault(
                        keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 16, count: 32))
                    )
                )
            ),
            audioInputDeviceProvider: provider
        )

        do {
            _ = try await service.record(
                CaptureRecordingRequest(
                    meetingID: UUID(),
                    sourceID: "teams",
                    includeMicrophone: true,
                    microphoneDeviceID: "airpods",
                    microphoneDeviceName: "Sikor AirPods Pro"
                )
            )
            XCTFail("Expected disconnected selected microphone to fail")
        } catch {
            XCTAssertEqual(
                error as? CaptureRecordingError,
                .microphoneUnavailable(id: "airpods", name: "Sikor AirPods Pro")
            )
        }

        XCTAssertTrue(engine.recordingRequests.isEmpty)
    }

    func testAVFoundationSelectedMicrophoneCaptureEngineUsesSelectedDevice() async throws {
        let recorder = CapturingSelectedMicrophoneAudioCapturer(
            chunk: CapturedAudioChunk(
                track: .microphone,
                data: Data("selected mic pcm".utf8),
                startTime: 0,
                duration: 12,
                codec: "AVCaptureAudio/CMSampleBuffer"
            )
        )
        let engine = AVFoundationSelectedMicrophoneCaptureEngine(capturer: recorder)
        let sources = try await engine.availableSources()
        let source = try XCTUnwrap(sources.first)
        let stopSignal = CaptureRecordingStopSignal()
        let frameEmitter = CaptureFrameEmitter(fanout: CaptureFrameFanout())
        try frameEmitter.emitCanonicalPCM(
            [Float(0.2)].withUnsafeBytes { Data($0) },
            sampleRate: 48_000,
            channelCount: 1,
            frameCount: 1,
            track: .remoteSystem
        )

        let output = try await engine.record(
            CaptureRecordingRequest(
                meetingID: UUID(),
                sourceID: source.id,
                includeMicrophone: true,
                microphoneDeviceID: "airpods",
                microphoneDeviceName: "Sikor AirPods Pro",
                maximumDuration: 12,
                stopSignal: stopSignal,
                frameEmitter: frameEmitter
            )
        )

        XCTAssertEqual(output.chunks.map(\.track), [.microphone])
        XCTAssertEqual(output.healthReport.transcriptionEngine, "pending")
        XCTAssertEqual(recorder.requests.map(\.deviceID), ["airpods"])
        XCTAssertEqual(recorder.requests.map(\.deviceName), ["Sikor AirPods Pro"])
        XCTAssertEqual(recorder.requests.map(\.maximumDuration), [12])
        XCTAssertEqual(recorder.requests.map { $0.stopSignal === stopSignal }, [true])
        XCTAssertTrue(recorder.requests.first?.frameEmitter === frameEmitter)
    }

    func testAVFoundationSelectedMicrophoneCaptureEngineRequiresSelectedDevice() async throws {
        let recorder = CapturingSelectedMicrophoneAudioCapturer(
            chunk: CapturedAudioChunk(
                track: .microphone,
                data: Data("unused".utf8),
                startTime: 0,
                duration: 1,
                codec: "AVCaptureAudio/CMSampleBuffer"
            )
        )
        let engine = AVFoundationSelectedMicrophoneCaptureEngine(capturer: recorder)
        let sources = try await engine.availableSources()
        let source = try XCTUnwrap(sources.first)

        do {
            _ = try await engine.record(
                CaptureRecordingRequest(
                    meetingID: UUID(),
                    sourceID: source.id,
                    includeMicrophone: true
                )
            )
            XCTFail("Expected selected microphone capture to require a microphone device ID")
        } catch {
            XCTAssertEqual(error as? CaptureRecordingError, .microphoneUnavailable(id: "selected-microphone", name: nil))
        }

        XCTAssertTrue(recorder.requests.isEmpty)
    }

    func testAVFoundationSelectedMicrophoneCaptureEngineCheckpointsStreamedChunkBeforeCapturerCompletes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultSelectedMicrophoneStreaming-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let vault = AESGCMDataVault(
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 22, count: 32))
        )
        let bundleStore = EncryptedMeetingBundleStore(rootDirectory: root, vault: vault)
        let writer = EncryptedAudioChunkWriter(bundleStore: bundleStore)
        let meetingID = UUID()
        _ = try bundleStore.createBundle(.initialEncryptedBundle(meetingID: meetingID, title: "Selected mic stream"))
        let releaseCapturer = CaptureRecordingStopSignal()
        let capturer = StreamingSelectedMicrophoneAudioCapturer(
            releaseSignal: releaseCapturer,
            chunk: CapturedAudioChunk(
                track: .microphone,
                data: Data("streamed selected microphone".utf8),
                startTime: 0,
                duration: 2,
                codec: "AVCaptureAudio/CMSampleBuffer"
            )
        )
        let engine = AVFoundationSelectedMicrophoneCaptureEngine(capturer: capturer)
        let service = CaptureRecordingService(engine: engine, chunkWriter: writer)
        let sources = try await engine.availableSources()
        let source = try XCTUnwrap(sources.first)

        let task = Task {
            try await service.record(
                CaptureRecordingRequest(
                    meetingID: meetingID,
                    sourceID: source.id,
                    includeMicrophone: true,
                    microphoneDeviceID: "airpods",
                    microphoneDeviceName: "Sikor AirPods Pro",
                    maximumDuration: 10
                )
            )
        }
        try await waitUntil("selected microphone streamed checkpoint is written before capture finishes") {
            (try? writer.readCheckpoint(meetingID: meetingID, track: .microphone).chunks.count) == 1
        }
        XCTAssertFalse(capturer.didFinish)

        releaseCapturer.requestStop()
        let result = try await task.value

        XCTAssertEqual(result.records.map(\.track), [.microphone])
        XCTAssertEqual(try writer.readChunk(result.records[0], meetingID: meetingID), Data("streamed selected microphone".utf8))
        XCTAssertEqual(result.microphoneDeviceID, "airpods")
        XCTAssertTrue(capturer.didFinish)
    }

    func testScreenCaptureKitSystemAudioEngineUsesFallbackSource() async throws {
        let capturer = CapturingScreenCaptureKitSystemAudioCapturer(
            chunk: CapturedAudioChunk(
                track: .remoteSystem,
                data: Data("system audio pcm".utf8),
                startTime: 0,
                duration: 9,
                codec: "ScreenCaptureKit/CMSampleBuffer"
            )
        )
        let engine = ScreenCaptureKitSystemAudioCaptureEngine(capturer: capturer)
        let sources = try await engine.availableSources()
        let source = try XCTUnwrap(sources.first)
        let stopSignal = CaptureRecordingStopSignal()
        let frameEmitter = CaptureFrameEmitter(fanout: CaptureFrameFanout())

        let output = try await engine.record(
            CaptureRecordingRequest(
                meetingID: UUID(),
                sourceID: source.id,
                includeMicrophone: false,
                maximumDuration: 9,
                stopSignal: stopSignal,
                frameEmitter: frameEmitter
            )
        )

        XCTAssertEqual(source.mode, .screenCaptureFallback)
        XCTAssertEqual(output.chunks.map(\.track), [.remoteSystem])
        XCTAssertEqual(output.healthReport.remoteDropouts, 0)
        XCTAssertEqual(output.healthReport.microphoneDropouts, 0)
        XCTAssertEqual(capturer.requests.map(\.sourceID), [source.id])
        XCTAssertEqual(capturer.requests.map(\.maximumDuration), [9])
        XCTAssertEqual(capturer.requests.map { $0.stopSignal === stopSignal }, [true])
        XCTAssertTrue(capturer.requests.first?.frameEmitter === frameEmitter)
    }

    func testScreenCaptureKitSystemAudioEnginePersistsEncryptedRemoteChunk() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultScreenCaptureKit-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let vault = AESGCMDataVault(
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 24, count: 32))
        )
        let bundleStore = EncryptedMeetingBundleStore(rootDirectory: root, vault: vault)
        let writer = EncryptedAudioChunkWriter(bundleStore: bundleStore)
        let meetingID = UUID()
        _ = try bundleStore.createBundle(.initialEncryptedBundle(meetingID: meetingID, title: "SCK fallback"))

        let engine = ScreenCaptureKitSystemAudioCaptureEngine(
            capturer: CapturingScreenCaptureKitSystemAudioCapturer(
                chunk: CapturedAudioChunk(
                    track: .remoteSystem,
                    data: Data("fallback system audio".utf8),
                    startTime: 0,
                    duration: 12,
                    codec: "ScreenCaptureKit/CMSampleBuffer"
                )
            )
        )
        let service = CaptureRecordingService(engine: engine, chunkWriter: writer)
        let sources = try await engine.availableSources()
        let source = try XCTUnwrap(sources.first)

        let result = try await service.record(
            CaptureRecordingRequest(
                meetingID: meetingID,
                sourceID: source.id,
                includeMicrophone: false,
                maximumDuration: 12
            )
        )

        XCTAssertEqual(result.records.map(\.track), [.remoteSystem])
        XCTAssertEqual(try writer.readChunk(result.records[0], meetingID: meetingID), Data("fallback system audio".utf8))
        XCTAssertEqual(try writer.readCheckpoint(meetingID: meetingID, track: .remoteSystem).chunks.count, 1)
        XCTAssertNil(result.microphoneDeviceID)
    }

    func testScreenCaptureKitSystemAudioEngineCheckpointsStreamedChunkBeforeCapturerCompletes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultScreenCaptureKitStreaming-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let vault = AESGCMDataVault(
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 21, count: 32))
        )
        let bundleStore = EncryptedMeetingBundleStore(rootDirectory: root, vault: vault)
        let writer = EncryptedAudioChunkWriter(bundleStore: bundleStore)
        let meetingID = UUID()
        _ = try bundleStore.createBundle(.initialEncryptedBundle(meetingID: meetingID, title: "SCK stream"))
        let releaseCapturer = CaptureRecordingStopSignal()
        let capturer = StreamingScreenCaptureKitSystemAudioCapturer(
            releaseSignal: releaseCapturer,
            chunk: CapturedAudioChunk(
                track: .remoteSystem,
                data: Data("streamed screen capture kit".utf8),
                startTime: 0,
                duration: 2,
                codec: "ScreenCaptureKit/CMSampleBuffer"
            )
        )
        let engine = ScreenCaptureKitSystemAudioCaptureEngine(capturer: capturer)
        let service = CaptureRecordingService(engine: engine, chunkWriter: writer)
        let sources = try await engine.availableSources()
        let source = try XCTUnwrap(sources.first)

        let task = Task {
            try await service.record(
                CaptureRecordingRequest(
                    meetingID: meetingID,
                    sourceID: source.id,
                    includeMicrophone: false,
                    maximumDuration: 10
                )
            )
        }
        try await waitUntil("ScreenCaptureKit streamed checkpoint is written before capture finishes") {
            (try? writer.readCheckpoint(meetingID: meetingID, track: .remoteSystem).chunks.count) == 1
        }
        XCTAssertFalse(capturer.didFinish)

        releaseCapturer.requestStop()
        let result = try await task.value

        XCTAssertEqual(result.records.map(\.track), [.remoteSystem])
        XCTAssertEqual(try writer.readChunk(result.records[0], meetingID: meetingID), Data("streamed screen capture kit".utf8))
        XCTAssertNil(result.microphoneDeviceID)
        XCTAssertTrue(capturer.didFinish)
    }

    func testCoreAudioTapCaptureEngineUsesSystemSource() async throws {
        let capturer = CapturingCoreAudioTapCapturer(
            chunk: CapturedAudioChunk(
                track: .remoteSystem,
                data: Data("core audio pcm".utf8),
                startTime: 0,
                duration: 11,
                codec: "CoreAudioTap/PCM"
            )
        )
        let engine = CoreAudioTapCaptureEngine(capturer: capturer)
        let sources = try await engine.availableSources()
        let source = try XCTUnwrap(sources.first)
        let stopSignal = CaptureRecordingStopSignal()
        let frameEmitter = CaptureFrameEmitter(fanout: CaptureFrameFanout())

        let output = try await engine.record(
            CaptureRecordingRequest(
                meetingID: UUID(),
                sourceID: source.id,
                includeMicrophone: false,
                maximumDuration: 11,
                stopSignal: stopSignal,
                frameEmitter: frameEmitter
            )
        )

        XCTAssertEqual(source.mode, .systemAudio)
        XCTAssertEqual(output.chunks.map(\.track), [.remoteSystem])
        XCTAssertEqual(output.healthReport.remoteDropouts, 0)
        XCTAssertEqual(capturer.requests.map(\.sourceID), [source.id])
        XCTAssertEqual(capturer.requests.map(\.maximumDuration), [11])
        XCTAssertEqual(capturer.requests.map { $0.stopSignal === stopSignal }, [true])
        XCTAssertTrue(capturer.requests.first?.frameEmitter === frameEmitter)
    }

    func testCoreAudioTapCaptureEnginePersistsEncryptedRemoteChunk() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultCoreAudio-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let vault = AESGCMDataVault(
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 25, count: 32))
        )
        let bundleStore = EncryptedMeetingBundleStore(rootDirectory: root, vault: vault)
        let writer = EncryptedAudioChunkWriter(bundleStore: bundleStore)
        let meetingID = UUID()
        _ = try bundleStore.createBundle(.initialEncryptedBundle(meetingID: meetingID, title: "Core Audio tap"))

        let engine = CoreAudioTapCaptureEngine(
            capturer: CapturingCoreAudioTapCapturer(
                chunk: CapturedAudioChunk(
                    track: .remoteSystem,
                    data: Data("core audio tap system audio".utf8),
                    startTime: 0,
                    duration: 13,
                    codec: "CoreAudioTap/PCM"
                )
            )
        )
        let service = CaptureRecordingService(engine: engine, chunkWriter: writer)
        let sources = try await engine.availableSources()
        let source = try XCTUnwrap(sources.first)

        let result = try await service.record(
            CaptureRecordingRequest(
                meetingID: meetingID,
                sourceID: source.id,
                includeMicrophone: false,
                maximumDuration: 13
            )
        )

        XCTAssertEqual(result.records.map(\.track), [.remoteSystem])
        XCTAssertEqual(try writer.readChunk(result.records[0], meetingID: meetingID), Data("core audio tap system audio".utf8))
        XCTAssertEqual(try writer.readCheckpoint(meetingID: meetingID, track: .remoteSystem).chunks.count, 1)
        XCTAssertNil(result.microphoneDeviceID)
    }

    func testCoreAudioTapCaptureEngineCheckpointsStreamedChunkBeforeCapturerCompletes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultCoreAudioStreaming-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let vault = AESGCMDataVault(
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 23, count: 32))
        )
        let bundleStore = EncryptedMeetingBundleStore(rootDirectory: root, vault: vault)
        let writer = EncryptedAudioChunkWriter(bundleStore: bundleStore)
        let meetingID = UUID()
        _ = try bundleStore.createBundle(.initialEncryptedBundle(meetingID: meetingID, title: "Core Audio stream"))
        let releaseCapturer = CaptureRecordingStopSignal()
        let capturer = StreamingCoreAudioTapCapturer(
            releaseSignal: releaseCapturer,
            chunk: CapturedAudioChunk(
                track: .remoteSystem,
                data: Data("streamed core audio tap".utf8),
                startTime: 0,
                duration: 2,
                codec: "CoreAudioTap/PCM"
            )
        )
        let engine = CoreAudioTapCaptureEngine(capturer: capturer)
        let service = CaptureRecordingService(engine: engine, chunkWriter: writer)
        let sources = try await engine.availableSources()
        let source = try XCTUnwrap(sources.first)

        let task = Task {
            try await service.record(
                CaptureRecordingRequest(
                    meetingID: meetingID,
                    sourceID: source.id,
                    includeMicrophone: false,
                    maximumDuration: 10
                )
            )
        }
        try await waitUntil("Core Audio streamed checkpoint is written before capture finishes") {
            (try? writer.readCheckpoint(meetingID: meetingID, track: .remoteSystem).chunks.count) == 1
        }
        XCTAssertFalse(capturer.didFinish)

        releaseCapturer.requestStop()
        let result = try await task.value

        XCTAssertEqual(result.records.map(\.track), [.remoteSystem])
        XCTAssertEqual(try writer.readChunk(result.records[0], meetingID: meetingID), Data("streamed core audio tap".utf8))
        XCTAssertTrue(capturer.didFinish)
    }
}

private final class RecordingLevelSnapshotRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [RecordingLevelSnapshot] = []

    var values: [RecordingLevelSnapshot] { lock.withLock { storage } }

    func append(_ snapshot: RecordingLevelSnapshot) {
        lock.withLock { storage.append(snapshot) }
    }
}

private final class AuthoritativeFrameCaptureEngine: CaptureRecordingEngine, @unchecked Sendable {
    let id = "authoritative-frame-engine"
    let mode: CaptureMode = .microphone
    private let source: CaptureSource
    private let lock = NSLock()
    private var provided = false

    var fanoutWasProvided: Bool { lock.withLock { provided } }

    init(source: CaptureSource) {
        self.source = source
    }

    func availableSources() async throws -> [CaptureSource] { [source] }

    func record(_ request: CaptureRecordingRequest) async throws -> CaptureRecordingEngineOutput {
        let emitter = try XCTUnwrap(request.frameEmitter)
        lock.withLock { provided = true }
        let samples = Array(repeating: Float(0.25), count: 16_000)
        let pcm = samples.withUnsafeBytes { Data($0) }
        for _ in 0..<6 {
            try emitter.emitCanonicalPCM(
                pcm,
                sampleRate: 16_000,
                channelCount: 1,
                frameCount: samples.count,
                track: .microphone
            )
        }
        return CaptureRecordingEngineOutput(chunks: [], healthReport: .healthyMock)
    }
}

private final class CapturingSelectedMicrophoneAudioCapturer: SelectedMicrophoneAudioCapturing, @unchecked Sendable {
    private let lock = NSLock()
    private let chunk: CapturedAudioChunk
    private var storage: [SelectedMicrophoneCaptureRequest] = []

    var requests: [SelectedMicrophoneCaptureRequest] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    init(chunk: CapturedAudioChunk) {
        self.chunk = chunk
    }

    func capture(_ request: SelectedMicrophoneCaptureRequest) async throws -> CapturedAudioChunk {
        lock.withLock {
            storage.append(request)
        }
        return chunk
    }
}

private final class StreamingSelectedMicrophoneAudioCapturer: SelectedMicrophoneAudioCapturing, @unchecked Sendable {
    private let releaseSignal: CaptureRecordingStopSignal
    private let chunk: CapturedAudioChunk
    private let lock = NSLock()
    private var finished = false

    var didFinish: Bool {
        lock.withLock { finished }
    }

    init(releaseSignal: CaptureRecordingStopSignal, chunk: CapturedAudioChunk) {
        self.releaseSignal = releaseSignal
        self.chunk = chunk
    }

    func capture(_ request: SelectedMicrophoneCaptureRequest) async throws -> CapturedAudioChunk {
        try request.chunkSink?.write(chunk)
        await releaseSignal.waitUntilStopped()
        lock.withLock {
            finished = true
        }
        return chunk
    }
}

private final class CapturingScreenCaptureKitSystemAudioCapturer: ScreenCaptureKitSystemAudioCapturing, @unchecked Sendable {
    private let lock = NSLock()
    private let chunk: CapturedAudioChunk
    private var storage: [ScreenCaptureKitAudioCaptureRequest] = []

    var requests: [ScreenCaptureKitAudioCaptureRequest] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    init(chunk: CapturedAudioChunk) {
        self.chunk = chunk
    }

    func capture(_ request: ScreenCaptureKitAudioCaptureRequest) async throws -> CapturedAudioChunk {
        lock.withLock {
            storage.append(request)
        }
        return chunk
    }
}

private final class StreamingScreenCaptureKitSystemAudioCapturer: ScreenCaptureKitSystemAudioCapturing, @unchecked Sendable {
    private let releaseSignal: CaptureRecordingStopSignal
    private let chunk: CapturedAudioChunk
    private let lock = NSLock()
    private var finished = false

    var didFinish: Bool {
        lock.withLock { finished }
    }

    init(releaseSignal: CaptureRecordingStopSignal, chunk: CapturedAudioChunk) {
        self.releaseSignal = releaseSignal
        self.chunk = chunk
    }

    func capture(_ request: ScreenCaptureKitAudioCaptureRequest) async throws -> CapturedAudioChunk {
        try request.chunkSink?.write(chunk)
        await releaseSignal.waitUntilStopped()
        lock.withLock {
            finished = true
        }
        return chunk
    }
}

private final class CapturingCoreAudioTapCapturer: CoreAudioTapCapturing, @unchecked Sendable {
    private let lock = NSLock()
    private let chunk: CapturedAudioChunk
    private var storage: [CoreAudioTapCaptureRequest] = []

    var requests: [CoreAudioTapCaptureRequest] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    init(chunk: CapturedAudioChunk) {
        self.chunk = chunk
    }

    func capture(_ request: CoreAudioTapCaptureRequest) async throws -> CapturedAudioChunk {
        lock.withLock {
            storage.append(request)
        }
        return chunk
    }
}

private final class StreamingCoreAudioTapCapturer: CoreAudioTapCapturing, @unchecked Sendable {
    private let releaseSignal: CaptureRecordingStopSignal
    private let chunk: CapturedAudioChunk
    private let lock = NSLock()
    private var finished = false

    var didFinish: Bool {
        lock.withLock { finished }
    }

    init(releaseSignal: CaptureRecordingStopSignal, chunk: CapturedAudioChunk) {
        self.releaseSignal = releaseSignal
        self.chunk = chunk
    }

    func capture(_ request: CoreAudioTapCaptureRequest) async throws -> CapturedAudioChunk {
        try request.chunkSink?.write(chunk)
        await releaseSignal.waitUntilStopped()
        lock.withLock {
            finished = true
        }
        return chunk
    }
}

private final class StreamingCheckpointCaptureRecordingEngine: CaptureRecordingEngine, @unchecked Sendable {
    let id = "streaming-checkpoint-capture"
    let mode: CaptureMode = .systemAudio

    private let releaseSignal: CaptureRecordingStopSignal
    private let source: CaptureSource
    private let chunk: CapturedAudioChunk
    private let lock = NSLock()
    private var finished = false

    var didFinish: Bool {
        lock.withLock { finished }
    }

    init(
        releaseSignal: CaptureRecordingStopSignal,
        source: CaptureSource,
        chunk: CapturedAudioChunk
    ) {
        self.releaseSignal = releaseSignal
        self.source = source
        self.chunk = chunk
    }

    func availableSources() async throws -> [CaptureSource] {
        [source]
    }

    func record(_ request: CaptureRecordingRequest) async throws -> CaptureRecordingEngineOutput {
        try request.chunkSink?.write(chunk)
        await releaseSignal.waitUntilStopped()
        lock.withLock {
            finished = true
        }
        return CaptureRecordingEngineOutput(chunks: [], healthReport: .healthyMock)
    }
}

private enum InterruptedCaptureFixtureError: Error, LocalizedError {
    case sourceDisappeared

    var errorDescription: String? {
        "System source disappeared during capture"
    }
}

private enum CallbackRelayTestError: Error, Equatable {
    case conversionFailed
    case durabilityRejected
    case consumerFailed
    case screenCaptureStopFailed
}

private final class CallbackFrameRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var count: Int { lock.withLock { storage } }

    func record() {
        lock.withLock { storage += 1 }
    }
}

private struct DeterministicFinalCallbackProducer: Sendable {
    let callbackQueue: DispatchQueue
    let recorder: CallbackFrameRecorder

    func stop() {
        callbackQueue.async { recorder.record() }
    }
}

private actor BoundedPreviewFrameConsumer: CaptureFrameConsumer {
    nonisolated let id: String
    nonisolated let deliveryPolicy: CaptureFrameDeliveryPolicy = .preview
    private var storage: [UInt64] = []
    private var finishes = 0
    private var cancellations = 0
    private var firstConsumeEntered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(id: String) {
        self.id = id
    }

    func consume(_ frame: CapturedPCMFrame) async throws {
        storage.append(frame.sequence)
        guard storage.count == 1 else { return }
        firstConsumeEntered = true
        entryWaiters.forEach { $0.resume() }
        entryWaiters.removeAll()
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func finish() async throws {
        finishes += 1
    }

    func cancel() async {
        cancellations += 1
    }

    func waitUntilFirstConsumeEntered() async {
        guard !firstConsumeEntered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }

    func sequences() -> [UInt64] { storage }
    func finishCount() -> Int { finishes }
    func cancelCount() -> Int { cancellations }
}

private final class PreviewLaneBurstCaptureEngine: CaptureRecordingEngine, @unchecked Sendable {
    let id = "preview-lane-burst"
    let mode: CaptureMode = .systemAudio
    let source = CaptureSource(
        id: "preview-lane-burst-source",
        displayName: "Preview Lane Burst",
        mode: .systemAudio,
        isRecommended: true,
        level: 0
    )
    private let consumers: [BoundedPreviewFrameConsumer]

    init(consumers: [BoundedPreviewFrameConsumer]) {
        self.consumers = consumers
    }

    func availableSources() async throws -> [CaptureSource] {
        [source]
    }

    func record(_ request: CaptureRecordingRequest) async throws -> CaptureRecordingEngineOutput {
        let pcm = [Float(0.25), -0.25].withUnsafeBytes { Data($0) }
        try request.frameEmitter?.emitCanonicalPCM(
            pcm,
            sampleRate: 48_000,
            channelCount: 1,
            frameCount: 2,
            track: .remoteSystem
        )
        for consumer in consumers {
            await consumer.waitUntilFirstConsumeEntered()
        }
        for _ in 1...12 {
            try request.frameEmitter?.emitCanonicalPCM(
                pcm,
                sampleRate: 48_000,
                channelCount: 1,
                frameCount: 2,
                track: .remoteSystem
            )
        }
        for consumer in consumers {
            await consumer.release()
        }
        return CaptureRecordingEngineOutput(chunks: [], healthReport: .healthyMock)
    }
}

private final class PreviewDropCountRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var latest: Int { lock.withLock { storage } }

    func record(_ count: Int) {
        lock.withLock { storage = max(storage, count) }
    }
}

private func replacing(
    _ format: AudioStreamBasicDescription,
    formatID: AudioFormatID? = nil,
    formatFlags: AudioFormatFlags? = nil,
    bytesPerPacket: UInt32? = nil,
    framesPerPacket: UInt32? = nil,
    bytesPerFrame: UInt32? = nil,
    channelsPerFrame: UInt32? = nil,
    bitsPerChannel: UInt32? = nil
) -> AudioStreamBasicDescription {
    AudioStreamBasicDescription(
        mSampleRate: format.mSampleRate,
        mFormatID: formatID ?? format.mFormatID,
        mFormatFlags: formatFlags ?? format.mFormatFlags,
        mBytesPerPacket: bytesPerPacket ?? format.mBytesPerPacket,
        mFramesPerPacket: framesPerPacket ?? format.mFramesPerPacket,
        mBytesPerFrame: bytesPerFrame ?? format.mBytesPerFrame,
        mChannelsPerFrame: channelsPerFrame ?? format.mChannelsPerFrame,
        mBitsPerChannel: bitsPerChannel ?? format.mBitsPerChannel,
        mReserved: format.mReserved
    )
}

private final class SingleFrameCaptureRecordingEngine: CaptureRecordingEngine, @unchecked Sendable {
    let id = "single-frame"
    let mode: CaptureMode = .systemAudio
    let source = CaptureSource(
        id: "single-frame-source",
        displayName: "Single Frame Source",
        mode: .systemAudio,
        isRecommended: true,
        level: 0
    )

    func availableSources() async throws -> [CaptureSource] {
        [source]
    }

    func record(_ request: CaptureRecordingRequest) async throws -> CaptureRecordingEngineOutput {
        try request.frameEmitter?.emitCanonicalPCM(
            [Float(0.25), -0.25].withUnsafeBytes { Data($0) },
            sampleRate: 48_000,
            channelCount: 1,
            frameCount: 2,
            track: .remoteSystem
        )
        return CaptureRecordingEngineOutput(chunks: [], healthReport: .healthyMock)
    }
}

private actor FailingServiceFrameConsumer: CaptureFrameConsumer {
    nonisolated let id = "failing-service-consumer"
    nonisolated let deliveryPolicy: CaptureFrameDeliveryPolicy = .durable

    func consume(_ frame: CapturedPCMFrame) async throws {
        throw CallbackRelayTestError.consumerFailed
    }

    func finish() async throws {}
    func cancel() async {}
}

private final class CallbackFailureRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var failures: [String] {
        lock.withLock { storage }
    }

    func append(_ failure: String) {
        lock.withLock { storage.append(failure) }
    }
}

private final class CoreAudioShutdownEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.withLock { storage }
    }

    func append(_ event: String) {
        lock.withLock { storage.append(event) }
    }
}

private func withTestAudioBufferList<Output>(
    channelCounts: [UInt32],
    byteCounts: [Int],
    _ body: (UnsafePointer<AudioBufferList>) throws -> Output
) rethrows -> Output {
    precondition(channelCounts.count == byteCounts.count)
    precondition(!channelCounts.isEmpty)
    let list = AudioBufferList.allocate(maximumBuffers: channelCounts.count)
    let allocations = byteCounts.map { byteCount in
        UnsafeMutableRawPointer.allocate(
            byteCount: max(1, byteCount),
            alignment: MemoryLayout<Float>.alignment
        )
    }
    defer {
        allocations.forEach { $0.deallocate() }
        free(list.unsafeMutablePointer)
    }
    for index in channelCounts.indices {
        allocations[index].initializeMemory(as: UInt8.self, repeating: 0, count: byteCounts[index])
        list[index] = AudioBuffer(
            mNumberChannels: channelCounts[index],
            mDataByteSize: UInt32(byteCounts[index]),
            mData: allocations[index]
        )
    }
    return try body(UnsafePointer(list.unsafeMutablePointer))
}

private func testFloat32Format(
    channelCount: UInt32,
    isNonInterleaved: Bool
) -> AudioStreamBasicDescription {
    let bytesPerFrame = isNonInterleaved
        ? UInt32(MemoryLayout<Float>.size)
        : channelCount * UInt32(MemoryLayout<Float>.size)
    return AudioStreamBasicDescription(
        mSampleRate: 16_000,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat
            | kAudioFormatFlagIsPacked
            | (isNonInterleaved ? kAudioFormatFlagIsNonInterleaved : 0),
        mBytesPerPacket: bytesPerFrame,
        mFramesPerPacket: 1,
        mBytesPerFrame: bytesPerFrame,
        mChannelsPerFrame: channelCount,
        mBitsPerChannel: 32,
        mReserved: 0
    )
}

private final class ImmediateFailingCaptureRecordingEngine: CaptureRecordingEngine, @unchecked Sendable {
    let id = "immediate-failure"
    let mode: CaptureMode = .systemAudio

    func availableSources() async throws -> [CaptureSource] { [] }

    func record(_ request: CaptureRecordingRequest) async throws -> CaptureRecordingEngineOutput {
        throw InterruptedCaptureFixtureError.sourceDisappeared
    }
}

private final class StopObservingCaptureRecordingEngine: CaptureRecordingEngine, @unchecked Sendable {
    let id = "stop-observer"
    let mode: CaptureMode = .microphone
    private let lock = NSLock()
    private var observedStop = false

    var didObserveStop: Bool { lock.withLock { observedStop } }

    func availableSources() async throws -> [CaptureSource] { [] }

    func record(_ request: CaptureRecordingRequest) async throws -> CaptureRecordingEngineOutput {
        await request.stopSignal?.waitUntilStopped()
        lock.withLock { observedStop = true }
        return CaptureRecordingEngineOutput(chunks: [], healthReport: .healthyMock)
    }
}

private final class FailingAfterStreamingCaptureRecordingEngine: CaptureRecordingEngine, @unchecked Sendable {
    let id = "failing-after-streaming-capture"
    let mode: CaptureMode = .systemAudio

    private let source: CaptureSource
    private let chunk: CapturedAudioChunk

    init(source: CaptureSource, chunk: CapturedAudioChunk) {
        self.source = source
        self.chunk = chunk
    }

    func availableSources() async throws -> [CaptureSource] {
        [source]
    }

    func record(_ request: CaptureRecordingRequest) async throws -> CaptureRecordingEngineOutput {
        try request.chunkSink?.write(chunk)
        throw InterruptedCaptureFixtureError.sourceDisappeared
    }
}

private func waitUntil(
    _ description: String,
    timeoutNanoseconds: UInt64 = 1_000_000_000,
    pollNanoseconds: UInt64 = 20_000_000,
    condition: () throws -> Bool
) async throws {
    var elapsed: UInt64 = 0
    while try !condition() && elapsed < timeoutNanoseconds {
        try await Task.sleep(nanoseconds: pollNanoseconds)
        elapsed += pollNanoseconds
    }
    XCTAssertTrue(try condition(), "Timed out waiting for \(description)")
}

private extension CaptureHealthReport {
    static let healthyMock = CaptureHealthReport(
        remoteDropouts: 0,
        microphoneDropouts: 0,
        remoteClippingPercent: 0,
        microphoneClippingPercent: 0,
        silentPeriods: [],
        deviceChanges: [],
        transcriptionEngine: "mock",
        intelligenceProvider: "mock"
    )
}
