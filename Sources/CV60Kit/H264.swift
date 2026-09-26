import AVFoundation
import CoreMedia
import VideoToolbox

/// Converts the camera's Annex-B access units into CMSampleBuffers (AVCC) and decodes them.
public final class H264Decoder {
    public private(set) var formatDescription: CMVideoFormatDescription?
    private var sps: [UInt8]?
    private var pps: [UInt8]?
    private var session: VTDecompressionSession?
    private var sawKeyframe = false

    public init() {}

    deinit { invalidate() }

    public func invalidate() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
    }

    /// Splits an Annex-B buffer into NAL units (without start codes).
    public static func nalUnits(_ b: [UInt8]) -> [ArraySlice<UInt8>] {
        var units: [ArraySlice<UInt8>] = []
        var i = 0, start = -1
        let n = b.count
        while i + 2 < n {
            if b[i] == 0 && b[i + 1] == 0 && b[i + 2] == 1 {
                if start >= 0 {
                    var end = i
                    if end > start && b[end - 1] == 0 { end -= 1 } // 4-byte start code
                    units.append(b[start..<end])
                }
                i += 3
                start = i
            } else {
                i += 1
            }
        }
        if start >= 0 && start < n { units.append(b[start..<n]) }
        return units.filter { !$0.isEmpty }
    }

    /// Groups a raw Annex-B stream (e.g. a `cv60 dump` file) into access units,
    /// splitting on AUD / SPS / first-slice-of-picture boundaries.
    public static func accessUnits(_ bytes: [UInt8]) -> [[UInt8]] {
        var units: [[UInt8]] = []
        var cur = [UInt8]()
        var curHasSlice = false
        for nal in nalUnits(bytes) {
            let t = nal.first! & 0x1F
            let firstSlice = (t == 1 || t == 5) && nal.count > 1 && nal[nal.startIndex + 1] & 0x80 != 0
            if (t == 9 || t == 7 || firstSlice) && curHasSlice {
                units.append(cur); cur = []; curHasSlice = false
            }
            cur += [0, 0, 0, 1] + nal
            if t == 1 || t == 5 { curHasSlice = true }
        }
        if curHasSlice { units.append(cur) }
        return units
    }

    /// Builds a CMSampleBuffer for one access unit. Returns nil until SPS/PPS and a keyframe were seen.
    public func sampleBuffer(annexB: [UInt8], pts: CMTime) -> CMSampleBuffer? {
        var avcc = [UInt8]()
        var isKey = false
        var paramsChanged = false
        for nal in Self.nalUnits(annexB) {
            let type = nal.first! & 0x1F
            switch type {
            case 7:
                if sps.map({ $0[...] != nal }) ?? true { sps = Array(nal); paramsChanged = true }
            case 8:
                if pps.map({ $0[...] != nal }) ?? true { pps = Array(nal); paramsChanged = true }
            case 9:
                continue // access unit delimiter
            default:
                if type == 5 { isKey = true }
                let len = UInt32(nal.count).bigEndian
                withUnsafeBytes(of: len) { avcc.append(contentsOf: $0) }
                avcc.append(contentsOf: nal)
            }
        }
        if paramsChanged, let sps, let pps {
            var fd: CMFormatDescription?
            let status = sps.withUnsafeBufferPointer { s in
                pps.withUnsafeBufferPointer { p in
                    let ptrs = [s.baseAddress!, p.baseAddress!]
                    let sizes = [sps.count, pps.count]
                    return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                        allocator: kCFAllocatorDefault, parameterSetCount: 2,
                        parameterSetPointers: ptrs, parameterSetSizes: sizes,
                        nalUnitHeaderLength: 4, formatDescriptionOut: &fd)
                }
            }
            if status == noErr, let fd {
                formatDescription = fd
                if let session, !VTDecompressionSessionCanAcceptFormatDescription(session, formatDescription: fd) {
                    invalidate()
                }
            }
        }
        guard let fd = formatDescription, !avcc.isEmpty else { return nil }
        if isKey { sawKeyframe = true }
        guard sawKeyframe else { return nil }

        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: avcc.count,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: avcc.count, flags: 0, blockBufferOut: &block) == noErr,
              let block,
              CMBlockBufferReplaceDataBytes(with: avcc, blockBuffer: block, offsetIntoDestination: 0, dataLength: avcc.count) == noErr
        else { return nil }

        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var size = avcc.count
        var sb: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: fd,
                                        sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sb) == noErr,
              let sb else { return nil }
        if !isKey, let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true) as? [NSMutableDictionary],
           let first = atts.first {
            first[kCMSampleAttachmentKey_NotSync] = true
        }
        return sb
    }

    /// Synchronously decodes to a BGRA, Metal-compatible pixel buffer.
    public func decode(_ sb: CMSampleBuffer) -> CVPixelBuffer? {
        guard let fd = CMSampleBufferGetFormatDescription(sb) else { return nil }
        if session == nil {
            let attrs: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferMetalCompatibilityKey: true,
            ]
            var s: VTDecompressionSession?
            let rc = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: fd, decoderSpecification: nil,
                                                  imageBufferAttributes: attrs as CFDictionary, outputCallback: nil,
                                                  decompressionSessionOut: &s)
            guard rc == noErr else { return nil }
            session = s
        }
        guard let session else { return nil }
        var out: CVPixelBuffer?
        _ = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sb, flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
            if status == noErr { out = image }
        }
        return out
    }
}

/// Writes the camera's H.264 stream into an MP4 without re-encoding.
public final class MP4Recorder {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private var started = false
    public let url: URL

    public init(url: URL, format: CMFormatDescription) throws {
        self.url = url
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
        input.expectsMediaDataInRealTime = true
        writer.add(input)
    }

    public func append(_ sb: CMSampleBuffer) {
        if !started {
            // Start on a keyframe so the file is playable from frame 0.
            if let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]],
               atts.first?[kCMSampleAttachmentKey_NotSync] as? Bool == true { return }
            guard writer.startWriting() else { return }
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sb))
            started = true
        }
        if input.isReadyForMoreMediaData { input.append(sb) }
    }

    public func finish(_ done: @escaping () -> Void) {
        guard started else { done(); return }
        input.markAsFinished()
        writer.finishWriting(completionHandler: done)
    }
}
