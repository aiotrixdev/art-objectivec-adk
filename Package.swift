// swift-tools-version: 5.9
import PackageDescription

// Each class's header and implementation sit together in
// Sources/ArtAdk/include/ArtAdk/<Folder>/. Every folder is searchable, so
// sources can use quoted imports. include/module.modulemap keeps the
// internal headers out of the ArtAdk module.
let sourceFolders = [
    "Agentic", "Auth", "Config", "CRDT", "Crypto", "Crypto/TweetNaCl",
    "Storage", "Types", "Util", "WebSocket",
]

let package = Package(
    name: "ArtAdk",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
    ],
    products: [
        .library(name: "ArtAdkObjC", targets: ["ArtAdk"]),
        .library(name: "ArtAdkNotifications", targets: ["ArtAdkNotifications"]),
    ],
    targets: [
        .target(
            name: "ArtAdk",
            path: "Sources/ArtAdk",
            publicHeadersPath: "include",
            cSettings: sourceFolders.map { .headerSearchPath("include/ArtAdk/\($0)") },
            linkerSettings: [.linkedFramework("UniformTypeIdentifiers")]
        ),
        .target(
            name: "ArtAdkNotifications",
            dependencies: ["ArtAdk"],
            path: "Sources/ArtAdkNotifications",
            publicHeadersPath: "include",
            cSettings: [.headerSearchPath("include/ArtAdkNotifications")]
        ),
    ],
    cLanguageStandard: .gnu17
)
