import Foundation

public enum FrameFedFinalTranscriptionError: Error, Equatable, LocalizedError, Sendable {
    case missingAudioData
    case invalidWAV
    case unsupportedWAVFormat(audioFormat: UInt16, bitsPerSample: UInt16)

    public var errorDescription: String? {
        switch self {
        case .missingAudioData: "The encrypted recording chunk did not contain audio data."
        case .invalidWAV: "The decrypted recording chunk is not a valid bounded WAV stream."
        case let .unsupportedWAVFormat(audioFormat, bitsPerSample):
            "The local final pass does not support WAV format \(audioFormat) at \(bitsPerSample) bits."
        }
    }
}

/// Reuses the provider-neutral, authoritative-frame path for the final pass.
/// It never opens an input engine, creates a plaintext URL, or invokes a model
/// download API. The injected local provider owns the verified model lease.
public actor FrameFedFinalTranscriptionEngine: TranscriptionEngine {
    public nonisolated let id = "frame-fed-local-final"
    public nonisolated let supportsRealtime = false

    private let provider: any LocalTranscriptionProviding
    private var remoteSpeakerNamesByMeeting: [UUID: [String: String]] = [:]
    private var meetingOrder: [UUID] = []

    public init(provider: any LocalTranscriptionProviding) {
        self.provider = provider
    }

    public func transcribe(_ request: TranscriptionRequest) async throws -> [TranscriptSegment] {
        guard let audioData = request.audioData else {
            throw FrameFedFinalTranscriptionError.missingAudioData
        }
        let audio = try Self.decodeWAV(audioData)
        let track = request.trackKind ?? .remoteSystem
        let session = try await provider.makeSession(TranscriptionSessionConfiguration(
            meetingID: request.meetingID,
            context: MeetingContext(localeIdentifier: request.localeIdentifier),
            expectedRemoteSpeakerCount: request.expectedRemoteSpeakerCount
        ))
        let eventTask = Task { () throws -> [TranscriptSegment] in
            var orderedIDs: [UUID] = []
            var byID: [UUID: TranscriptSegment] = [:]
            for try await event in session.events {
                switch event {
                case let .partial(segment), let .final(segment):
                    if byID[segment.id] == nil { orderedIDs.append(segment.id) }
                    byID[segment.id] = segment
                case .status, .level, .activeSpeakers, .degraded:
                    break
                }
            }
            return orderedIDs.compactMap { byID[$0] }
        }

        do {
            var sequence: UInt64 = 0
            var frameOffset = 0
            while frameOffset < audio.frameCount {
                let count = min(CapturedPCMFrame.maximumFrameCount, audio.frameCount - frameOffset)
                let sampleStart = frameOffset * audio.channelCount
                let sampleEnd = (frameOffset + count) * audio.channelCount
                let pcm = audio.samples[sampleStart..<sampleEnd].withUnsafeBytes { Data($0) }
                try await session.submit(try CapturedPCMFrame(
                    sequence: sequence,
                    track: track,
                    meetingTime: Double(frameOffset) / audio.sampleRate,
                    sampleRate: audio.sampleRate,
                    channelCount: audio.channelCount,
                    frameCount: count,
                    pcm: pcm
                ))
                sequence &+= 1
                frameOffset += count
            }
            try await session.finish()
            let offset = request.startTime ?? 0
            return try await eventTask.value.map {
                normalize(
                    $0,
                    meetingID: request.meetingID,
                    offset: offset,
                    maximumRemoteSpeakers: request.expectedRemoteSpeakerCount
                )
            }
        } catch {
            await session.cancel()
            eventTask.cancel()
            _ = try? await eventTask.value
            throw error
        }
    }

    private func normalize(
        _ input: TranscriptSegment,
        meetingID: UUID,
        offset: TimeInterval,
        maximumRemoteSpeakers: Int?
    ) -> TranscriptSegment {
        var segment = input
        segment.startTime += offset
        segment.endTime += offset
        segment.isFinal = true
        if segment.trackKind == .microphone {
            segment.speakerName = "You"
        } else if segment.trackKind == .remoteSystem {
            if remoteSpeakerNamesByMeeting[meetingID] == nil {
                meetingOrder.append(meetingID)
                if meetingOrder.count > 32 {
                    remoteSpeakerNamesByMeeting.removeValue(forKey: meetingOrder.removeFirst())
                }
            }
            var remoteSpeakerNames = remoteSpeakerNamesByMeeting[meetingID, default: [:]]
            if let known = remoteSpeakerNames[segment.speakerName] {
                segment.speakerName = known
            } else {
                let maximum = min(max(1, maximumRemoteSpeakers ?? 10), 10)
                let name = "Speaker \(min(remoteSpeakerNames.count + 1, maximum))"
                remoteSpeakerNames[segment.speakerName] = name
                segment.speakerName = name
            }
            remoteSpeakerNamesByMeeting[meetingID] = remoteSpeakerNames
        }
        return segment
    }
}

