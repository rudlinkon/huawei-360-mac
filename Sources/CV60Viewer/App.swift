import AppKit
import CV60Kit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare SwiftPM executable (no .app bundle).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct CV60ViewerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var session = CameraSession()

    var body: some Scene {
        WindowGroup("Huawei 360 Camera", id: ContentView.windowID) {
            ContentView()
                .environmentObject(session)
                .frame(minWidth: 800, minHeight: 500)
        }
        Window(WebcamView.title, id: WebcamView.windowID) {
            WebcamView()
                .environmentObject(session)
        }
        .defaultSize(width: 1280, height: 720)
    }
}

struct ContentView: View {
    static let windowID = "main"
    @EnvironmentObject private var session: CameraSession
    @Environment(\.openWindow) private var openWindow
    @State private var mode: ViewMode = .perspective
    @State private var resolution: CV60Camera.LiveResolution = .r1920
    @State private var showLog = false
    @AppStorage("mount") private var mount: MountOrientation = .sideways

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                PanoramaView(store: session.store, mode: mode, mount: mount)
                if !session.running {
                    VStack(spacing: 8) {
                        Image(systemName: "camera.aperture").font(.system(size: 48))
                        Text(session.status).multilineTextAlignment(.center)
                        Text("Plug in the Huawei EnVizion 360 (CV60), then press Connect.")
                            .foregroundStyle(.secondary)
                    }
                    .padding(24)
                    .foregroundStyle(.white)
                }
            }
            .background(Color.black)
            .onChange(of: mount) { session.mount = $0 }
            .onAppear {
                session.mount = mount
                session.handleLaunchArguments(resolution: resolution) { openWindow(id: $0) }
                let a = CommandLine.arguments
                if let i = a.firstIndex(of: "--mode"), i + 1 < a.count, let m = Int32(a[i + 1]), let vm = ViewMode(rawValue: m) {
                    mode = vm
                }
            }

            HStack(spacing: 12) {
                Button(session.running ? "Disconnect" : "Connect") {
                    session.running ? session.stop() : session.start(resolution: resolution)
                }
                .keyboardShortcut(.return, modifiers: [])

                Picker("", selection: $resolution) {
                    ForEach(CV60Camera.LiveResolution.allCases, id: \.self) { Text($0.description).tag($0) }
                }
                .frame(width: 120)
                .disabled(session.running)

                Picker("", selection: $mode) {
                    ForEach(ViewMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 260)

                Picker("", selection: $mount) {
                    ForEach(MountOrientation.allCases) { Text($0.title).tag($0) }
                }
                .frame(width: 170)
                .help("How the camera is attached — fixes a tilted horizon")

                Button {
                    session.toggleRecording()
                } label: {
                    Label(session.isRecording ? "Stop" : "Record", systemImage: session.isRecording ? "stop.circle.fill" : "record.circle")
                }
                .tint(session.isRecording ? .red : nil)
                .disabled(!session.running)

                Button { session.takePhoto() } label: {
                    Label(session.photoProgress ?? "Photo", systemImage: "camera.fill")
                }
                .disabled(!session.running || session.photoProgress != nil)
                .help("Full-resolution photo taken by the camera")

                Button { session.snapshot() } label: { Label("Snapshot", systemImage: "camera.viewfinder") }
                    .disabled(!session.running)
                    .help("Quick grab of the live-view frame")

                Button { openWindow(id: WebcamView.windowID) } label: { Label("Webcam", systemImage: "video") }
                    .help("Webcam preview — aim the view that OBS receives via Syphon")

                Spacer()

                Text(statusLine).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Button { showLog.toggle() } label: { Image(systemName: "list.bullet.rectangle") }
                    .popover(isPresented: $showLog) {
                        ScrollView {
                            Text(session.log.joined(separator: "\n"))
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding()
                        }
                        .frame(width: 560, height: 360)
                    }
            }
            .padding(10)
        }
    }

    private var statusLine: String {
        guard session.running else { return session.status }
        var s = String(format: "%@  %.0f fps  %.1f Mbit/s", session.status, session.fps, session.bitrate)
        if !session.firmware.isEmpty { s += "  fw \(session.firmware)" }
        switch session.thermal {
        case 1: s += "  ⚠︎ hot"
        case 2: s += "  ⚠︎ overheat"
        case 3: s += "  ⚠︎ cold"
        default: break
        }
        return s
    }
}
