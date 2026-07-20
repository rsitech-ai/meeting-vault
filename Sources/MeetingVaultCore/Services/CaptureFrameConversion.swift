import AVFoundation
import CoreMedia
import Foundation

enum CanonicalPCMFrameConversionError: Error, Equatable {
    case invalidFormat
    case unsupportedFormat
    case missingBufferData
    case insufficientFrames
    case sampleBufferCopyFailed(OSStatus)
}

struct CanonicalPCMGeometry: Equatable {
    let channelCount: Int
    let frameCount: Int
    let bytesPerSample: Int
    let bytesPerFrame: Int
    let bytesPerPacket: Int
    let sourceByteCount: Int
    let canonicalByteCount: Int
    let isFloat: Bool
    let isNonInterleaved: Bool
}

private struct CanonicalPCMFormatGeometry {
    let channelCount: Int
    let bytesPerSample: Int
    let bytesPerFrame: Int
    let bytesPerPacket: Int
    let isFloat: Bool
    let isNonInterleaved: Bool
}

enum CanonicalPCMFrameConverter {
    static func frame(
        audioBufferList: UnsafePointer<AudioBufferList>,
        format: AudioStreamBasicDescription,
        frameCount: Int,
        sequence: UInt64,
        track: TrackKind,
        meetingTime: TimeInterval
    ) throws -> CapturedPCMFrame {
        let geometry = try validatedAudioBufferListGeometry(
            audioBufferList: audioBufferList,
            format: format,
            expectedFrameCount: frameCount
        )
        let channels = geometry.channelCount
        let bytesPerSample = geometry.bytesPerSample
        let isFloat = geometry.isFloat
        let isNonInterleaved = geometry.isNonInterleaved
        let buffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: audioBufferList)
        )
        var samples: [Float] = []
        samples.reserveCapacity(geometry.canonicalByteCount / MemoryLayout<Float>.size)
        for frameIndex in 0..<geometry.frameCount {
            for channelIndex in 0..<channels {
                let bufferIndex = isNonInterleaved ? channelIndex : 0
                guard let baseAddress = buffers[bufferIndex].mData else {
                    throw CanonicalPCMFrameConversionError.missingBufferData
                }
                let sampleIndex = isNonInterleaved
                    ? frameIndex
                    : frameIndex * channels + channelIndex
                let raw = UnsafeRawPointer(baseAddress)
                let sample: Float
                if isFloat {
                    sample = raw.loadUnaligned(
                        fromByteOffset: sampleIndex * bytesPerSample,
                        as: Float.self
                    )
                } else if bytesPerSample == 2 {
                    let value = raw.loadUnaligned(
                        fromByteOffset: sampleIndex * bytesPerSample,
                        as: Int16.self
                    )
                    sample = Float(value) / Float(Int16.max)
                } else {
                    let value = raw.loadUnaligned(
                        fromByteOffset: sampleIndex * bytesPerSample,
                        as: Int32.self
                    )
                    sample = Float(value) / Float(Int32.max)
                }
                samples.append(sample.isFinite ? min(1, max(-1, sample)) : 0)
            }
        }
        let pcm = samples.withUnsafeBytes { Data($0) }
        return try CapturedPCMFrame(
            sequence: sequence,
            track: track,
            meetingTime: meetingTime,
            sampleRate: format.mSampleRate,
            channelCount: channels,
            frameCount: geometry.frameCount,
            pcm: pcm
        )
    }

    static func frame(
        sampleBuffer: CMSampleBuffer,
        sequence: UInt64,
        track: TrackKind,
        meetingTime: TimeInterval
    ) throws -> CapturedPCMFrame {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        else {
            throw CanonicalPCMFrameConversionError.invalidFormat
        }
        let sampleCount = CMSampleBufferGetNumSamples(sampleBuffer)
        return try withValidatedSampleBufferGeometry(
            format: streamDescription.pointee,
            frameCount: sampleCount,
            sourceByteCount: CMSampleBufferGetTotalSampleSize(sampleBuffer)
        ) { _ in
            guard let audioFormat = AVAudioFormat(streamDescription: streamDescription),
                  let buffer = AVAudioPCMBuffer(
                      pcmFormat: audioFormat,
                      frameCapacity: AVAudioFrameCount(sampleCount)
                  )
            else {
                throw CanonicalPCMFrameConversionError.invalidFormat
            }
            buffer.frameLength = AVAudioFrameCount(sampleCount)
            let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
                sampleBuffer,
                at: 0,
                frameCount: Int32(sampleCount),
                into: buffer.mutableAudioBufferList
            )
            guard status == noErr else {
                throw CanonicalPCMFrameConversionError.sampleBufferCopyFailed(status)
            }
            return try frame(
                audioBufferList: UnsafePointer(buffer.audioBufferList),
                format: streamDescription.pointee,
                frameCount: sampleCount,
                sequence: sequence,
                track: track,
                meetingTime: meetingTime
            )
        }
    }

    static func withValidatedSampleBufferGeometry<Output>(
        format: AudioStreamBasicDescription,
        frameCount: Int,
        sourceByteCount: Int,
        _ body: (CanonicalPCMGeometry) throws -> Output
    ) throws -> Output {
        let geometry = try validatedGeometry(
            format: format,
            frameCount: frameCount,
            sourceByteCount: sourceByteCount
        )
        return try body(geometry)
    }

    static func withValidatedAudioBufferListGeometry<Output>(
        audioBufferList: UnsafePointer<AudioBufferList>,
        format: AudioStreamBasicDescription,
        expectedFrameCount: Int? = nil,
        _ body: (CanonicalPCMGeometry) throws -> Output
    ) throws -> Output {
        let geometry = try validatedAudioBufferListGeometry(
            audioBufferList: audioBufferList,
            format: format,
            expectedFrameCount: expectedFrameCount
        )
        return try body(geometry)
    }

    private static func validatedAudioBufferListGeometry(
        audioBufferList: UnsafePointer<AudioBufferList>,
        format: AudioStreamBasicDescription,
        expectedFrameCount: Int?
    ) throws -> CanonicalPCMGeometry {
        let formatGeometry = try validatedFormatGeometry(format)
        let buffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: audioBufferList)
        )
        let frameCount: Int
        let sourceByteCount: Int

        if formatGeometry.isNonInterleaved {
            guard buffers.count == formatGeometry.channelCount else {
                throw CanonicalPCMFrameConversionError.invalidFormat
            }
            var planeByteCount: Int?
            var checkedTotal = 0
            for buffer in buffers {
                let byteCount = Int(buffer.mDataByteSize)
                guard buffer.mNumberChannels == 1,
                      buffer.mData != nil,
                      byteCount > 0,
                      byteCount.isMultiple(of: formatGeometry.bytesPerSample)
                else {
                    throw CanonicalPCMFrameConversionError.invalidFormat
                }
                if let planeByteCount {
                    guard byteCount == planeByteCount else {
                        throw CanonicalPCMFrameConversionError.invalidFormat
                    }
                } else {
                    planeByteCount = byteCount
                }
                let (nextTotal, overflow) = checkedTotal.addingReportingOverflow(byteCount)
                guard !overflow, nextTotal <= CapturedPCMFrame.maximumPCMByteCount else {
                    throw CanonicalPCMFrameConversionError.invalidFormat
                }
                checkedTotal = nextTotal
            }
            guard let planeByteCount else {
                throw CanonicalPCMFrameConversionError.missingBufferData
            }
            frameCount = planeByteCount / formatGeometry.bytesPerSample
            sourceByteCount = checkedTotal
        } else {
            guard buffers.count == 1, let buffer = buffers.first else {
                throw CanonicalPCMFrameConversionError.invalidFormat
            }
            let byteCount = Int(buffer.mDataByteSize)
            guard buffer.mNumberChannels == UInt32(formatGeometry.channelCount),
                  buffer.mData != nil,
                  byteCount > 0,
                  byteCount <= CapturedPCMFrame.maximumPCMByteCount,
                  byteCount.isMultiple(of: formatGeometry.bytesPerFrame)
            else {
                throw CanonicalPCMFrameConversionError.invalidFormat
            }
            frameCount = byteCount / formatGeometry.bytesPerFrame
            sourceByteCount = byteCount
        }

        if let expectedFrameCount, frameCount != expectedFrameCount {
            throw CanonicalPCMFrameConversionError.invalidFormat
        }
        return try validatedGeometry(
            format: format,
            frameCount: frameCount,
            sourceByteCount: sourceByteCount
        )
    }

    private static func validatedGeometry(
        format: AudioStreamBasicDescription,
        frameCount: Int,
        sourceByteCount: Int?
    ) throws -> CanonicalPCMGeometry {
        let formatGeometry = try validatedFormatGeometry(format)
        let channels = formatGeometry.channelCount
        let bytesPerSample = formatGeometry.bytesPerSample
        let expectedBytesPerFrame = formatGeometry.bytesPerFrame
        let expectedBytesPerPacket = formatGeometry.bytesPerPacket

        guard frameCount > 0,
              frameCount <= CapturedPCMFrame.maximumFrameCount
        else {
            throw CanonicalPCMFrameConversionError.invalidFormat
        }

        let (sampleCount, sampleCountOverflow) = frameCount
            .multipliedReportingOverflow(by: channels)
        let (requiredSourceBytes, sourceBytesOverflow) = sampleCount
            .multipliedReportingOverflow(by: bytesPerSample)
        let (canonicalBytes, canonicalBytesOverflow) = sampleCount
            .multipliedReportingOverflow(by: MemoryLayout<Float>.size)
        guard !sampleCountOverflow,
              !sourceBytesOverflow,
              !canonicalBytesOverflow,
              requiredSourceBytes > 0,
              requiredSourceBytes <= CapturedPCMFrame.maximumPCMByteCount,
              canonicalBytes <= CapturedPCMFrame.maximumPCMByteCount
        else {
            throw CanonicalPCMFrameConversionError.invalidFormat
        }
        if let sourceByteCount {
            guard sourceByteCount >= requiredSourceBytes else {
                throw CanonicalPCMFrameConversionError.insufficientFrames
            }
            guard sourceByteCount == requiredSourceBytes else {
                throw CanonicalPCMFrameConversionError.invalidFormat
            }
        }

        return CanonicalPCMGeometry(
            channelCount: channels,
            frameCount: frameCount,
            bytesPerSample: bytesPerSample,
            bytesPerFrame: expectedBytesPerFrame,
            bytesPerPacket: expectedBytesPerPacket,
            sourceByteCount: requiredSourceBytes,
            canonicalByteCount: canonicalBytes,
            isFloat: formatGeometry.isFloat,
            isNonInterleaved: formatGeometry.isNonInterleaved
        )
    }

    private static func validatedFormatGeometry(
        _ format: AudioStreamBasicDescription
    ) throws -> CanonicalPCMFormatGeometry {
        guard format.mFormatID == kAudioFormatLinearPCM else {
            throw CanonicalPCMFrameConversionError.unsupportedFormat
        }
        guard format.mSampleRate.isFinite,
              format.mSampleRate > 0,
              format.mChannelsPerFrame > 0,
              format.mChannelsPerFrame <= UInt32(CapturedPCMFrame.maximumChannelCount),
              format.mReserved == 0
        else {
            throw CanonicalPCMFrameConversionError.invalidFormat
        }

        let allowedFlags = kAudioFormatFlagIsFloat
            | kAudioFormatFlagIsSignedInteger
            | kAudioFormatFlagIsPacked
            | kAudioFormatFlagIsNonInterleaved
        let flags = format.mFormatFlags
        let isFloat = flags & kAudioFormatFlagIsFloat != 0
        let isSignedInteger = flags & kAudioFormatFlagIsSignedInteger != 0
        let isPacked = flags & kAudioFormatFlagIsPacked != 0
        let isNonInterleaved = flags & kAudioFormatFlagIsNonInterleaved != 0
        guard flags & ~allowedFlags == 0,
              isPacked,
              isFloat != isSignedInteger,
              (isFloat && format.mBitsPerChannel == 32)
                  || (isSignedInteger && (format.mBitsPerChannel == 16 || format.mBitsPerChannel == 32))
        else {
            throw CanonicalPCMFrameConversionError.unsupportedFormat
        }

        let channels = Int(format.mChannelsPerFrame)
        let bytesPerSample = Int(format.mBitsPerChannel / 8)
        let (interleavedBytesPerFrame, frameStrideOverflow) = bytesPerSample
            .multipliedReportingOverflow(by: channels)
        guard !frameStrideOverflow else {
            throw CanonicalPCMFrameConversionError.invalidFormat
        }
        let expectedBytesPerFrame = isNonInterleaved
            ? bytesPerSample
            : interleavedBytesPerFrame
        let framesPerPacket = Int(format.mFramesPerPacket)
        let (expectedBytesPerPacket, packetStrideOverflow) = expectedBytesPerFrame
            .multipliedReportingOverflow(by: framesPerPacket)
        let encodedBytesPerFrame = UInt32(exactly: expectedBytesPerFrame)
        let encodedBytesPerPacket = UInt32(exactly: expectedBytesPerPacket)
        guard framesPerPacket > 0,
              !packetStrideOverflow,
              expectedBytesPerFrame > 0,
              expectedBytesPerPacket > 0,
              let encodedBytesPerFrame,
              let encodedBytesPerPacket,
              format.mBytesPerFrame == encodedBytesPerFrame,
              format.mBytesPerPacket == encodedBytesPerPacket
        else {
            throw CanonicalPCMFrameConversionError.invalidFormat
        }

        return CanonicalPCMFormatGeometry(
            channelCount: channels,
            bytesPerSample: bytesPerSample,
            bytesPerFrame: expectedBytesPerFrame,
            bytesPerPacket: expectedBytesPerPacket,
            isFloat: isFloat,
            isNonInterleaved: isNonInterleaved
        )
    }
}

