import Foundation

/// USB Mass Storage Bulk-Only Transport, carrying Huawei vendor CDBs (opcode 0x7A read / 0x7B write).
/// Mirrors a.b.a.b / a.b.a.a in the decompiled Android app.
public final class SCSITransport {
    public static let bigReadSize = 65536
    public static let smallReadSize = 64
    private static let chunk = 16384

    private let usb: USBDevice
    private let lock = NSLock()
    private var chunkBuf = [UInt8](repeating: 0, count: SCSITransport.chunk)
    public private(set) var lastActivity = Date()
    public var log: (String) -> Void = { _ in }
    public var traceCommands = false

    public init(usb: USBDevice) {
        self.usb = usb
    }

    private func makeCBW(tag: UInt32, length: UInt32, dirIn: Bool, cdb: [UInt8]) -> [UInt8] {
        var cbw = [UInt8](repeating: 0, count: 31)
        cbw[0] = 0x55; cbw[1] = 0x53; cbw[2] = 0x42; cbw[3] = 0x43 // "USBC"
        withUnsafeBytes(of: tag.bigEndian) { for i in 0..<4 { cbw[4 + i] = $0[i] } }
        withUnsafeBytes(of: length.littleEndian) { for i in 0..<4 { cbw[8 + i] = $0[i] } }
        cbw[12] = dirIn ? 0x80 : 0x00
        cbw[13] = 0 // LUN
        cbw[14] = 16 // CDB length
        for i in 0..<min(16, cdb.count) { cbw[15 + i] = cdb[i] }
        return cbw
    }

    /// True if the last 13 bytes of `buf[0..<n]` are a CSW ("USBS") for `tag`.
    private func endsWithCSW(_ buf: [UInt8], _ n: Int, tag: UInt32?) -> Bool {
        guard n >= 13 else { return false }
        let o = n - 13
        guard buf[o] == 0x55, buf[o + 1] == 0x53, buf[o + 2] == 0x42, buf[o + 3] == 0x53 else { return false }
        guard let tag else { return true }
        let t = withUnsafeBytes(of: tag.bigEndian) { Array($0) }
        return buf[o + 4] == t[0] && buf[o + 5] == t[1] && buf[o + 6] == t[2] && buf[o + 7] == t[3]
    }

    private func sendCBW(_ cbw: [UInt8], timeoutMs: UInt32) throws {
        var cbw = cbw
        let n = try cbw.withUnsafeMutableBufferPointer { try usb.bulk(usb.epOut, $0.baseAddress!, 31, timeoutMs: timeoutMs) }
        if n != 31 { throw CV60Error.badCSW("short CBW write (\(n))") }
    }

    /// Vendor "read" command: returns the data phase (without CSW).
    public func read(_ cdb: [UInt8], small: Bool = false, timeoutMs: UInt32 = 2000) throws -> [UInt8] {
        lock.lock(); defer { lock.unlock(); lastActivity = Date() }
        let maxLen = small ? Self.smallReadSize : Self.bigReadSize
        let tag = UInt32.random(in: 1...UInt32.max)
        if traceCommands { log("CMD " + hex(cdb)) }
        try sendCBW(makeCBW(tag: tag, length: UInt32(maxLen), dirIn: true, cdb: cdb), timeoutMs: timeoutMs)

        var out = [UInt8]()
        out.reserveCapacity(maxLen)
        while true {
            let n = try chunkBuf.withUnsafeMutableBufferPointer {
                try usb.bulk(usb.epIn, $0.baseAddress!, Self.chunk, timeoutMs: timeoutMs)
            }
            if n == 0 { throw CV60Error.badCSW("empty read for \(hex(Array(cdb.prefix(3))))") }
            if endsWithCSW(chunkBuf, n, tag: tag) {
                if n > 13 { out.append(contentsOf: chunkBuf[0..<(n - 13)]) }
                let status = chunkBuf[n - 1]
                if status != 0 && traceCommands { log("CSW status \(status) for \(hex(Array(cdb.prefix(3))))") }
                return out
            }
            if out.count + n > maxLen {
                throw CV60Error.badCSW("data overflow (\(out.count + n) > \(maxLen))")
            }
            out.append(contentsOf: chunkBuf[0..<n])
        }
    }

    /// Vendor "write" command with a data-out phase.
    public func write(_ cdb: [UInt8], data: [UInt8], timeoutMs: UInt32 = 2000) throws {
        lock.lock(); defer { lock.unlock(); lastActivity = Date() }
        let tag = UInt32.random(in: 1...UInt32.max)
        if traceCommands { log("WRITE " + hex(cdb) + " (\(data.count) bytes)") }
        try sendCBW(makeCBW(tag: tag, length: UInt32(data.count), dirIn: false, cdb: cdb), timeoutMs: timeoutMs)
        var offset = 0
        var data = data
        while offset < data.count {
            let len = min(Self.chunk, data.count - offset)
            let n = try data.withUnsafeMutableBufferPointer {
                try usb.bulk(usb.epOut, $0.baseAddress! + offset, len, timeoutMs: timeoutMs)
            }
            if n != len { throw CV60Error.badCSW("short data write \(n)/\(len)") }
            offset += len
        }
        let n = try chunkBuf.withUnsafeMutableBufferPointer {
            try usb.bulk(usb.epIn, $0.baseAddress!, Self.chunk, timeoutMs: timeoutMs)
        }
        if !endsWithCSW(chunkBuf, n, tag: nil) { throw CV60Error.badCSW("no CSW after write") }
    }
}

public func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
    bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
}
