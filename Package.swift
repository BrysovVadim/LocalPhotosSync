// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LocalPhotosSync",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "LocalPhotosSyncUSB", targets: ["LocalPhotosSyncUSB"])],
    targets: [
        .executableTarget(name: "LocalPhotosSyncUSB"),
        .testTarget(name: "LocalPhotosSyncUSBTests", dependencies: ["LocalPhotosSyncUSB"]),
    ],
    swiftLanguageModes: [.v5]
)
