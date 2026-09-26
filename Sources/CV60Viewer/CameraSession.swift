import AppKit
import CoreImage
import CoreMedia
import CV60Kit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Owns the USB thread: connect → open communication → live view → fetch/decode frames.
final class CameraSession: ObservableObject {
    @Published var status = "Disconnected"
    @Published var running = false
    @Published var firmware = ""
    @Published var fps = 0.0
    @Published var bitrate = 0.0
    @Published var thermal: UInt8 = 0
    @Published var recordingURL: URL?
    @Published var log: [String] = []
    @Published var photoProgress: String?

    let store = FrameStore()
    /// Webcam feed for OBS (Syphon Client source → OBS Virtual Camera).
    let syphon: SyphonOutput

    init() {
        syphon = SyphonOutput(store: store)
        let d = UserDefaults.standard
        if let m = ViewMode(rawValue: Int32(d.object(forKey: "webcamMode") as? Int ?? 1)) { syphon.mode = m }
        if let h = d.object(forKey: "webcamHeight") as? Int { syphon.height = h }
        syphon.enabled = d.object(forKey: "syphonEnabled") as? Bool ?? true
    }
    private var thread: Thread?
    private var stopFlag = false
    private let recLock = NSLock()
    private var recorder: CorrectedRecorder?
    private var wantRecording = false
    private let corrector = EquirectCorrector()
    private var _mount: MountOrientation = .sideways
    private var photoRequested = false
    private var activity: NSObjectProtocol?