public enum CaptureFrameEmissionError: Error, Equatable, Sendable {
    case durabilityRejected
}

public final class CaptureFrameEmitter: @unchecked Sendable {
    private let fanout: CaptureFrameFanout
    private let clock: ContinuousClock
    private let startedAt: ContinuousClock.Instant
    private let lock = NSLock()
    private var nextSequenceByTrack: [TrackKind: UInt64] = [:]
    private var emittedFrameCountByTrack: [TrackKind: Int] = [:]

    public func hasEmittedFrames(for track: TrackKind) -> Bool {
        lock.withLock { emittedFrameCountByTrack[track, default: 0] > 0 }
    }

    public init(
        fanout: CaptureFrameFanout,
        clock: ContinuousClock = ContinuousClock()
    ) {
        self.fanout = fanout
        self.clock = clock
        startedAt = clock.now
    }

    func finishProducerAfterFailedStop() {
        fanout.finishProducerAfterFailedStop()
    }

    @discardableResult
    public func emitCanonicalPCM(
        _ pcm: Data,
        sampleRate: Double,
        channelCount: Int,
        frameCount: Int,
        track: TrackKind
    ) throws -> FrameOfferResult {
        let frame = try CapturedPCMFrame(
            sequence: takeSequence(for: track),
            track: track,
            meetingTime: meetingTime,
            sampleRate: sampleRate,
            channelCount: channelCount,
            frameCount: frameCount,
            pcm: pcm
        )
        return try offer(frame)
    }