private extension FrameFedFinalTranscriptionEngine {
    struct DecodedAudio: Sendable {
        var sampleRate: Double
        var channelCount: Int
        var frameCount: Int
        var samples: [Float]
    }

    static func decodeWAV(_ data: Data) throws -> DecodedAudio {
        guard data.count >= 44,
              String(decoding: data[0..<4], as: UTF8.self) == "RIFF",
              String(decoding: data[8..<12], as: UTF8.self) == "WAVE",
              String(decoding: data[12..<16], as: UTF8.self) == "fmt ",
              data.uint32LE(at: 16) == 16,
              String(decoding: data[36..<40], as: UTF8.self) == "data"
        else { throw FrameFedFinalTranscriptionError.invalidWAV }

        let audioFormat = data.uint16LE(at: 20)
        let channelCount = Int(data.uint16LE(at: 22))
        let sampleRate = Double(data.uint32LE(at: 24))
        let blockAlign = Int(data.uint16LE(at: 32))
        let bitsPerSample = data.uint16LE(at: 34)
        let payloadByteCount = Int(data.uint32LE(at: 40))
        guard channelCount > 0, channelCount <= CapturedPCMFrame.maximumChannelCount,
              sampleRate.isFinite, sampleRate > 0,
              blockAlign > 0, payloadByteCount > 0,
              payloadByteCount.isMultiple(of: blockAlign),
              data.count >= 44 + payloadByteCount
        else { throw FrameFedFinalTranscriptionError.invalidWAV }

        let payload = data[44..<(44 + payloadByteCount)]
        let samples: [Float]
        switch (audioFormat, bitsPerSample) {
        case (3, 32):
            guard payload.count.isMultiple(of: MemoryLayout<Float>.size) else {
                throw FrameFedFinalTranscriptionError.invalidWAV
            }
            samples = payload.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        case (1, 16):
            guard payload.count.isMultiple(of: MemoryLayout<Int16>.size) else {
                throw FrameFedFinalTranscriptionError.invalidWAV
            }
            samples = payload.withUnsafeBytes {
                $0.bindMemory(to: Int16.self).map { Float(Int16(littleEndian: $0)) / Float(Int16.max) }
            }
        default:
            throw FrameFedFinalTranscriptionError.unsupportedWAVFormat(
                audioFormat: audioFormat,
                bitsPerSample: bitsPerSample
            )
        }
        guard samples.count.isMultiple(of: channelCount),
              samples.allSatisfy({ $0.isFinite })
        else { throw FrameFedFinalTranscriptionError.invalidWAV }
        return DecodedAudio(
            sampleRate: sampleRate,
            channelCount: channelCount,
            frameCount: samples.count / channelCount,
            samples: samples
        )
    }
}

private extension Data {
    func uint16LE(at offset: Int) -> UInt16 {
        self[offset..<(offset + 2)].enumerated().reduce(0) { result, item in
            result | (UInt16(item.element) << UInt16(item.offset * 8))
        }
    }

    func uint32LE(at offset: Int) -> UInt32 {
        self[offset..<(offset + 4)].enumerated().reduce(0) { result, item in
            result | (UInt32(item.element) << UInt32(item.offset * 8))
        }
    }
}