    /// Keep macOS from throttling (App Nap) while streaming — the webcam window may be in the background.
    private func setBusy(_ busy: Bool) {
        if busy, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical],
                                                             reason: "Streaming 360 camera")
        } else if !busy, let a = activity {
            ProcessInfo.processInfo.endActivity(a)
            activity = nil
        }
    }

    /// Physical orientation; recordings and snapshots are re-projected to be level.
    var mount: MountOrientation {
        get { recLock.lock(); defer { recLock.unlock() }; return _mount }
        set { recLock.lock(); _mount = newValue; recLock.unlock(); syphon.mount = newValue }
    }

    private func ui(_ block: @escaping () -> Void) { DispatchQueue.main.async(execute: block) }

    private func addLog(_ s: String) {
        NSLog("[CV60] %@", s)
        ui { self.log.append(s); if self.log.count > 200 { self.log.removeFirst(self.log.count - 200) } }
    }

    func start(resolution: CV60Camera.LiveResolution) {
        guard thread == nil else { return }
        stopFlag = false
        running = true
        setBusy(true)
        let t = Thread { [weak self] in self?.run(resolution) }
        t.name = "CV60-USB"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    func stop() {
        stopFlag = true
    }

    private var launchHandled = false

    /// Applies launch flags once, from whichever window appears first (macOS may restore only one):
    /// --play <dump.h264> replay a `cv60 dump` file · --connect start streaming · --webcam open the OBS window.
    func handleLaunchArguments(resolution: CV60Camera.LiveResolution = .r1920, open: (String) -> Void) {
        guard !launchHandled else { return }
        launchHandled = true
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--play"), i + 1 < a.count {
            play(file: URL(fileURLWithPath: a[i + 1]))
        } else if a.contains("--connect") && !running {
            start(resolution: resolution)
        }
        if a.contains("--webcam") { open(WebcamView.windowID) }
    }

    /// Replays a raw H.264 dump (from `cv60 dump`) in a loop — for testing without the camera.
    func play(file: URL) {
        guard thread == nil else { return }
        stopFlag = false
        running = true
        let t = Thread { [weak self] in
            guard let self else { return }
            defer { self.ui { self.running = false; self.thread = nil; self.fps = 0 } }
            guard let data = try? Data(contentsOf: file) else {
                self.ui { self.status = "Cannot read \(file.path)" }
                return
            }
            let units = H264Decoder.accessUnits([UInt8](data))
            self.ui { self.status = "Playing \(file.lastPathComponent)"; self.fps = 30 }
            let decoder = H264Decoder()
            var i = 0
            while !self.stopFlag && !units.isEmpty {
                let pts = CMClockGetTime(CMClockGetHostTimeClock())
                if let sb = decoder.sampleBuffer(annexB: units[i % units.count], pts: pts) {
                    if let pb = decoder.decode(sb) {
                        self.store.set(pb)
                        self.record(pb, pts: pts)
                    }
                }
                i += 1
                Thread.sleep(forTimeInterval: 1.0 / 30)
            }
            decoder.invalidate()
            self.ui { self.status = "Disconnected" }
        }
        thread = t
        t.start()
    }

    private func run(_ res: CV60Camera.LiveResolution) {
        defer {
            ui { self.running = false; self.thread = nil; self.fps = 0; self.setBusy(false) }
            finishRecording()
        }
        do {
            ui { self.status = "Connecting…" }
            let cam = try CV60Camera()
            cam.log = { [weak self] in self?.addLog($0) }
            try cam.connect()
            defer { cam.disconnect() }

            ui { self.status = "Opening communication…" }
            try cam.openCommunication()
            let fw = try cam.firmwareVersion()
            addLog("firmware \(fw)")
            ui { self.firmware = fw }
            if let s = try? cam.settings() {
                do { try cam.writeSettings(s) } catch { addLog("write settings (non-fatal): \(error)") }
            }

            ui { self.status = "Starting live view \(res)…" }
            try cam.beginStreaming(res)
            ui { self.status = "Streaming \(res)" }

            let decoder = H264Decoder()
            var frames = 0, bytes = 0
            var windowStart = Date()
            var thermalMonitor = ThermalMonitor()
            var overheated = false
            while !stopFlag {
                if consumePhotoRequest() { capturePhoto(cam) }
                guard let f = try cam.nextFrame() else {
                    Thread.sleep(forTimeInterval: 0.004)
                    continue
                }
                let pts = CMClockGetTime(CMClockGetHostTimeClock())
                if let sb = decoder.sampleBuffer(annexB: f.h264, pts: pts) {
                    if let pb = decoder.decode(sb) {
                        store.set(pb)
                        record(pb, pts: pts)
                    }
                }
                if let level = thermalMonitor.update(f.thermal) {
                    addLog("thermal level \(level.rawValue) (\(level))")
                    ui { self.thermal = level.rawValue }
                    if let a = level.alert { Notifier.shared.post(title: a.title, body: a.body) }
                    if level == .overheat { overheated = true; break }
                }
                frames += 1
                bytes += f.h264.count
                let dt = Date().timeIntervalSince(windowStart)
                if dt >= 1 {
                    let fps = Double(frames) / dt, mbps = Double(bytes) * 8 / dt / 1e6
                    ui { self.fps = fps; self.bitrate = mbps }
                    frames = 0; bytes = 0; windowStart = Date()
                }
            }
            ui { self.status = "Stopping…" }
            try? cam.stopLiveView()
            decoder.invalidate()
            if overheated {
                // Same as the Android app: power the camera off so it can cool down.
                do { try cam.powerOff(); addLog("camera powered off (overheat)") } catch { addLog("power off failed: \(error)") }
                ui { self.status = "Camera overheated — powered off" }
            } else {
                try? cam.closeCommunication()
                ui { self.status = "Disconnected" }
            }
        } catch {
            addLog("error: \(error)")
            ui { self.status = "Error: \(error)" }
        }
    }

    // MARK: - Recording

    var isRecording: Bool { recordingURL != nil }

    func toggleRecording() {
        recLock.lock()
        wantRecording.toggle()
        let finishing = !wantRecording
        recLock.unlock()
        if finishing { finishRecording() }
    }

    private func record(_ pb: CVPixelBuffer, pts: CMTime) {
        recLock.lock(); defer { recLock.unlock() }
        guard wantRecording else { return }
        guard let level = corrector?.correct(pb, mount: _mount) else { return }
        if recorder == nil {
            let url = Self.outputURL(folder: .moviesDirectory, ext: "mp4")
            do {
                recorder = try CorrectedRecorder(url: url, width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb))
                ui { self.recordingURL = url }
                addLog("recording → \(url.path)")
            } catch {
                addLog("recorder: \(error)")
                wantRecording = false
                return
            }
        }
        recorder?.append(level, pts: pts)
    }

    private func finishRecording() {
        recLock.lock()
        let r = recorder
        recorder = nil
        wantRecording = false
        recLock.unlock()
        guard let r else { ui { self.recordingURL = nil }; return }
        r.finish { [weak self] in
            Self.giveToSudoUser(r.url)
            self?.addLog("saved \(r.url.path)")
            self?.ui { self?.recordingURL = nil }
        }
    }

    // MARK: - Full-resolution photo (taken by the camera)

    func takePhoto() {
        recLock.lock(); photoRequested = true; recLock.unlock()
        photoProgress = "Waiting…"
    }

    private func consumePhotoRequest() -> Bool {
        recLock.lock(); defer { recLock.unlock() }
        let r = photoRequested
        photoRequested = false
        return r
    }

    /// Runs on the USB thread; live view pauses while the camera captures and transfers the JPEG.
    private func capturePhoto(_ cam: CV60Camera) {
        do {
            let jpeg = try cam.capturePhoto(orientation: mount.photoOrientationCode) { [weak self] p in
                self?.ui { self?.photoProgress = p }
            }
            let url = Self.outputURL(folder: .picturesDirectory, ext: "jpg")
            try Data(PhotoFixer.process(jpeg, mount: mount, corrector: corrector)).write(to: url)
            Self.giveToSudoUser(url)
            // Keep the untouched camera file too, in case the mount setting was wrong.
            let originals = url.deletingLastPathComponent().appendingPathComponent("Originals", isDirectory: true)
            try? FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
            let original = originals.appendingPathComponent(url.lastPathComponent)
            try? Data(jpeg).write(to: original)
            Self.giveToSudoUser(originals)
            Self.giveToSudoUser(original)
            addLog("photo (\(jpeg.count / 1024) KB) → \(url.path)")
            ui { self.photoProgress = nil; NSWorkspace.shared.activateFileViewerSelecting([url]) }
        } catch {
            addLog("photo failed: \(error)")
            ui { self.photoProgress = nil }
        }
    }

    // MARK: - Snapshot

    func snapshot() {
        guard let raw = store.get(), let pb = corrector?.correct(raw, mount: mount) else { return }
        let ci = CIImage(cvPixelBuffer: pb)
        guard let cg = CIContext().createCGImage(ci, from: ci.extent) else { return }
        let url = Self.outputURL(folder: .picturesDirectory, ext: "jpg")
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        if CGImageDestinationFinalize(dest) {
            Self.giveToSudoUser(url)
            addLog("snapshot → \(url.path)")
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    /// ~/Movies/CV60 or ~/Pictures/CV60 of the real user, even when launched with sudo.
    static func outputURL(folder: FileManager.SearchPathDirectory, ext: String) -> URL {
        let env = ProcessInfo.processInfo.environment
        let home = env["SUDO_USER"].flatMap { FileManager.default.homeDirectory(forUser: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        let base = home.appendingPathComponent(folder == .moviesDirectory ? "Movies" : "Pictures")
            .appendingPathComponent("CV60", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        giveToSudoUser(base)
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        return base.appendingPathComponent("CV60_\(f.string(from: Date())).\(ext)")
    }

    /// Files created while running as root are handed back to the invoking user.
    static func giveToSudoUser(_ url: URL) {
        let env = ProcessInfo.processInfo.environment
        guard let uid = env["SUDO_UID"].flatMap(UInt32.init), let gid = env["SUDO_GID"].flatMap(UInt32.init) else { return }
        chown(url.path, uid, gid)
    }
}
