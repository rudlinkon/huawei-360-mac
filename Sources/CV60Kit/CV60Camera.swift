import Foundation

/// High-level CV60 protocol, reverse engineered from a.a.a.a (UsbCoreMsg handler) in the Android app.
///
/// Every command is a 16-byte CDB. Byte 0 of the response is a status:
/// 0 = ok, 1 = busy, 2 = fail, 0xFF = camera went to power-save (re-open communication, then retry).
public final class CV60Camera {
    public enum LiveResolution: UInt8, CaseIterable, CustomStringConvertible {
        case r1280 = 10 // 1280x640
        case r1920 = 9 // 1920x960
        public var size: (w: Int, h: Int) { self == .r1920 ? (1920, 960) : (1280, 640) }
        public var description: String { "\(size.w)x\(size.h)" }
    }

    public struct Frame {
        public let h264: [UInt8] // Annex-B (00 00 00 01 start codes)
        public let width: Int
        public let height: Int
        public let thermal: UInt8 // 0 normal, 1 hot, 2 overheat (app powers off), 3 cold
    }

    public struct Settings {
        public var raw: [UInt8] // 48 bytes, layout from cmd 18503/18519
        public var photoResolution: UInt8 { raw[2] }
        public var videoResolution: UInt8 { raw[3] }
        public var ev: UInt8 { raw[6] }
        public var whiteBalance: UInt8 { raw[7] }
        public var filter: UInt8 { raw[32] }
        public var bitrate: UInt8 { raw[35] }
        public var logoType: UInt8 { raw[39] }
        public var dateString: String {
            let year = Int(raw[10]) | Int(raw[11]) << 8
            return String(format: "%04d-%02d-%02d %02d:%02d:%02d", year, raw[12], raw[13], raw[14], raw[15], raw[16])
        }
    }

    public static let appVersion = "7.72.00" // res/values/strings.xml internal_app_version

    public let usb: USBDevice
    public let scsi: SCSITransport
    public var log: (String) -> Void = { print($0) } {
        didSet { usb.log = log; scsi.log = log }
    }

    public init() throws {
        usb = try USBDevice()
        scsi = SCSITransport(usb: usb)
        usb.log = log
        scsi.log = log
    }

    public func connect() throws {
        try usb.open()
    }

    public func disconnect() {
        usb.close()
    }

    private func cdb(_ b0: UInt8, _ b1: UInt8, _ b2: UInt8) -> [UInt8] {
        var c = [UInt8](repeating: 0, count: 16)
        c[0] = b0; c[1] = b1; c[2] = b2
        return c
    }

    /// Sends a read command; transparently handles power-save (0xFF) and one busy retry.
    @discardableResult
    private func command(_ c: [UInt8], allowBusy: Bool = false) throws -> [UInt8] {
        var resp = try scsi.read(c)
        if resp.first == 0xFF {
            log("camera in power-save mode, re-opening communication")
            try openCommunication(reset: false)
            resp = try scsi.read(c)
        }
        guard let status = resp.first else { throw CV60Error.camera("empty response to \(hex(c.prefix(3)))") }
        if status == 0 || (status == 1 && allowBusy) { return resp }
        throw CV60Error.camera("command \(hex(c.prefix(3))) returned status \(status)")
    }

    // MARK: - Session

