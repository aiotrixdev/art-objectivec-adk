// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ArtAdk",
    platforms: [
        .iOS(.v15)
    ],
    products: [
        .library(name: "ArtAdkObjC", targets: ["ArtAdkObjC"])
    ],
    targets: [
        .target(
            name: "ArtAdkObjC",
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
