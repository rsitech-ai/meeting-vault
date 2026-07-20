import AudioToolbox
import AVFoundation
import CoreMedia
import Foundation

enum LinearPCMAudioChunkError: Error, Equatable {
    case missingFormat
    case unsupportedFormat(AudioFormatID)
    case invalidFormat
    case inconsistentFormat
    case sampleBufferCopyFailed(OSStatus)
    case chunkTooLarge(Int)
}

struct LinearPCMAudioChunk: Equatable {
    var data: Data
    var duration: TimeInterval
}

final class LinearPCMAudioChunkAccumulator {
    private var format: AudioStreamBasicDescription?
    private var interleavedPCM = Data()
    private var frameCount: UInt64 = 0

    var byteCount: Int { interleavedPCM.count }

    var duration: TimeInterval {
        guard let format, format.mSampleRate > 0 else { return 0 }
        return TimeInterval(frameCount) / format.mSampleRate
    }

    var isEmpty: Bool { interleavedPCM.isEmpty }

    func append(sampleBuffer: CMSampleBuffer) throws {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        else {
            throw LinearPCMAudioChunkError.missingFormat
        }
        let audioFormat = AVAudioFormat(streamDescription: streamDescription)
        guard let audioFormat else {
            throw LinearPCMAudioChunkError.invalidFormat
        }
        let sampleCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard sampleCount > 0 else { return }
        let frames = AVAudioFrameCount(sampleCount)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: frames) else {
            throw LinearPCMAudioChunkError.invalidFormat
        }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(sampleCount),
            into: buffer.mutableAudioBufferList
        )
        guard status == noErr else {
            throw LinearPCMAudioChunkError.sampleBufferCopyFailed(status)
        }
        try append(
            audioBufferList: UnsafePointer(buffer.audioBufferList),
            format: streamDescription.pointee,
            frameCount: UInt32(sampleCount)
        )
    }

    func append(
        audioBufferList: UnsafePointer<AudioBufferList>,
        format incomingFormat: AudioStreamBasicDescription,
        frameCount incomingFrameCount: UInt32? = nil
    ) throws {
        let normalizedFormat = try Self.validated(incomingFormat)
        if let format, !Self.matches(format, normalizedFormat) {
            throw LinearPCMAudioChunkError.inconsistentFormat
        }
        format = normalizedFormat

        let buffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: audioBufferList)
        )
        let channels = Int(normalizedFormat.mChannelsPerFrame)
        let bytesPerSample = Int(normalizedFormat.mBitsPerChannel / 8)
        let nonInterleaved = normalizedFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0

        if nonInterleaved {
            guard buffers.count >= channels,
                  channels > 0,
                  bytesPerSample > 0
            else {
                throw LinearPCMAudioChunkError.invalidFormat
            }
            let availableFrames = buffers.prefix(channels).map {
                Int($0.mDataByteSize) / bytesPerSample
            }.min() ?? 0
            let frames = min(Int(incomingFrameCount ?? UInt32(availableFrames)), availableFrames)
            guard frames > 0 else { return }
            interleavedPCM.reserveCapacity(interleavedPCM.count + frames * channels * bytesPerSample)
            for frame in 0..<frames {
                for channel in 0..<channels {
                    guard let baseAddress = buffers[channel].mData else {
                        throw LinearPCMAudioChunkError.invalidFormat
                    }
                    interleavedPCM.append(
                        baseAddress.assumingMemoryBound(to: UInt8.self).advanced(by: frame * bytesPerSample),
                        count: bytesPerSample
                    )
                }
            }
            frameCount += UInt64(frames)
            return
        }

        guard let buffer = buffers.first,
              let baseAddress = buffer.mData,
              normalizedFormat.mBytesPerFrame > 0
        else {
            throw LinearPCMAudioChunkError.invalidFormat
        }
        let availableFrames = Int(buffer.mDataByteSize / normalizedFormat.mBytesPerFrame)
        let frames = min(Int(incomingFrameCount ?? UInt32(availableFrames)), availableFrames)
        guard frames > 0 else { return }
        let byteCount = frames * Int(normalizedFormat.mBytesPerFrame)
        interleavedPCM.append(baseAddress.assumingMemoryBound(to: UInt8.self), count: byteCount)
        frameCount += UInt64(frames)
    }

    func finishChunk() throws -> LinearPCMAudioChunk? {
        guard let format, !interleavedPCM.isEmpty else { return nil }
        guard interleavedPCM.count <= Int(UInt32.max) - 36 else {
            throw LinearPCMAudioChunkError.chunkTooLarge(interleavedPCM.count)
        }
        let chunkDuration = duration
        let data = try Self.wavData(pcmData: interleavedPCM, format: format)
        interleavedPCM.removeAll(keepingCapacity: true)
        frameCount = 0
        return LinearPCMAudioChunk(data: data, duration: chunkDuration)
    }

    static func mergeWAVChunks(_ chunks: [Data]) throws -> Data {
        guard let first = chunks.first else { return Data() }
        let parsed = try chunks.map(parseWAV)
        guard parsed.dropFirst().allSatisfy({ $0.format == parsed[0].format }) else {
            throw LinearPCMAudioChunkError.inconsistentFormat
        }
        let payloadSize = parsed.reduce(0) { $0 + $1.payload.count }
        guard payloadSize <= Int(UInt32.max) - 36 else {
            throw LinearPCMAudioChunkError.chunkTooLarge(payloadSize)
        }
        var merged = Data(first.prefix(44))
        merged.replaceLittleEndian(UInt32(36 + payloadSize), in: 4..<8)
        merged.replaceLittleEndian(UInt32(payloadSize), in: 40..<44)
        for item in parsed {
            merged.append(item.payload)
        }
        return merged
    }

    private static func parseWAV(_ data: Data) throws -> (format: Data, payload: Data) {
        guard data.count >= 44,
              String(decoding: data[0..<4], as: UTF8.self) == "RIFF",
              String(decoding: data[8..<12], as: UTF8.self) == "WAVE",
              String(decoding: data[12..<16], as: UTF8.self) == "fmt ",
              data.littleEndianUInt32(at: 16) == 16,
              String(decoding: data[36..<40], as: UTF8.self) == "data"
        else {
            throw LinearPCMAudioChunkError.invalidFormat
        }
        let payloadSize = Int(data.littleEndianUInt32(at: 40))
        guard payloadSize >= 0, data.count >= 44 + payloadSize else {
            throw LinearPCMAudioChunkError.invalidFormat
        }
        return (
            format: data.subdata(in: 20..<36),
            payload: data.subdata(in: 44..<(44 + payloadSize))
        )
    }

    private static func validated(_ format: AudioStreamBasicDescription) throws -> AudioStreamBasicDescription {
        guard format.mFormatID == kAudioFormatLinearPCM else {
            throw LinearPCMAudioChunkError.unsupportedFormat(format.mFormatID)
        }
        guard format.mSampleRate > 0,
              format.mChannelsPerFrame > 0,
              format.mBitsPerChannel > 0,
              format.mBitsPerChannel.isMultiple(of: 8)
        else {
            throw LinearPCMAudioChunkError.invalidFormat
        }
        return format
    }

    private static func matches(
        _ lhs: AudioStreamBasicDescription,
        _ rhs: AudioStreamBasicDescription
    ) -> Bool {
        lhs.mSampleRate == rhs.mSampleRate
            && lhs.mFormatID == rhs.mFormatID
            && lhs.mFormatFlags == rhs.mFormatFlags
            && lhs.mBytesPerFrame == rhs.mBytesPerFrame
            && lhs.mChannelsPerFrame == rhs.mChannelsPerFrame
            && lhs.mBitsPerChannel == rhs.mBitsPerChannel
    }

    private static func wavData(
        pcmData: Data,
        format: AudioStreamBasicDescription
    ) throws -> Data {
        let channels = UInt16(format.mChannelsPerFrame)
        let bitsPerSample = UInt16(format.mBitsPerChannel)
        let bytesPerSample = UInt32(bitsPerSample / 8)
        let blockAlign = UInt16(UInt32(channels) * bytesPerSample)
        let sampleRate = UInt32(format.mSampleRate.rounded())
        let byteRate = sampleRate * UInt32(blockAlign)
        let audioFormat: UInt16 = format.mFormatFlags & kAudioFormatFlagIsFloat != 0 ? 3 : 1
        var data = Data()
        data.reserveCapacity(44 + pcmData.count)
        data.appendASCII("RIFF")
        data.appendLittleEndian(UInt32(36 + pcmData.count))
        data.appendASCII("WAVE")
        data.appendASCII("fmt ")
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(audioFormat)
        data.appendLittleEndian(channels)
        data.appendLittleEndian(sampleRate)
        data.appendLittleEndian(byteRate)
        data.appendLittleEndian(blockAlign)
        data.appendLittleEndian(bitsPerSample)
        data.appendASCII("data")
        data.appendLittleEndian(UInt32(pcmData.count))
        data.append(pcmData)
        return data
    }
}

private extension Data {
    mutating func appendASCII(_ value: String) {
        append(contentsOf: value.utf8)
    }

    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    func littleEndianUInt32(at offset: Int) -> UInt32 {
        self[offset..<(offset + 4)].enumerated().reduce(0) { result, item in
            result | (UInt32(item.element) << UInt32(item.offset * 8))
        }
    }

    mutating func replaceLittleEndian(_ value: UInt32, in range: Range<Int>) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { replaceSubrange(range, with: $0) }
    }
}
