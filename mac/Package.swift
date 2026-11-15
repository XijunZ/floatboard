// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "FloatBoard",
    platforms: [.macOS(.v15)],
    targets: [
        // Offline, deterministic board logic: models, SQLite, store. Must never use networking.
        .target(
            name: "FloatBoardCore",
            path: "Sources/FloatBoardCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // Online connectors (filled in later); the only code allowed to talk to the network.
        .target(
            name: "FloatBoardConnectors",
            dependencies: ["FloatBoardCore"],
            path: "Sources/FloatBoardConnectors"
        ),
        .executableTarget(
            name: "FloatBoard",
            dependencies: ["FloatBoardCore", "FloatBoardConnectors"],
            path: "Sources/FloatBoard"
        ),
        .executableTarget(
            name: "FloatBoardChecks",
            dependencies: ["FloatBoardCore", "FloatBoardConnectors"],
            path: "Sources/FloatBoardChecks"
        ),
    ],
    swiftLanguageModes: [.v5]
)
