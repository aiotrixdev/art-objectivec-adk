// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ArtAdk",
    platforms: [
        .iOS(.v15)
    ],
    products: [
        .library(name: "ArtAdk", targets: ["ArtAdk"])
    ],
    targets: [
        .target(
            name: "ArtAdk",
            path: "Sources/ADK",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("Auth"),
                .headerSearchPath("Config"),
                .headerSearchPath("CRDT"),
                .headerSearchPath("Crypto"),
                .headerSearchPath("Crypto/TweetNaCl"),
                .headerSearchPath("Types"),
                .headerSearchPath("WebSocket")
            ]
        )
    ],
    cLanguageStandard: .gnu17
)
