// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CV60Mac",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "cv60", targets: ["cv60"]),
        .executable(name: "CV60Viewer", targets: ["CV60Viewer"]),
    ],
    targets: [
        .systemLibrary(name: "CLibUSB", path: "Sources/CLibUSB"),
        .target(
            name: "CV60Kit",
            dependencies: ["CLibUSB"],
            linkerSettings: [.unsafeFlags(["-L/opt/homebrew/lib"])]
        ),
        .executableTarget(name: "cv60", dependencies: ["CV60Kit"]),
        .executableTarget(name: "CV60Viewer", dependencies: ["CV60Kit"]),
    ]
)
