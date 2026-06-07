// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DriveForge",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "DriveForge", targets: ["macos-installer-usb-builder"])
    ],
    targets: [
        .executableTarget(
            name: "macos-installer-usb-builder"
        )
    ]
)
