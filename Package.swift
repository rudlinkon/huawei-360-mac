// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CV60Mac",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "cv60", targets: ["cv60"]),
        .executable(name: "CV60Viewer", targets: ["CV60Viewer"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"), // auto-update
    ],
    targets: [
        .systemLibrary(name: "CLibUSB", path: "Sources/CLibUSB"),
        .target(
            name: "CV60Kit",
            dependencies: ["CLibUSB"],
            linkerSettings: [.unsafeFlags(["-L/opt/homebrew/lib"])]
        ),
        .executableTarget(name: "cv60", dependencies: ["CV60Kit"]),
        .binaryTarget(name: "Syphon", path: "Vendor/Syphon.xcframework"), // scripts/build-syphon.sh
        .executableTarget(
            name: "CV60Viewer",
            dependencies: ["CV60Kit", "Syphon", .product(name: "Sparkle", package: "Sparkle")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
    ]
)
