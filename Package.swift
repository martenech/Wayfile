// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Wayfile",
    platforms: [.macOS("14.4")],
    dependencies: [
        // Integrated terminal (MIT)
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", .upToNextMinor(from: "1.20.0")),
        // SFTP / SSH browser (MIT)
        .package(url: "https://github.com/orlandos-nl/Citadel.git", .upToNextMinor(from: "0.12.1")),
        // YAML viewer (MIT)
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "Wayfile",
            dependencies: [
                "ScriptBridge",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "Citadel", package: "Citadel"),
                .product(name: "Yams", package: "Yams"),
            ],
            path: "Sources/Wayfile",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // JavaScript engine shared by the app and the script runner.
        .target(
            name: "ScriptBridge",
            path: "Sources/ScriptBridge",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Runs one JavaScript script in a sandbox without file / network / process access (bundled next to the app).
        .executableTarget(
            name: "wayfile-script-runner",
            dependencies: ["ScriptBridge"],
            path: "Sources/ScriptRunner",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
