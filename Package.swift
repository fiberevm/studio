// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AICode",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0"),
    ],
    targets: [
        .executableTarget(
            name: "AICode",
            dependencies: ["SwiftTerm"],
            path: "Sources/AICode"
        ),
    ]
)
