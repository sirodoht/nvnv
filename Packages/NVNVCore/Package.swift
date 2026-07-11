// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "NVNVCorePackage",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "NVNVCore", targets: ["NVNVCore"]),
        .executable(name: "nvnv-probes", targets: ["NVNVProbes"]),
    ],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(name: "NVNVCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "NVNVProbes", dependencies: ["NVNVCore"]),
        .testTarget(name: "NVNVCoreTests", dependencies: ["NVNVCore", "CSQLite"]),
    ]
)