    /// 7A 00 01 — "open communication". Retries while the camera answers busy (1).
    public func openCommunication(reset: Bool = true) throws {
        if reset {
            do { try usb.massStorageReset() } catch { log("reset: \(error)") }
            usb.clearHalts()
        }
        for attempt in 1...200 {
            do {
                let r = try scsi.read(cdb(0x7A, 0x00, 0x01))
                switch r.first {
                case 0: return
                case 1: break
                default: throw CV60Error.camera("open communication failed: status \(r.first.map { String($0) } ?? "-")")
                }
            } catch let e as CV60Error {
                if case .camera = e { throw e }
                log("open communication try \(attempt): \(e)")
                try? usb.massStorageReset()
                usb.clearHalts()
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw CV60Error.camera("camera stayed busy while opening communication")
    }

    /// 7A 00 02 — close communication (camera goes back to idle).
    public func closeCommunication() throws {
        var c = cdb(0x7A, 0x00, 0x02)
        c[8] = 1
        c[12] = 0x2C; c[13] = 0x01 // 300 (LE)
        try command(c)
    }

    /// 7A 01 F0 — power the camera off (the Android app does this on overheat).
    public func powerOff() throws {
        try command(cdb(0x7A, 0x01, 0xF0))
    }

    /// 7A 03 FF — keep-alive; the app sends it every 500 ms when idle.
    public func keepAlive() throws {
        _ = try scsi.read(cdb(0x7A, 0x03, 0xFF), small: true)
    }

    // MARK: - Info

    /// 7A 03 01 — camera info. The app version string goes in CDB[8...]; firmware version comes back at offset 97.
    public func firmwareVersion() throws -> String {
        var c = cdb(0x7A, 0x03, 0x01)
        for (i, b) in Self.appVersion.utf8.prefix(8).enumerated() { c[8 + i] = b }
        let r = try command(c)
        guard r.count > 97 else { return "?" }
        let bytes = r[97..<min(r.count, 129)].prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// 7A 03 30 — (execution status, thermal status).
    public func status() throws -> (execution: UInt8, thermal: UInt8) {
        let r = try command(cdb(0x7A, 0x03, 0x30))
        return (r.count > 1 ? r[1] : 0, r.count > 4 ? r[4] : 0)
    }

    /// Raw dump of any read command, for exploration from the CLI.
    public func rawRead(_ b1: UInt8, _ b2: UInt8) throws -> [UInt8] {
        try scsi.read(cdb(0x7A, b1, b2))
    }

    // MARK: - Settings

    /// 7A 04 60 — all settings (48 bytes).
    public func settings() throws -> Settings {
        let r = try command(cdb(0x7A, 0x04, 0x60))
        var raw = [UInt8](repeating: 0, count: 48)
        for i in 0..<min(48, r.count) { raw[i] = r[i] }
        return Settings(raw: raw)
    }

    /// 7B 04 60 — write all settings. Same field layout the app uses; clock is set to now.
    public func writeSettings(_ s: Settings, date: Date = Date()) throws {
        var d = [UInt8](repeating: 0, count: 48)
        for i in [2, 3, 6, 7, 32, 35, 39] { d[i] = s.raw[i] }
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: date)
        let year = comps.year ?? 2020
        d[10] = UInt8(year & 0xFF); d[11] = UInt8(year >> 8)
        d[12] = UInt8(comps.month ?? 1); d[13] = UInt8(comps.day ?? 1)
        d[14] = UInt8(comps.hour ?? 0); d[15] = UInt8(comps.minute ?? 0); d[16] = UInt8(comps.second ?? 0)
        let ms = (comps.nanosecond ?? 0) / 1_000_000
        d[18] = UInt8(ms & 0xFF); d[19] = UInt8(ms >> 8)
        var c = cdb(0x7B, 0x04, 0x60)
        c[4] = 48
        try scsi.write(c, data: d)
    }

    // MARK: - Live view

    /// 7A 01 01 — start live view. CDB[9] = resolution code.
    public func startLiveView(_ res: LiveResolution) throws {
        var c = cdb(0x7A, 0x01, 0x01)
        c[9] = res.rawValue
        try command(c)
    }

    /// 7A 02 01 — true once the live stream is running.
    public func liveViewReady() throws -> Bool {
        let r = try command(cdb(0x7A, 0x02, 0x01), allowBusy: true)
        return r[0] == 0
    }

    /// 7A 01 02 — stop live view.
    public func stopLiveView() throws {
        try command(cdb(0x7A, 0x01, 0x02))
    }

    /// Starts live view and waits until the camera reports it ready.
    public func beginStreaming(_ res: LiveResolution, timeout: TimeInterval = 10) throws {
        try startLiveView(res)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try liveViewReady() { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw CV60Error.camera("live view did not become ready within \(Int(timeout))s")
    }

    // MARK: - Photo (full resolution, taken by the camera itself)

    public struct CaptureStatus {
        public let code: UInt8 // 0 picture ready · 1 busy · 3 capture finished
        public let exposureDone: Bool
        public let storedPictures: UInt8
        public let name: String
    }

    /// 7A 01 05 — shutter. Live view must be running. CDB[8] = orientation code 0...3
    /// (the Android app derives it from the phone's rotation sensor).
    public func takePicture(orientation: UInt8 = 0) throws {
        var c = cdb(0x7A, 0x01, 0x05)
        c[8] = orientation
        try command(c)
    }

    /// 7A 02 05 — capture progress.
    public func captureStatus() throws -> CaptureStatus {
        var r = try scsi.read(cdb(0x7A, 0x02, 0x05))
        if r.first == 0xFF {
            try openCommunication(reset: false)
            r = try scsi.read(cdb(0x7A, 0x02, 0x05))
        }
        guard r.count >= 4 else { throw CV60Error.camera("short capture status") }
        let name = r.count > 8 ? String(decoding: r[8..<min(r.count, 72)].prefix { $0 != 0 }, as: UTF8.self) : ""
        return CaptureStatus(code: r[0], exposureDone: r[2] == 0, storedPictures: r[3], name: name)
    }

    /// 7A 05 03 — small preview JPEG of the last capture (len at [16..19], data at [20...]).
    public func thumbnail() throws -> [UInt8]? {
        let r = try command(cdb(0x7A, 0x05, 0x03), allowBusy: true)
        if r[0] == 1 || r.count < 20 { return nil }
        let len = Int(r[16]) | Int(r[17]) << 8 | Int(r[18]) << 16 | Int(r[19]) << 24
        guard len > 0, 20 + len <= r.count else { return nil }
        return Array(r[20..<(20 + len)])
    }

    /// 7A 05 02 — downloads the full-resolution JPEG. CDB[8..11] = byte offset (LE);
    /// response [1] = last-piece flag, [16..19] = piece length, [20...] = data.
    /// Finishes with 7A 05 82 ("picture received").
    public func downloadPicture(progress: (Int) -> Void = { _ in }, timeout: TimeInterval = 60) throws -> [UInt8] {
        var jpeg = [UInt8]()
        var c = cdb(0x7A, 0x05, 0x02)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let off = UInt32(jpeg.count)
            c[8] = UInt8(off & 0xFF); c[9] = UInt8(off >> 8 & 0xFF); c[10] = UInt8(off >> 16 & 0xFF); c[11] = UInt8(off >> 24)
            let r = try command(c, allowBusy: true)
            if r[0] == 1 { Thread.sleep(forTimeInterval: 0.005); continue }
            guard r.count >= 20 else { throw CV60Error.camera("short picture header") }
            let len = Int(r[16]) | Int(r[17]) << 8 | Int(r[18]) << 16 | Int(r[19]) << 24
            guard len >= 0, 20 + len <= r.count else { throw CV60Error.camera("invalid picture piece length \(len)") }
            jpeg.append(contentsOf: r[20..<(20 + len)])
            progress(jpeg.count)
            if r[1] != 0 {
                var done = cdb(0x7A, 0x05, 0x82)
                done[8] = c[8]; done[9] = c[9]; done[10] = c[10]; done[11] = c[11]
                _ = try? scsi.read(done)
                return jpeg
            }
        }
        throw CV60Error.camera("picture download timed out (\(jpeg.count) bytes)")
    }

    /// Full capture sequence: shutter → wait ready → download → wait until the camera is done.
    /// Live view keeps running afterwards (call nextFrame() again).
    public func capturePhoto(orientation: UInt8 = 0, timeout: TimeInterval = 30,
                             progress: (String) -> Void = { _ in }) throws -> [UInt8] {
        try takePicture(orientation: orientation)
        progress("Capturing…")
        let deadline = Date().addingTimeInterval(timeout)
        var st = try captureStatus()
        while st.code != 0 {
            if st.code == 3 { throw CV60Error.camera("camera finished capture without a picture") }
            if st.code != 1 { throw CV60Error.camera("capture failed: status \(st.code)") }
            if Date() > deadline { throw CV60Error.camera("capture timed out") }
            Thread.sleep(forTimeInterval: 0.02)
            st = try captureStatus()
        }
        if !st.name.isEmpty { log("camera picture: \(st.name) (stored: \(st.storedPictures))") }
        progress("Downloading…")
        let jpeg = try downloadPicture(progress: { progress("Downloading… \($0 / 1024) KB") })
        // Wait for "capture done" so live view resumes cleanly.
        while Date() < deadline {
            let s = try captureStatus()
            if s.code == 3 || (s.code != 0 && s.code != 1) { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return jpeg
    }

    /// 7A 05 01 — fetch one H.264 frame. The frame arrives in pieces:
    /// resp[1] = 0 while more pieces follow, resp[4] = resolution, resp[20] = thermal,
    /// resp[28..31] = piece length (LE), resp[32...] = piece bytes.
    /// Returns nil when the camera has no frame ready yet (busy).
    public func nextFrame() throws -> Frame? {
        var c = cdb(0x7A, 0x05, 0x01)
        c[8] = 0
        var data = [UInt8]()
        while true {
            let r = try command(c, allowBusy: true)
            if r[0] == 1 { return nil }
            guard r.count >= 32 else { throw CV60Error.camera("short frame header (\(r.count) bytes)") }
            let len = Int(r[28]) | Int(r[29]) << 8 | Int(r[30]) << 16 | Int(r[31]) << 24
            guard len >= 0, 32 + len <= r.count else {
                throw CV60Error.camera("invalid frame piece length \(len) (got \(r.count))")
            }
            data.append(contentsOf: r[32..<(32 + len)])
            if data.count > 4 * 1024 * 1024 { throw CV60Error.camera("frame too large") }
            if r[1] != 0 {
                let (w, h): (Int, Int)
                switch r[4] {
                case 9: (w, h) = (1920, 960)
                case 11: (w, h) = (3840, 1920)
                default: (w, h) = (1280, 640)
                }
                return Frame(h264: data, width: w, height: h, thermal: r[20])
            }
        }
    }
}
