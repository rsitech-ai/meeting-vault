import Foundation

public final class SystemAndMicrophoneCaptureEngine: CaptureRecordingEngine, @unchecked Sendable {
    public let id = "system-and-microphone"
    public let mode: CaptureMode = .systemAudio

    private let source: CaptureSource
    private let systemSourceID: String
    private let microphoneSourceID: String
    private let systemEngine: any CaptureRecordingEngine
    private let microphoneEngine: any CaptureRecordingEngine

    public init(
        source: CaptureSource,
        systemSourceID: String,
        microphoneSourceID: String,
        systemEngine: any CaptureRecordingEngine,
        microphoneEngine: any CaptureRecordingEngine
    ) {
        self.source = source
        self.systemSourceID = systemSourceID
        self.microphoneSourceID = microphoneSourceID
        self.systemEngine = systemEngine
        self.microphoneEngine = microphoneEngine
    }

    public func availableSources() async throws -> [CaptureSource] {
        [source]
    }

    public func record(_ request: CaptureRecordingRequest) async throws -> CaptureRecordingEngineOutput {
        guard request.sourceID == source.id else {
            throw CaptureRecordingError.sourceUnavailable(request.sourceID)
        }
        let systemRequest: CaptureRecordingRequest = {
            var copy = request
            copy.sourceID = systemSourceID
            return copy
        }()

        guard request.includeMicrophone else {
            return try await systemEngine.record(systemRequest)
        }
        let microphoneRequest: CaptureRecordingRequest = {
            var copy = request
            copy.sourceID = microphoneSourceID
            return copy
        }()

        let outputs: (system: CaptureRecordingEngineOutput, microphone: CaptureRecordingEngineOutput) = try await withThrowingTaskGroup(of: TrackOutput.self) { group in
            do {
                group.addTask { .system(try await self.systemEngine.record(systemRequest)) }
                group.addTask { .microphone(try await self.microphoneEngine.record(microphoneRequest)) }
                var system: CaptureRecordingEngineOutput?
                var microphone: CaptureRecordingEngineOutput?
                while let output = try await group.next() {
                    switch output {
                    case let .system(value):
                        system = value
                    case let .microphone(value):
                        microphone = value
                    }
                }
                guard let system, let microphone else {
                    throw CaptureRecordingError.sourceUnavailable(request.sourceID)
                }
                return (system: system, microphone: microphone)
            } catch {
                request.stopSignal?.requestStop()
                group.cancelAll()
                throw error
            }
        }
        return CaptureRecordingEngineOutput(
            chunks: outputs.system.chunks + outputs.microphone.chunks,
            healthReport: Self.merged(outputs.system.healthReport, outputs.microphone.healthReport)
        )
    }

    private static func merged(_ system: CaptureHealthReport, _ microphone: CaptureHealthReport) -> CaptureHealthReport {
        CaptureHealthReport(
            remoteDropouts: system.remoteDropouts,
            microphoneDropouts: microphone.microphoneDropouts,
            remoteClippingPercent: system.remoteClippingPercent,
            microphoneClippingPercent: microphone.microphoneClippingPercent,
            silentPeriods: system.silentPeriods + microphone.silentPeriods,
            deviceChanges: system.deviceChanges + microphone.deviceChanges,
            transcriptionEngine: "pending",
            intelligenceProvider: "pending"
        )
    }
}

private enum TrackOutput: Sendable {
    case system(CaptureRecordingEngineOutput)
    case microphone(CaptureRecordingEngineOutput)
}
