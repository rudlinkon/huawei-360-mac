import SwiftUI

/// Preview + aiming window for the webcam feed. What it shows is what the
/// "360 Webcam" Syphon server sends to OBS (the window itself does not need to stay open).
struct WebcamView: View {
    static let windowID = "webcam"
    static let title = "Huawei 360 Webcam"

    @EnvironmentObject private var session: CameraSession
    @Environment(\.openWindow) private var openWindow
    @AppStorage("webcamMode") private var modeRaw = Int(ViewMode.perspective.rawValue)
    @AppStorage("webcamHeight") private var outputHeight = 1080
    @AppStorage("syphonEnabled") private var syphonEnabled = true
    @AppStorage("mount") private var mount: MountOrientation = .sideways

    private var mode: Binding<ViewMode> {
        Binding(get: { ViewMode(rawValue: Int32(modeRaw)) ?? .perspective }, set: { modeRaw = Int($0.rawValue) })
    }

    var body: some View {
        PanoramaView(store: session.store, mode: mode.wrappedValue, mount: mount, angles: session.syphon.angles)
            .aspectRatio(16 / 9, contentMode: .fit)
            .frame(minWidth: 480, minHeight: 270)
            .background(Color.black)
            .onAppear {
                session.mount = mount
                session.handleLaunchArguments { openWindow(id: $0) }
            }
            .onChange(of: mount) { session.mount = $0 }
            .onChange(of: modeRaw) { _ in session.syphon.mode = mode.wrappedValue }
            .onChange(of: outputHeight) { session.syphon.height = $0 }
            .onChange(of: syphonEnabled) { session.syphon.enabled = $0 }
            .contextMenu {
                Button(session.running ? "Disconnect Camera" : "Connect Camera") {
                    session.running ? session.stop() : session.start(resolution: .r1920)
                }
                Button("Show Controls") { openWindow(id: ContentView.windowID) }
                Divider()
                Picker("View", selection: mode) {
                    ForEach(ViewMode.allCases) { Text($0.title).tag($0) }
                }
                Picker("Output size", selection: $outputHeight) {
                    Text("1280×720").tag(720)
                    Text("1920×1080").tag(1080)
                }
                Toggle("Send to OBS (Syphon “\(SyphonOutput.serverName)”)", isOn: $syphonEnabled)
                Divider()
                Text("Drag: aim · Scroll: zoom · Double-click: reset")
            }
    }
}
