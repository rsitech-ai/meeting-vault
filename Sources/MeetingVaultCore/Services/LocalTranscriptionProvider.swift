import Foundation

public enum LocalTranscriptionAudioInputStrategy: String, Codable, Equatable, Sendable {
    /// The provider accepts only frames emitted by MeetingVault's selected capture
    /// engine. It never opens AVAudioEngine or another input device.
    case authoritativeCaptureFrames
}

public struct ProviderDescriptor: Codable, Equatable, Sendable {
    public var id: String
    public var modelVersion: String
    public var supportedLocaleIdentifiers: Set<String>
    public var audioInputStrategy: LocalTranscriptionAudioInputStrategy
    public var supportsRemoteSpeakerDiarization: Bool
    public var maximumRemoteSpeakerCount: Int

    public init(
        id: String,
        modelVersion: String,
        supportedLocaleIdentifiers: Set<String>,
        audioInputStrategy: LocalTranscriptionAudioInputStrategy = .authoritativeCaptureFrames,
        supportsRemoteSpeakerDiarization: Bool = false,
        maximumRemoteSpeakerCount: Int = 1
    ) {
        self.id = id
        self.modelVersion = modelVersion
        self.supportedLocaleIdentifiers = supportedLocaleIdentifiers
        self.audioInputStrategy = audioInputStrategy
        self.supportsRemoteSpeakerDiarization = supportsRemoteSpeakerDiarization
        self.maximumRemoteSpeakerCount = max(1, maximumRemoteSpeakerCount)
    }
}

public struct TranscriptionSessionConfiguration: Equatable, Sendable {
    public var meetingID: UUID
    public var context: MeetingContext
    public var expectedRemoteSpeakerCount: Int?
    public var sourceID: String?
    public var microphoneDeviceID: String?
    public var microphoneDeviceName: String?

    public init(
        meetingID: UUID,
        context: MeetingContext,
        expectedRemoteSpeakerCount: Int? = nil,
        sourceID: String? = nil,
        microphoneDeviceID: String? = nil,
        microphoneDeviceName: String? = nil
    ) {
        self.meetingID = meetingID
        self.context = context
        self.expectedRemoteSpeakerCount = expectedRemoteSpeakerCount
        self.sourceID = sourceID
        self.microphoneDeviceID = microphoneDeviceID
        self.microphoneDeviceName = microphoneDeviceName
    }
}

public enum LocalTranscriptionEvent: Equatable, Sendable {
    case status(String)
    case level(track: TrackKind, value: Double)
    case partial(TranscriptSegment)
    case final(TranscriptSegment)
    case activeSpeakers([String])
    case degraded(String)
}

public enum LocalTranscriptionError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedLocale(String)
    case invalidExpectedSpeakerCount
    case providerAlreadyStarted
    case providerNotStarted
    case providerUnavailable(String)
    case invalidProviderEvent

    public var errorDescription: String? {
        switch self {
        case let .unsupportedLocale(locale):
            "Local transcription does not support \(locale). Choose Automatic, Polish, or English."
        case .invalidExpectedSpeakerCount:
            "Expected remote speaker count is outside the provider's supported range."
        case .providerAlreadyStarted:
            "The local transcription session has already started."
        case .providerNotStarted:
            "The local transcription session is not running."
        case let .providerUnavailable(reason):
            "Local transcription is unavailable: \(reason)"
        case .invalidProviderEvent:
            "The local transcription provider emitted invalid data."
        }
    }
}

public protocol LocalTranscriptionProviding: Sendable {
    var descriptor: ProviderDescriptor { get }
    func makeSession(_ configuration: TranscriptionSessionConfiguration) async throws
        -> any LocalTranscriptionSession
}

public protocol LocalTranscriptionSession: Sendable {
    var events: AsyncThrowingStream<LocalTranscriptionEvent, Error> { get }
    func submit(_ frame: CapturedPCMFrame) async throws
    func finish() async throws
    func cancel() async
}

public struct TranscriptionCoordinatorSnapshot: Equatable, Sendable {
    public var acceptedFrameCount: Int
    public var droppedFrameCount: Int
    public var activeTaskCount: Int
    public var isTerminal: Bool
    public var providerFailed: Bool