    @discardableResult
    func emit(
        sampleBuffer: CMSampleBuffer,
        track: TrackKind
    ) throws -> FrameOfferResult {
        let frame = try CanonicalPCMFrameConverter.frame(
            sampleBuffer: sampleBuffer,
            sequence: takeSequence(for: track),
            track: track,
            meetingTime: meetingTime
        )
        return try offer(frame)
    }

    @discardableResult
    func emit(
        audioBufferList: UnsafePointer<AudioBufferList>,
        format: AudioStreamBasicDescription,
        frameCount: Int,
        track: TrackKind
    ) throws -> FrameOfferResult {
        let frame = try CanonicalPCMFrameConverter.frame(
            audioBufferList: audioBufferList,
            format: format,
            frameCount: frameCount,
            sequence: takeSequence(for: track),
            track: track,
            meetingTime: meetingTime
        )
        return try offer(frame)
    }

    private var meetingTime: TimeInterval {
        let duration = startedAt.duration(to: clock.now)
        return max(0, Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000_000)
    }

    private func takeSequence(for track: TrackKind) -> UInt64 {
        lock.withLock {
            let sequence = nextSequenceByTrack[track, default: 0]
            nextSequenceByTrack[track] = sequence &+ 1
            return sequence
        }
    }

    private func offer(_ frame: CapturedPCMFrame) throws -> FrameOfferResult {
        let result = fanout.offer(frame)
        if result == .durabilityRejected {
            throw CaptureFrameEmissionError.durabilityRejected
        }
        lock.withLock { emittedFrameCountByTrack[frame.track, default: 0] += 1 }
        return result
    }
}
