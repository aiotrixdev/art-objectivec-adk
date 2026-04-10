// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ADK",
    platforms: [
        .iOS(.v15)
    ],
    products: [
        .library(name: "ADK", targets: ["ADK"])
    ],
    targets: [
        .target(
            name: "ADK",
            path: "Sources/ADK",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("Auth"),
                .headerSearchPath("Config"),
                .headerSearchPath("CRDT"),
                .headerSearchPath("Crypto"),
                .headerSearchPath("Crypto/TweetNaCl"),
                .headerSearchPath("Helper"),
                .headerSearchPath("Types"),
                .headerSearchPath("WebSocket")
            ]
        )
    ],
    cLanguageStandard: .gnu17
)
