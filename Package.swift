// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Studio",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0"),
    ],
    targets: [
        .executableTarget(
            name: "Studio",
            dependencies: ["SwiftTerm"],
            path: "Sources/Studio"
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
