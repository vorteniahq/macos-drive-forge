// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "FlashForge",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "FlashForge", targets: ["macos-installer-usb-builder"])
    ],
    targets: [
        .executableTarget(
            name: "macos-installer-usb-builder"
        )
    ]
)
