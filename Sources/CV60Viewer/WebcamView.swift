import AppKit
import SwiftUI

/// Clean 16:9 output (no title bar, no controls) meant to be captured by OBS
/// and published through "OBS Virtual Camera" to Zoom / Meet / Teams.
struct WebcamView: View {
    static let windowID = "webcam"
    static let title = "Huawei 360 Webcam"

    @EnvironmentObject private var session: CameraSession
    @AppStorage("webcamMode") private var modeRaw = Int(ViewMode.perspective.rawValue)

    private var mode: Binding<ViewMode> {
        Binding(get: { ViewMode(rawValue: Int32(modeRaw)) ?? .perspective }, set: { modeRaw = Int($0.rawValue) })
    }
    @AppStorage("mount") private var mount: MountOrientation = .sideways

    var body: some View {
        PanoramaView(store: session.store, mode: mode.wrappedValue, mount: mount, drivesItself: true)
            .aspectRatio(16 / 9, contentMode: .fit)
            .frame(minWidth: 480, minHeight: 270)
            .background(Color.black)
            .ignoresSafeArea()
            .background(ChromelessWindow())
            .contextMenu {
                Picker("View", selection: mode) {
                    ForEach(ViewMode.allCases) { Text($0.title).tag($0) }
                }
                Menu("Size") {
                    ForEach([(640, 360), (1280, 720), (1920, 1080)], id: \.0) { w, h in
                        Button("\(w)×\(h)") { resize(w, h) }
                    }
                }
                Divider()
                Text("Drag: aim · Scroll: zoom · Double-click: reset · ⌥-drag: move window")
                Button("Close") { NSApp.windows.first { $0.title == Self.title }?.close() }
            }
    }

    private func resize(_ w: Int, _ h: Int) {
        guard let win = NSApp.windows.first(where: { $0.title == Self.title }) else { return }
        // Window points; on a Retina screen OBS receives 2x pixels.
        let scale = win.backingScaleFactor
        win.setContentSize(NSSize(width: CGFloat(w) / scale, height: CGFloat(h) / scale))
    }
}

/// Hides the title bar and traffic-light buttons and locks the window to 16:9.
private struct ChromelessWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            guard let w = v.window else { return }
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.styleMask.insert(.fullSizeContentView)
            for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                w.standardWindowButton(b)?.isHidden = true
            }
            w.contentAspectRatio = NSSize(width: 16, height: 9)
            w.backgroundColor = .black
            w.hasShadow = false
        }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
