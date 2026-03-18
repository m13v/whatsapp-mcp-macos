// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "whatsapp-mcp",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0"),
        .package(url: "https://github.com/mediar-ai/MacosUseSDK.git", branch: "main")
    ],
    targets: [
        .executableTarget(
            name: "whatsapp-mcp",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "MacosUseSDK", package: "MacosUseSDK")
            ],
            path: "Sources/WhatsAppMCP"
        )
    ]
)
