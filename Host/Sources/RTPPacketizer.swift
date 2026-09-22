import Foundation
import CoreMedia
import LSProtocol

/// Turns VideoToolbox's AVCC output into RFC 6184 RTP packets and pushes them
/// straight at the socket.
///
/// VideoToolbox hands us length-prefixed NAL units (AVCC). RTP wants bare NAL
/// units, one per packet when they fit and FU-A fragments when they do not, so
/// we strip the length prefixes and re-frame.
final class RTPPacketizer {

    private let sender: UDPSender
    private let ssrc: UInt32
    /// Total datagram size including the 12-byte RTP header.
    private var mtuPayload: Int

    private var sequence: UInt16 = 0
    private var packetBuffer: UnsafeMutableRawPointer

    /// Only ever touched on the VideoToolbox output thread.
    private var lastParameterSets: [Data] = []
    /// Set from another thread when a client appears, so it needs a lock. The
    /// parameter sets themselves stay single-threaded.
    private let resendLock = NSLock()
    private var resendParameterSets = false

    private(set) var packetsSent: UInt64 = 0
    private(set) var bytesSent: UInt64 = 0

    init(sender: UDPSender, mtuPayload: Int) {
        self.sender = sender
        self.mtuPayload = max(Int(LS_RTP_HEADER_SIZE) + 64,
                              min(mtuPayload, Int(LS_MAX_UDP_PAYLOAD)))
        self.ssrc = UInt32.random(in: 1...UInt32.max)
        self.packetBuffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(LS_MAX_UDP_PAYLOAD), alignment: 16)
        // Starting at a random sequence number is what RTP asks for, and it
        // stops a restarted host from colliding with a client that is still
        // holding state from the previous run.
        self.sequence = UInt16.random(in: 0...UInt16.max)
    }

    deinit { packetBuffer.deallocate() }

    /// Forces the next keyframe to re-send SPS/PPS even if they have not
    /// changed. Called from the control thread when a new client says hello.
    func invalidateParameterSetCache() {
        resendLock.lock()
        resendParameterSets = true
        resendLock.unlock()
    }

    func packetize(sampleBuffer: CMSampleBuffer) {
        resendLock.lock()
        let forceParameterSets = resendParameterSets
        resendParameterSets = false
        resendLock.unlock()

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let rtpTimestamp = UInt32(truncatingIfNeeded:
            Int64((pts.seconds * Double(LS_RTP_CLOCK_HZ)).rounded()))

        let isKeyframe = Self.isKeyframe(sampleBuffer)

        // --- parameter sets -------------------------------------------------
        var nalHeaderLength: Int32 = 4
        if let fmt = CMSampleBufferGetFormatDescription(sampleBuffer) {
            let sets = Self.parameterSets(from: fmt, nalHeaderLength: &nalHeaderLength)
            if isKeyframe && (forceParameterSets || sets != lastParameterSets) {
                for set in sets {
                    set.withUnsafeBytes { raw in
                        guard let base = raw.baseAddress else { return }
                        emitNAL(base, raw.count, timestamp: rtpTimestamp, marker: false)
                    }
                }
                lastParameterSets = sets
            }
        }

        // --- slice data -----------------------------------------------------
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0,
                                          lengthAtOffsetOut: nil,
                                          totalLengthOut: &totalLength,
                                          dataPointerOut: &dataPointer) == kCMBlockBufferNoErr,
              let base = dataPointer else { return }

        let bytes = UnsafeRawPointer(base).assumingMemoryBound(to: UInt8.self)
        let prefix = Int(nalHeaderLength)

        // First pass: find NAL boundaries so we know which one is last and can
        // set the RTP marker bit on the final packet of the access unit.
        var ranges: [(offset: Int, length: Int)] = []
        var cursor = 0
        while cursor + prefix <= totalLength {
            var length = 0
            for i in 0..<prefix { length = (length << 8) | Int(bytes[cursor + i]) }
            cursor += prefix
            if length <= 0 || cursor + length > totalLength { break }
            ranges.append((cursor, length))
            cursor += length
        }

        for (index, range) in ranges.enumerated() {
            let isLast = (index == ranges.count - 1)
            emitNAL(UnsafeRawPointer(bytes + range.offset), range.length,
                    timestamp: rtpTimestamp, marker: isLast)
        }
    }

    // MARK: - packet emission

    private func emitNAL(_ nal: UnsafeRawPointer, _ length: Int,
                         timestamp: UInt32, marker: Bool) {
        guard length > 0 else { return }
        let maxPayload = mtuPayload - Int(LS_RTP_HEADER_SIZE)

        if length <= maxPayload {
            // Single NAL unit packet: the NAL goes in verbatim, header and all.
            let header = ls_rtp_write_header(packetBuffer.assumingMemoryBound(to: UInt8.self),
                                             Int(LS_MAX_UDP_PAYLOAD),
                                             marker ? 1 : 0, sequence, timestamp, ssrc)
            sequence &+= 1
            memcpy(packetBuffer + Int(header), nal, length)
            transmit(Int(header) + length)
            return
        }

        // FU-A. The original NAL header byte is consumed: its NRI goes into the
        // FU indicator and its type into the FU header, so only bytes 1..n of
        // the NAL are actually fragmented.
        let nalBytes = nal.assumingMemoryBound(to: UInt8.self)
        let nalHeader = nalBytes[0]
        var offset = 1
        let remainingTotal = length - 1
        let fragmentCapacity = maxPayload - 2   // 2 bytes of FU-A prefix

        guard fragmentCapacity > 0, remainingTotal > 0 else { return }

        while offset < length {
            let remaining = length - offset
            let chunk = min(fragmentCapacity, remaining)
            let isStart = (offset == 1)
            let isEnd = (chunk == remaining)

            let p = packetBuffer.assumingMemoryBound(to: UInt8.self)
            let header = ls_rtp_write_header(p, Int(LS_MAX_UDP_PAYLOAD),
                                             (marker && isEnd) ? 1 : 0,
                                             sequence, timestamp, ssrc)
            sequence &+= 1
            let fu = ls_rtp_write_fu_a_prefix(p + Int(header),
                                              Int(LS_MAX_UDP_PAYLOAD) - Int(header),
                                              nalHeader, isStart ? 1 : 0, isEnd ? 1 : 0)
            memcpy(packetBuffer + Int(header) + Int(fu), nal + offset, chunk)
            transmit(Int(header) + Int(fu) + chunk)
            offset += chunk
        }
    }

    private func transmit(_ count: Int) {
        let n = sender.send(packetBuffer, count)
        if n > 0 {
            packetsSent &+= 1
            bytesSent &+= UInt64(n)
        }
    }

    // MARK: - helpers

    static func isKeyframe(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
              let first = attachments.first else { return true }
        // No "NotSync" attachment at all means this IS a sync sample.
        if let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool {
            return !notSync
        }
        return true
    }

    static func parameterSets(from fmt: CMFormatDescription,
                              nalHeaderLength: inout Int32) -> [Data] {
        var count = 0
        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                fmt, parameterSetIndex: 0,
                parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: &count,
                nalUnitHeaderLengthOut: &nalHeaderLength) == noErr else { return [] }

        var result: [Data] = []
        result.reserveCapacity(count)
        for i in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    fmt, parameterSetIndex: i,
                    parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr,
               let p = pointer, size > 0 {
                result.append(Data(bytes: p, count: size))
            }
        }
        return result
    }

    /// SPS/PPS as base64, for the fmtp line of the .sdp test file.
    var sdpParameterSets: (sps: String, pps: String)? {
        guard lastParameterSets.count >= 2 else { return nil }
        return (lastParameterSets[0].base64EncodedString(),
                lastParameterSets[1].base64EncodedString())
    }
}
