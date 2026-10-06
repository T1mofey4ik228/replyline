// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClientReplyCompanion",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "ClientReplyCompanion", targets: ["ClientReplyCompanion"])],
    targets: [
        .executableTarget(
            name: "ClientReplyCompanion",
            path: "Sources/ClientReplyCompanion"
        )
    ]
)
