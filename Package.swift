// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "foldcast",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "CVirtualDisplay",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "foldcast",
            dependencies: ["CVirtualDisplay"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreImage"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("Network")
            ]
        )
    ]
)
