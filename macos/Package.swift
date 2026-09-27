// swift-tools-version:6.0
import PackageDescription

// Swift 5 language mode: the controller and renderers are main-actor bound and
// hand work to background queues explicitly; strict Swift 6 checking adds noise
// without catching anything those boundaries do not already guarantee.
let swift5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "Cinmux",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "cinmux", targets: ["cinmux"]),
        // Not "Cinmux": executables share one directory and APFS is case-insensitive.
        .executable(name: "CinmuxApp", targets: ["CinmuxApp"]),
    ],
    dependencies: [
        // 1.20 is the newest line whose manifest builds with Swift 6.0.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", .upToNextMinor(from: "1.20.0")),
    ],
    targets: [
        .target(name: "CinmuxCore", swiftSettings: swift5),
        .target(name: "CinmuxTUI", dependencies: ["CinmuxCore", "SwiftTerm"], swiftSettings: swift5),
        .executableTarget(name: "cinmux", dependencies: ["CinmuxCore", "CinmuxTUI"], swiftSettings: swift5),
        .executableTarget(name: "CinmuxApp", dependencies: ["CinmuxCore", "SwiftTerm"], swiftSettings: swift5),
        .testTarget(name: "CinmuxCoreTests", dependencies: ["CinmuxCore"], swiftSettings: swift5),
        .testTarget(name: "CinmuxTUITests", dependencies: ["CinmuxTUI"], swiftSettings: swift5),
    ]
)
