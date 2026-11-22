// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Studio",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0"),
        // In-app updates (Studio → Check for Updates…), fed by appcast.xml on the latest GitHub release.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "Studio",
            dependencies: ["SwiftTerm", .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Studio",
            // Sparkle.framework sits in Studio.app/Contents/Frameworks (build-app.sh copies it there).
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        // MCP server injected into every Claude session Studio starts; forwards tool calls to the app.
        .executableTarget(
            name: "studio-mcp",
            path: "Sources/StudioMCP"
        ),
        // A tab's terminal for a session on a worker (a machine running studio-worker): WebSocket ⇄ the tab's pty.
        .executableTarget(
            name: "studio-attach",
            path: "Sources/StudioAttach"
        ),
    ]
)
