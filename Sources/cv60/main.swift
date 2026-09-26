import CoreMedia
import CV60Kit
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

let usage = """
usage: cv60 [-v] <command>
  info                          connect, print firmware / status / settings
  dump <out.h264> [secs] [1920] stream live view to a raw H.264 file (default 10 s, 1280x640)
  photo <out.jpg> [orient 0-3]  take a full-resolution photo with the camera
  raw <b1> <b2>                 send 7A <b1> <b2> and hex-dump the response (hex bytes)
  off                           power the camera off (7A 01 F0)
  mp4 <in.h264> <out.mp4>       wrap a raw dump into an MP4 (no re-encode, 30 fps)

If connecting fails with ACCESS/BUSY, run with sudo (macOS mass-storage driver must be detached).
"""

var args = Array(CommandLine.arguments.dropFirst())
let verbose = args.first == "-v"
if verbose { args.removeFirst() }
guard let cmd = args.first else { print(usage); exit(1) }

var stopRequested = false
signal(SIGINT) { _ in stopRequested = true }

/// Offline: raw Annex-B dump -> MP4.
func convertToMP4(_ input: String, _ output: String) throws {
    let units = H264Decoder.accessUnits([UInt8](try Data(contentsOf: URL(fileURLWithPath: input))))
    let dec = H264Decoder()
    var rec: MP4Recorder?
    var n = 0
    for u in units {
        guard let sb = dec.sampleBuffer(annexB: u, pts: CMTime(value: CMTimeValue(n), timescale: 30)) else { continue }
        if rec == nil, let fd = dec.formatDescription {
            try? FileManager.default.removeItem(atPath: output)
            rec = try MP4Recorder(url: URL(fileURLWithPath: output), format: fd)
        }
        rec?.append(sb)
        n += 1
    }
    let done = DispatchSemaphore(value: 0)
    rec?.finish { done.signal() }
    done.wait()
    print("\(n) frames -> \(output)")
}

func run() throws {
    if cmd == "mp4" {
        guard args.count >= 3 else { print(usage); exit(1) }
        try convertToMP4(args[1], args[2])
        return
    }
    let cam = try CV60Camera()
    cam.scsi.traceCommands = verbose
    try cam.connect()
    defer { cam.disconnect() }

    print("opening communication…")
    try cam.openCommunication()
    print("firmware: \(try cam.firmwareVersion())")

    switch cmd {
    case "info":
        let st = try cam.status()
        print("execution status: \(st.execution)  thermal: \(st.thermal)")
        let s = try cam.settings()
        print("settings raw: \(hex(s.raw))")
        print("camera clock: \(s.dateString)  photoRes=\(s.photoResolution) videoRes=\(s.videoResolution) ev=\(s.ev) wb=\(s.whiteBalance) bitrate=\(s.bitrate)")
        try? cam.closeCommunication()

    case "dump":
        guard args.count >= 2 else { print(usage); exit(1) }
        let url = URL(fileURLWithPath: args[1])
        let secs = args.count >= 3 ? Double(args[2]) ?? 10 : 10
        let res: CV60Camera.LiveResolution = args.contains("1920") ? .r1920 : .r1280
        if let s = try? cam.settings() {
            do { try cam.writeSettings(s) } catch { print("write settings (non-fatal): \(error)") }
        }
        print("starting live view \(res)…")
        try cam.beginStreaming(res)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let fh = try FileHandle(forWritingTo: url)
        defer { try? fh.close() }
        let start = Date()
        var frames = 0, bytes = 0, busy = 0
        while Date().timeIntervalSince(start) < secs && !stopRequested {
            guard let f = try cam.nextFrame() else {
                busy += 1
                Thread.sleep(forTimeInterval: 0.005)
                continue
            }
            if frames == 0 {
                print("first frame: \(f.width)x\(f.height), \(f.h264.count) bytes, head: \(hex(f.h264.prefix(24)))")
            }
            fh.write(Data(f.h264))
            frames += 1
            bytes += f.h264.count
            if frames % 30 == 0 {
                let t = Date().timeIntervalSince(start)
                print(String(format: "%d frames  %.1f fps  %.2f Mbit/s  thermal=%d", frames, Double(frames) / t, Double(bytes) * 8 / t / 1e6, f.thermal))
            }
        }
        print("stopping… (\(frames) frames, \(busy) busy polls) -> \(url.path)")
        try? cam.stopLiveView()
        try? cam.closeCommunication()

    case "photo":
        guard args.count >= 2 else { print(usage); exit(1) }
        let orient = args.count >= 3 ? UInt8(args[2]) ?? 0 : 0
        if let s = try? cam.settings() {
            print("photo resolution setting: \(s.photoResolution)")
            do { try cam.writeSettings(s) } catch { print("write settings (non-fatal): \(error)") }
        }
        try cam.beginStreaming(.r1280)
        for _ in 0..<15 { _ = try cam.nextFrame() } // let exposure settle
        let t0 = Date()
        let jpeg = try cam.capturePhoto(orientation: orient) { print($0) }
        try Data(jpeg).write(to: URL(fileURLWithPath: args[1]))
        print(String(format: "saved %@ (%d KB) in %.1fs", args[1], jpeg.count / 1024, Date().timeIntervalSince(t0)))
        if let f = try cam.nextFrame() { print("live view still running (\(f.width)x\(f.height))") }
        try? cam.stopLiveView()
        try? cam.closeCommunication()

    case "raw":
        guard args.count >= 3, let b1 = UInt8(args[1], radix: 16), let b2 = UInt8(args[2], radix: 16) else {
            print(usage); exit(1)
        }
        let r = try cam.rawRead(b1, b2)
        print("\(r.count) bytes")
        for off in stride(from: 0, to: min(r.count, 512), by: 16) {
            let row = r[off..<min(off + 16, r.count)]
            let ascii = row.map { (0x20...0x7E).contains($0) ? String(UnicodeScalar($0)) : "." }.joined()
            print(String(format: "%04x  ", off) + hex(row).padding(toLength: 48, withPad: " ", startingAt: 0) + "  " + ascii)
        }

    case "off":
        try cam.powerOff()
        print("power off sent")

    default:
        print(usage)
        exit(1)
    }
}

do {
    try run()
} catch {
    print("error: \(error)")
    exit(2)
}