    public init(
        acceptedFrameCount: Int,
        droppedFrameCount: Int,
        activeTaskCount: Int,
        isTerminal: Bool,
        providerFailed: Bool
    ) {
        self.acceptedFrameCount = acceptedFrameCount
        self.droppedFrameCount = droppedFrameCount
        self.activeTaskCount = activeTaskCount
        self.isTerminal = isTerminal
        self.providerFailed = providerFailed
    }
}

/// One bounded preview consumer for both capture tracks. Capture durability does
/// not depend on this actor: `consume` only enqueues and returns, while provider
/// work runs on a separate task and failures become degraded preview events.
public actor TranscriptionSessionCoordinator: CaptureFrameConsumer, CapturePreviewDropObserving {
    public nonisolated let id = "local-transcription-coordinator"
    public nonisolated let deliveryPolicy: CaptureFrameDeliveryPolicy = .preview
    public nonisolated let events: AsyncStream<LocalTranscriptionEvent>

    private enum State { case idle, running, finishing, terminal }

    private let provider: any LocalTranscriptionProviding
    private let configuration: TranscriptionSessionConfiguration
    private let queueCapacityPerTrack: Int
    private let eventContinuation: AsyncStream<LocalTranscriptionEvent>.Continuation
    private var state: State = .idle
    private var session: (any LocalTranscriptionSession)?
    private var frameQueues: [TrackKind: [CapturedPCMFrame]] = [:]
    private var frameWaiters: [CheckedContinuation<Void, Never>] = []
    private var frameWorker: Task<Void, Never>?
    private var eventWorker: Task<Void, Never>?
    private var acceptedFrameCount = 0
    private var droppedFrameCount = 0
    private var providerFailed = false
    private var didEmitProviderFailure = false
    private var rawSpeakerNames: [String: String] = [:]
    private var nextSpeakerNumber = 1
    private nonisolated let previewCoverageTracker = TranscriptPreviewCoverageTracker()

    public init(
        provider: any LocalTranscriptionProviding,
        configuration: TranscriptionSessionConfiguration,
        queueCapacityPerTrack: Int = 16
    ) {
        self.provider = provider
        self.configuration = configuration
        self.queueCapacityPerTrack = max(1, queueCapacityPerTrack)
        let pair = AsyncStream<LocalTranscriptionEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(128)
        )
        events = pair.stream
        eventContinuation = pair.continuation
    }

    public func start() async throws {
        guard state == .idle else { throw LocalTranscriptionError.providerAlreadyStarted }
        let validated: MeetingContext
        do {
            validated = try configuration.context.validated()
        } catch MeetingContextValidationError.unsupportedLocale {
            throw LocalTranscriptionError.unsupportedLocale(
                configuration.context.localeIdentifier ?? "unknown"
            )
        }
        if let locale = validated.localeIdentifier,
           !provider.descriptor.supportedLocaleIdentifiers.contains(locale) {
            throw LocalTranscriptionError.unsupportedLocale(locale)
        }
        if let expected = configuration.expectedRemoteSpeakerCount,
           !(1...provider.descriptor.maximumRemoteSpeakerCount).contains(expected) {
            throw LocalTranscriptionError.invalidExpectedSpeakerCount
        }
        var resolved = configuration
        resolved.context = validated
        let localSession = try await provider.makeSession(resolved)
        session = localSession
        state = .running
        eventContinuation.yield(.status("Local transcription ready"))
        frameWorker = Task { [weak self] in await self?.runFrameWorker(localSession) }
        eventWorker = Task { [weak self] in await self?.runEventWorker(localSession) }
    }

    public func consume(_ frame: CapturedPCMFrame) async throws {
        guard state == .running, !providerFailed else { return }
        guard frame.track == .microphone || frame.track == .remoteSystem else { return }
        var queue = frameQueues[frame.track, default: []]
        if queue.count >= queueCapacityPerTrack {
            let overflow = queue.count - queueCapacityPerTrack + 1
            for dropped in queue.prefix(overflow) {
                previewCoverageTracker.recordDroppedFrame(dropped)
            }
            queue.removeFirst(overflow)
            droppedFrameCount += overflow
            eventContinuation.yield(.degraded("Live transcription skipped \(overflow) delayed audio frame\(overflow == 1 ? "" : "s"); encrypted recording is unaffected"))
        }
        queue.append(frame)
        frameQueues[frame.track] = queue
        acceptedFrameCount += 1
        eventContinuation.yield(.level(track: frame.track, value: frame.rmsLevel))
        resumeFrameWorkers()
    }

    public func finish() async throws {
        switch state {
        case .terminal: return
        case .idle:
            state = .terminal
            eventContinuation.finish()
            return
        case .finishing:
            await awaitWorkers()
            return
        case .running:
            state = .finishing
        }
        resumeFrameWorkers()
        await frameWorker?.value
        frameWorker = nil
        if !providerFailed, let session {
            do {
                try await session.finish()
            } catch {
                emitProviderFailure(error)
                // A provider may throw without completing its event stream.
                // Cancel our iterator and request provider cancellation so Stop
                // can complete without retaining live tasks or model leases.
                eventWorker?.cancel()
                await session.cancel()
            }
        }
        await eventWorker?.value
        eventWorker = nil
        session = nil
        state = .terminal
        eventContinuation.finish()
    }

    public func cancel() async {
        guard state != .terminal else { return }
        state = .terminal
        frameQueues.removeAll()
        resumeFrameWorkers()
        frameWorker?.cancel()
        eventWorker?.cancel()
        if let session { await session.cancel() }
        await awaitWorkers()
        self.session = nil
        eventContinuation.finish()
    }

    public func handleSystemSleep() async {
        await cancel()
    }

    public func snapshot() -> TranscriptionCoordinatorSnapshot {
        TranscriptionCoordinatorSnapshot(
            acceptedFrameCount: acceptedFrameCount,
            droppedFrameCount: droppedFrameCount,
            activeTaskCount: (frameWorker == nil ? 0 : 1) + (eventWorker == nil ? 0 : 1),
            isTerminal: state == .terminal,
            providerFailed: providerFailed
        )
    }

    public nonisolated func recordDroppedPreviewFrame(_ frame: CapturedPCMFrame) {
        previewCoverageTracker.recordDroppedFrame(frame)
    }

    public func previewEvidenceSnapshot() -> TranscriptPreviewEvidence {
        previewCoverageTracker.snapshot()
    }

    private func runFrameWorker(_ session: any LocalTranscriptionSession) async {
        while !Task.isCancelled {
            if let frame = dequeueNextFrame() {
                do {
                    try await session.submit(frame)
                } catch {
                    emitProviderFailure(error)
                    frameQueues.removeAll()
                    await session.cancel()
                    eventWorker?.cancel()
                    return
                }
                continue
            }
            if state != .running { return }
            await withCheckedContinuation { frameWaiters.append($0) }
        }
    }

    private func runEventWorker(_ session: any LocalTranscriptionSession) async {
        do {
            for try await event in session.events {
                guard !Task.isCancelled else { return }
                if let sanitized = sanitize(event) {
                    eventContinuation.yield(sanitized)
                }
            }
        } catch {
            guard !Task.isCancelled else { return }
            emitProviderFailure(error)
        }
    }

    private func sanitize(_ event: LocalTranscriptionEvent) -> LocalTranscriptionEvent? {
        switch event {
        case let .level(track, value):
            guard value.isFinite else { return nil }
            return .level(track: track, value: min(1, max(0, value)))
        case let .partial(segment):
            return sanitizedSegment(segment, final: false).map(LocalTranscriptionEvent.partial)
        case let .final(segment):
            return sanitizedSegment(segment, final: true).map(LocalTranscriptionEvent.final)
        case let .activeSpeakers(names):
            return .activeSpeakers(names.compactMap(remoteSpeakerName))
        case let .status(message):
            return message.isEmpty ? nil : .status(message)
        case let .degraded(message):
            return message.isEmpty ? nil : .degraded(message)
        }
    }

    private func sanitizedSegment(_ input: TranscriptSegment, final: Bool) -> TranscriptSegment? {
        guard input.startTime.isFinite, input.endTime.isFinite,
              input.startTime >= 0, input.endTime > input.startTime,
              input.confidence.isFinite,
              !input.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              input.trackKind == .microphone || input.trackKind == .remoteSystem else {
            return nil
        }
        var segment = input
        segment.isFinal = final
        segment.confidence = min(1, max(0, segment.confidence))
        if segment.trackKind == .microphone {
            segment.speakerName = "You"
        } else if segment.speakerName == "Multiple speakers" {
            segment.speakerName = "Multiple speakers"
        } else {
            let rawName = segment.speakerName
            let resolved = remoteSpeakerName(rawName)
            if Self.isMeaningfulPreviewSpeakerIdentity(rawName),
               let identity = try? TranscriptPreviewSpeakerIdentity(
                   track: segment.trackKind,
                   startTime: segment.startTime,
                   endTime: segment.endTime,
                   speakerName: resolved
            ) {
                previewCoverageTracker.recordSpeakerIdentity(identity)
            }
            segment.speakerName = resolved
        }
        return segment
    }

    private static func isMeaningfulPreviewSpeakerIdentity(_ raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !value.isEmpty
            && value != "remote-unassigned"
            && value != "unassigned"
            && value != "unknown"
            && value != "multiple speakers"
    }

    private func remoteSpeakerName(_ raw: String) -> String {
        if let existing = rawSpeakerNames[raw] { return existing }
        let maximum = min(
            provider.descriptor.maximumRemoteSpeakerCount,
            configuration.expectedRemoteSpeakerCount ?? provider.descriptor.maximumRemoteSpeakerCount
        )
        let assigned = min(nextSpeakerNumber, maximum)
        let value = "Speaker \(assigned)"
        rawSpeakerNames[raw] = value
        if nextSpeakerNumber < maximum { nextSpeakerNumber += 1 }
        return value
    }

    private func dequeueNextFrame() -> CapturedPCMFrame? {
        let candidates = [TrackKind.microphone, .remoteSystem].compactMap { track -> CapturedPCMFrame? in
            frameQueues[track]?.first
        }
        guard let next = candidates.min(by: {
            if $0.meetingTime == $1.meetingTime { return $0.sequence < $1.sequence }
            return $0.meetingTime < $1.meetingTime
        }) else { return nil }
        frameQueues[next.track]?.removeFirst()
        return next
    }

    private func resumeFrameWorkers() {
        let waiters = frameWaiters
        frameWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func emitProviderFailure(_ error: Error) {
        providerFailed = true
        guard !didEmitProviderFailure else { return }
        didEmitProviderFailure = true
        let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        eventContinuation.yield(.degraded("Local transcription stopped: \(message)"))
        resumeFrameWorkers()
    }

    private func awaitWorkers() async {
        await frameWorker?.value
        await eventWorker?.value
        frameWorker = nil
        eventWorker = nil
    }
}

public struct LiveTranscriptProjection: Equatable, Sendable {
    public private(set) var segments: [TranscriptSegment]
    public private(set) var activeSpeakers: [String]
    public private(set) var levels: [TrackKind: Double]
    public private(set) var degradationMessages: [String]

    public init(events: [LocalTranscriptionEvent]) {
        var byID: [UUID: TranscriptSegment] = [:]
        var order: [UUID] = []
        var activeSpeakers: [String] = []
        var levels: [TrackKind: Double] = [:]
        var degradationMessages: [String] = []
        for event in events {
            switch event {
            case let .partial(segment), let .final(segment):
                if byID[segment.id] == nil { order.append(segment.id) }
                byID[segment.id] = segment
            case let .activeSpeakers(names): activeSpeakers = names
            case let .level(track, value): levels[track] = value
            case let .degraded(message): degradationMessages.append(message)
            case .status: break
            }
        }
        segments = order.compactMap { byID[$0] }.sorted {
            if $0.startTime == $1.startTime { return $0.id.uuidString < $1.id.uuidString }
            return $0.startTime < $1.startTime
        }
        self.activeSpeakers = activeSpeakers
        self.levels = levels
        self.degradationMessages = degradationMessages
    }
}
