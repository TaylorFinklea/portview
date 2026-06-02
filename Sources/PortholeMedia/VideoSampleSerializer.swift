import Foundation
import CoreMedia
import PortholeProtocol

/// An encoded video frame in a transport-friendly form: the codec parameter sets
/// (VPS/SPS/PPS for HEVC) plus the AVCC-framed NAL data, and whether it is a keyframe.
public struct EncodedVideoSample: Sendable, Equatable {
    public var parameterSets: [[UInt8]]
    public var data: [UInt8]
    public var isKeyframe: Bool

    public init(parameterSets: [[UInt8]], data: [UInt8], isKeyframe: Bool) {
        self.parameterSets = parameterSets
        self.data = data
        self.isKeyframe = isKeyframe
    }

    /// Pack into a byte blob suitable for a `VideoFrame.data` payload.
    public func serialized() -> [UInt8] {
        var writer = BinaryWriter()
        writer.putBool(isKeyframe)
        writer.putVarUInt(UInt64(parameterSets.count))
        for set in parameterSets { writer.putData(set) }
        writer.putData(data)
        return writer.bytes
    }

    /// Unpack from a `VideoFrame.data` payload.
    public init(serialized bytes: [UInt8]) throws {
        var reader = BinaryReader(bytes)
        let isKeyframe = try reader.bool()
        let count = try reader.varUInt()
        var sets: [[UInt8]] = []
        for _ in 0..<count { sets.append(try reader.data()) }
        let data = try reader.data()
        self.init(parameterSets: sets, data: data, isKeyframe: isKeyframe)
    }
}

/// Converts between VideoToolbox `CMSampleBuffer`s and the transport-friendly `EncodedVideoSample`.
public enum VideoSampleSerializer {
    /// Extract parameter sets + NAL data from an encoded HEVC sample buffer.
    public static func serialize(_ sampleBuffer: CMSampleBuffer) throws -> EncodedVideoSample {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            throw VideoCodecError.noOutput
        }

        var count = 0
        let countStatus = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
            format, parameterSetIndex: 0,
            parameterSetPointerOut: nil, parameterSetSizeOut: nil,
            parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil
        )
        guard countStatus == noErr else { throw VideoCodecError.encodeFailed(countStatus) }

        var parameterSets: [[UInt8]] = []
        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                format, parameterSetIndex: index,
                parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
            )
            guard status == noErr, let pointer else { throw VideoCodecError.encodeFailed(status) }
            parameterSets.append(Array(UnsafeBufferPointer(start: pointer, count: size)))
        }

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            throw VideoCodecError.noOutput
        }
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let dataStatus = CMBlockBufferGetDataPointer(
            blockBuffer, atOffset: 0, lengthAtOffsetOut: nil,
            totalLengthOut: &totalLength, dataPointerOut: &dataPointer
        )
        guard dataStatus == noErr, let dataPointer else { throw VideoCodecError.encodeFailed(dataStatus) }
        let data = dataPointer.withMemoryRebound(to: UInt8.self, capacity: totalLength) {
            Array(UnsafeBufferPointer(start: $0, count: totalLength))
        }

        return EncodedVideoSample(parameterSets: parameterSets, data: data, isKeyframe: isKeyframe(sampleBuffer))
    }

    /// Rebuild a decodable `CMSampleBuffer` from an `EncodedVideoSample` (HEVC, 4-byte NAL length).
    public static func deserialize(_ sample: EncodedVideoSample) throws -> CMSampleBuffer {
        var allocations: [UnsafeMutableBufferPointer<UInt8>] = []
        defer { for buffer in allocations { buffer.deallocate() } }
        var pointers: [UnsafePointer<UInt8>] = []
        var sizes: [Int] = []
        for set in sample.parameterSets {
            let buffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: set.count)
            _ = buffer.initialize(from: set)
            allocations.append(buffer)
            pointers.append(UnsafePointer(buffer.baseAddress!))
            sizes.append(set.count)
        }

        var format: CMFormatDescription?
        let formatStatus = pointers.withUnsafeBufferPointer { pointerBuffer in
            sizes.withUnsafeBufferPointer { sizeBuffer in
                CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: pointers.count,
                    parameterSetPointers: pointerBuffer.baseAddress!,
                    parameterSetSizes: sizeBuffer.baseAddress!,
                    nalUnitHeaderLength: 4,
                    extensions: nil,
                    formatDescriptionOut: &format
                )
            }
        }
        guard formatStatus == noErr, let format else { throw VideoCodecError.decodeFailed(formatStatus) }

        var blockBuffer: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: sample.data.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: sample.data.count, flags: 0, blockBufferOut: &blockBuffer
        )
        guard blockStatus == kCMBlockBufferNoErr, let blockBuffer else { throw VideoCodecError.decodeFailed(blockStatus) }
        let copyStatus = sample.data.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: sample.data.count)
        }
        guard copyStatus == kCMBlockBufferNoErr else { throw VideoCodecError.decodeFailed(copyStatus) }

        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sampleSize = sample.data.count
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: blockBuffer, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let sampleBuffer else { throw VideoCodecError.decodeFailed(sampleStatus) }
        return sampleBuffer
    }

    private static func isKeyframe(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
              let first = attachments.first else {
            return true
        }
        let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        return !notSync
    }
}
