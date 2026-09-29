// swift-tools-version: 6.2
import PackageDescription

let v5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "Vedetta",
    defaultLocalization: "en",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "Vedetta", targets: ["Vedetta"]),
        .executable(name: "vedetta-probe", targets: ["vedetta-probe"]),
    ],
    targets: [
        .target(name: "VedettaL10n", swiftSettings: v5),
        .target(name: "RTSPKit", dependencies: ["VedettaL10n"], swiftSettings: v5),
        .target(name: "MediaKit", dependencies: ["RTSPKit", "VedettaL10n"], swiftSettings: v5),
        .target(name: "NetKit", dependencies: ["VedettaL10n"], swiftSettings: v5),
        .target(name: "ONVIFKit", dependencies: ["NetKit", "VedettaL10n"], swiftSettings: v5),
        .target(name: "VigiKit", dependencies: ["NetKit", "VedettaL10n"], swiftSettings: v5),
        .target(name: "VedettaCore", dependencies: ["RTSPKit", "MediaKit", "ONVIFKit", "VigiKit", "NetKit", "VedettaL10n"], swiftSettings: v5),
        .executableTarget(name: "Vedetta", dependencies: ["VedettaCore", "VedettaL10n"], swiftSettings: v5),
        .executableTarget(name: "vedetta-probe", dependencies: ["VedettaCore", "RTSPKit", "MediaKit", "ONVIFKit", "VigiKit", "NetKit"], swiftSettings: v5),
        .testTarget(name: "RTSPKitTests", dependencies: ["RTSPKit"], swiftSettings: v5),
        .testTarget(name: "VigiKitTests", dependencies: ["VigiKit"], swiftSettings: v5),
        .testTarget(name: "ONVIFKitTests", dependencies: ["ONVIFKit"], swiftSettings: v5),
        .testTarget(name: "MediaKitTests", dependencies: ["MediaKit", "RTSPKit"], swiftSettings: v5),
        .testTarget(name: "VedettaCoreTests", dependencies: ["VedettaCore", "ONVIFKit"], swiftSettings: v5),
    ]
)
