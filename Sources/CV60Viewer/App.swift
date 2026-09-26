import AppKit
import CV60Kit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare SwiftPM executable (no .app bundle).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        Notifier.shared.setUp()
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
                .frame(minWidth: 560, minHeight: 360)
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

            statusBar
        }
        .hideToolbarTitle()
        // Toolbar items that don't fit a narrow window collapse into the » overflow menu.
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    session.running ? session.stop() : session.start(resolution: resolution)
                } label: {
                    Label(session.running ? "Disconnect" : "Connect", systemImage: session.running ? "stop.fill" : "play.fill")
                }
                .labelStyle(.titleAndIcon)
                .keyboardShortcut(.return, modifiers: [])
                .help(session.running ? "Stop streaming and release the camera" : "Connect to the camera and start live view")

                // Menu (not a bare Picker) so the toolbar always shows the current value.
                Menu {
                    Picker("Resolution", selection: $resolution) {
                        ForEach(CV60Camera.LiveResolution.allCases, id: \.self) { Text($0.description).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Text(resolution.description)
                }
                .fixedSize()
                .disabled(session.running)
                .help("Live-view resolution (change while disconnected)")
            }

            ToolbarItem(placement: .principal) {
                Picker("View", selection: $mode) {
                    ForEach(ViewMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("Flat panorama, 360° perspective or little planet")
            }

            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Picker("Mount", selection: $mount) {
                        ForEach(MountOrientation.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label(mount.title, systemImage: "rotate.3d")
                        .labelStyle(.titleAndIcon)
                }
                .fixedSize()
                .help("How the camera is attached — fixes a tilted horizon")

                Button { session.toggleRecording() } label: {
                    Label(session.isRecording ? "Stop Recording" : "Record",
                          systemImage: session.isRecording ? "stop.circle.fill" : "record.circle")
                }
                .foregroundStyle(session.isRecording ? .red : .primary)
                .disabled(!session.running)
                .help(session.isRecording ? "Stop recording" : "Record a level 360° MP4 to ~/Movies/CV60")

                Button { session.takePhoto() } label: { Label("Photo", systemImage: "camera") }
                    .disabled(!session.running || session.photoProgress != nil)
                    .help("Full-resolution 5376×2688 photo taken by the camera")

                Button { session.snapshot() } label: { Label("Snapshot", systemImage: "camera.viewfinder") }
                    .disabled(!session.running)
                    .help("Quick grab of the live-view frame")

                Button { openWindow(id: WebcamView.windowID) } label: { Label("Webcam", systemImage: "video") }
                    .help("Webcam preview — aim the view that OBS receives via Syphon")
            }
        }
    }

    /// One-line status strip; long text truncates instead of wrapping.
    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusLine)
                .lineLimit(1)
                .truncationMode(.tail)
            if let warning = thermalWarning {
                Label(warning, systemImage: "thermometer.high")
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .fixedSize()
            }
            Spacer(minLength: 8)
            Button { showLog.toggle() } label: { Image(systemName: "list.bullet.rectangle") }
                .buttonStyle(.borderless)
                .help("Show log")
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
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.bar)
    }

    private var statusColor: Color {
        if session.isRecording { return .red }
        if session.running { return .green }
        return session.status.hasPrefix("Error") || session.status.contains("overheated") ? .orange : .gray
    }

    private var thermalWarning: String? {
        switch session.thermal {
        case 1: return "Hot"
        case 2: return "Overheat"
        case 3: return "Cold"
        default: return nil
        }
    }

    private var statusLine: String {
        guard session.running else { return session.status }
        var parts = [session.status, String(format: "%.0f fps", session.fps), String(format: "%.1f Mbit/s", session.bitrate)]
        if session.isRecording { parts.insert("● REC", at: 0) }
        if let p = session.photoProgress { parts.insert("Photo: \(p)", at: 0) }
        if !session.firmware.isEmpty { parts.append("fw \(session.firmware)") }
        return parts.joined(separator: "  ·  ")
    }
}

private extension View {
    /// The window title takes a third of the toolbar; drop it so the controls fit (the Window menu keeps the name).
    @ViewBuilder func hideToolbarTitle() -> some View {
        if #available(macOS 15, *) { toolbar(removing: .title) } else { self }
    }
}
