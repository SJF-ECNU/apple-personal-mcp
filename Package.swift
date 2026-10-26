// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "ApplePersonalMCP",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "apple-personal-mcp", targets: ["MCPBridge"]),
        .executable(name: "ApplePersonalMCPHost", targets: ["NativeHost"]),
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.1"),
        .package(url: "https://github.com/mp-consulting/apple-mail-mcp.git", revision: "4255bef5da220bcad96f4a0a3ea2df98856b4972"),
        .package(url: "https://github.com/mattt/Madrid.git", .upToNextMinor(from: "0.4.0")),
    ],
    targets: [
        .target(name: "PersonalCore", dependencies: [.product(name: "MailStore", package: "apple-mail-mcp"), .product(name: "TypedStream", package: "Madrid")], linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "MCPBridge", dependencies: ["PersonalCore", .product(name: "MCP", package: "swift-sdk")]),
        .executableTarget(name: "NativeHost", dependencies: ["PersonalCore"]),
        .testTarget(name: "PersonalCoreTests", dependencies: ["PersonalCore"], resources: [.copy("Fixtures")]),
    ],
    swiftLanguageModes: [.v5]
)
